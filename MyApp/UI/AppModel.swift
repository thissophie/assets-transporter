import Foundation
import Observation
import SwiftUI   // IndexSet-based move(fromOffsets:toOffset:) for List.onMove

/// App-wide state: the list of named servers (Keychain-backed) and the live
/// `ServerSession` for each server that has been opened this run.
///
/// Servers are the app's "documents": each one gets its own window on macOS
/// (`MyApp` opens a `WindowGroup` scene keyed by profile id) and the server
/// list is the library window. A session is created lazily the first time a
/// server is opened — or eagerly at launch when the server has local
/// background work (persisted watch, queued uploads) — and is then kept for
/// the rest of the run, so closing a window never interrupts an upload.
@Observable @MainActor final class AppModel {
    private(set) var servers: [ServerProfile] = []

    /// Set when loading saved servers from the Keychain fails at launch.
    var configError: String?

    /// Result of the app-wide staging sweep at launch (orphaned staged files
    /// no server's queue references). nil when there was nothing to report.
    private(set) var maintenanceNote: String?

    /// Set by the File ▸ New Server… command (macOS) so the Servers window
    /// presents its editor; the window clears it once the sheet is up.
    var presentNewServerEditor = false

    /// Not observed: `session(for:)` fills this lazily from inside view
    /// bodies (`ServerWindowView`), and an observed write there would
    /// re-trigger the very body that caused it. Views observe the session
    /// object itself once they hold it.
    @ObservationIgnored private var sessions: [ServerProfile.ID: ServerSession] = [:]
    private let credentials: CredentialStore
    private let queueRoot: URL
    private let defaults: UserDefaults

    init(credentials: CredentialStore = CredentialStore(),
         queueRoot: URL = ServerLocalState.defaultQueueRoot,
         defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.queueRoot = queueRoot
        self.defaults = defaults
        do {
            let loaded = try credentials.loadServers()
            servers = loaded.servers
            if let migrated = loaded.migratedLegacyServerID {
                // Best effort: a failed move leaves the legacy files in place,
                // which only costs a cold queue/watch for that server.
                try? ServerLocalState.migrateLegacyState(root: queueRoot, defaults: defaults,
                                                         to: migrated)
            }
        } catch {
            configError = "Saved servers could not be loaded from the Keychain "
                + "(\(String(describing: error))). Add the server again to reconnect."
        }
        startBackgroundSessions()
        sweepStagingOrphans()
    }

    // MARK: - Lookup

    var isEmpty: Bool { servers.isEmpty }

    func server(id: ServerProfile.ID) -> ServerProfile? {
        servers.first { $0.id == id }
    }

    /// The live session for a server, created on first use. nil when no such
    /// server exists (e.g. a restored window for a since-deleted server).
    func session(for id: ServerProfile.ID) -> ServerSession? {
        if let session = sessions[id] { return session }
        guard let profile = server(id: id) else { return nil }
        let session = ServerSession(
            profile: profile,
            queueDirectory: ServerLocalState.queueDirectory(root: queueRoot, serverID: id),
            defaults: defaults)
        sessions[id] = session
        return session
    }

    /// Sessions that exist this run — for status display, not creation.
    func existingSession(for id: ServerProfile.ID) -> ServerSession? {
        sessions[id]
    }

    // MARK: - Mutation (all-or-nothing: Keychain first, then in-memory state)

    func add(_ profile: ServerProfile) throws {
        try persist(servers + [profile])
    }

    /// Persists an edited profile and hands it to the live session (if any),
    /// which rebuilds its stack only when the connection settings changed.
    func update(_ profile: ServerProfile) throws {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = servers
        updated[index] = profile
        try persist(updated)
        sessions[profile.id]?.update(profile: profile)
    }

    /// Removes the server, its Keychain entry, and all of its local state
    /// (queue file, watched folder). Refuses while an upload is running for
    /// it — the caller disables Delete in that case, this is the guard.
    func remove(id: ServerProfile.ID) throws {
        guard !(sessions[id]?.isUploading ?? false) else { return }
        try persist(servers.filter { $0.id != id })
        sessions[id]?.shutDown()
        sessions[id] = nil
        ServerLocalState.removeAll(root: queueRoot, defaults: defaults, serverID: id)
    }

    func move(fromOffsets: IndexSet, toOffset: Int) throws {
        var reordered = servers
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try persist(reordered)
    }

    private func persist(_ updated: [ServerProfile]) throws {
        try credentials.saveServers(updated)
        servers = updated
        configError = nil
    }

    // MARK: - Launch work

    /// Starts sessions for servers with local background work so persisted
    /// watches re-arm and interrupted uploads resume without a window.
    private func startBackgroundSessions() {
        for profile in servers
        where ServerLocalState.hasBackgroundWork(root: queueRoot, defaults: defaults,
                                                 serverID: profile.id) {
            _ = session(for: profile.id)
        }
    }

    /// Deletes staged files that no server's queue references. Reads every
    /// server's store (not just the live sessions') so a server that is not
    /// open cannot have its staged copies swept from under it.
    private func sweepStagingOrphans() {
        let stores = servers.map {
            UploadQueueStore(directory: ServerLocalState.queueDirectory(root: queueRoot,
                                                                        serverID: $0.id))
        }
        Task {
            var liveJobs: [UploadJob] = []
            for store in stores {
                liveJobs += await store.load()
            }
            let removed = await Task.detached {
                Self.removeOrphanedStagingFiles(jobs: liveJobs)
            }.value
            if removed > 0 {
                maintenanceNote = "Removed \(removed) orphaned staged file\(removed == 1 ? "" : "s")"
            }
        }
    }

    /// Deletes files under Staging/ that no stored job references. Skips
    /// files added within the last hour — `addedToDirectoryDate` is NOT
    /// preserved by a copy (unlike mtime), so a stage-copy racing this sweep
    /// always looks new and is never deleted before its job record lands.
    /// Unknown ages are treated as new (skipped). Returns the count removed.
    private nonisolated static func removeOrphanedStagingFiles(jobs: [UploadJob]) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: IntakeModel.stagingDirectory,
            includingPropertiesForKeys: [.addedToDirectoryDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let cutoff = Date(timeIntervalSinceNow: -60 * 60)
        let oldEnough = files.filter { url in
            let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate
            return (added ?? Date()) < cutoff
        }
        var removed = 0
        for url in IntakeModel.orphanedStagingFiles(files: oldEnough, jobs: jobs)
        where (try? fm.removeItem(at: url)) != nil {
            removed += 1
        }
        return removed
    }
}
