import Foundation
import Testing
@testable import AssetsTransporter

/// Pins the shared user-facing error text: HTTP errors show the status only
/// (never the response body, which can echo request details), URL errors use
/// their localized description, everything else falls back to the debug
/// description.
struct ErrorTextTests {
    @Test func httpErrorsShowStatusOnlyNeverTheBody() {
        let text = ErrorText.describe(
            S3Error.http(status: 403, body: "<Error>SignatureDoesNotMatch: secret detail</Error>"))
        #expect(text == "server returned HTTP 403")
    }

    @Test func urlErrorsUseLocalizedDescription() {
        let error = URLError(.notConnectedToInternet)
        #expect(ErrorText.describe(error) == error.localizedDescription)
    }

    @Test func otherErrorsFallBackToStringDescribing() {
        struct Boom: Error {}
        #expect(ErrorText.describe(Boom()) == String(describing: Boom()))
    }
}
