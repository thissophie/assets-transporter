import Foundation
import Testing
@testable import MyApp

struct BucketReaderTests {

    private func makeReader(transport: RecordingTransport) -> BucketReader {
        let config = S3Config(endpoint: URL(string: "https://example.com")!,
                              bucket: "video", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        return BucketReader(client: S3Client(config: config, transport: transport))
    }

    // MARK: - listClients

    // 1. Unreadable client.json must not hide the client; sorted by displayName.
    @Test func listClientsFallsBackForUnreadableManifestAndSortsByName() async throws {
        let listXML = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>beta-films-q2w3/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>acme-corp-x7f2/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(listXML.utf8), 200))
        transport.respond(to: "acme-corp-x7f2/client.json",
                          with: (Data(#"{"displayName":"Acme Corp"}"#.utf8), 200))
        transport.respond(to: "beta-films-q2w3/client.json",
                          with: (Data("<Error><Code>NoSuchKey</Code></Error>".utf8), 404))
        let reader = makeReader(transport: transport)

        let clients = try await reader.listClients()

        #expect(clients == [
            ClientRef(prefix: "acme-corp-x7f2/", displayName: "Acme Corp"),
            ClientRef(prefix: "beta-films-q2w3/", displayName: "beta-films-q2w3"),
        ])
    }

