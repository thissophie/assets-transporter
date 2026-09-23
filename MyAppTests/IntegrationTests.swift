import Foundation
import Testing
@testable import AssetsTransporter

/// Environment gate for the ministack integration suite: the tests only run
/// when `S3_IT_ENDPOINT` is set (e.g. http://localhost:4566), so normal test
/// runs skip them entirely.
nonisolated enum IntegrationEnv {
    static var endpoint: String? {
        ProcessInfo.processInfo.environment["S3_IT_ENDPOINT"]
    }
}

/// Transport wrapper that fails requests matching a predicate a fixed number
/// of times (then passes everything through) — used to prove upload resume.
private nonisolated final class FlakyTransport: S3Transport, @unchecked Sendable {
    private let wrapped: any S3Transport
    private let matcher: @Sendable (URLRequest) -> Bool
    private let lock = NSLock()
    private var remainingFailures: Int

    init(wrapping: any S3Transport = URLSessionTransport(), failures: Int = 1,
         matching: @escaping @Sendable (URLRequest) -> Bool) {
        self.wrapped = wrapping
        self.remainingFailures = failures
        self.matcher = matching
    }

    func perform(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let shouldFail: Bool
        lock.lock()
        if remainingFailures > 0, matcher(request) {
            remainingFailures -= 1
            shouldFail = true
        } else {
            shouldFail = false
        }
        lock.unlock()
        if shouldFail { throw URLError(.networkConnectionLost) }
        return try await wrapped.perform(request, uploadFile: uploadFile)
    }
}

/// Integration tests against a live S3-compatible server (ministack).
///
/// Run with: `xcodebuild test ... TEST_RUNNER_S3_IT_ENDPOINT=http://localhost:4566`
/// against a server that has an empty bucket named `it-video` (path style,
/// any credentials accepted). Each test works under a unique UUID prefix and
/// best-effort deletes everything it created, so runs never collide.
@Suite("ministack integration", .enabled(if: IntegrationEnv.endpoint != nil), .serialized)
struct IntegrationTests {

    private static let megabyte: Int64 = 1024 * 1024

    // MARK: - Harness

    private static func makeClient(transport: any S3Transport = URLSessionTransport()) throws -> S3Client {
        let endpointText = try #require(IntegrationEnv.endpoint)
        let endpoint = try #require(URL(string: endpointText))
        let config = S3Config(endpoint: endpoint, bucket: "it-video",
                              accessKey: "test", secretKey: "test",
                              style: .path, region: "us-east-1")
        return S3Client(config: config, transport: transport)
    }

    /// Best-effort removal of every object and in-flight multipart upload
    /// under `prefix`. Never throws: cleanup must not mask a test failure.
    private static func cleanUp(prefix: String, client: S3Client) async {
        if let uploads = try? await client.listMultipartUploads(prefix: prefix) {
            for upload in uploads {
                try? await client.abortMultipartUpload(key: upload.key, uploadId: upload.uploadId)
            }
        }
        if let listing = try? await client.listObjects(prefix: prefix, delimiter: nil) {
            for object in listing.objects {
                try? await client.deleteObject(key: object.key)
            }
        }
    }

    /// Runs `body` with a real client and a unique key prefix, cleaning up the
    /// prefix afterwards whether the body succeeded or threw.
    private func withTestPrefix(_ body: (String, S3Client) async throws -> Void) async throws {
        let client = try Self.makeClient()
        let prefix = "it-\(UUID().uuidString.lowercased())/"
        do {
            try await body(prefix, client)
        } catch {
            await Self.cleanUp(prefix: prefix, client: client)
            throw error
        }
        await Self.cleanUp(prefix: prefix, client: client)
    }

