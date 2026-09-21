import CryptoKit
import Foundation

/// AWS Signature Version 4 request signer for S3-compatible storage.
///
/// All payloads in this app are signed as `UNSIGNED-PAYLOAD` over HTTPS.
nonisolated enum SigV4 {

    // MARK: - Primitives

    /// Lowercase hex encoding of the SHA-256 digest of `data`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256 of `data` keyed with `key`.
    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Derives the SigV4 signing key:
    /// HMAC("AWS4" + secret, date) -> HMAC(-, region) -> HMAC(-, service) -> HMAC(-, "aws4_request").
    static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data(("AWS4" + secret).utf8), data: Data(date.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    // MARK: - Canonical request

    /// Builds the SigV4 canonical request string for `request`.
    ///
    /// Signed headers are `host` plus every `x-amz-*` header present on the request.
    static func canonicalRequest(for request: URLRequest, payloadHash: String) -> String {
        let method = request.httpMethod ?? "GET"
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }

        // Canonical URI: the already-percent-encoded path; do NOT re-encode.
        var canonicalURI = components?.percentEncodedPath ?? ""
        if canonicalURI.isEmpty { canonicalURI = "/" }

        let canonicalQuery = canonicalQueryString(from: components)

        let headers = signedHeaders(for: request)
        let canonicalHeaders = headers.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaderList = headers.map(\.name).joined(separator: ";")

        return [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaderList,
            payloadHash,
        ].joined(separator: "\n")
    }

    /// String to sign: algorithm, timestamp, credential scope, and hash of the canonical request.
    static func stringToSign(canonicalRequest: String, amzDate: String, dateStamp: String,
                             region: String, service: String) -> String {
        [
            "AWS4-HMAC-SHA256",
            amzDate,
            "\(dateStamp)/\(region)/\(service)/aws4_request",
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
    }

    // MARK: - Signing

    /// Signs `request` with SigV4 and returns the request with `Host`, `x-amz-date`,
    /// `x-amz-content-sha256`, and `Authorization` headers set.
    static func sign(request: URLRequest, accessKey: String, secretKey: String, region: String,
                     service: String = "s3", date: Date = Date()) -> URLRequest {
        var req = request

        let amzDate = amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if req.value(forHTTPHeaderField: "x-amz-content-sha256") == nil {
            req.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        }

        // Ensure the Host header matches the URL host (with port if non-default).
        if let url = req.url, let host = url.host {
            var hostValue = host
            if let port = url.port {
                let isDefault = (url.scheme?.lowercased() == "https" && port == 443)
                    || (url.scheme?.lowercased() == "http" && port == 80)
                if !isDefault { hostValue += ":\(port)" }
            }
            req.setValue(hostValue, forHTTPHeaderField: "Host")
        }

        let payloadHash = req.value(forHTTPHeaderField: "x-amz-content-sha256") ?? "UNSIGNED-PAYLOAD"
        let canonical = canonicalRequest(for: req, payloadHash: payloadHash)
        let sts = stringToSign(canonicalRequest: canonical, amzDate: amzDate, dateStamp: dateStamp,
                               region: region, service: service)
        let key = signingKey(secret: secretKey, date: dateStamp, region: region, service: service)
        let signature = hexString(hmac(key: key, data: Data(sts.utf8)))

        let signedHeaderList = signedHeaders(for: req).map(\.name).joined(separator: ";")
        let credential = "\(accessKey)/\(dateStamp)/\(region)/\(service)/aws4_request"
        req.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaderList), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return req
    }

    // MARK: - Presigned URLs

    /// Returns `url` with SigV4 query-string authentication appended
    /// (`X-Amz-Algorithm` … `X-Amz-Signature`), valid for `expires` seconds.
    ///
    /// The only signed header is `host` and the payload hash is
    /// `UNSIGNED-PAYLOAD`, so the whole grant lives in the URL — required for
    /// consumers that cannot attach request headers (e.g. AVPlayer streaming).
    static func presignedURL(method: String = "GET", url: URL, accessKey: String,
                             secretKey: String, region: String, service: String = "s3",
                             expires: Int, date: Date = Date()) -> URL {
        let amzDate = amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        let credential = "\(accessKey)/\(dateStamp)/\(region)/\(service)/aws4_request"

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            preconditionFailure("presignedURL requires a decomposable URL: \(url)")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: credential),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expires)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ])
        components.queryItems = items
        let canonicalQuery = canonicalQueryString(from: components)

        var canonicalURI = components.percentEncodedPath
        if canonicalURI.isEmpty { canonicalURI = "/" }

        var hostValue = components.host ?? ""
        if let port = components.port {
            let isDefault = (components.scheme?.lowercased() == "https" && port == 443)
                || (components.scheme?.lowercased() == "http" && port == 80)
            if !isDefault { hostValue += ":\(port)" }
        }

        let canonical = [
            method,
            canonicalURI,
            canonicalQuery,
            "host:\(hostValue)\n",
            "host",
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let sts = stringToSign(canonicalRequest: canonical, amzDate: amzDate, dateStamp: dateStamp,
                               region: region, service: service)
        let key = signingKey(secret: secretKey, date: dateStamp, region: region, service: service)
        let signature = hexString(hmac(key: key, data: Data(sts.utf8)))

        // The final query must byte-match what was signed, so reuse the
        // canonical string rather than re-encoding through queryItems.
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=\(signature)"
        guard let signed = components.url else {
            preconditionFailure("presignedURL produced an invalid URL for: \(url)")
        }
        return signed
    }

    // MARK: - Internals

    /// UTC formatter producing SigV4 timestamps of the form `yyyyMMdd'T'HHmmss'Z'`.
    /// ISO8601DateFormatter is thread-safe (unlike DateFormatter); omitting the
    /// separator options yields the basic format SigV4 requires.
    private static let amzDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Characters AWS leaves unencoded in canonical query strings: A-Z a-z 0-9 - . _ ~
    private static let awsUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Percent-encodes per AWS rules (unreserved characters only; space becomes %20).
    private static func awsEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: awsUnreserved) ?? string
    }

    /// Canonical query string: AWS-encoded items sorted by encoded key then encoded value.
    /// A valueless item like `uploads` encodes as `uploads=`. Empty string if no query.
    private static func canonicalQueryString(from components: URLComponents?) -> String {
        guard let items = components?.queryItems, !items.isEmpty else { return "" }
        var encoded: [(key: String, value: String)] = items.map { item in
            (key: awsEncode(item.name), value: awsEncode(item.value ?? ""))
        }
        encoded.sort { lhs, rhs in
            lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key
        }
        let pairs: [String] = encoded.map { "\($0.key)=\($0.value)" }
        return pairs.joined(separator: "&")
    }

    /// The headers included in signing: `host` plus every `x-amz-*` header on the request,
    /// lowercased, values trimmed, sorted by name.
    private static func signedHeaders(for request: URLRequest) -> [(name: String, value: String)] {
        (request.allHTTPHeaderFields ?? [:])
            .compactMap { name, value -> (name: String, value: String)? in
                let lower = name.lowercased()
                guard lower == "host" || lower.hasPrefix("x-amz-") else { return nil }
                return (lower, value.trimmingCharacters(in: .whitespaces))
            }
            .sorted { $0.name < $1.name }
    }
}
