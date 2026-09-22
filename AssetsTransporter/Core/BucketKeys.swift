import Foundation

/// Builds and parses S3 object keys for the bucket layout:
/// `<client>/client.json`, `<client>/<project>/project.json`,
/// `<client>/<project>/clips/<yyyy-MM-dd_HHmmss>_<camera>_<id>.<ext>`
/// (+ `.json` sidecar, + optional `.thumb.jpg` poster frame).
nonisolated enum BucketKeys {
    /// UTC, fixed-locale timestamp formatter for clip key prefixes.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    static func clientManifestKey(client: String) -> String {
        "\(client)/client.json"
    }

    static func projectManifestKey(client: String, project: String) -> String {
        "\(client)/\(project)/project.json"
    }

    static func clipKey(client: String, project: String, capturedAt: Date,
                        cameraLabel: String?, id: String, ext: String) -> String {
        let timestamp = timestampFormatter.string(from: capturedAt)
        let cam = cameraLabel.flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Slug.make(from: $0)
        } ?? "cam"
        let cleanExt = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = cleanExt.isEmpty ? "" : ".\(cleanExt)"
        return "\(client)/\(project)/clips/\(timestamp)_\(cam)_\(id)\(suffix)"
    }

    static func sidecarKey(forClipKey clipKey: String) -> String {
        clipKey + ".json"
    }

    /// Poster-frame JPEG stored alongside the clip and its sidecar. Optional:
    /// clips uploaded before this feature (or whose generation failed) simply
    /// have no thumbnail object.
    static func thumbnailKey(forClipKey clipKey: String) -> String {
        clipKey + ".thumb.jpg"
    }

    /// "acme-corp-x7f2" -> "acme-corp-x7f2/" (unchanged if already slash-terminated).
    /// Folder prefixes must be slash-terminated before listing/deleting so a
    /// prefix can never match a sibling folder that merely shares its spelling.
    static func ensuringTrailingSlash(_ prefix: String) -> String {
        prefix.hasSuffix("/") ? prefix : prefix + "/"
    }

    static func isClipFile(_ key: String) -> Bool {
        key.contains("/clips/") && !key.hasSuffix(".json") && !key.hasSuffix(".thumb.jpg")
    }

    /// Extracts the leading `yyyy-MM-dd_HHmmss` timestamp from the key's last
    /// path component, or nil if the key doesn't conform.
    static func parseClipTimestamp(fromKey key: String) -> Date? {
        let filename = key.split(separator: "/").last.map(String.init) ?? key
        guard filename.count >= 17 else { return nil }
        let prefix = String(filename.prefix(17))
        return timestampFormatter.date(from: prefix)
    }
}
