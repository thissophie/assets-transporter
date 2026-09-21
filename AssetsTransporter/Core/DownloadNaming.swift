import Foundation

/// Generates order-prefixed filenames for downloading a project's clips,
/// e.g. `001_cam-a_intro.mov`, `002_main-talk.mp4`.
nonisolated enum DownloadNaming {
    /// Zero-pad width for the order index: at least 3 digits, more for 1000+ clips.
    static func indexWidth(count: Int) -> Int {
        max(3, String(count).count)
    }

    /// Filenames for clips already in playback order (see `ClipOrdering.sorted`).
    /// Each is `<index>_<camera-slug>_<name-slug>.<ext>` (camera omitted when absent).
    /// The camera+name+ext portion is deduped with `-2`, `-3`, ... before the
    /// extension so names stay distinguishable even without the index prefix.
    static func filenames(forOrdered clips: [Clip]) -> [String] {
        let width = indexWidth(count: clips.count)
        var used = Set<String>()
        return clips.enumerated().map { i, clip in
            let ext = (clip.key as NSString).pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            var parts: [String] = []
            if let camera = clip.sidecar.cameraLabel {
                parts.append(Slug.make(from: camera))
            }
            parts.append(Slug.make(from: clip.sidecar.displayName))
            let stem = parts.joined(separator: "_")

            var candidate = stem + suffix
            var n = 1
            while used.contains(candidate) {
                n += 1
                candidate = "\(stem)-\(n)\(suffix)"
            }
            used.insert(candidate)

            let index = String(format: "%0\(width)d", i + 1)
            return "\(index)_\(candidate)"
        }
    }
}
