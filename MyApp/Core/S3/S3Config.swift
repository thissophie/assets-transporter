import Foundation

/// Endpoint configuration for an S3-compatible object store, plus URL building
/// for object keys under either path-style or virtual-host-style addressing.
nonisolated struct S3Config: Equatable, Sendable {
    enum AddressingStyle: String, Codable, Sendable { case path, virtualHost }

    var endpoint: URL          // e.g. https://minio.example.com:9000
    var bucket: String
    var accessKey: String
    var secretKey: String
    var style: AddressingStyle = .path
    var region: String = "us-east-1"

    /// Builds the request URL for `key`, percent-encoding each path segment
    /// (unreserved characters A-Za-z0-9-._~ pass through; `/` separates segments).
    func url(forKey key: String, query: [URLQueryItem]? = nil) -> URL {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.port = endpoint.port

        let encodedKey = Self.encodeKey(key)
        switch style {
        case .path:
            components.host = endpoint.host
            components.percentEncodedPath = "/\(bucket)/\(encodedKey)"
        case .virtualHost:
            components.host = "\(bucket).\(endpoint.host ?? "")"
            components.percentEncodedPath = "/\(encodedKey)"
        }

        if let query, !query.isEmpty {
            // Render valueless items (e.g. "uploads") without a trailing "=".
            components.percentEncodedQuery = query.map { item in
                let name = Self.encodeQueryComponent(item.name)
                guard let value = item.value else { return name }
                return "\(name)=\(Self.encodeQueryComponent(value))"
            }.joined(separator: "&")
        }

        guard let url = components.url else {
            preconditionFailure("S3Config produced an invalid URL for key: \(key)")
        }
        return url
    }

    /// Unreserved characters per RFC 3986, plus `/` kept as the segment separator.
    private static let keyAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        set.insert("/")
        return set
    }()

    /// Unreserved characters only — everything else is percent-encoded.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encodeKey(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: keyAllowed) ?? key
    }

    private static func encodeQueryComponent(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? component
    }
}
