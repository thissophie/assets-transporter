import Foundation
import Testing
@testable import MyApp

struct BucketKeyTests {
    private var referenceDate: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 19
        comps.hour = 18; comps.minute = 30; comps.second = 42
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    @Test func clipKeyFormat() {
        let key = BucketKeys.clipKey(client: "acme-corp-x7f2", project: "spring-gala-k9q1",
                                     capturedAt: referenceDate, cameraLabel: "Cam A", id: "e51f", ext: "mov")
        #expect(key == "acme-corp-x7f2/spring-gala-k9q1/clips/2026-09-19_183042_cam-a_e51f.mov")
        #expect(BucketKeys.sidecarKey(forClipKey: key) ==
                "acme-corp-x7f2/spring-gala-k9q1/clips/2026-09-19_183042_cam-a_e51f.mov.json")
    }

    @Test func manifestKeys() {
        #expect(BucketKeys.clientManifestKey(client: "acme-corp-x7f2") == "acme-corp-x7f2/client.json")
        #expect(BucketKeys.projectManifestKey(client: "acme-corp-x7f2", project: "spring-gala-k9q1")
                == "acme-corp-x7f2/spring-gala-k9q1/project.json")
    }

    @Test func isClipKeyDistinguishesSidecars() {
        #expect(BucketKeys.isClipFile("a/b/clips/x.mov"))
        #expect(!BucketKeys.isClipFile("a/b/clips/x.mov.json"))
    }

    @Test func parseClipTimestampRoundTrips() {
        let key = BucketKeys.clipKey(client: "acme-corp-x7f2", project: "spring-gala-k9q1",
                                     capturedAt: referenceDate, cameraLabel: "Cam A", id: "e51f", ext: "mov")
        #expect(BucketKeys.parseClipTimestamp(fromKey: key) == referenceDate)
        #expect(BucketKeys.parseClipTimestamp(fromKey: "a/b/clips/not-a-timestamp.mov") == nil)
    }
}
