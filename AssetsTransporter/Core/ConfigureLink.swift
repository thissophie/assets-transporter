import Foundation

// Configure links: a QR code (or pasted link) from the companion web service
// that fills in the new-server form. The contract is
// `assetstransporter-svc/docs/CONFIGURE_API.md`; every user-facing string
// below is quoted from it.

/// A scanned or pasted string that has the shape of a configure link:
/// `https://<host>/configure/<id>?sig=<jwt>` (`http` only for `localhost` and
/// `127.0.0.1`). The link is otherwise opaque — the JWT is never parsed here.
nonisolated struct ConfigureLink: Equatable, Sendable {
    /// The trimmed link exactly as it will be requested.
    let url: URL

    /// Returns nil for anything that isn't a configure link; callers show
    /// `ConfigureError.notALink`'s message and make no request.
    init?(scanned raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }

        switch scheme {
        case "https": break
        case "http" where Self.developmentHosts.contains(host): break
        default: return nil
        }

        // Exactly `/configure/<something>`: two segments, the second non-empty.
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0].isEmpty, segments[1] == "configure",
              !segments[2].isEmpty
        else { return nil }

        guard let sig = components.queryItems?.first(where: { $0.name == "sig" })?.value,
              !sig.isEmpty,
              let url = components.url
        else { return nil }
        self.url = url
    }

    /// Hosts for which plain `http` is accepted (local development servers).
    static let developmentHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// Host shown to the user ("Filled in from transporter.example.com").
    var host: String { url.host() ?? url.absoluteString }
}

/// Every way fetching a configure link can fail, with the contract's text.
nonisolated enum ConfigureError: Error, Equatable, Sendable {
    /// Rejected locally; no request was made.
    case notALink
    /// 401 for anything but an expired signature.
    case invalid
    /// 401 whose `reason` is exactly "This link has expired."
    case expired
    /// 404: the credential set was deleted.
    case credentialsGone
    /// 410: the link was already used.
    case alreadyUsed
    /// Any other status, a network failure or an undecodable body; `detail`
    /// is the underlying error text.
    case failed(detail: String)

    var message: String {
        switch self {
        case .notALink:
            "This is not an Assets Transporter link."
        case .invalid:
            "This link is not valid."
        case .expired:
            "This link has expired. Show a new QR code and try again."
        case .credentialsGone:
            "These credentials no longer exist."
        case .alreadyUsed:
            "This link has already been used. Show a new QR code and try again."
        case .failed(let detail):
            "Could not fetch the credentials. \(detail)"
        }
    }
}

/// The 200 body of `GET /configure/{shortid}` (contract version 1). Unknown
/// fields are ignored by `Decodable`.
nonisolated struct ConfigurePayload: Decodable, Equatable, Sendable {
    static let supportedVersion = 1

    var version: Int
    var name: String
    var endpoint: String
    var bucket: String
    var region: String
    var pathStyle: Bool
    var accessKey: String
    var secretKey: String
}

/// The values of the server form (`ServerEditorView`), as the user would type
/// them. Filled from a configure response; nothing is saved until the user
/// presses Save.
nonisolated struct ServerFormValues: Equatable, Sendable {
    var name: String
    var endpoint: String
    var bucket: String
    var region: String
    var pathStyle: Bool
    var accessKey: String
    var secretKey: String

    init(name: String, endpoint: String, bucket: String, region: String,
         pathStyle: Bool, accessKey: String, secretKey: String) {
        self.name = name
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.pathStyle = pathStyle
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    init(_ payload: ConfigurePayload) {
        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.init(name: clean(payload.name), endpoint: clean(payload.endpoint),
                  bucket: clean(payload.bucket), region: clean(payload.region),
                  pathStyle: payload.pathStyle, accessKey: clean(payload.accessKey),
                  secretKey: clean(payload.secretKey))
    }
}

/// Network seam for `ConfigureClient`, so tests use canned responses.
/// Implementations must not follow redirects to another origin.
nonisolated protocol ConfigureTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Fetches a configure link and turns the answer into form values or a
/// `ConfigureError`.
nonisolated struct ConfigureClient: Sendable {
    var transport: any ConfigureTransport

    init(transport: any ConfigureTransport = URLSessionConfigureTransport()) {
        self.transport = transport
    }

    /// The exact text the server sends as `reason` for an expired link.
    static let expiredReason = "This link has expired."

    /// The request the contract prescribes: a plain GET, JSON only, no cookies.
    static func request(for link: ConfigureLink) -> URLRequest {
        var request = URLRequest(url: link.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    func fetch(_ link: ConfigureLink) async throws(ConfigureError) -> ConfigurePayload {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.perform(Self.request(for: link))
        } catch let error as ConfigureError {
            throw error
        } catch {
            throw .failed(detail: ErrorText.describe(error))
        }
        return try Self.interpret(data: data, status: response.statusCode)
    }

    /// Maps a response to the payload or the contract's error. Pure.
    static func interpret(data: Data, status: Int) throws(ConfigureError) -> ConfigurePayload {
        switch status {
        case 200:
            return try decodePayload(data)
        case 401:
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.reason
            throw reason == expiredReason ? .expired : .invalid
        case 404:
            throw .credentialsGone
        case 410:
            throw .alreadyUsed
        case 300..<400:
            // Only reaches here when the transport refused a redirect.
            throw .failed(detail: "The server redirected to another address, which the app does not follow.")
        default:
            throw .failed(detail: "The server returned HTTP \(status).")
        }
    }

    private static func decodePayload(_ data: Data) throws(ConfigureError) -> ConfigurePayload {
        // Check the version on its own first, so a future format with other
        // fields is reported as an unsupported version, not as bad JSON.
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw .failed(detail: "The server's response was not readable.")
        }
        guard probe.version == ConfigurePayload.supportedVersion else {
            throw .failed(detail: "The server sent configuration version \(probe.version), "
                          + "which this version of the app does not support.")
        }
        guard let payload = try? JSONDecoder().decode(ConfigurePayload.self, from: data) else {
            throw .failed(detail: "The server's response was missing some settings.")
        }
        let required = [payload.name, payload.endpoint, payload.bucket, payload.region,
                        payload.accessKey, payload.secretKey]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw .failed(detail: "The server's response was missing some settings.")
        }
        return payload
    }

    private struct VersionProbe: Decodable { var version: Int }
    private struct ErrorBody: Decodable { var reason: String? }

    /// Redirect policy: follow only within the same origin (scheme, host and
    /// port), so a link can never be bounced to another host or downgraded
    /// from https to http.
    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
              let fromHost = original.host()?.lowercased(),
              let toHost = target.host()?.lowercased()
        else { return false }
        return original.scheme?.lowercased() == target.scheme?.lowercased()
            && fromHost == toHost
            && effectivePort(original) == effectivePort(target)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Production `ConfigureTransport`: an ephemeral session (no cookies, no
/// cache) whose delegate refuses cross-origin redirects. A refused redirect
/// surfaces as the 3xx response itself.
nonisolated struct URLSessionConfigureTransport: ConfigureTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = Self.defaultConfiguration()) {
        session = URLSession(configuration: configuration, delegate: RedirectGuard(),
                             delegateQueue: nil)
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    // Completion-handler form on purpose: the `async` variant of this
    // delegate method crashes the Swift 6.4 compiler (SILGen, ObjC thunk).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let origin = task.originalRequest?.url ?? response.url
            completionHandler(ConfigureClient.allowsRedirect(from: origin, to: request.url)
                              ? request : nil)
        }
    }
}
