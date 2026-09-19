import Foundation
import Testing
@testable import MyApp

struct ManifestTests {
    @Test func clipSidecarRoundTrip() throws {
        let clip = ClipSidecar(
            displayName: "Intro", cameraLabel: "cam-a", notes: "keeper",
            capturedAt: Date(timeIntervalSince1970: 1_789_000_000),
            orderOverride: nil, duration: 12.5, width: 3840, height: 2160,
            codec: "hvc1", fileSize: 123_456_789,
            originalFilename: "IMG_0042.MOV", sourceDevice: "Patrick's iPhone")
        let data = try ManifestCoding.encode(clip)
        let back = try ManifestCoding.decode(ClipSidecar.self, from: data)
        #expect(back == clip)
        // dates must be ISO8601 so other tools can read the bucket
        #expect(String(data: data, encoding: .utf8)!.contains("2026-09-10T00:26:40Z"))
    }

    @Test func projectManifestDefaults() throws {
        let json = #"{"displayName":"Gala","createdAt":"2026-09-19T18:30:00Z"}"#
        let m = try ManifestCoding.decode(ProjectManifest.self, from: Data(json.utf8))
        #expect(m.sortIndex == nil)  // optional fields tolerate absence
    }
}
