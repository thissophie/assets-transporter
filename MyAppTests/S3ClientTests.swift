import Foundation
import Testing
@testable import MyApp

/// Canned-response transport that records every request handed to it.
nonisolated final class RecordingTransport: S3Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(request: URLRequest, uploadFile: URL?)] = []
    private var responses: [(data: Data, status: Int, headers: [String: String])]

    init(responses: [(data: Data, status: Int, headers: [String: String])]) {
        self.responses = responses
    }

    convenience init(status: Int = 200, data: Data = Data(), headers: [String: String] = [:]) {
        self.init(responses: [(data: data, status: status, headers: headers)])
    }

    var requests: [(request: URLRequest, uploadFile: URL?)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func perform(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append((request: request, uploadFile: uploadFile))
        let canned = responses.isEmpty
            ? (data: Data(), status: 200, headers: [String: String]())
            : responses.removeFirst()
        lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: canned.status,
                                       httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        return (canned.data, response)
    }
}

struct S3ClientTests {

    private func makeClient(transport: RecordingTransport) -> S3Client {
        let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                              bucket: "video", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        return S3Client(config: config, transport: transport)
    }

    /// Every request the client sends must be SigV4-signed and date-stamped.
    private func expectAllSigned(_ transport: RecordingTransport) {
        for entry in transport.requests {
            let auth = entry.request.value(forHTTPHeaderField: "Authorization")
            #expect(auth?.hasPrefix("AWS4-HMAC-SHA256") == true)
            #expect(entry.request.value(forHTTPHeaderField: "x-amz-date") != nil)
        }
    }

