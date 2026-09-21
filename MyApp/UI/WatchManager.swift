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
    /// Identities already enqueued from the watched folder, oldest first.
    /// Persisted (capped) so a relaunch doesn't re-upload files still sitting
    /// in the folder; seeds `WatchedFolder.initiallyProcessed` on restore/move.
    @ObservationIgnored private var processedLog: [FileIdentity] = []

    nonisolated static let defaultsKey = "watchConfig"
    nonisolated static let processedDefaultsKey = "watchProcessed"
    /// The persisted processed log keeps only the most recent entries — a
    /// watch folder that has seen thousands of clips must not grow defaults
    /// forever, and old entries are files long since removed.
    nonisolated static let processedCap = 1_000

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

    /// Bounds the persisted processed log: keeps the MOST RECENT `limit`
    /// entries (the log is appended in fire order, oldest first).
    nonisolated static func capped(_ identities: [FileIdentity], limit: Int) -> [FileIdentity] {
        identities.count > limit ? Array(identities.suffix(limit)) : identities
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
            // A newly chosen folder starts with an empty processed log:
            // whatever sits in it now is exactly what the user asked to queue.
            try startWatcher(url: folderURL, holdingScope: accessing, config: config,
                             seed: [], app: app)
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
        UserDefaults.standard.removeObject(forKey: Self.processedDefaultsKey)
        processedLog = []
        status = nil
    }

    /// Re-targets the current watch at a different project ("Move watch
    /// here"): same folder and bookmark, new prefix + camera label. The
    /// processed log is KEPT — files already uploaded to the old project
    /// must not silently re-upload into the new one. No-op when nothing is
    /// being watched.
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
    /// security scope, and starts the watcher seeded with the persisted
    /// processed log — files uploaded before a relaunch never re-fire, while
    /// files added or changed while the app was closed still do. Failure
    /// releases the scope and surfaces in `status`; the persisted config is
    /// left alone.
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
                try startWatcher(url: url, holdingScope: accessing, config: config,
                                 seed: loadProcessedLog(), app: app)
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
    private func startWatcher(url: URL, holdingScope: Bool, config: WatchConfig,
                              seed: [FileIdentity], app: AppModel) throws {
        let prefix = config.projectPrefix
        let label = config.cameraLabel
        let folderName = url.lastPathComponent
        let watcher = WatchedFolder(url: url,
                                    initiallyProcessed: Set(seed)) { [weak self, weak app] fileURL, identity in
            guard let self, let app else { return }
            // Enqueue while we hold the folder's security scope; staging
            // copies the file into our container before anything else runs.
            app.intake.enqueue(fileURLs: [fileURL], projectPrefix: prefix,
                               cameraLabel: label, app: app)
            self.recordProcessed(identity)
            self.sessionQueuedCount += 1
            self.status = Self.statusLine(folderName: folderName, projectPrefix: prefix,
                                          queuedCount: self.sessionQueuedCount)
        }
        try watcher.start()
        self.watcher = watcher
        scopedURL = holdingScope ? url : nil
        activeConfig = config
        watchedFolderDisplayPath = url.path
        processedLog = seed
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

    /// Appends a fired identity to the processed log and persists it (capped
    /// to the most recent `processedCap` entries) so a relaunch won't
    /// re-upload the same file.
    private func recordProcessed(_ identity: FileIdentity) {
        processedLog.append(identity)
        processedLog = Self.capped(processedLog, limit: Self.processedCap)
        guard let data = try? JSONEncoder().encode(processedLog) else { return }
        UserDefaults.standard.set(data, forKey: Self.processedDefaultsKey)
    }

    private func loadProcessedLog() -> [FileIdentity] {
        guard let data = UserDefaults.standard.data(forKey: Self.processedDefaultsKey),
              let log = try? JSONDecoder().decode([FileIdentity].self, from: data) else { return [] }
        return log
    }
}
#endif
