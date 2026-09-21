import Foundation
import Testing
@testable import MyApp

/// Pure tests for `ServerProfile` and the per-server local-state layout and
/// migration (`ServerLocalState`). Keychain-backed load/save stay untested
/// (flaky in test hosts); the migration *decision* there is one line.
struct ServerProfileTests {

    private func makeSettings(host: String = "minio.example.com:9000",
                              bucket: String = "video") -> StoredS3Settings {
        StoredS3Settings(endpoint: URL(string: "https://\(host)")!,
                         bucket: bucket, accessKey: "AK", secretKey: "SK",
                         pathStyle: true, region: "ap-southeast-2")
    }

    // MARK: - ServerProfile

    @Test func profileRoundTripsThroughJSONKeepingIDAndName() throws {
        let profile = ServerProfile(name: "Production", settings: makeSettings())
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.id == profile.id)
        #expect(decoded.name == "Production")
    }

    @Test func summaryIsBucketOnHost() {
        let profile = ServerProfile(name: "x", settings: makeSettings())
        #expect(profile.summary == "video on minio.example.com")
    }

    @Test func migratedNameDescribesTheConnectionNotAPlaceholder() {
        let settings = makeSettings(host: "localhost:4566", bucket: "it-video")
        #expect(ServerProfile.migratedName(for: settings) == "it-video on localhost")
    }

    @Test func nameIsIndependentOfEndpoint() {
        // Two profiles on the same endpoint and bucket are distinct servers
        // (different ids and names) — identity never keys off the URL.
        let a = ServerProfile(name: "Read-only creds", settings: makeSettings())
        let b = ServerProfile(name: "Admin creds", settings: makeSettings())
        #expect(a != b)
        #expect(a.id != b.id)
        #expect(a.settings == b.settings)
    }

    // MARK: - ServerLocalState paths

    @Test func queueDirectoryIsPerServer() {
        let root = URL(fileURLWithPath: "/tmp/queue", isDirectory: true)
        let a = UUID(), b = UUID()
        let dirA = ServerLocalState.queueDirectory(root: root, serverID: a)
        let dirB = ServerLocalState.queueDirectory(root: root, serverID: b)
        #expect(dirA != dirB)
        #expect(dirA.lastPathComponent == a.uuidString)
        #expect(dirA.deletingLastPathComponent().path == root.path)
    }

    @Test func watchKeysArePerServerAndDistinctFromLegacy() {
        let id = UUID()
        let config = ServerLocalState.watchConfigKey(serverID: id)
        let processed = ServerLocalState.watchProcessedKey(serverID: id)
        #expect(config != ServerLocalState.legacyWatchConfigKey)
        #expect(processed != ServerLocalState.legacyWatchProcessedKey)
        #expect(config != processed)
        #expect(config.hasSuffix(id.uuidString))
    }

    // MARK: - Migration

    private func withScratch(_ body: (URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "server-local-state-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "server-local-state-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(root, defaults)
    }

    @Test func legacyQueueFileAndWatchKeysMoveUnderTheMigratedServer() throws {
        try withScratch { root, defaults in
            let id = UUID()
            let legacyJobs = root.appending(path: "jobs.json")
            try Data("[]".utf8).write(to: legacyJobs)
            defaults.set(Data([1, 2, 3]), forKey: ServerLocalState.legacyWatchConfigKey)
            defaults.set(Data([4]), forKey: ServerLocalState.legacyWatchProcessedKey)

            try ServerLocalState.migrateLegacyState(root: root, defaults: defaults, to: id)

            let migratedJobs = ServerLocalState.queueDirectory(root: root, serverID: id)
                .appending(path: "jobs.json")
            #expect(!FileManager.default.fileExists(atPath: legacyJobs.path))
            #expect(try Data(contentsOf: migratedJobs) == Data("[]".utf8))
            #expect(defaults.data(forKey: ServerLocalState.watchConfigKey(serverID: id)) == Data([1, 2, 3]))
            #expect(defaults.data(forKey: ServerLocalState.watchProcessedKey(serverID: id)) == Data([4]))
            #expect(defaults.data(forKey: ServerLocalState.legacyWatchConfigKey) == nil)
            #expect(defaults.data(forKey: ServerLocalState.legacyWatchProcessedKey) == nil)
        }
    }

    @Test func migrationIsIdempotentAndNeverOverwritesPerServerState() throws {
        try withScratch { root, defaults in
            let id = UUID()
            // Nothing legacy: a no-op, no directory created.
            try ServerLocalState.migrateLegacyState(root: root, defaults: defaults, to: id)
            let directory = ServerLocalState.queueDirectory(root: root, serverID: id)
            #expect(!FileManager.default.fileExists(atPath: directory.path))

            // A per-server file already there wins over a stale legacy one,
            // and the legacy file is still cleaned up.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("[\"new\"]".utf8).write(to: directory.appending(path: "jobs.json"))
            try Data("[\"old\"]".utf8).write(to: root.appending(path: "jobs.json"))
            defaults.set(Data([9]), forKey: ServerLocalState.watchConfigKey(serverID: id))
            defaults.set(Data([1]), forKey: ServerLocalState.legacyWatchConfigKey)

            try ServerLocalState.migrateLegacyState(root: root, defaults: defaults, to: id)

            #expect(try Data(contentsOf: directory.appending(path: "jobs.json")) == Data("[\"new\"]".utf8))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "jobs.json").path))
            #expect(defaults.data(forKey: ServerLocalState.watchConfigKey(serverID: id)) == Data([9]))
            #expect(defaults.data(forKey: ServerLocalState.legacyWatchConfigKey) == nil)
        }
    }

    @Test func backgroundWorkDetectedFromWatchConfigOrQueueFile() throws {
        try withScratch { root, defaults in
            let id = UUID()
            #expect(!ServerLocalState.hasBackgroundWork(root: root, defaults: defaults, serverID: id))

            defaults.set(Data([1]), forKey: ServerLocalState.watchConfigKey(serverID: id))
            #expect(ServerLocalState.hasBackgroundWork(root: root, defaults: defaults, serverID: id))
            defaults.removeObject(forKey: ServerLocalState.watchConfigKey(serverID: id))

            let directory = ServerLocalState.queueDirectory(root: root, serverID: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: directory.appending(path: "jobs.json"))
            #expect(ServerLocalState.hasBackgroundWork(root: root, defaults: defaults, serverID: id))

            // Another server's state is not this server's work.
            #expect(!ServerLocalState.hasBackgroundWork(root: root, defaults: defaults, serverID: UUID()))
        }
    }

    @Test func removeAllDeletesOnlyThatServersState() throws {
        try withScratch { root, defaults in
            let keep = UUID(), drop = UUID()
            for id in [keep, drop] {
                let directory = ServerLocalState.queueDirectory(root: root, serverID: id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("[]".utf8).write(to: directory.appending(path: "jobs.json"))
                defaults.set(Data([1]), forKey: ServerLocalState.watchConfigKey(serverID: id))
                defaults.set(Data([2]), forKey: ServerLocalState.watchProcessedKey(serverID: id))
            }

            ServerLocalState.removeAll(root: root, defaults: defaults, serverID: drop)

            #expect(!ServerLocalState.hasBackgroundWork(root: root, defaults: defaults, serverID: drop))
            #expect(defaults.data(forKey: ServerLocalState.watchProcessedKey(serverID: drop)) == nil)
            #expect(ServerLocalState.hasBackgroundWork(root: root, defaults: defaults, serverID: keep))
            #expect(defaults.data(forKey: ServerLocalState.watchProcessedKey(serverID: keep)) == Data([2]))
        }
    }
}