    /// Deterministic patterned bytes (distinct per seed) — verifiable without
    /// keeping a second copy around.
    private static func patternData(size: Int, seed: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<size {
                bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ seed)
            }
        }
        return data
    }

    /// Writes patterned data to a fresh temp file; caller removes it.
    private static func writeTempFile(size: Int, seed: Int, name: String) throws -> (url: URL, data: Data) {
        let data = patternData(size: size, seed: seed)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "it-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return (url, data)
    }

    private static func makeStore() -> UploadQueueStore {
        UploadQueueStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "it-store-\(UUID().uuidString)"))
    }

    private static func makeSidecar(displayName: String, cameraLabel: String?,
                                    capturedAt: Date?, fileSize: Int64,
                                    originalFilename: String) -> ClipSidecar {
        ClipSidecar(displayName: displayName, cameraLabel: cameraLabel, notes: nil,
                    capturedAt: capturedAt, orderOverride: nil,
                    duration: 12.5, width: 1920, height: 1080, codec: "hvc1",
                    fileSize: fileSize, originalFilename: originalFilename,
                    sourceDevice: "integration-test")
    }

    // MARK: - 1. Object round trip

    @Test func putListGetDelete() async throws {
        try await withTestPrefix { prefix, client in
            let key = prefix + "small.bin"
            let data = Data((0..<1024).map { _ in UInt8.random(in: .min ... .max) })

            try await client.putObject(key: key, data: data,
                                       contentType: "application/octet-stream")

            let listing = try await client.listObjects(prefix: prefix, delimiter: nil)
            #expect(listing.objects.count == 1)
            #expect(listing.objects.first?.key == key)
            #expect(listing.objects.first?.size == 1024)

            let fetched = try await client.getObject(key: key)
            #expect(fetched == data)

            let ranged = try await client.getObject(key: key, range: 10...19)
            #expect(ranged == data.subdata(in: 10..<20))

            let size = try await client.objectSize(key: key)
            #expect(size == 1024)

            try await client.deleteObject(key: key)
            let after = try await client.listObjects(prefix: prefix, delimiter: nil)
            #expect(after.objects.isEmpty)
        }
    }

    // MARK: - 2. Multipart lifecycle

    @Test func multipartLifecycleWithResume() async throws {
        try await withTestPrefix { prefix, client in
            let key = prefix + "multi.bin"
            // S3 requires >= 5 MB for every part but the last.
            let partSizes = [5 * Int(Self.megabyte), 5 * Int(Self.megabyte), Int(Self.megabyte)]
            var partFiles: [(url: URL, data: Data)] = []
            defer { for part in partFiles { try? FileManager.default.removeItem(at: part.url) } }
            for (index, size) in partSizes.enumerated() {
                partFiles.append(try Self.writeTempFile(size: size, seed: index + 1,
                                                        name: "part\(index + 1)"))
            }
            let totalSize = Int64(partSizes.reduce(0, +))

            let uploadId = try await client.createMultipartUpload(
                key: key, contentType: "application/octet-stream")

            var etags: [Int: String] = [:]
            for partNumber in [1, 2] {
                etags[partNumber] = try await client.uploadPart(
                    key: key, uploadId: uploadId, partNumber: partNumber,
                    fileURL: partFiles[partNumber - 1].url)
            }

            let listed = try await client.listParts(key: key, uploadId: uploadId)
            #expect(listed.count == 2)
            #expect(Set(listed.map(\.partNumber)) == [1, 2])
            for part in listed {
                #expect(part.size == Int64(partSizes[part.partNumber - 1]))
                #expect(part.etag == etags[part.partNumber])
            }

            // Simulated resume: upload the final part and complete.
            etags[3] = try await client.uploadPart(key: key, uploadId: uploadId,
                                                   partNumber: 3, fileURL: partFiles[2].url)
            try await client.completeMultipartUpload(
                key: key, uploadId: uploadId,
                parts: etags.map { (partNumber: $0.key, etag: $0.value) })

            #expect(try await client.objectSize(key: key) == totalSize)

            let head = try await client.getObject(key: key, range: 0...15)
            #expect(head == partFiles[0].data.prefix(16))
            let tail = try await client.getObject(key: key, range: (totalSize - 16)...(totalSize - 1))
            #expect(tail == partFiles[2].data.suffix(16))

            try await client.deleteObject(key: key)
        }
    }

    // MARK: - 3. Upload engine end to end

    @Test func uploadEngineEndToEnd() async throws {
        try await withTestPrefix { prefix, client in
            let totalSize = 11 * Self.megabyte
            let source = try Self.writeTempFile(size: Int(totalSize), seed: 7, name: "src.mov")
            defer { try? FileManager.default.removeItem(at: source.url) }

            let clipKey = prefix + "clips/2026-09-19_120000_cam-a_ab12.mov"
            let sidecar = Self.makeSidecar(displayName: "Keynote",
                                           cameraLabel: "Cam A",
                                           capturedAt: Date(timeIntervalSince1970: 1_789_812_000),
                                           fileSize: totalSize,
                                           originalFilename: "keynote.mov")
            let job = UploadJob(id: UUID(), sourceURL: source.url, sourceBookmark: nil,
                                clipKey: clipKey, sidecar: sidecar, state: .waiting,
                                partSize: 5 * Self.megabyte, totalSize: totalSize,
                                completedParts: [:])

            let engine = UploadEngine(client: client, store: Self.makeStore(),
                                      partSize: 5 * Self.megabyte)
            let result = await engine.run(job: job)
            #expect(result.state == .done)

            #expect(try await client.objectSize(key: clipKey) == totalSize)

            let sidecarData = try await client.getObject(
                key: BucketKeys.sidecarKey(forClipKey: clipKey))
            let decoded = try ManifestCoding.decode(ClipSidecar.self, from: sidecarData)
            #expect(decoded == sidecar)

            let clips = try await BucketReader(client: client).listClips(projectPrefix: prefix)
            #expect(clips.count == 1)
            #expect(clips.first?.key == clipKey)
            #expect(clips.first?.sidecar == sidecar)
        }
    }

    // MARK: - 4. Upload engine resume after failure

    @Test func uploadEngineResumeAfterFailure() async throws {
        try await withTestPrefix { prefix, _ in
            let totalSize = 11 * Self.megabyte
            let source = try Self.writeTempFile(size: Int(totalSize), seed: 9, name: "src.mov")
            defer { try? FileManager.default.removeItem(at: source.url) }

            let clipKey = prefix + "clips/2026-09-19_130000_cam-b_cd34.mov"
            let sidecar = Self.makeSidecar(displayName: "B-roll",
                                           cameraLabel: "Cam B",
                                           capturedAt: Date(timeIntervalSince1970: 1_789_815_600),
                                           fileSize: totalSize,
                                           originalFilename: "broll.mov")
            let job = UploadJob(id: UUID(), sourceURL: source.url, sourceBookmark: nil,
                                clipKey: clipKey, sidecar: sidecar, state: .waiting,
                                partSize: 5 * Self.megabyte, totalSize: totalSize,
                                completedParts: [:])
            let store = Self.makeStore()

            // Fail the first attempt to upload part 2, exactly once.
            let flaky = FlakyTransport(failures: 1) { request in
                request.httpMethod == "PUT"
                    && request.url?.query?.contains("partNumber=2") == true
            }
            let flakyClient = try Self.makeClient(transport: flaky)

            let firstRun = await UploadEngine(client: flakyClient, store: store,
                                              partSize: 5 * Self.megabyte).run(job: job)
            guard case .failed = firstRun.state else {
                Issue.record("expected .failed, got \(firstRun.state)")
                return
            }
            #expect(firstRun.uploadId != nil)
            #expect(firstRun.completedParts.count == 1)

            // Persisted record carries the resume bookkeeping.
            let persisted = try #require(await store.load().first { $0.id == job.id })
            #expect(persisted.uploadId == firstRun.uploadId)
            #expect(persisted.completedParts.count == 1)

            // Second run on a fresh engine. Drop the local part records so the
            // engine must recover server-side progress via listParts.
            var resumed = persisted
            resumed.completedParts = [:]
            let client = try Self.makeClient()
            let secondRun = await UploadEngine(client: client, store: store,
                                               partSize: 5 * Self.megabyte).run(job: resumed)
            #expect(secondRun.state == .done)

            #expect(try await client.objectSize(key: clipKey) == totalSize)
            let head = try await client.getObject(key: clipKey, range: 0...15)
            #expect(head == source.data.prefix(16))
            let middle = try await client.getObject(
                key: clipKey, range: (5 * Self.megabyte)...(5 * Self.megabyte + 15))
            #expect(middle == source.data.subdata(in: Int(5 * Self.megabyte)..<Int(5 * Self.megabyte + 16)))
            let tail = try await client.getObject(key: clipKey,
                                                  range: (totalSize - 16)...(totalSize - 1))
            #expect(tail == source.data.suffix(16))
        }
    }

    // MARK: - 5. Bucket reader/writer round trip

    @Test func bucketReaderWriterRoundTrip() async throws {
        let client = try Self.makeClient()
        let writer = BucketWriter(client: client)
        let reader = BucketReader(client: client)
        // createClient writes at the bucket root; track its prefix for cleanup.
        var createdPrefix: String?

        func run() async throws {
            let clientName = "IT Client \(UUID().uuidString.prefix(8))"
            let clientRef = try await writer.createClient(name: clientName)
            createdPrefix = clientRef.prefix

            var alpha = try await writer.createProject(name: "Alpha", in: clientRef.prefix)
            var beta = try await writer.createProject(name: "Beta", in: clientRef.prefix)

            // Rename, then reorder to [Beta, Alpha] — keeping refs in sync so a
            // later write can't clobber an earlier one.
            try await writer.renameProject(alpha, to: "Alpha Renamed")
            alpha.manifest.displayName = "Alpha Renamed"
            try await writer.setProjectOrder([beta, alpha])
            beta.manifest.sortIndex = 0
            alpha.manifest.sortIndex = 1

            let clients = try await reader.listClients()
            let found = try #require(clients.first { $0.prefix == clientRef.prefix })
            #expect(found.displayName == clientName)

            let projects = try await reader.listProjects(clientPrefix: clientRef.prefix)
            #expect(projects.map(\.prefix) == [beta.prefix, alpha.prefix])
            #expect(projects.map(\.manifest.displayName) == ["Beta", "Alpha Renamed"])
            #expect(projects.map(\.manifest.sortIndex) == [0, 1])
            #expect(projects.map(\.manifest.createdAt) == [beta.manifest.createdAt,
                                                           alpha.manifest.createdAt])

            // client.json + 2 project.json manifests.
            let preview = try await writer.deletionPreview(prefix: clientRef.prefix)
            #expect(preview.objectCount == 3)
            #expect(preview.totalBytes > 0)

            try await writer.deletePrefix(clientRef.prefix)
            let remaining = try await client.listObjects(prefix: clientRef.prefix, delimiter: nil)
            #expect(remaining.objects.isEmpty)
        }

        do {
            try await run()
        } catch {
            if let createdPrefix { await Self.cleanUp(prefix: createdPrefix, client: client) }
            throw error
        }
        if let createdPrefix { await Self.cleanUp(prefix: createdPrefix, client: client) }
    }

    // MARK: - 6. Download engine round trip

    @Test func downloadEngineRoundTrip() async throws {
        try await withTestPrefix { prefix, client in
            struct Fixture {
                var key: String
                var data: Data
                var sidecar: ClipSidecar
            }
            let sizes = [3000, 5000]
            let fixtures: [Fixture] = try (0..<2).map { index in
                let key = prefix + "clips/2026-09-19_1\(index)0000_cam-\(index)_e\(index)f\(index).mov"
                let data = Self.patternData(size: sizes[index], seed: 40 + index)
                let sidecar = Self.makeSidecar(
                    displayName: "Clip \(index)",
                    cameraLabel: "Cam \(index)",
                    capturedAt: Date(timeIntervalSince1970: 1_789_804_800 + Double(index) * 3600),
                    fileSize: Int64(sizes[index]),
                    originalFilename: "clip\(index).mov")
                return Fixture(key: key, data: data, sidecar: sidecar)
            }
            for fixture in fixtures {
                try await client.putObject(key: fixture.key, data: fixture.data,
                                           contentType: "video/quicktime")
                try await client.putObject(key: BucketKeys.sidecarKey(forClipKey: fixture.key),
                                           data: ManifestCoding.encode(fixture.sidecar),
                                           contentType: "application/json")
            }

            let clips = try await BucketReader(client: client).listClips(projectPrefix: prefix)
            #expect(clips.map(\.key) == fixtures.map(\.key))

            let filenames = DownloadNaming.filenames(forOrdered: clips)
            let items = zip(clips, filenames).map { DownloadEngine.Item(clip: $0, filename: $1) }
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "it-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let manifest = ProjectManifest(displayName: "IT Project", sortIndex: nil,
                                           createdAt: Date(timeIntervalSince1970: 1_789_800_000))
            let engine = DownloadEngine(client: client, chunkSize: 1024)
            try await engine.download(items: items, into: directory, projectManifest: manifest)

            for (fixture, filename) in zip(fixtures, filenames) {
                let local = try Data(contentsOf: directory.appending(path: filename))
                #expect(local == fixture.data)
            }
            let manifestData = try Data(contentsOf: directory.appending(path: "project.json"))
            #expect(try ManifestCoding.decode(ProjectManifest.self, from: manifestData) == manifest)

            // Truncate the first file to half and re-download: the engine must
            // resume with a ranged GET and restore the exact bytes.
            let truncatedURL = directory.appending(path: filenames[0])
            let handle = try FileHandle(forWritingTo: truncatedURL)
            try handle.truncate(atOffset: UInt64(sizes[0] / 2))
            try handle.close()

            try await DownloadEngine(client: client, chunkSize: 1024)
                .download(items: items, into: directory, projectManifest: manifest)
            let resumed = try Data(contentsOf: truncatedURL)
            #expect(resumed == fixtures[0].data)
        }
    }

    // MARK: - 7. Stale upload sweep

    @Test func staleUploadSweep() async throws {
        try await withTestPrefix { prefix, client in
            let key = prefix + "clips/2026-09-19_140000_cam-c_ef56.mov"
            let uploadId = try await client.createMultipartUpload(
                key: key, contentType: "video/quicktime")

            let before = try await client.listMultipartUploads(prefix: prefix)
            #expect(before.count == 1)
            #expect(before.first?.key == key)
            #expect(before.first?.uploadId == uploadId)

            let engine = UploadEngine(client: client, store: Self.makeStore())
            let aborted = try await engine.abandonStaleUploads(prefix: prefix, liveJobs: [],
                                                               olderThan: nil)
            #expect(aborted == 1)

            let after = try await client.listMultipartUploads(prefix: prefix)
            #expect(after.isEmpty)
        }
    }
}
