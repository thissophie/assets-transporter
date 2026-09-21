import Foundation

nonisolated struct ClientManifest: Codable, Equatable, Sendable {
    var displayName: String
    /// Hidden from the client list by default. Optional so manifests written
    /// before this field existed still decode; nil means visible.
    var hidden: Bool? = nil
}

nonisolated struct ProjectManifest: Codable, Equatable, Sendable {
    var displayName: String
    var sortIndex: Int?
    var createdAt: Date
}

nonisolated struct ClipSidecar: Codable, Equatable, Sendable {
    var displayName: String
    var cameraLabel: String?
    var notes: String?
    var capturedAt: Date?
    var orderOverride: Date?   // manual "effective time" correction
    var duration: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var fileSize: Int64
    var originalFilename: String
    var sourceDevice: String
}

nonisolated enum ManifestCoding {
    static func encode(_ value: some Encodable) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: data)
    }
}
