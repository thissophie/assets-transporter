import Foundation
import Testing
@testable import AssetsTransporter

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

    @Test func keyTimestampUsedWhenSidecarTimesMissing() {
        // 2026-09-19 UTC: 18:00 = 1789840800, 18:30:42 (from key) sits between, 19:00 = 1789844400
        let early = clip("a-early", captured: 1_789_840_800)
        let fromKey = clip("c/p/clips/2026-09-19_183042_cam_x.mov", captured: nil)
        let late = clip("b-late", captured: 1_789_844_400)
        #expect(ClipOrdering.sorted([late, fromKey, early]).map(\.key)
                == ["a-early", "c/p/clips/2026-09-19_183042_cam_x.mov", "b-late"])
    }

    @Test func missingTimesSortFirstByKey() {
        let a = clip("z-unknown", captured: nil), b = clip("b", captured: 100)
        #expect(ClipOrdering.sorted([a, b]).map(\.key) == ["z-unknown", "b"])
    }
}
