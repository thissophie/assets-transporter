import Foundation

/// Builds and parses S3 object keys for the bucket layout:
/// `<client>/client.json`, `<client>/<project>/project.json`,
/// `<client>/<project>/clips/<yyyy-MM-dd_HHmmss>_<camera>_<id>.<ext>` (+ `.json` sidecar).
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
        let cam = cameraLabel.map(Slug.make) ?? "cam"
        return "\(client)/\(project)/clips/\(timestamp)_\(cam)_\(id).\(ext)"
    }

    static func sidecarKey(forClipKey clipKey: String) -> String {
        clipKey + ".json"
    }

    static func isClipFile(_ key: String) -> Bool {
        key.contains("/clips/") && !key.hasSuffix(".json")
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
