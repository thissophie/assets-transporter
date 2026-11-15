import Foundation
import Testing
@testable import AssetsTransporter

/// Which scanned/pasted strings count as configure links
/// (`assetstransporter-svc/docs/CONFIGURE_API.md`, "What the app accepts").
struct ConfigureLinkParsingTests {
    @Test(arguments: [
        "https://transporter.m.ac.nz/configure/abcdefghjk?sig=eyJ.a.b",
        "https://other.example.com/configure/x?sig=1",
        "https://host.example:8443/configure/abc?sig=s&extra=1",
        "HTTPS://Transporter.M.AC.NZ/configure/abc?sig=s",
        "http://localhost/configure/abc?sig=s",
        "http://localhost:8080/configure/abc?sig=s",
        "http://127.0.0.1:8080/configure/abc?sig=s",
        "  https://transporter.m.ac.nz/configure/abc?sig=s \n",
        "\thttps://transporter.m.ac.nz/configure/abc?sig=s\r\n",
    ])
    func accepts(_ raw: String) {
        #expect(ConfigureLink(scanned: raw) != nil)
    }

    @Test(arguments: [
        "",
        "   ",
        "hello world",
        "transporter.m.ac.nz/configure/abc?sig=s",              // no scheme
        "http://transporter.m.ac.nz/configure/abc?sig=s",       // http off localhost
        "http://192.168.1.10/configure/abc?sig=s",
        "ftp://transporter.m.ac.nz/configure/abc?sig=s",
        "https:///configure/abc?sig=s",                         // no host
        "https://transporter.m.ac.nz/configure/abc",            // no sig
        "https://transporter.m.ac.nz/configure/abc?sig=",       // empty sig
        "https://transporter.m.ac.nz/configure/abc?sig",        // valueless sig
        "https://transporter.m.ac.nz/configure/abc?signature=s",
        "https://transporter.m.ac.nz/configure/?sig=s",         // empty id
        "https://transporter.m.ac.nz/configure?sig=s",
        "https://transporter.m.ac.nz/configure/abc/extra?sig=s",
        "https://transporter.m.ac.nz/prefix/configure/abc?sig=s",
        "https://transporter.m.ac.nz/Configure/abc?sig=s",
        "https://transporter.m.ac.nz/?sig=s",
        "WIFI:S:Network;T:WPA;P:secret;;",
    ])
    func rejects(_ raw: String) {
        #expect(ConfigureLink(scanned: raw) == nil)
    }

    @Test func keepsTheTrimmedLinkAsIs() throws {
        let link = try #require(ConfigureLink(scanned: "  https://t.example/configure/abc?sig=a.b.c\n"))
        #expect(link.url.absoluteString == "https://t.example/configure/abc?sig=a.b.c")
        #expect(link.host == "t.example")
    }
}

