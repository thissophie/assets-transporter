import Foundation

/// One named S3 server the app can connect to. The name is the user's label
/// ("Production", "Local ministack") and is independent of the endpoint —
/// two profiles may point at the same URL and bucket with different
/// credentials, and renaming never touches the connection. The `id` is the
/// stable identity everything local hangs off: upload-queue directory,
/// watched-folder defaults keys, window identity.
nonisolated struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var settings: StoredS3Settings

    init(id: UUID = UUID(), name: String, settings: StoredS3Settings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    /// Short "bucket on host" line shown under the name in the server list.
    var summary: String {
        Self.summary(for: settings)
    }

    nonisolated static func summary(for settings: StoredS3Settings) -> String {
        let host = settings.endpoint.host() ?? settings.endpoint.absoluteString
        return "\(settings.bucket) on \(host)"
    }

    /// Name given to the single pre-multi-server settings blob when it is
    /// migrated into a profile — the user had never named it, so describe it.
    nonisolated static func migratedName(for settings: StoredS3Settings) -> String {
        summary(for: settings)
    }
}

/// Where each server's *local* state lives, and how the pre-multi-server
/// state is migrated into it. Pure path/key arithmetic plus two filesystem +
/// UserDefaults moves; no Keychain.
///
/// Layout:
/// - upload queue: `<queueRoot>/<server id>/jobs.json` (was `<queueRoot>/jobs.json`)
/// - watched folder: defaults keys `watchConfig.<id>` / `watchProcessed.<id>`
///   (were `watchConfig` / `watchProcessed`)
///
/// Staged copies stay app-global (`IntakeModel.stagingDirectory`) — they are
/// named by UUID and referenced from whichever server's queue owns them.
nonisolated enum ServerLocalState {
    static let defaultQueueRoot = URL.applicationSupportDirectory
        .appending(path: "UploadQueue", directoryHint: .isDirectory)

    static let legacyWatchConfigKey = "watchConfig"
    static let legacyWatchProcessedKey = "watchProcessed"

    static func queueDirectory(root: URL, serverID: UUID) -> URL {
        root.appending(path: serverID.uuidString, directoryHint: .isDirectory)
    }

    static func watchConfigKey(serverID: UUID) -> String {
        "\(legacyWatchConfigKey).\(serverID.uuidString)"
    }

    static func watchProcessedKey(serverID: UUID) -> String {
        "\(legacyWatchProcessedKey).\(serverID.uuidString)"
    }

    /// True when the server has local work that should run without a window
    /// being open: a persisted watched folder, or a queue file (which may
    /// hold resumable jobs). Cheap synchronous checks only — used at launch
    /// to decide which sessions to start eagerly.
    static func hasBackgroundWork(root: URL, defaults: UserDefaults, serverID: UUID) -> Bool {
        if defaults.data(forKey: watchConfigKey(serverID: serverID)) != nil { return true }
        let jobsFile = queueDirectory(root: root, serverID: serverID).appending(path: "jobs.json")
        return FileManager.default.fileExists(atPath: jobsFile.path)
    }

    /// Moves the single-server queue file and watch defaults under `serverID`.
    /// Idempotent: anything already migrated (or absent) is left alone, and a
    /// legacy item never overwrites an existing per-server one.
    static func migrateLegacyState(root: URL, defaults: UserDefaults, to serverID: UUID) throws {
        let fm = FileManager.default
        let legacyJobs = root.appending(path: "jobs.json")
        if fm.fileExists(atPath: legacyJobs.path) {
            let directory = queueDirectory(root: root, serverID: serverID)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: "jobs.json")
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: legacyJobs)
            } else {
                try fm.moveItem(at: legacyJobs, to: target)
            }
        }
        for (legacy, new) in [(legacyWatchConfigKey, watchConfigKey(serverID: serverID)),
                              (legacyWatchProcessedKey, watchProcessedKey(serverID: serverID))] {
            guard let data = defaults.data(forKey: legacy) else { continue }
            if defaults.data(forKey: new) == nil {
                defaults.set(data, forKey: new)
            }
            defaults.removeObject(forKey: legacy)
        }
    }

    /// Deletes everything local that belongs to `serverID` (queue directory,
    /// watch defaults). Staged files it referenced become orphans for the
    /// next staging sweep.
    static func removeAll(root: URL, defaults: UserDefaults, serverID: UUID) {
        try? FileManager.default.removeItem(at: queueDirectory(root: root, serverID: serverID))
        defaults.removeObject(forKey: watchConfigKey(serverID: serverID))
        defaults.removeObject(forKey: watchProcessedKey(serverID: serverID))
    }
}
