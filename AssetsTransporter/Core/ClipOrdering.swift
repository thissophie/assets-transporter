import Foundation

nonisolated struct Clip: Equatable, Sendable, Identifiable {
    var key: String            // full object key of the video file
    var sidecar: ClipSidecar
    /// True when a `.thumb.jpg` poster frame exists alongside the clip
    /// (uploads made before the thumbnail feature don't have one).
    var hasThumbnail: Bool = false
    var id: String { key }

    /// override > capturedAt > timestamp parsed from the key > distantPast
    var effectiveTime: Date {
        sidecar.orderOverride ?? sidecar.capturedAt
            ?? BucketKeys.parseClipTimestamp(fromKey: key) ?? .distantPast
    }
}

nonisolated enum ClipOrdering {
    static func sorted(_ clips: [Clip]) -> [Clip] {
        // Precompute effectiveTime once per clip: it may parse the key
        // timestamp, and DateFormatter parses are expensive.
        clips.map { ($0.effectiveTime, $0) }
            .sorted { ($0.0, $0.1.key) < ($1.0, $1.1.key) }
            .map(\.1)
    }
}