/// Canned-response transport that records the requests it receives.
nonisolated final class StubConfigureTransport: ConfigureTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let result: Result<(Data, Int), any Error>

    init(status: Int, body: String) {
        result = .success((Data(body.utf8), status))
    }

    init(error: any Error) {
        result = .failure(error)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let (data, status) = try result.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

/// Status → message mapping, decoding, and the request's shape.
struct ConfigureClientTests {
    static let link = ConfigureLink(scanned: "https://t.example/configure/abcdefghjk?sig=a.b.c")!

    static let okBody = """
    {"version":1,"name":"Production","endpoint":"https://s3.example.com","bucket":"events",
     "region":"us-east-1","pathStyle":true,"accessKey":"AKIA1","secretKey":"s3cr3t"}
    """

    private func fetchError(status: Int, body: String) async -> ConfigureError? {
        do {
            _ = try await ConfigureClient(transport: StubConfigureTransport(status: status, body: body))
                .fetch(Self.link)
            return nil
        } catch {
            return error
        }
    }

    @Test func successDecodesEveryField() async throws {
        let payload = try await ConfigureClient(
            transport: StubConfigureTransport(status: 200, body: Self.okBody)).fetch(Self.link)
        #expect(payload == ConfigurePayload(version: 1, name: "Production",
                                            endpoint: "https://s3.example.com", bucket: "events",
                                            region: "us-east-1", pathStyle: true,
                                            accessKey: "AKIA1", secretKey: "s3cr3t"))
    }

    @Test func unknownExtraFieldsAreIgnored() async throws {
        let body = """
        {"version":1,"name":"N","endpoint":"http://localhost:4566","bucket":"b","region":"r",
         "pathStyle":false,"accessKey":"a","secretKey":"s","comment":"hi","nested":{"x":[1,2]}}
        """
        let payload = try await ConfigureClient(
            transport: StubConfigureTransport(status: 200, body: body)).fetch(Self.link)
        #expect(payload.name == "N")
        #expect(payload.pathStyle == false)
    }

    @Test func requestIsAPlainJSONGetOfTheLink() async throws {
        let transport = StubConfigureTransport(status: 200, body: Self.okBody)
        _ = try await ConfigureClient(transport: transport).fetch(Self.link)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url == Self.link.url)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func invalid401() async {
        let error = await fetchError(status: 401,
                                     body: #"{"error":true,"reason":"This link is not valid."}"#)
        #expect(error == .invalid)
        #expect(error?.message == "This link is not valid.")
    }

    @Test func invalid401WithUnreadableBody() async {
        #expect(await fetchError(status: 401, body: "nope") == .invalid)
    }

    @Test func expired401IsToldApartByReason() async {
        let error = await fetchError(status: 401,
                                     body: #"{"error":true,"reason":"This link has expired."}"#)
        #expect(error == .expired)
        #expect(error?.message == "This link has expired. Show a new QR code and try again.")
    }

    @Test func notFound404() async {
        let error = await fetchError(status: 404, body: #"{"error":true,"reason":"gone"}"#)
        #expect(error == .credentialsGone)
        #expect(error?.message == "These credentials no longer exist.")
    }

    @Test func alreadyUsed410() async {
        let error = await fetchError(status: 410, body: #"{"error":true,"reason":"used"}"#)
        #expect(error == .alreadyUsed)
        #expect(error?.message
                == "This link has already been used. Show a new QR code and try again.")
    }

    @Test(arguments: [400, 403, 429, 500, 502, 503])
    func otherStatus(_ status: Int) async {
        let error = await fetchError(status: status, body: #"{"error":true,"reason":"x"}"#)
        #expect(error == .failed(detail: "The server returned HTTP \(status)."))
        #expect(error?.message
                == "Could not fetch the credentials. The server returned HTTP \(status).")
    }

    @Test func refusedRedirectIsAFetchFailure() async {
        let error = await fetchError(status: 302, body: "")
        #expect(error?.message.hasPrefix("Could not fetch the credentials. ") == true)
        #expect(error?.message.contains("redirect") == true)
    }

    @Test func networkErrorCarriesTheUnderlyingText() async {
        let urlError = URLError(.notConnectedToInternet)
        let transport = StubConfigureTransport(error: urlError)
        do {
            _ = try await ConfigureClient(transport: transport).fetch(Self.link)
            Issue.record("expected a failure")
        } catch {
            #expect(error == .failed(detail: urlError.localizedDescription))
            #expect(error.message
                    == "Could not fetch the credentials. \(urlError.localizedDescription)")
        }
    }

    @Test(arguments: [
        "",
        "<html>For the app</html>",
        #"{"version":"1"}"#,
        #"[1,2,3]"#,
    ])
    func undecodableBody(_ body: String) async {
        let error = await fetchError(status: 200, body: body)
        #expect(error?.message.hasPrefix("Could not fetch the credentials. ") == true)
        if case .failed = error {} else { Issue.record("expected .failed, got \(String(describing: error))") }
    }

    @Test func missingOrEmptyFieldIsAFetchFailure() async {
        let missing = #"{"version":1,"name":"N","endpoint":"https://e","bucket":"b","region":"r","pathStyle":true,"accessKey":"a"}"#
        let empty = #"{"version":1,"name":"N","endpoint":"https://e","bucket":" ","region":"r","pathStyle":true,"accessKey":"a","secretKey":"s"}"#
        for body in [missing, empty] {
            let error = await fetchError(status: 200, body: body)
            #expect(error == .failed(detail: "The server's response was missing some settings."))
        }
    }

    @Test(arguments: [0, 2, 99])
    func wrongVersionIsRejected(_ version: Int) async {
        let body = Self.okBody.replacingOccurrences(of: #""version":1"#,
                                                    with: #""version":\#(version)"#)
        let error = await fetchError(status: 200, body: body)
        #expect(error?.message.hasPrefix("Could not fetch the credentials. ") == true)
        #expect(error?.message.contains("version \(version)") == true)
    }

    @Test func notALinkMessage() {
        #expect(ConfigureError.notALink.message == "This is not an Assets Transporter link.")
    }
}

/// Redirects are followed only within the link's own origin.
struct ConfigureRedirectPolicyTests {
    private func allows(_ from: String, _ to: String) -> Bool {
        ConfigureClient.allowsRedirect(from: URL(string: from), to: URL(string: to))
    }

    @Test func sameOriginIsFollowed() {
        #expect(allows("https://t.example/configure/a?sig=s", "https://t.example/configure/b?sig=s"))
        #expect(allows("https://T.example/configure/a?sig=s", "https://t.example:443/other"))
        #expect(allows("http://localhost:8080/configure/a?sig=s", "http://localhost:8080/x"))
    }

    @Test func otherHostSchemeOrPortIsRefused() {
        #expect(!allows("https://t.example/configure/a?sig=s", "https://evil.example/configure/a"))
        #expect(!allows("https://t.example/configure/a?sig=s", "https://sub.t.example/x"))
        #expect(!allows("https://t.example/configure/a?sig=s", "http://t.example/x"))
        #expect(!allows("https://t.example/configure/a?sig=s", "https://t.example:8443/x"))
        #expect(!allows("http://localhost:8080/configure/a?sig=s", "http://127.0.0.1:8080/x"))
        #expect(ConfigureClient.allowsRedirect(from: nil, to: URL(string: "https://t.example")) == false)
    }
}

/// Maps a response into the editor's fields.
struct ServerFormValuesTests {
    @Test func mapsEveryField() {
        let payload = ConfigurePayload(version: 1, name: " Production ",
                                       endpoint: "https://s3.example.com\n", bucket: "events",
                                       region: "ap-southeast-2", pathStyle: false,
                                       accessKey: "AKIA1", secretKey: "s3cr3t")
        #expect(ServerFormValues(payload) == ServerFormValues(
            name: "Production", endpoint: "https://s3.example.com", bucket: "events",
            region: "ap-southeast-2", pathStyle: false, accessKey: "AKIA1", secretKey: "s3cr3t"))
    }

    @Test func filledValuesPassTheFormsValidation() {
        let values = ServerFormValues(ConfigurePayload(
            version: 1, name: "N", endpoint: "http://localhost:4566", bucket: "it-video",
            region: "us-east-1", pathStyle: true, accessKey: "a", secretKey: "s"))
        #expect(SettingsValidation.validate(name: values.name, endpoint: values.endpoint,
                                            bucket: values.bucket, accessKey: values.accessKey,
                                            secretKey: values.secretKey) == nil)
    }
}

