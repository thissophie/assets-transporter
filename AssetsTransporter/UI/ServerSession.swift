import Foundation
import Observation

/// Everything that belongs to one connected server: the service stack built
/// from its profile (client, reader, writer, upload engine), its own upload
/// queue store, its intake coordinator, and (macOS) its watched folder.
///
/// Sessions are created by `AppModel.session(for:)` and live for the rest of
/// the app's run — closing a server's window must not kill an upload in
/// flight or a watched folder. Two windows on the same server share one
/// session, so uploads stay serialized per server.
@Observable @MainActor final class ServerSession: Identifiable {
    private(set) var profile: ServerProfile
    private(set) var client: S3Client
    private(set) var reader: BucketReader
    private(set) var writer: BucketWriter
    private(set) var engine: UploadEngine

    /// This server's queue store — one per server, so persisted jobs always
    /// resume against the bucket they were queued for.
    let store: UploadQueueStore

    /// Intake/upload coordinator. Per server (not per project view) so its
    /// `isRunning`/`runningJobID` guards actually serialize all of this
    /// server's uploads, and the queue screen can retry/remove jobs safely.
    let intake = IntakeModel()

    #if os(macOS)
    /// Watched-folder coordinator: one designated folder feeding one project
    /// on this server (re-armed in `init` once the upload stack exists).
    let watch: WatchManager
    #endif

    /// Result of the most recent stale-upload sweep, surfaced subtly in the
    /// upload queue screen's footer. nil when there was nothing to report.
    private(set) var maintenanceNote: String?

    nonisolated var id: ServerProfile.ID { profileID }
    private nonisolated let profileID: ServerProfile.ID

    init(profile: ServerProfile, queueDirectory: URL, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.profileID = profile.id
        let (client, reader, writer) = Self.buildStack(settings: profile.settings)
        self.client = client
        self.reader = reader
        self.writer = writer
        self.store = UploadQueueStore(directory: queueDirectory)
        self.engine = UploadEngine(client: client, store: store)
        #if os(macOS)
        self.watch = WatchManager(serverID: profile.id, defaults: defaults)
        #endif
        runMaintenance(engine: engine)
        intake.resumePersistedJobs(session: self)
        #if os(macOS)
        // After the stack exists, so a restored watch can actually upload.
        watch.restoreIfConfigured(session: self)
        #endif
    }

    /// Adopts an edited profile. A pure rename keeps the live stack; changed
    /// connection settings rebuild client/reader/writer/engine (an upload
    /// already running keeps the engine it started with until it finishes —
    /// the intake loop holds its own reference).
    func update(profile: ServerProfile) {
        let settingsChanged = profile.settings != self.profile.settings
        self.profile = profile
        guard settingsChanged else { return }
        let (client, reader, writer) = Self.buildStack(settings: profile.settings)
        self.client = client
        self.reader = reader
        self.writer = writer
        self.engine = UploadEngine(client: client, store: store)
    }

    /// Stops background activity before the server is removed. The persisted
    /// watch config is cleared by `WatchManager.disable`; the queue directory
    /// is removed by the caller (`ServerLocalState.removeAll`).
    func shutDown() {
        #if os(macOS)
        watch.disable()
        #endif
    }

    /// True while this server's intake loop has a job in flight.
    var isUploading: Bool { intake.runningJobID != nil }

    /// Uploads must be at least this old before the sweep may abort them:
    /// other devices upload into the same bucket, and "not in OUR store" says
    /// nothing about THEIR in-flight uploads. 48 hours comfortably outlives
    /// any real upload attempt.
    private static let staleUploadAge: TimeInterval = 48 * 60 * 60

    /// Best-effort sweep when the session starts: abort server-side multipart
    /// uploads that are both unowned locally AND older than `staleUploadAge`
    /// (each abandoned attempt otherwise keeps billable parts forever).
    /// Fire-and-forget — the outcome (including failure) only surfaces via
    /// `maintenanceNote`. Orphaned staged files are swept app-wide by
    /// `AppModel`, since staging is shared across servers.
    private func runMaintenance(engine: UploadEngine) {
        Task {
            let liveJobs = await store.load()
            do {
                let aborted = try await engine.abandonStaleUploads(
                    prefix: "", liveJobs: liveJobs,
                    olderThan: Date(timeIntervalSinceNow: -Self.staleUploadAge))
                // Only report when something happened; a quiet sweep shouldn't
                // clear a real note from a previous configuration.
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

extension ServerSession {
    /// A session for SwiftUI previews: placeholder profile, unreachable
    /// endpoint (so network calls fail fast), throwaway queue directory.
    static func preview() -> ServerSession {
        let settings = StoredS3Settings(endpoint: URL(string: "http://localhost:1")!,
                                        bucket: "preview", accessKey: "preview",
                                        secretKey: "preview", pathStyle: true,
                                        region: "us-east-1")
        let profile = ServerProfile(name: "Preview Server", settings: settings)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "preview-queue-\(profile.id.uuidString)", directoryHint: .isDirectory)
        return ServerSession(profile: profile, queueDirectory: directory,
                             defaults: UserDefaults(suiteName: "preview") ?? .standard)
    }
}
