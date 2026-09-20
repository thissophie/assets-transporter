#if os(macOS)
import Foundation
import Observation

/// Persisted description of the one watched folder: which directory (held as
/// a security-scoped bookmark) feeds which project, with an optional camera
/// label applied to every queued clip.
nonisolated struct WatchConfig: Codable, Equatable {
    var bookmark: Data
    var projectPrefix: String
    var cameraLabel: String?
}

/// Owns the app's single watched folder (macOS): wraps `WatchedFolder` with
/// security-scope handling, persistence, and a human-readable status line.
///
/// - New stable videos are funnelled into `IntakeModel.enqueue` with the
///   configured project prefix + camera label. Staging copies the file while
///   this manager still holds the folder's security scope, so the child file
///   is readable even though its own `startAccessing…` call returns false.
/// - The config (bookmark + prefix + label) persists in UserDefaults under
///   `"watchConfig"` as JSON; `restoreIfConfigured` re-arms it at launch and
///   transparently refreshes a stale bookmark.
/// - At most one watcher exists at a time: `enable` and `move` tear down any
///   existing watch (releasing its scope) before starting the next.
@Observable @MainActor final class WatchManager {
    /// The config currently being watched. nil when not watching — including
    /// after a failed restore, where the *persisted* config is kept so a
    /// relaunch (or re-enable) can try again.
    private(set) var activeConfig: WatchConfig?
    /// Filesystem path of the watched folder, for display in the menu.
    private(set) var watchedFolderDisplayPath: String?
    /// e.g. "Watching Downloads → gala-k9 (3 queued this session)", or a
    /// failure message when enabling/restoring didn't work.
    private(set) var status: String?

    @ObservationIgnored private var watcher: WatchedFolder?
    /// The URL we called `startAccessingSecurityScopedResource` on — held for
    /// the whole time the folder is watched, released on disable/deinit.
    /// `@ObservationIgnored` keeps it a plain stored property so `deinit`
    /// (nonisolated) may still read it — URL is Sendable.
    @ObservationIgnored private var scopedURL: URL?
    /// Files queued since this watch started (feeds the status line).
    @ObservationIgnored private var sessionQueuedCount = 0

    nonisolated static let defaultsKey = "watchConfig"

    deinit {
        // WatchedFolder's own deinit cancels its dispatch source (closing the
        // directory descriptor); here we only release the security scope.
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Pure helpers

    /// Status line shown while watching. The target is the project component
    /// of the prefix ("acme-x1/gala-k9/" → "gala-k9"), falling back to the
    /// whole prefix when it has no project part.
    nonisolated static func statusLine(folderName: String, projectPrefix: String,
                                       queuedCount: Int) -> String {
        let components = IntakeModel.clipKeyComponents(fromProjectPrefix: projectPrefix)
        let target = components.project.isEmpty ? projectPrefix : components.project
        return "Watching \(folderName) → \(target) (\(queuedCount) queued this session)"
    }

    // MARK: - Lifecycle

    /// Starts watching `folderURL` (fresh from a folder picker, so its
    /// security scope is redeemable), queuing new videos into
    /// `projectPrefix`. Replaces any existing watch. On success the config is
    /// persisted so the watch survives relaunches; on failure the previous
    /// watch stays torn down and `status` explains what went wrong.
    func enable(folderURL: URL, projectPrefix: String, cameraLabel: String?, app: AppModel) {
        disable()
        let accessing = folderURL.startAccessingSecurityScopedResource()
        do {
            let bookmark = try folderURL.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
            let config = WatchConfig(bookmark: bookmark,
                                     projectPrefix: projectPrefix,
                                     cameraLabel: cameraLabel)
            try startWatcher(url: folderURL, holdingScope: accessing, config: config, app: app)
            persist(config)
        } catch {
            if accessing { folderURL.stopAccessingSecurityScopedResource() }
            status = "Could not watch “\(folderURL.lastPathComponent)”: \(ErrorText.describe(error))"
        }
    }

    /// Stops watching, clears the persisted config, and releases the folder's
    /// security scope.
    func disable() {
        stopWatching()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        status = nil
    }

    /// Re-targets the current watch at a different project ("Move watch
    /// here"): same folder and bookmark, new prefix + camera label. No-op
    /// when nothing is being watched.
    func move(projectPrefix: String, cameraLabel: String?, app: AppModel) {
        guard var config = activeConfig else { return }
        config.projectPrefix = projectPrefix
        config.cameraLabel = cameraLabel
        stopWatching()
        persist(config)
        startFromBookmark(config, app: app, failureVerb: "moved")
    }

    /// Re-arms a previously persisted watch (called from `AppModel.install`
    /// once the upload stack exists). A stale bookmark is transparently
    /// re-created and re-persisted. On failure the config is KEPT — the
    /// folder may merely be on an unmounted volume — and `status` says so.
    func restoreIfConfigured(app: AppModel) {
        guard watcher == nil,
              let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let config = try? JSONDecoder().decode(WatchConfig.self, from: data) else { return }
        startFromBookmark(config, app: app, failureVerb: "restored")
    }

    // MARK: - Internals

    /// Resolves the config's bookmark (refreshing it when stale), takes the
    /// security scope, and starts the watcher. Failure releases the scope and
    /// surfaces in `status`; the persisted config is left alone.
    private func startFromBookmark(_ config: WatchConfig, app: AppModel, failureVerb: String) {
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: config.bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            let accessing = url.startAccessingSecurityScopedResource()
            do {
                var config = config
                if isStale {
                    config.bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                           includingResourceValuesForKeys: nil,
                                                           relativeTo: nil)
                    persist(config)
                }
                try startWatcher(url: url, holdingScope: accessing, config: config, app: app)
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        } catch {
            status = "The watched folder could not be \(failureVerb): \(ErrorText.describe(error))"
        }
    }

    /// Builds and starts the `WatchedFolder`, then publishes the new state.
    /// Mutates nothing if `start()` throws (so a failed enable/restore leaves
    /// the manager cleanly stopped).
    private func startWatcher(url: URL, holdingScope: Bool,
                              config: WatchConfig, app: AppModel) throws {
        let prefix = config.projectPrefix
        let label = config.cameraLabel
        let folderName = url.lastPathComponent
        let watcher = WatchedFolder(url: url) { [weak self, weak app] fileURL in
            guard let self, let app else { return }
            // Enqueue while we hold the folder's security scope; staging
            // copies the file into our container before anything else runs.
            app.intake.enqueue(fileURLs: [fileURL], projectPrefix: prefix,
                               cameraLabel: label, app: app)
            self.sessionQueuedCount += 1
            self.status = Self.statusLine(folderName: folderName, projectPrefix: prefix,
                                          queuedCount: self.sessionQueuedCount)
        }
        try watcher.start()
        self.watcher = watcher
        scopedURL = holdingScope ? url : nil
        activeConfig = config
        watchedFolderDisplayPath = url.path
        sessionQueuedCount = 0
        status = Self.statusLine(folderName: folderName, projectPrefix: prefix, queuedCount: 0)
    }

    /// Tears down the live watcher and releases the scope, leaving the
    /// persisted config alone (callers decide whether to clear or replace it).
    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        activeConfig = nil
        watchedFolderDisplayPath = nil
        sessionQueuedCount = 0
    }

    private func persist(_ config: WatchConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
#endif
