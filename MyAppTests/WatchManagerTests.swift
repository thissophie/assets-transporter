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
