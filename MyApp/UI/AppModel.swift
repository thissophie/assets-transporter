import Foundation
import Observation

/// App-wide state: the stored S3 settings and the service stack built from
/// them (client, reader, writer, upload engine). Unconfigured until settings
/// exist; a Keychain read failure at launch surfaces in `configError` instead
/// of crashing.
@Observable @MainActor final class AppModel {
    private(set) var settings: StoredS3Settings?
    private(set) var client: S3Client?
    private(set) var reader: BucketReader?
    private(set) var writer: BucketWriter?
    private(set) var engine: UploadEngine?

    /// Single shared queue store — multiple instances would race on the
    /// backing file.
    let store = UploadQueueStore()

    /// Single shared intake/upload coordinator. App-wide (not per project
    /// view) so its `isRunning`/`runningJobID` guards actually serialize all
    /// uploads, and the queue screen can retry/remove jobs safely.
    let intake = IntakeModel()

    /// Set when loading saved settings from the Keychain fails at launch.
    var configError: String?

    /// Result of the most recent maintenance pass (stale-upload sweep +
    /// staging orphan cleanup, run whenever the model becomes configured),
    /// surfaced subtly in the upload queue screen's footer. nil when there
    /// was nothing to report.
    private(set) var maintenanceNote: String?

    private let credentials = CredentialStore()

    var isConfigured: Bool { client != nil }

    init() {
        do {
            if let stored = try credentials.load() {
                install(stored)
            }
        } catch {
            configError = "Saved settings could not be loaded from the Keychain "
                + "(\(String(describing: error))). Enter them again to reconnect."
        }
    }

    /// Persists `settings` to the Keychain, then rebuilds the service stack.
    /// All-or-nothing: if the Keychain save throws, existing state is untouched.
    func apply(_ settings: StoredS3Settings) throws {
        try credentials.save(settings)
        install(settings)
        configError = nil
    }

    /// Deletes the Keychain item and tears down the stack.
    func clearSettings() {
        credentials.delete()
        settings = nil
        client = nil
        reader = nil
        writer = nil
        engine = nil
    }

    private func install(_ settings: StoredS3Settings) {
        let (client, reader, writer) = Self.buildStack(settings: settings)
        self.settings = settings
        self.client = client
        self.reader = reader
        self.writer = writer
        let engine = UploadEngine(client: client, store: store)
        self.engine = engine
        runMaintenance(engine: engine)
        intake.resumePersistedJobs(app: self)
    }

    /// Uploads must be at least this old before the sweep may abort them:
    /// other devices upload into the same bucket, and "not in OUR store" says
    /// nothing about THEIR in-flight uploads. 48 hours comfortably outlives
    /// any real upload attempt.
    private static let staleUploadAge: TimeInterval = 48 * 60 * 60

    /// Best-effort background maintenance whenever the model becomes
    /// configured: (1) abort server-side multipart uploads that are both
    /// unowned locally AND older than `staleUploadAge` (each abandoned attempt
    /// otherwise keeps billable parts forever), (2) delete orphaned staged
    /// files no stored job references. Fire-and-forget — all awaits happen
    /// inside the task, so becoming configured never blocks; the outcome
    /// (including failure) only surfaces via `maintenanceNote`.
    private func runMaintenance(engine: UploadEngine) {
        Task {
            var notes: [String] = []
            let liveJobs = await store.load()
            do {
                let aborted = try await engine.abandonStaleUploads(
                    prefix: "", liveJobs: liveJobs,
                    olderThan: Date(timeIntervalSinceNow: -Self.staleUploadAge))
                // Only report when something happened; a quiet sweep shouldn't
                // clear a real note from a previous configuration.
                if aborted > 0 {
                    notes.append("Cleaned \(aborted) stale upload\(aborted == 1 ? "" : "s")")
                }
            } catch {
                notes.append("Stale-upload cleanup didn't run — it will retry next launch.")
            }
            let removed = await Task.detached {
                Self.removeOrphanedStagingFiles(jobs: liveJobs)
            }.value
            if removed > 0 {
                notes.append("Removed \(removed) orphaned staged file\(removed == 1 ? "" : "s")")
            }
            if !notes.isEmpty { maintenanceNote = notes.joined(separator: " · ") }
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

    /// Pure stack construction from settings — no Keychain, no stored state.
    /// iOS uses the shared background transport so uploads survive suspension;
    /// macOS uses a plain URLSession transport.
    nonisolated static func buildStack(
        settings: StoredS3Settings
    ) -> (client: S3Client, reader: BucketReader, writer: BucketWriter) {
        #if os(iOS)
        let transport: any S3Transport = BackgroundTransport.shared
        #else
        let transport: any S3Transport = URLSessionTransport()
        #endif
        let client = S3Client(config: settings.makeS3Config(), transport: transport)
        return (client, BucketReader(client: client), BucketWriter(client: client))
    }
}