/// The production transport, driven through a `URLProtocol` stub so no
/// network is touched: it sends the request through and refuses a
/// cross-host redirect.
@Suite(.serialized)
struct URLSessionConfigureTransportTests {
    private func transport() -> URLSessionConfigureTransport {
        let configuration = URLSessionConfigureTransport.defaultConfiguration()
        configuration.protocolClasses = [ConfigureStubProtocol.self]
        return URLSessionConfigureTransport(configuration: configuration)
    }

    @Test func deliversTheResponseAndAcceptHeader() async throws {
        ConfigureStubProtocol.reset()
        let client = ConfigureClient(transport: transport())
        let payload = try await client.fetch(ConfigureClientTests.link)
        #expect(payload.name == "Production")
        #expect(ConfigureStubProtocol.seen.first?.value(forHTTPHeaderField: "Accept")
                == "application/json")
    }

    @Test func refusesACrossHostRedirect() async {
        ConfigureStubProtocol.reset()
        let link = ConfigureLink(scanned: "https://t.example/configure/bounce?sig=s")!
        do {
            _ = try await ConfigureClient(transport: transport()).fetch(link)
            Issue.record("expected the redirect to be refused")
        } catch {
            if case .failed = error {} else { Issue.record("unexpected \(error)") }
        }
        #expect(!ConfigureStubProtocol.seen.contains { $0.url?.host() == "evil.example" })
    }
}

/// Answers `t.example` requests: `/configure/bounce` redirects to
/// `evil.example`, everything else returns the 200 body. Records requests.
nonisolated final class ConfigureStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock(); requests = []; lock.unlock()
    }

    static var seen: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        if url.path().hasSuffix("/bounce") {
            let target = URL(string: "https://evil.example/configure/bounce?sig=s")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target),
                                redirectResponse: response)
            // If the redirect is refused, the loading system expects the
            // redirect response itself to finish the load.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(ConfigureClientTests.okBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
