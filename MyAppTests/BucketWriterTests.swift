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
                                          from entry: (request: URLRequest, uploadFile: URL?,
                                                       uploadFileSize: Int64?, uploadFileData: Data?)) throws -> T {
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

    // 3b. renameClient preserves the hidden flag from the ref.
    @Test func renameClientPreservesHiddenFlag() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)
        let ref = ClientRef(prefix: "acme-corp-x7f2/", displayName: "Acme Corp", isHidden: true)

        try await writer.renameClient(ref, to: "Acme Corporation")

        let manifest = try decodeBody(ClientManifest.self, from: transport.requests[0])
        #expect(manifest == ClientManifest(displayName: "Acme Corporation", hidden: true))
    }

    // MARK: - setClientHidden

    // 3c. setClientHidden rewrites just that client's manifest with the flag,
    //     preserving the display name. Unhiding writes hidden as an *absent*
    //     key, restoring the pre-feature manifest shape.
    @Test func setClientHiddenRewritesManifestPreservingName() async throws {
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)
        let ref = ClientRef(prefix: "acme-corp-x7f2/", displayName: "Acme Corp")

        try await writer.setClientHidden(ref, hidden: true)
        try await writer.setClientHidden(ClientRef(prefix: ref.prefix,
                                                   displayName: ref.displayName,
                                                   isHidden: true),
                                         hidden: false)

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.request.httpMethod == "PUT" })
        #expect(requests.allSatisfy { $0.request.url?.path == "/video/acme-corp-x7f2/client.json" })

        let hidden = try decodeBody(ClientManifest.self, from: requests[0])
        #expect(hidden == ClientManifest(displayName: "Acme Corp", hidden: true))

        let unhidden = try decodeBody(ClientManifest.self, from: requests[1])
        #expect(unhidden == ClientManifest(displayName: "Acme Corp"))
        let unhiddenBody = try #require(requests[1].request.httpBody)
        #expect(!String(decoding: unhiddenBody, as: UTF8.self).contains("hidden"))
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

    // createProject stamps createdAt from the injected clock, truncated to whole
    // seconds so a write-then-read round-trips exactly through ISO8601.
    @Test func createProjectStampsTruncatedInjectedClock() async throws {
        let transport = RecordingTransport(responses: [])
        var writer = makeWriter(transport: transport)
        writer.now = { Date(timeIntervalSince1970: 1_700_000_000.75) }

        let ref = try await writer.createProject(name: "Spring Gala", in: "acme-corp-x7f2/")

        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ref.manifest.createdAt == expected)
        let manifest = try decodeBody(ProjectManifest.self, from: transport.requests[0])
        #expect(manifest.createdAt == expected)
    }

    // MARK: - Deletion

    private static let projectPrefix = "acme-corp-x7f2/spring-gala-k9q1/"

    private static let deletionListXML = """
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>\(projectPrefix)project.json</Key><Size>100</Size></Contents>
      <Contents><Key>\(projectPrefix)clips/2026-03-01_120000_cama_abc1.mov</Key><Size>200</Size></Contents>
      <Contents><Key>\(projectPrefix)clips/2026-03-01_120000_cama_abc1.mov.json</Key><Size>300</Size></Contents>
    </ListBucketResult>
    """

    private func makeClip(key: String) -> Clip {
        Clip(key: key,
             sidecar: ClipSidecar(displayName: "Clip",
                                  cameraLabel: nil, notes: nil, capturedAt: nil,
                                  orderOverride: nil, duration: nil,
                                  width: nil, height: nil, codec: nil,
                                  fileSize: 200,
                                  originalFilename: "clip.mov",
                                  sourceDevice: "iPhone 17"))
    }

    // 7. deletionPreview counts objects and sums bytes from the listing.
    @Test func deletionPreviewCountsObjectsAndSumsBytes() async throws {
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(Self.deletionListXML.utf8), 200))
        let writer = makeWriter(transport: transport)

        let preview = try await writer.deletionPreview(prefix: Self.projectPrefix)

        #expect(preview == DeletionPreview(objectCount: 3, totalBytes: 600))
        let listURL = transport.requests[0].request.url?.absoluteString.removingPercentEncoding ?? ""
        #expect(listURL.contains("prefix=\(Self.projectPrefix)"))
        #expect(!listURL.contains("delimiter"))
    }

    // 8. deletePrefix lists everything under the prefix and issues one DELETE
    //    per listed object, with exact keys.
    @Test func deletePrefixDeletesEveryListedObject() async throws {
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(Self.deletionListXML.utf8), 200))
        let writer = makeWriter(transport: transport)

        try await writer.deletePrefix(Self.projectPrefix)

        let requests = transport.requests
        #expect(requests.count == 4)   // 1 list + 3 deletes
        #expect(requests[0].request.httpMethod == "GET")
        let deletes = requests.dropFirst()
        #expect(deletes.allSatisfy { $0.request.httpMethod == "DELETE" })
        #expect(deletes.map(\.request.url?.path) == [
            "/video/\(Self.projectPrefix)project.json",
            "/video/\(Self.projectPrefix)clips/2026-03-01_120000_cama_abc1.mov",
            "/video/\(Self.projectPrefix)clips/2026-03-01_120000_cama_abc1.mov.json",
        ])
    }

    // 8b. Slash-less prefixes are normalized before listing so
    //     deletePrefix("acme-corp-x7f2") can never match a sibling like
    //     "acme-corp-x7f2b-.../" keys. Same guard for deletionPreview.
    @Test func deletionNormalizesPrefixWithTrailingSlash() async throws {
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(Self.deletionListXML.utf8), 200))
        let writer = makeWriter(transport: transport)

        _ = try await writer.deletionPreview(prefix: "acme-corp-x7f2")
        try await writer.deletePrefix("acme-corp-x7f2")

        let listURLs = transport.requests
            .filter { $0.request.httpMethod == "GET" }
            .map { $0.request.url?.absoluteString.removingPercentEncoding ?? "" }
        #expect(listURLs.count == 2)
        #expect(listURLs.allSatisfy { $0.contains("prefix=acme-corp-x7f2/") })
    }

    // 8c. deletePrefix halts on the first delete error: the failing key's error
    //     propagates and later keys are never attempted.
    @Test func deletePrefixHaltsOnFirstDeleteError() async throws {
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(Self.deletionListXML.utf8), 200))
        transport.respond(to: "abc1.mov", with: (Data("boom".utf8), 500))   // second of three keys
        let writer = makeWriter(transport: transport)

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            try await writer.deletePrefix(Self.projectPrefix)
        }

        let requests = transport.requests
        #expect(requests.count == 3)   // list + first two deletes only
        let deletePaths = requests.filter { $0.request.httpMethod == "DELETE" }
            .map { $0.request.url?.path ?? "" }
        #expect(deletePaths == [
            "/video/\(Self.projectPrefix)project.json",
            "/video/\(Self.projectPrefix)clips/2026-03-01_120000_cama_abc1.mov",
        ])
        #expect(!deletePaths.contains { $0.hasSuffix(".mov.json") })
    }

    // 9. deleteClip deletes the file, then its sidecar, then its thumbnail; a
    //    404 on the sidecar or thumbnail delete is tolerated (either may not exist).
    @Test func deleteClipDeletesFileSidecarAndThumbnailToleratingMissing() async throws {
        let clipKey = Self.projectPrefix + "clips/2026-03-01_120000_cama_abc1.mov"
        let transport = RecordingTransport(responses: [])
        transport.respond(to: ".mov.json", with: (Data("no such key".utf8), 404))
        transport.respond(to: ".mov.thumb.jpg", with: (Data("no such key".utf8), 404))
        let writer = makeWriter(transport: transport)

        try await writer.deleteClip(makeClip(key: clipKey))

        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.request.httpMethod == "DELETE" })
        #expect(requests[0].request.url?.path == "/video/\(clipKey)")
        #expect(requests[1].request.url?.path == "/video/\(clipKey).json")
        #expect(requests[2].request.url?.path == "/video/\(clipKey).thumb.jpg")
    }

    // 10. A 404 on the FILE delete propagates (and the sidecar delete never runs).
    @Test func deleteClipPropagates404OnFileDelete() async throws {
        let clipKey = Self.projectPrefix + "clips/2026-03-01_120000_cama_abc1.mov"
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "abc1.mov", with: (Data("gone".utf8), 404))
        let writer = makeWriter(transport: transport)

        await #expect(throws: S3Error.http(status: 404, body: "gone")) {
            try await writer.deleteClip(makeClip(key: clipKey))
        }
        #expect(transport.requests.count == 1)
    }

    // 10b. deleteClips deletes each clip (file, sidecar, thumbnail) in order.
    @Test func deleteClipsDeletesEachClipInOrder() async throws {
        let keys = [
            Self.projectPrefix + "clips/2026-03-01_120000_cama_abc1.mov",
            Self.projectPrefix + "clips/2026-03-01_130000_camb_def2.mov",
        ]
        let transport = RecordingTransport(responses: [])
        let writer = makeWriter(transport: transport)

        try await writer.deleteClips(keys.map(makeClip))

        let requests = transport.requests
        #expect(requests.count == 6)
        #expect(requests.allSatisfy { $0.request.httpMethod == "DELETE" })
        #expect(requests.map(\.request.url?.path) == [
            "/video/\(keys[0])",
            "/video/\(keys[0]).json",
            "/video/\(keys[0]).thumb.jpg",
            "/video/\(keys[1])",
            "/video/\(keys[1]).json",
            "/video/\(keys[1]).thumb.jpg",
        ])
    }

    // 10c. deleteClips halts on the first failing clip: the error propagates
    //      and later clips are never attempted.
    @Test func deleteClipsHaltsOnFirstFailure() async throws {
        let keys = [
            Self.projectPrefix + "clips/2026-03-01_120000_cama_abc1.mov",
            Self.projectPrefix + "clips/2026-03-01_130000_camb_def2.mov",
        ]
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "abc1.mov", with: (Data("boom".utf8), 500))
        let writer = makeWriter(transport: transport)

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            try await writer.deleteClips(keys.map(makeClip))
        }
        #expect(transport.requests.count == 1)   // first file delete only
    }

    // 11. Non-404 errors on the sidecar delete propagate.
    @Test func deleteClipPropagatesNon404SidecarError() async throws {
        let clipKey = Self.projectPrefix + "clips/2026-03-01_120000_cama_abc1.mov"
        let transport = RecordingTransport(responses: [])
        transport.respond(to: ".mov.json", with: (Data("boom".utf8), 500))
        let writer = makeWriter(transport: transport)

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            try await writer.deleteClip(makeClip(key: clipKey))
        }
        #expect(transport.requests.count == 2)
    }
}