    // 1b. hidden: true in client.json surfaces as isHidden; an absent key
    //     (pre-feature manifest) means visible.
    @Test func listClientsReadsHiddenFlag() async throws {
        let listXML = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>acme-corp-x7f2/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>beta-films-q2w3/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(listXML.utf8), 200))
        transport.respond(to: "acme-corp-x7f2/client.json",
                          with: (Data(#"{"displayName":"Acme Corp","hidden":true}"#.utf8), 200))
        transport.respond(to: "beta-films-q2w3/client.json",
                          with: (Data(#"{"displayName":"Beta Films"}"#.utf8), 200))
        let reader = makeReader(transport: transport)

        let clients = try await reader.listClients()

        #expect(clients == [
            ClientRef(prefix: "acme-corp-x7f2/", displayName: "Acme Corp", isHidden: true),
            ClientRef(prefix: "beta-films-q2w3/", displayName: "Beta Films", isHidden: false),
        ])
    }

    // MARK: - listProjects

    // 2. Order: (sortIndex ?? Int.max) ascending, then createdAt, then displayName.
    //    Indexed projects come first; nil-index ones follow ordered by createdAt.
    @Test func listProjectsSortsByIndexThenCreatedAt() async throws {
        let listXML = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>acme-corp-x7f2/autumn-fest-c3d4/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>acme-corp-x7f2/spring-gala-k9q1/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>acme-corp-x7f2/winter-ball-a1b2/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(listXML.utf8), 200))
        transport.respond(to: "spring-gala-k9q1/project.json", with: (Data("""
            {"displayName":"Spring Gala","sortIndex":2,"createdAt":"2026-02-01T00:00:00Z"}
            """.utf8), 200))
        transport.respond(to: "autumn-fest-c3d4/project.json", with: (Data("""
            {"displayName":"Autumn Fest","createdAt":"2026-01-01T00:00:00Z"}
            """.utf8), 200))
        transport.respond(to: "winter-ball-a1b2/project.json", with: (Data(), 404))
        let reader = makeReader(transport: transport)

        let projects = try await reader.listProjects(clientPrefix: "acme-corp-x7f2/")

        // spring-gala has sortIndex 2 -> first. The other two have nil sortIndex
        // (Int.max) and order by createdAt: fallback (.distantPast) before Autumn Fest.
        #expect(projects.map(\.prefix) == [
            "acme-corp-x7f2/spring-gala-k9q1/",
            "acme-corp-x7f2/winter-ball-a1b2/",
            "acme-corp-x7f2/autumn-fest-c3d4/",
        ])
        #expect(projects[0].manifest.displayName == "Spring Gala")
        #expect(projects[0].manifest.sortIndex == 2)
        // 404 fallback manifest: last path component, nil index, distantPast.
        #expect(projects[1].manifest == ProjectManifest(displayName: "winter-ball-a1b2",
                                                        sortIndex: nil,
                                                        createdAt: .distantPast))
        #expect(projects[2].manifest.displayName == "Autumn Fest")
    }

    // 2b. displayName ties break case-insensitively (like listClients), and a
    //     case-insensitively equal name falls through to the prefix tiebreak.
    @Test func listProjectsSortsNamesCaseInsensitivelyWithPrefixTiebreak() async throws {
        let listXML = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>acme-corp-x7f2/z-proj/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>acme-corp-x7f2/a-proj/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>acme-corp-x7f2/m-proj/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(listXML.utf8), 200))
        // Same (nil) sortIndex and identical createdAt everywhere: only the
        // displayName (then prefix) tiebreaks apply.
        transport.respond(to: "z-proj/project.json", with: (Data("""
            {"displayName":"alpha","createdAt":"2026-01-01T00:00:00Z"}
            """.utf8), 200))
        transport.respond(to: "a-proj/project.json", with: (Data("""
            {"displayName":"ALPHA","createdAt":"2026-01-01T00:00:00Z"}
            """.utf8), 200))
        transport.respond(to: "m-proj/project.json", with: (Data("""
            {"displayName":"Beta","createdAt":"2026-01-01T00:00:00Z"}
            """.utf8), 200))
        let reader = makeReader(transport: transport)

        let projects = try await reader.listProjects(clientPrefix: "acme-corp-x7f2/")

        // Case-insensitive: both alphas before Beta (case-sensitive ASCII would
        // put "Beta" before "alpha"); "ALPHA"/"alpha" tie -> prefix ascending.
        #expect(projects.map(\.prefix) == [
            "acme-corp-x7f2/a-proj/",
            "acme-corp-x7f2/z-proj/",
            "acme-corp-x7f2/m-proj/",
        ])
    }

    // MARK: - listClips

    // 3. Sidecars merge onto clips; missing sidecar -> fallback; sidecar objects
    //    themselves never appear as clips; ordered by effectiveTime.
    @Test func listClipsMergesSidecarsAndFallsBackForMissingOnes() async throws {
        let base = "acme-corp-x7f2/spring-gala-k9q1/clips/"
        let listXML = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>\(base)2026-03-01_120000_cama_abc1.mov</Key><Size>1000</Size></Contents>
          <Contents><Key>\(base)2026-03-01_120000_cama_abc1.mov.json</Key><Size>300</Size></Contents>
          <Contents><Key>\(base)2026-02-01_090000_camb_def2.mov</Key><Size>2000</Size></Contents>
        </ListBucketResult>
        """
        let sidecarJSON = """
        {"displayName":"Ceremony","capturedAt":"2026-03-01T12:00:00Z","fileSize":1000,
         "originalFilename":"ceremony.mov","sourceDevice":"iPhone 17"}
        """
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(listXML.utf8), 200))
        transport.respond(to: "abc1.mov.json", with: (Data(sidecarJSON.utf8), 200))
        let reader = makeReader(transport: transport)

        let clips = try await reader.listClips(projectPrefix: "acme-corp-x7f2/spring-gala-k9q1/")

        #expect(clips.count == 2)
        #expect(!clips.contains { $0.key.hasSuffix(".json") })

        // Ordered by effectiveTime: February clip before March clip.
        #expect(clips.map(\.key) == [
            base + "2026-02-01_090000_camb_def2.mov",
            base + "2026-03-01_120000_cama_abc1.mov",
        ])

        // Missing sidecar -> fallback synthesized from key + listing entry.
        let fallback = clips[0].sidecar
        #expect(fallback.displayName == "2026-02-01_090000_camb_def2")
        #expect(fallback.capturedAt == BucketKeys.parseClipTimestamp(fromKey: clips[0].key))
        #expect(fallback.fileSize == 2000)
        #expect(fallback.originalFilename == "2026-02-01_090000_camb_def2.mov")
        #expect(fallback.sourceDevice == "unknown")
        #expect(fallback.cameraLabel == nil)
        #expect(fallback.notes == nil)
        #expect(fallback.orderOverride == nil)
        #expect(fallback.duration == nil)

        // Present sidecar decodes and carries its values.
        #expect(clips[1].sidecar.displayName == "Ceremony")
        #expect(clips[1].sidecar.fileSize == 1000)
        #expect(clips[1].sidecar.sourceDevice == "iPhone 17")

        // Exactly one list + one sidecar GET: the clip without a sidecar in the
        // listing must not trigger a speculative sidecar fetch.
        #expect(transport.requests.count == 2)

        // The listing request targeted <project>/clips/ with no delimiter.
        let listRequest = transport.requests[0].request
        let listURL = listRequest.url?.absoluteString.removingPercentEncoding ?? ""
        #expect(listURL.contains("prefix=acme-corp-x7f2/spring-gala-k9q1/clips/"))
        #expect(!listURL.contains("delimiter"))
    }

    // 4. Sidecar that exists but fails to decode -> fallback sidecar, no throw.
    @Test func listClipsFallsBackWhenSidecarFailsToDecode() async throws {
        let base = "acme-corp-x7f2/spring-gala-k9q1/clips/"
        let listXML = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>\(base)2026-03-01_120000_cama_abc1.mov</Key><Size>1000</Size></Contents>
          <Contents><Key>\(base)2026-03-01_120000_cama_abc1.mov.json</Key><Size>12</Size></Contents>
        </ListBucketResult>
        """
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data(listXML.utf8), 200))
        transport.respond(to: "abc1.mov.json", with: (Data("not valid json".utf8), 200))
        let reader = makeReader(transport: transport)

        let clips = try await reader.listClips(projectPrefix: "acme-corp-x7f2/spring-gala-k9q1/")

        #expect(clips.count == 1)
        let sidecar = clips[0].sidecar
        #expect(sidecar.displayName == "2026-03-01_120000_cama_abc1")
        #expect(sidecar.fileSize == 1000)
        #expect(sidecar.originalFilename == "2026-03-01_120000_cama_abc1.mov")
        #expect(sidecar.sourceDevice == "unknown")
        #expect(sidecar.capturedAt == BucketKeys.parseClipTimestamp(fromKey: clips[0].key))
    }

    // 5. A failing listing (500) propagates from all three methods.
    @Test func listFailurePropagatesFromAllThreeMethods() async throws {
        let transport = RecordingTransport(responses: [])
        transport.respond(to: "list-type=2", with: (Data("boom".utf8), 500))
        let reader = makeReader(transport: transport)

        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            _ = try await reader.listClients()
        }
        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            _ = try await reader.listProjects(clientPrefix: "acme-corp-x7f2/")
        }
        await #expect(throws: S3Error.http(status: 500, body: "boom")) {
            _ = try await reader.listClips(projectPrefix: "acme-corp-x7f2/spring-gala-k9q1/")
        }
    }
}
