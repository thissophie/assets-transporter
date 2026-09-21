import Foundation

/// Maps file extensions to MIME content types for upload headers.
nonisolated enum MediaTypes {
    /// Case-insensitive; tolerates a leading dot. Unknown extensions fall
    /// back to `application/octet-stream`.
    ///
    /// `m4v` maps to `video/x-m4v` (Apple's registered type for the format)
    /// rather than the generic `video/mp4`.
    static func contentType(forExtension ext: String) -> String {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch normalized {
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "avi": return "video/x-msvideo"
        case "mxf": return "application/mxf"
        default: return "application/octet-stream"
        }
    }
}
