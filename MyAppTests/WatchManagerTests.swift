import Foundation
import Testing
@testable import MyApp

#if os(macOS)

struct WatchManagerTests {

    @Test func watchConfigRoundTripsThroughJSON() throws {
        let config = WatchConfig(bookmark: Data([0x01, 0x02, 0x03]),
                                 projectPrefix: "acme-x1/gala-k9/",
                                 cameraLabel: "A-cam")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WatchConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func watchConfigRoundTripsWithNilCameraLabel() throws {
        let config = WatchConfig(bookmark: Data(),
                                 projectPrefix: "acme-x1/gala-k9/",
                                 cameraLabel: nil)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WatchConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.cameraLabel == nil)
    }

    @Test func processedIdentitiesRoundTripThroughJSONAndCapKeepsMostRecent() throws {
        // Sub-second mtimes must survive the persistence round-trip exactly,
        // or every launch would treat every processed file as new again.
        let precise = FileIdentity(name: "cam-a-clip.mov", size: 1_048_576,
                                   modifiedAt: Date(timeIntervalSince1970: 1_726_000_000.123456))
        let plain = FileIdentity(name: "b.mov", size: 2,
                                 modifiedAt: Date(timeIntervalSince1970: 1))
        let data = try JSONEncoder().encode([precise, plain])
        let decoded = try JSONDecoder().decode([FileIdentity].self, from: data)
        #expect(decoded == [precise, plain])
        #expect(Set(decoded).contains(precise))

        // The persisted log is bounded: the cap keeps the MOST RECENT entries.
        let many = (0..<1_200).map {
            FileIdentity(name: "f\($0).mov", size: Int64($0), modifiedAt: .now)
        }
        let capped = WatchManager.capped(many, limit: 1_000)
        #expect(capped.count == 1_000)
        #expect(capped.first?.name == "f200.mov")
        #expect(capped.last?.name == "f1199.mov")
        #expect(WatchManager.capped([precise], limit: 1_000) == [precise])
    }

    @Test func statusLineShowsFolderProjectAndSessionCount() {
        #expect(WatchManager.statusLine(folderName: "Downloads",
                                        projectPrefix: "acme-x1/gala-k9/",
                                        queuedCount: 3)
                == "Watching Downloads → gala-k9 (3 queued this session)")
        // A prefix without a project component falls back to the whole prefix.
        #expect(WatchManager.statusLine(folderName: "Inbox",
                                        projectPrefix: "solo",
                                        queuedCount: 0)
                == "Watching Inbox → solo (0 queued this session)")
    }
}

#endif
