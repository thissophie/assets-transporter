import Foundation
import Testing
@testable import MyApp

struct BucketWriterTests {

    private func makeWriter(transport: RecordingTransport) -> BucketWriter {
        let config = S3Config(endpoint: URL(string: "https://example.com")!,
                              bucket: "video", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        return BucketWriter(client: S3Client(config: config, transport: transport))
    }

    private func decodeBody<T: Decodable>(_ type: T.Type,
                                          from entry: (request: URLRequest, uploadFile: URL?)) throws -> T {
        let body = try #require(entry.request.httpBody)
        return try ManifestCoding.decode(type, from: body)
    }

    // MARK: - createClient

    // 1. createClient puts a decodable ClientManifest at <slug>/client.json and
    //    returns a matching ClientRef. Slug shape: name-slug + 4-char short id + "/".
    @Test func createClientPutsManifestAndReturnsRef() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)

        let ref = try await writer.createClient(name: "Acme Corp")

        #expect(ref.displayName == "Acme Corp")
        #expect(ref.prefix.range(of: "^[a-z0-9-]+-[a-z0-9]{4}/$",
                                 options: .regularExpression) != nil)
        #expect(ref.prefix.hasPrefix("acme-corp-"))

        let requests = transport.requests
        #expect(requests.count == 1)
        let request = requests[0].request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/video/\(ref.prefix)client.json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let manifest = try decodeBody(ClientManifest.self, from: requests[0])
        #expect(manifest == ClientManifest(displayName: "Acme Corp"))
    }

    // MARK: - createProject

    // 2. createProject nests under the client prefix; manifest has the name and
    //    nil sortIndex.
    @Test func createProjectNestsUnderClientPrefix() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)

        let ref = try await writer.createProject(name: "Spring Gala", in: "acme-corp-x7f2/")

        #expect(ref.prefix.range(of: "^acme-corp-x7f2/[a-z0-9-]+-[a-z0-9]{4}/$",
                                 options: .regularExpression) != nil)
        #expect(ref.prefix.hasPrefix("acme-corp-x7f2/spring-gala-"))
        #expect(ref.manifest.displayName == "Spring Gala")
        #expect(ref.manifest.sortIndex == nil)

        let requests = transport.requests
        #expect(requests.count == 1)
        let request = requests[0].request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/video/\(ref.prefix)project.json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let manifest = try decodeBody(ProjectManifest.self, from: requests[0])
        #expect(manifest.displayName == "Spring Gala")
        #expect(manifest.sortIndex == nil)
    }

    // MARK: - rename

    // 3. renameClient rewrites just that client's manifest with the new name.
    @Test func renameClientRewritesManifest() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)
        let ref = ClientRef(prefix: "acme-corp-x7f2/", displayName: "Acme Corp")

        try await writer.renameClient(ref, to: "Acme Corporation")

        let requests = transport.requests
        #expect(requests.count == 1)
        let request = requests[0].request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/video/acme-corp-x7f2/client.json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let manifest = try decodeBody(ClientManifest.self, from: requests[0])
        #expect(manifest == ClientManifest(displayName: "Acme Corporation"))
    }

    // 4. renameProject changes displayName but preserves sortIndex and createdAt.
    @Test func renameProjectPreservesSortIndexAndCreatedAt() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)   // whole seconds: ISO8601 round-trips
        let ref = ProjectRef(prefix: "acme-corp-x7f2/spring-gala-k9q1/",
                             manifest: ProjectManifest(displayName: "Spring Gala",
                                                       sortIndex: 3, createdAt: createdAt))

        try await writer.renameProject(ref, to: "Spring Gala 2026")

        let requests = transport.requests
        #expect(requests.count == 1)
        let request = requests[0].request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/video/acme-corp-x7f2/spring-gala-k9q1/project.json")
        let manifest = try decodeBody(ProjectManifest.self, from: requests[0])
        #expect(manifest == ProjectManifest(displayName: "Spring Gala 2026",
                                            sortIndex: 3, createdAt: createdAt))
    }

    // MARK: - setProjectOrder

    // 5. setProjectOrder writes sortIndex = array position to each manifest,
    //    preserving displayName and createdAt.
    @Test func setProjectOrderWritesPositionsToEachManifest() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)
        let base = "acme-corp-x7f2/"
        let dates = [Date(timeIntervalSince1970: 1_000_000),
                     Date(timeIntervalSince1970: 2_000_000),
                     Date(timeIntervalSince1970: 3_000_000)]
        let refs = [
            ProjectRef(prefix: base + "winter-ball-a1b2/",
                       manifest: ProjectManifest(displayName: "Winter Ball",
                                                 sortIndex: 5, createdAt: dates[0])),
            ProjectRef(prefix: base + "spring-gala-k9q1/",
                       manifest: ProjectManifest(displayName: "Spring Gala",
                                                 sortIndex: nil, createdAt: dates[1])),
            ProjectRef(prefix: base + "autumn-fest-c3d4/",
                       manifest: ProjectManifest(displayName: "Autumn Fest",
                                                 sortIndex: 0, createdAt: dates[2])),
        ]

        try await writer.setProjectOrder(refs)

        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests.map(\.request.url?.path) == [
            "/video/\(base)winter-ball-a1b2/project.json",
            "/video/\(base)spring-gala-k9q1/project.json",
            "/video/\(base)autumn-fest-c3d4/project.json",
        ])
        #expect(requests.allSatisfy { $0.request.httpMethod == "PUT" })

        let manifests = try requests.map { try decodeBody(ProjectManifest.self, from: $0) }
        #expect(manifests == [
            ProjectManifest(displayName: "Winter Ball", sortIndex: 0, createdAt: dates[0]),
            ProjectManifest(displayName: "Spring Gala", sortIndex: 1, createdAt: dates[1]),
            ProjectManifest(displayName: "Autumn Fest", sortIndex: 2, createdAt: dates[2]),
        ])
    }

    // MARK: - updateClipSidecar

    // 6. updateClipSidecar puts the encoded sidecar at <clipKey>.json.
    @Test func updateClipSidecarPutsToSidecarKey() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)
        let clipKey = "acme-corp-x7f2/spring-gala-k9q1/clips/2026-03-01_120000_cama_abc1.mov"
        let sidecar = ClipSidecar(displayName: "Ceremony",
                                  cameraLabel: "Cam A", notes: "wide shot",
                                  capturedAt: Date(timeIntervalSince1970: 1_772_000_000),
                                  orderOverride: nil, duration: 12.5,
                                  width: 3840, height: 2160, codec: "hevc",
                                  fileSize: 1000,
                                  originalFilename: "ceremony.mov",
                                  sourceDevice: "iPhone 17")

        try await writer.updateClipSidecar(clipKey: clipKey, sidecar: sidecar)

        let requests = transport.requests
        #expect(requests.count == 1)
        let request = requests[0].request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/video/\(clipKey).json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let decoded = try decodeBody(ClipSidecar.self, from: requests[0])
        #expect(decoded == sidecar)
    }
}