    // 1. putObject(data)
    @Test func putObjectDataSendsSignedPut() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)

        try await client.putObject(key: "movies/a.mov", data: Data("hello".utf8),
                                   contentType: "video/quicktime")

        let requests = transport.requests
        #expect(requests.count == 1)
        let request = requests[0].request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/video/movies/a.mov")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == "UNSIGNED-PAYLOAD")
        #expect(request.httpBody == Data("hello".utf8))
        expectAllSigned(transport)
    }

    // 2. getObject with range
    @Test func getObjectWithRangeSetsRangeHeader() async throws {
        let transport = RecordingTransport(status: 206, data: Data(count: 500))
        let client = makeClient(transport: transport)

        let data = try await client.getObject(key: "a.mov", range: 0...499)

        #expect(data.count == 500)
        let request = transport.requests[0].request
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-499")
        expectAllSigned(transport)
    }

    // 3. non-2xx throws S3Error.http
    @Test func non2xxThrowsHTTPErrorWithBody() async throws {
        let transport = RecordingTransport(status: 500, data: Data("boom".utf8))
        let client = makeClient(transport: transport)

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            _ = try await client.getObject(key: "a.mov")
        }
    }

    // 4. listObjects follows continuation tokens
    @Test func listObjectsFollowsContinuationToken() async throws {
        let page1 = """
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>token-1</NextContinuationToken>
          <Contents><Key>a/one.mov</Key><Size>10</Size></Contents>
        </ListBucketResult>
        """
        let page2 = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>a/two.mov</Key><Size>20</Size></Contents>
          <CommonPrefixes><Prefix>a/sub/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let transport = RecordingTransport(responses: [
            (data: Data(page1.utf8), status: 200, headers: [:]),
            (data: Data(page2.utf8), status: 200, headers: [:]),
        ])
        let client = makeClient(transport: transport)

        let result = try await client.listObjects(prefix: "a/", delimiter: "/")

        #expect(result.objects.map(\.key) == ["a/one.mov", "a/two.mov"])
        #expect(result.commonPrefixes == ["a/sub/"])
        let requests = transport.requests
        #expect(requests.count == 2)
        let firstURL = requests[0].request.url?.absoluteString ?? ""
        #expect(firstURL.contains("list-type=2"))
        #expect(firstURL.contains("prefix=a%2F"))
        #expect(!firstURL.contains("continuation-token"))
        let secondURL = requests[1].request.url?.absoluteString ?? ""
        #expect(secondURL.contains("continuation-token=token-1"))
        expectAllSigned(transport)
    }

    // 5. createMultipartUpload
    @Test func createMultipartUploadParsesUploadId() async throws {
        let xml = """
        <InitiateMultipartUploadResult>
          <Bucket>video</Bucket>
          <Key>a.mov</Key>
          <UploadId>
            abc123
          </UploadId>
        </InitiateMultipartUploadResult>
        """
        let transport = RecordingTransport(data: Data(xml.utf8))
        let client = makeClient(transport: transport)

        let uploadId = try await client.createMultipartUpload(key: "a.mov", contentType: "video/quicktime")

        #expect(uploadId == "abc123")
        let request = transport.requests[0].request
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("?uploads") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
        expectAllSigned(transport)
    }

    // 6. uploadPart
    @Test func uploadPartPassesFileAndUnquotesETag() async throws {
        let transport = RecordingTransport(headers: ["ETag": "\"etag-2\""])
        let client = makeClient(transport: transport)
        let fileURL = URL(fileURLWithPath: "/tmp/part2.bin")

        let etag = try await client.uploadPart(key: "a.mov", uploadId: "abc", partNumber: 2,
                                               fileURL: fileURL)

        #expect(etag == "etag-2")
        let recorded = transport.requests[0]
        #expect(recorded.uploadFile == fileURL)
        let url = recorded.request.url?.absoluteString ?? ""
        #expect(url.contains("partNumber=2"))
        #expect(url.contains("uploadId=abc"))
        #expect(recorded.request.httpMethod == "PUT")
        expectAllSigned(transport)
    }

    private static let completeSuccessXML = """
    <CompleteMultipartUploadResult>
      <Location>https://minio.example.com:9000/video/a.mov</Location>
      <Key>a.mov</Key>
      <ETag>"final-etag"</ETag>
    </CompleteMultipartUploadResult>
    """

    // 7. completeMultipartUpload sorts parts and quotes ETags
    @Test func completeMultipartUploadSortsPartsInBody() async throws {
        let transport = RecordingTransport(data: Data(Self.completeSuccessXML.utf8))
        let client = makeClient(transport: transport)

        try await client.completeMultipartUpload(key: "a.mov", uploadId: "abc", parts: [
            (partNumber: 3, etag: "e3"),
            (partNumber: 1, etag: "e1"),
            (partNumber: 2, etag: "e2"),
        ])

        let request = transport.requests[0].request
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.contains("uploadId=abc") == true)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("<CompleteMultipartUpload>"))
        let expectedOrder = "<Part><PartNumber>1</PartNumber><ETag>\"e1\"</ETag></Part>"
            + "<Part><PartNumber>2</PartNumber><ETag>\"e2\"</ETag></Part>"
            + "<Part><PartNumber>3</PartNumber><ETag>\"e3\"</ETag></Part>"
        #expect(body.contains(expectedOrder))
        expectAllSigned(transport)
    }

    // 7b. completeMultipartUpload rejects HTTP 200 responses carrying an <Error> body
    @Test func completeMultipartUploadThrowsOnErrorBodyDespite200() async throws {
        let errorXML = """
        <Error>
          <Code>InternalError</Code>
          <Message>We encountered an internal error. Please try again.</Message>
        </Error>
        """
        let transport = RecordingTransport(data: Data(errorXML.utf8))
        let client = makeClient(transport: transport)

        await #expect(throws: S3Error.http(status: 200, body: errorXML)) {
            try await client.completeMultipartUpload(key: "a.mov", uploadId: "abc",
                                                     parts: [(partNumber: 1, etag: "e1")])
        }
    }

    // 7c. completeMultipartUpload succeeds on a valid CompleteMultipartUploadResult body
    @Test func completeMultipartUploadSucceedsOnResultBody() async throws {
        let transport = RecordingTransport(data: Data(Self.completeSuccessXML.utf8))
        let client = makeClient(transport: transport)

        try await client.completeMultipartUpload(key: "a.mov", uploadId: "abc",
                                                 parts: [(partNumber: 1, etag: "e1")])
        expectAllSigned(transport)
    }

    // 8. listParts parses parts and follows part-number-marker
    @Test func listPartsParsesXMLAndFollowsMarker() async throws {
        let page1 = """
        <ListPartsResult>
          <IsTruncated>true</IsTruncated>
          <NextPartNumberMarker>2</NextPartNumberMarker>
          <Part><PartNumber>1</PartNumber><ETag>"e1"</ETag><Size>100</Size></Part>
          <Part><PartNumber>2</PartNumber><ETag>"e2"</ETag><Size>200</Size></Part>
        </ListPartsResult>
        """
        let page2 = """
        <ListPartsResult>
          <IsTruncated>false</IsTruncated>
          <Part><PartNumber>3</PartNumber><ETag>"e3"</ETag><Size>50</Size></Part>
        </ListPartsResult>
        """
        let transport = RecordingTransport(responses: [
            (data: Data(page1.utf8), status: 200, headers: [:]),
            (data: Data(page2.utf8), status: 200, headers: [:]),
        ])
        let client = makeClient(transport: transport)

        let parts = try await client.listParts(key: "a.mov", uploadId: "abc")

        #expect(parts.count == 3)
        #expect(parts[0] == (partNumber: 1, etag: "e1", size: 100))
        #expect(parts[1] == (partNumber: 2, etag: "e2", size: 200))
        #expect(parts[2] == (partNumber: 3, etag: "e3", size: 50))
        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].request.url?.absoluteString.contains("part-number-marker=2") == true)
        expectAllSigned(transport)
    }

    // 9. listMultipartUploads
    @Test func listMultipartUploadsParsesXML() async throws {
        let xml = """
        <ListMultipartUploadsResult>
          <Upload><Key>a.mov</Key><UploadId>u1</UploadId></Upload>
          <Upload><Key>b.mov</Key><UploadId>u2</UploadId></Upload>
        </ListMultipartUploadsResult>
        """
        let transport = RecordingTransport(data: Data(xml.utf8))
        let client = makeClient(transport: transport)

        let uploads = try await client.listMultipartUploads(prefix: "a")

        #expect(uploads.count == 2)
        #expect(uploads[0] == (key: "a.mov", uploadId: "u1"))
        #expect(uploads[1] == (key: "b.mov", uploadId: "u2"))
        let url = transport.requests[0].request.url?.absoluteString ?? ""
        #expect(url.contains("uploads"))
        #expect(url.contains("prefix=a"))
        expectAllSigned(transport)
    }

    // 9b. listMultipartUploads follows key-marker/upload-id-marker pagination
    @Test func listMultipartUploadsFollowsMarkers() async throws {
        let page1 = """
        <ListMultipartUploadsResult>
          <IsTruncated>true</IsTruncated>
          <NextKeyMarker>b.mov</NextKeyMarker>
          <NextUploadIdMarker>u2</NextUploadIdMarker>
          <Upload><Key>a.mov</Key><UploadId>u1</UploadId></Upload>
          <Upload><Key>b.mov</Key><UploadId>u2</UploadId></Upload>
        </ListMultipartUploadsResult>
        """
        let page2 = """
        <ListMultipartUploadsResult>
          <IsTruncated>false</IsTruncated>
          <Upload><Key>c.mov</Key><UploadId>u3</UploadId></Upload>
        </ListMultipartUploadsResult>
        """
        let transport = RecordingTransport(responses: [
            (data: Data(page1.utf8), status: 200, headers: [:]),
            (data: Data(page2.utf8), status: 200, headers: [:]),
        ])
        let client = makeClient(transport: transport)

        let uploads = try await client.listMultipartUploads(prefix: "")

        #expect(uploads.count == 3)
        #expect(uploads[2] == (key: "c.mov", uploadId: "u3"))
        let requests = transport.requests
        #expect(requests.count == 2)
        let secondURL = requests[1].request.url?.absoluteString ?? ""
        #expect(secondURL.contains("key-marker=b.mov"))
        #expect(secondURL.contains("upload-id-marker=u2"))
        expectAllSigned(transport)
    }

    // 10. deleteObject
    @Test func deleteObjectSendsDelete() async throws {
        let transport = RecordingTransport(status: 204)
        let client = makeClient(transport: transport)

        try await client.deleteObject(key: "a.mov")

        let request = transport.requests[0].request
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/video/a.mov")
        expectAllSigned(transport)
    }

    // Abort multipart upload sends DELETE with uploadId
    @Test func abortMultipartUploadSendsDeleteWithUploadId() async throws {
        let transport = RecordingTransport(status: 204)
        let client = makeClient(transport: transport)

        try await client.abortMultipartUpload(key: "a.mov", uploadId: "abc")

        let request = transport.requests[0].request
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString.contains("uploadId=abc") == true)
        expectAllSigned(transport)
    }
}
