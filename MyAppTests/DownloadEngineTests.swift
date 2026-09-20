import Foundation
import Testing
@testable import MyApp

/// Thread-safe recorder for the batch progress callback.
private nonisolated final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(completed: Int64, total: Int64)] = []
    var onUpdate: (@Sendable (Int64, Int64) -> Void)?

    func record(_ completed: Int64, _ total: Int64) {
        lock.lock()
        recorded.append((completed: completed, total: total))
        lock.unlock()
        onUpdate?(completed, total)
    }

    var updates: [(completed: Int64, total: Int64)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

struct DownloadEngineTests {

    private func makeClient(transport: RecordingTransport) -> S3Client {
        let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                              bucket: "video", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        return S3Client(config: config, transport: transport)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DownloadEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeClip(key: String, name: String, size: Int64) -> Clip {
        Clip(key: key,
             sidecar: ClipSidecar(displayName: name, cameraLabel: nil, notes: nil,
                                  capturedAt: nil, orderOverride: nil, duration: nil,
                                  width: nil, height: nil, codec: nil,
                                  fileSize: size,
                                  originalFilename: name, sourceDevice: "test"))
    }

    /// GET Range headers sent for a given key, in request order.
    private func getRanges(_ transport: RecordingTransport, key: String) -> [String?] {
        transport.requests
            .filter { $0.request.httpMethod == "GET"
                && ($0.request.url?.path.contains(key) ?? false) }
            .map { $0.request.value(forHTTPHeaderField: "Range") }
    }

    private func expectMonotonic(_ updates: [(completed: Int64, total: Int64)]) {
        for (previous, next) in zip(updates, updates.dropFirst()) {
            #expect(next.completed >= previous.completed)
            #expect(next.total == previous.total)
        }
    }

    private static let manifest = ProjectManifest(
        displayName: "Spring Gala", sortIndex: 3,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    private static let bytesA = Data((0..<10).map { UInt8($0) })
    private static let bytesB = Data((100..<105).map { UInt8($0) })

    /// Transport with the two standard objects loaded into the keyed responder.
    private func makeStandardTransport() -> RecordingTransport {
        let transport = RecordingTransport()
        transport.respond(to: "clips/a.mov", with: (Self.bytesA, 200))
        transport.respond(to: "clips/b.mov", with: (Self.bytesB, 200))
        return transport
    }

    private func makeStandardItems() -> [DownloadEngine.Item] {
        let clips = [
            makeClip(key: "acme/gala/clips/a.mov", name: "Alpha", size: 10),
            makeClip(key: "acme/gala/clips/b.mov", name: "Beta", size: 5),
        ]
        let filenames = DownloadNaming.filenames(forOrdered: clips)
        return zip(clips, filenames).map { DownloadEngine.Item(clip: $0, filename: $1) }
    }

    // 1. Fresh download of two items in ≤4-byte ranged chunks.
    @Test func freshDownloadWritesExactBytesInRangedChunks() async throws {
        let transport = makeStandardTransport()
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = makeStandardItems()
        let recorder = ProgressRecorder()

        try await engine.download(items: items, into: directory,
                                  projectManifest: Self.manifest) { recorder.record($0, $1) }

        // Order-prefixed filenames, exact contents.
        #expect(items.map(\.filename) == ["001_alpha.mov", "002_beta.mov"])
        let fileA = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        let fileB = try Data(contentsOf: directory.appending(path: "002_beta.mov"))
        #expect(fileA == Self.bytesA)
        #expect(fileB == Self.bytesB)

        // Chunked ranged GETs.
        #expect(getRanges(transport, key: "clips/a.mov") == ["bytes=0-3", "bytes=4-7", "bytes=8-9"])
        #expect(getRanges(transport, key: "clips/b.mov") == ["bytes=0-3", "bytes=4-4"])

        // Progress is monotonic across the batch and ends at (15, 15).
        let updates = recorder.updates
        expectMonotonic(updates)
        #expect(updates.last?.completed == 15)
        #expect(updates.last?.total == 15)

        // project.json written alongside and decodes to the manifest.
        let manifestData = try Data(contentsOf: directory.appending(path: "project.json"))
        let decoded = try ManifestCoding.decode(ProjectManifest.self, from: manifestData)
        #expect(decoded == Self.manifest)
    }

    // 2. Resume: a partial file is appended to from its existing size.
    @Test func resumeAppendsFromExistingSize() async throws {
        let transport = makeStandardTransport()
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = makeStandardItems()

        // 6 of 10 bytes already on disk for item 1.
        try Self.bytesA.prefix(6).write(to: directory.appending(path: "001_alpha.mov"))

        try await engine.download(items: items, into: directory,
                                  projectManifest: nil, progress: nil)

        #expect(getRanges(transport, key: "clips/a.mov") == ["bytes=6-9"])
        let fileA = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        #expect(fileA == Self.bytesA)
        // No manifest requested -> no project.json.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "project.json").path))
    }

    // 3. A complete file is skipped (zero GETs) but still counted in progress.
    @Test func completeFileIsSkippedAndCountedInProgress() async throws {
        let transport = makeStandardTransport()
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = makeStandardItems()
        let recorder = ProgressRecorder()

        try Self.bytesA.write(to: directory.appending(path: "001_alpha.mov"))

        try await engine.download(items: items, into: directory,
                                  projectManifest: nil) { recorder.record($0, $1) }

        #expect(getRanges(transport, key: "clips/a.mov").isEmpty)
        #expect(getRanges(transport, key: "clips/b.mov") == ["bytes=0-3", "bytes=4-4"])
        let updates = recorder.updates
        expectMonotonic(updates)
        #expect(updates.last?.completed == 15)
        #expect(updates.last?.total == 15)
        let fileA = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        #expect(fileA == Self.bytesA)
    }

    // 4. Failure on the second item propagates; the first item's file is intact.
    @Test func failurePropagatesAndKeepsEarlierFiles() async throws {
        let transport = RecordingTransport()
        transport.respond(to: "clips/a.mov", with: (Self.bytesA, 200))
        transport.respond(to: "clips/b.mov", with: (Data("boom".utf8), 500))
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = makeStandardItems()

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            try await engine.download(items: items, into: directory,
                                      projectManifest: Self.manifest, progress: nil)
        }

        let fileA = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        #expect(fileA == Self.bytesA)
        // No partial project.json after a failed batch.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "project.json").path))
    }

    // 5. cancel() between chunks throws CancellationError, preserving the partial file.
    @Test func cancelBetweenChunksThrowsAndPreservesPartial() async throws {
        let transport = RecordingTransport()
        transport.respond(to: "clips/a.mov", with: (Self.bytesA, 200))
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = makeClip(key: "acme/gala/clips/a.mov", name: "Alpha", size: 10)
        let items = [DownloadEngine.Item(clip: clip, filename: "001_alpha.mov")]
        let recorder = ProgressRecorder()
        // Cancel as soon as the first chunk's bytes land.
        recorder.onUpdate = { completed, _ in
            if completed > 0 { engine.cancel() }
        }

        await #expect(throws: CancellationError.self) {
            try await engine.download(items: items, into: directory,
                                      projectManifest: Self.manifest) { recorder.record($0, $1) }
        }

        // Only the first chunk was fetched; its bytes remain for a later resume.
        #expect(getRanges(transport, key: "clips/a.mov") == ["bytes=0-3"])
        let partial = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        #expect(partial == Self.bytesA.prefix(4))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "project.json").path))
    }

    // 7. The engine is reusable after cancel(): a fresh download() call on the
    // same actor must not inherit the previous run's cancel flag.
    @Test func downloadIsReusableAfterCancel() async throws {
        let transport = makeStandardTransport()
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = makeClip(key: "acme/gala/clips/a.mov", name: "Alpha", size: 10)
        let items = [DownloadEngine.Item(clip: clip, filename: "001_alpha.mov")]
        let recorder = ProgressRecorder()
        // Cancel as soon as the first chunk's bytes land.
        recorder.onUpdate = { completed, _ in
            if completed > 0 { engine.cancel() }
        }

        await #expect(throws: CancellationError.self) {
            try await engine.download(items: items, into: directory,
                                      projectManifest: nil) { recorder.record($0, $1) }
        }

        // Same engine, new call: resumes the partial file and completes.
        try await engine.download(items: items, into: directory,
                                  projectManifest: nil, progress: nil)
        let file = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        #expect(file == Self.bytesA)
    }

    // 6. fileSize == 0 falls back to a HEAD objectSize lookup for the total.
    @Test func zeroFileSizeFallsBackToObjectSize() async throws {
        let transport = RecordingTransport()
        transport.respond(to: "clips/a.mov", with: (Self.bytesA, 200),
                          headers: ["Content-Length": "10"])
        let engine = DownloadEngine(client: makeClient(transport: transport), chunkSize: 4)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = makeClip(key: "acme/gala/clips/a.mov", name: "Alpha", size: 0)
        let items = [DownloadEngine.Item(clip: clip, filename: "001_alpha.mov")]
        let recorder = ProgressRecorder()

        try await engine.download(items: items, into: directory,
                                  projectManifest: nil) { recorder.record($0, $1) }

        let heads = transport.requests.filter { $0.request.httpMethod == "HEAD" }
        #expect(heads.count == 1)
        #expect(recorder.updates.last?.total == 10)
        let fileA = try Data(contentsOf: directory.appending(path: "001_alpha.mov"))
        #expect(fileA == Self.bytesA)
    }
}
