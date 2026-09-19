import Foundation

nonisolated struct Clip: Equatable, Sendable, Identifiable {
    var key: String            // full object key of the video file
    var sidecar: ClipSidecar
    var id: String { key }

    /// override > capturedAt > timestamp parsed from the key > distantPast
    var effectiveTime: Date {
        sidecar.orderOverride ?? sidecar.capturedAt
            ?? BucketKeys.parseClipTimestamp(fromKey: key) ?? .distantPast
    }
}

nonisolated enum ClipOrdering {
    static func sorted(_ clips: [Clip]) -> [Clip] {
        clips.sorted {
            ($0.effectiveTime, $0.key) < ($1.effectiveTime, $1.key)
        }
    }
}
