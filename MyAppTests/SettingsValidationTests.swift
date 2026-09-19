import Foundation
import Testing
@testable import MyApp

struct SettingsValidationTests {
    @Test func validInputReturnsNil() {
        #expect(SettingsValidation.validate(endpoint: "https://s3.example.com:9000",
                                            bucket: "video",
                                            accessKey: "AK",
                                            secretKey: "SK") == nil)
    }

    @Test func nonHTTPSchemeIsRejected() {
        let message = SettingsValidation.validate(endpoint: "ftp://s3.example.com",
                                                  bucket: "video",
                                                  accessKey: "AK",
                                                  secretKey: "SK")
        #expect(message != nil)
    }

    @Test func endpointWithoutHostIsRejected() {
        let message = SettingsValidation.validate(endpoint: "https://",
                                                  bucket: "video",
                                                  accessKey: "AK",
                                                  secretKey: "SK")
        #expect(message != nil)
    }

    @Test func unparseableEndpointIsRejected() {
        let message = SettingsValidation.validate(endpoint: "not a url",
                                                  bucket: "video",
                                                  accessKey: "AK",
                                                  secretKey: "SK")
        #expect(message != nil)
    }

    @Test func emptyBucketIsRejected() {
        let message = SettingsValidation.validate(endpoint: "https://s3.example.com",
                                                  bucket: "   ",
                                                  accessKey: "AK",
                                                  secretKey: "SK")
        #expect(message != nil)
    }

    @Test func emptyAccessKeyIsRejected() {
        let message = SettingsValidation.validate(endpoint: "https://s3.example.com",
                                                  bucket: "video",
                                                  accessKey: "",
                                                  secretKey: "SK")
        #expect(message != nil)
    }

    @Test func emptySecretKeyIsRejected() {
        let message = SettingsValidation.validate(endpoint: "https://s3.example.com",
                                                  bucket: "video",
                                                  accessKey: "AK",
                                                  secretKey: "  ") 
        #expect(message != nil)
    }

    @Test func surroundingWhitespaceIsTolerated() {
        #expect(SettingsValidation.validate(endpoint: "  https://s3.example.com:9000  ",
                                            bucket: " video ",
                                            accessKey: " AK ",
                                            secretKey: " SK ") == nil)
    }
}
