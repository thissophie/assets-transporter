import Foundation
import Testing
@testable import MyApp

/// Thread-safe collector for progress callback values.
private nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

struct UploadEngineTests {

    // MARK: - Fixtures

    private static let clipKey = "acme/gala/clips/2026-09-19_183042_cam-a_e51f.mov"

    private func makeClient(transport: RecordingTransport) -> S3Client {
        let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                              bucket: "video", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        return S3Client(config: config, transport: transport)
    }

    private func makeStore() -> UploadQueueStore {
        UploadQueueStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "engine-tests-\(UUID().uuidString)"))
    }

    private func makeEngine(transport: RecordingTransport, store: UploadQueueStore,
                            partSize: Int64 = 100) -> UploadEngine {
        UploadEngine(client: makeClient(transport: transport), store: store, partSize: partSize)
    }

    /// Writes `count` patterned bytes to a temp file; caller cleans up.
    private func makeSource(bytes count: Int) throws -> (url: URL, data: Data) {
        let data = Data((0..<count).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory
            .appending(path: "engine-src-\(UUID().uuidString).mov")
        try data.write(to: url)
        return (url, data)
    }

    private func makeJob(sourceURL: URL,
                         clipKey: String = UploadEngineTests.clipKey,
                         uploadId: String? = nil,
                         state: UploadJob.State = .waiting,
                         partSize: Int64 = 100,
                         totalSize: Int64 = 300,
                         completedParts: [Int: String] = [:]) -> UploadJob {
        UploadJob(
            id: UUID(),
            sourceURL: sourceURL,
            sourceBookmark: nil,
            clipKey: clipKey,
            sidecar: ClipSidecar(displayName: "Clip", cameraLabel: "Cam A", notes: nil,
                                 capturedAt: Date(timeIntervalSince1970: 1_758_300_000),
                                 orderOverride: nil, duration: 12.5, width: 3840, height: 2160,
                                 codec: "hvc1", fileSize: totalSize,
                                 originalFilename: "clip.mov", sourceDevice: "test"),
            uploadId: uploadId,
            state: state,
            partSize: partSize,
            totalSize: totalSize,
            completedParts: completedParts
        )
    }

    private func ok(_ xml: String) -> (data: Data, status: Int, headers: [String: String]) {
        (data: Data(xml.utf8), status: 200, headers: [:])
    }

    private func etag(_ value: String) -> (data: Data, status: Int, headers: [String: String]) {
        (data: Data(), status: 200, headers: ["ETag": "\"\(value)\""])
    }

    private func createXML(_ uploadId: String) -> String {
        """
        <InitiateMultipartUploadResult>
          <Bucket>video</Bucket>
          <Key>\(Self.clipKey)</Key>
          <UploadId>\(uploadId)</UploadId>
        </InitiateMultipartUploadResult>
        """
    }

    private var completeXML: String {
        """
        <CompleteMultipartUploadResult>
          <Key>\(Self.clipKey)</Key>
          <ETag>"final-etag"</ETag>
        </CompleteMultipartUploadResult>
        """
    }

    // MARK: - 1. Happy path

    @Test func happyPathUploadsAllPartsThenCompletesThenSidecarLast() async throws {
        let (sourceURL, sourceData) = try makeSource(bytes: 300)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transport = RecordingTransport(responses: [
            ok(createXML("fresh-1")),
            etag("e1"), etag("e2"), etag("e3"),
            ok(completeXML),
            ok(""),                             // sidecar PUT
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)
        let progress = ProgressBox()

        let result = await engine.run(job: makeJob(sourceURL: sourceURL)) { progress.append($0) }

        // Final state, persisted.
        #expect(result.state == .done)
        #expect(result.uploadId == "fresh-1")
        #expect(result.completedParts == [1: "e1", 2: "e2", 3: "e3"])
        #expect(store.load() == [result])

        // Request sequence: create, parts 1-3 ascending, complete, sidecar LAST.
        let requests = transport.requests
        #expect(requests.count == 6)
        #expect(requests[0].request.httpMethod == "POST")
        #expect(requests[0].request.url?.absoluteString.hasSuffix("?uploads") == true)
        #expect(requests[0].request.value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
        for (index, partNumber) in [(1, 1), (2, 2), (3, 3)] {
            let entry = requests[index]
            #expect(entry.request.httpMethod == "PUT")
            let url = entry.request.url?.absoluteString ?? ""
            #expect(url.contains("partNumber=\(partNumber)"))
            #expect(url.contains("uploadId=fresh-1"))
            // Exact bytes of each slice were streamed from a 100-byte part file.
            #expect(entry.uploadFileSize == 100)
            let lower = (partNumber - 1) * 100
            #expect(entry.uploadFileData == sourceData[lower..<(lower + 100)])
        }
        #expect(requests[4].request.httpMethod == "POST")
        #expect(requests[4].request.url?.absoluteString.contains("uploadId=fresh-1") == true)
        let completeBody = String(decoding: requests[4].request.httpBody ?? Data(), as: UTF8.self)
        #expect(completeBody.contains("<PartNumber>1</PartNumber><ETag>\"e1\"</ETag>"))
        #expect(completeBody.contains("<PartNumber>3</PartNumber><ETag>\"e3\"</ETag>"))
        let sidecarRequest = requests[5].request
        #expect(sidecarRequest.httpMethod == "PUT")
        #expect(sidecarRequest.url?.path == "/video/\(Self.clipKey).json")
        #expect(sidecarRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let decoded = try ManifestCoding.decode(ClipSidecar.self,
                                                from: sidecarRequest.httpBody ?? Data())
        #expect(decoded == result.sidecar)

        // Progress ascended and ended at 1.0.
        #expect(progress.all == [1.0 / 3.0, 2.0 / 3.0, 1.0])

        // Temp part files were cleaned up.
        for entry in requests[1...3] {
            let partURL = try #require(entry.uploadFile)
            #expect(!FileManager.default.fileExists(atPath: partURL.path))
        }
    }

    // MARK: - 2. Resume from server-side progress

    @Test func resumeRecoversListedPartsAndUploadsOnlyMissing() async throws {
        let (sourceURL, sourceData) = try makeSource(bytes: 300)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let listPartsXML = """
        <ListPartsResult>
          <IsTruncated>false</IsTruncated>
          <Part><PartNumber>1</PartNumber><ETag>"e1"</ETag><Size>100</Size></Part>
          <Part><PartNumber>2</PartNumber><ETag>"e2"</ETag><Size>100</Size></Part>
        </ListPartsResult>
        """
        let transport = RecordingTransport(responses: [
            ok(listPartsXML),
            etag("e3"),
            ok(completeXML),
            ok(""),
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)
        let job = makeJob(sourceURL: sourceURL, uploadId: "u1",
                          state: .failed(message: "network down"))

        let result = await engine.run(job: job)

        #expect(result.state == .done)
        #expect(result.completedParts == [1: "e1", 2: "e2", 3: "e3"])
        let requests = transport.requests
        #expect(requests.count == 4)
        #expect(requests[0].request.httpMethod == "GET")
        #expect(requests[0].request.url?.absoluteString.contains("uploadId=u1") == true)
        // Exactly one part uploaded: part 3, with part 3's bytes.
        let partRequests = requests.filter {
            ($0.request.url?.absoluteString ?? "").contains("partNumber=")
        }
        #expect(partRequests.count == 1)
        #expect(partRequests[0].request.url?.absoluteString.contains("partNumber=3") == true)
        #expect(partRequests[0].uploadFileData == sourceData[200..<300])
        #expect(requests[3].request.url?.path.hasSuffix(".json") == true)
    }

    // MARK: - 3. Mid-upload failure persists resumable state

    @Test func partFailurePersistsCompletedPartsAndUploadId() async throws {
        let (sourceURL, _) = try makeSource(bytes: 300)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transport = RecordingTransport(responses: [
            ok(createXML("fresh-1")),
            etag("e1"),
            (data: Data("boom".utf8), status: 500, headers: [:]),
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)

        let result = await engine.run(job: makeJob(sourceURL: sourceURL))

        guard case .failed = result.state else {
            Issue.record("expected .failed, got \(result.state)")
            return
        }
        #expect(result.uploadId == "fresh-1")
        #expect(result.completedParts == [1: "e1"])
        #expect(store.load() == [result])

        // No complete, no abort, no sidecar after the failure.
        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(!requests.contains { $0.request.httpMethod == "DELETE" })
        #expect(!requests.contains { ($0.request.url?.path ?? "").hasSuffix(".json") })
        // Failed part's temp file was still cleaned up.
        let failedPartURL = try #require(requests[2].uploadFile)
        #expect(!FileManager.default.fileExists(atPath: failedPartURL.path))
    }

    // MARK: - 4. Sidecar strictly after successful complete

    @Test func completeErrorBodyMeansNoSidecarPut() async throws {
        let (sourceURL, _) = try makeSource(bytes: 300)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let errorXML = "<Error><Code>InternalError</Code><Message>try again</Message></Error>"
        let transport = RecordingTransport(responses: [
            ok(createXML("fresh-1")),
            etag("e1"), etag("e2"), etag("e3"),
            ok(errorXML),                       // HTTP 200 but an <Error> body
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)

        let result = await engine.run(job: makeJob(sourceURL: sourceURL))

        guard case .failed = result.state else {
            Issue.record("expected .failed, got \(result.state)")
            return
        }
        let requests = transport.requests
        #expect(requests.count == 5)
        #expect(!requests.contains { ($0.request.url?.path ?? "").hasSuffix(".json") })
        // Parts are kept for resume: uploadId and ETags survive the failure.
        #expect(result.uploadId == "fresh-1")
        #expect(result.completedParts.count == 3)
        #expect(store.load() == [result])
    }

    // MARK: - 5. Stale uploadId (NoSuchUpload) restarts fresh

    @Test func noSuchUploadOnListPartsStartsFreshMultipart() async throws {
        let (sourceURL, _) = try makeSource(bytes: 300)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transport = RecordingTransport(responses: [
            (data: Data("<Error><Code>NoSuchUpload</Code></Error>".utf8), status: 404, headers: [:]),
            ok(createXML("fresh-2")),
            etag("e1"), etag("e2"), etag("e3"),
            ok(completeXML),
            ok(""),
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)
        let job = makeJob(sourceURL: sourceURL, uploadId: "gone",
                          state: .uploading(uploadId: "gone"))

        let result = await engine.run(job: job)

        #expect(result.state == .done)
        #expect(result.uploadId == "fresh-2")
        let requests = transport.requests
        #expect(requests.count == 7)
        #expect(requests[1].request.httpMethod == "POST")
        #expect(requests[1].request.url?.absoluteString.hasSuffix("?uploads") == true)
    }

    // MARK: - 6. abandonStaleUploads

    private var listUploadsXML: String {
        """
        <ListMultipartUploadsResult>
          <Upload><Key>acme/a.mov</Key><UploadId>u1</UploadId></Upload>
          <Upload><Key>acme/b.mov</Key><UploadId>u2</UploadId></Upload>
        </ListMultipartUploadsResult>
        """
    }

    @Test func abandonStaleUploadsSkipsLiveJobs() async throws {
        let transport = RecordingTransport(responses: [
            ok(listUploadsXML),
            (data: Data(), status: 204, headers: [:]),
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)
        let live = makeJob(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                           clipKey: "acme/a.mov", uploadId: "u1",
                           state: .uploading(uploadId: "u1"))

        let aborted = try await engine.abandonStaleUploads(prefix: "acme/", liveJobs: [live])

        #expect(aborted == 1)
        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].request.httpMethod == "DELETE")
        #expect(requests[1].request.url?.path == "/video/acme/b.mov")
        #expect(requests[1].request.url?.absoluteString.contains("uploadId=u2") == true)
    }

    @Test func abandonStaleUploadsSwallowsIndividualAbortFailures() async throws {
        let transport = RecordingTransport(responses: [
            ok(listUploadsXML),
            (data: Data("boom".utf8), status: 500, headers: [:]),   // abort u1 fails
            (data: Data(), status: 204, headers: [:]),              // abort u2 succeeds
        ])
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)

        let aborted = try await engine.abandonStaleUploads(prefix: "acme/", liveJobs: [])

        #expect(aborted == 1)
        let deletes = transport.requests.filter { $0.request.httpMethod == "DELETE" }
        #expect(deletes.count == 2)
    }

    @Test func abandonStaleUploadsPropagatesListingErrors() async throws {
        let transport = RecordingTransport(status: 500, data: Data("boom".utf8))
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            _ = try await engine.abandonStaleUploads(prefix: "acme/", liveJobs: [])
        }
    }

    // MARK: - 7. Done job is a no-op

    @Test func doneJobReturnsUnchangedWithZeroRequests() async throws {
        let transport = RecordingTransport()
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let engine = makeEngine(transport: transport, store: store)
        let job = makeJob(sourceURL: URL(fileURLWithPath: "/tmp/missing.mov"),
                          uploadId: "u1", state: .done,
                          completedParts: [1: "e1", 2: "e2", 3: "e3"])

        let result = await engine.run(job: job)

        #expect(result == job)
        #expect(transport.requests.isEmpty)
        #expect(store.load().isEmpty)
    }
}
