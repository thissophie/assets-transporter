import Foundation
import Testing
@testable import MyApp

struct ClipOrderingTests {
    private func clip(_ key: String, captured: TimeInterval?, override: TimeInterval? = nil) -> Clip {
        Clip(key: key,
             sidecar: ClipSidecar(displayName: key, cameraLabel: nil, notes: nil,
                                  capturedAt: captured.map { Date(timeIntervalSince1970: $0) },
                                  orderOverride: override.map { Date(timeIntervalSince1970: $0) },
                                  duration: nil, width: nil, height: nil, codec: nil,
                                  fileSize: 0, originalFilename: key, sourceDevice: "test"))
    }

    @Test func overrideBeatsCaptureTime() {
        let a = clip("a", captured: 100, override: 300)
        let b = clip("b", captured: 200)
        #expect(ClipOrdering.sorted([a, b]).map(\.key) == ["b", "a"])
    }

    @Test func stableTiebreakOnKey() {
        let a = clip("a", captured: 100), b = clip("b", captured: 100)
        #expect(ClipOrdering.sorted([b, a]).map(\.key) == ["a", "b"])
    }

    @Test func missingTimesSortFirstByKey() {
        let a = clip("z-unknown", captured: nil), b = clip("b", captured: 100)
        #expect(ClipOrdering.sorted([a, b]).map(\.key) == ["z-unknown", "b"])
    }
}
