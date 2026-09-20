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

    /// Result of the most recent stale-upload sweep (best-effort maintenance
    /// run whenever the model becomes configured), surfaced subtly in the
    /// upload queue screen's footer. nil when there was nothing to report.
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
        sweepStaleUploads(engine: engine)
    }

    /// Best-effort background sweep: aborts server-side multipart uploads no
    /// persisted job owns (each abandoned attempt otherwise keeps billable
    /// parts forever). Fire-and-forget — all awaits happen inside the task, so
    /// becoming configured never blocks on the network; the outcome (including
    /// failure) only surfaces via `maintenanceNote`.
    private func sweepStaleUploads(engine: UploadEngine) {
        Task {
            do {
                let liveJobs = await store.load()
                let aborted = try await engine.abandonStaleUploads(prefix: "", liveJobs: liveJobs)
                // Only report when something happened; sweeping engines from a
                // superseded configuration shouldn't clear a real note.
                if aborted > 0 {
                    maintenanceNote = "Cleaned \(aborted) stale upload\(aborted == 1 ? "" : "s")"
                }
            } catch {
                maintenanceNote = "Stale-upload cleanup didn't run — it will retry next launch."
            }
        }
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
