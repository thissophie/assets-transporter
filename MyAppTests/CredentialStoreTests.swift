import Foundation
import Testing
@testable import MyApp

/// Pure tests for the StoredS3Settings -> S3Config bridge. Keychain-backed
/// save/load/delete are intentionally untested (flaky in test hosts).
struct CredentialStoreTests {

    private func makeSettings(pathStyle: Bool) -> StoredS3Settings {
        StoredS3Settings(endpoint: URL(string: "https://minio.example.com:9000")!,
                         bucket: "video", accessKey: "AK", secretKey: "SK",
                         pathStyle: pathStyle, region: "ap-southeast-2")
    }

    @Test func makeS3ConfigMapsPathStyle() {
        let config = makeSettings(pathStyle: true).makeS3Config()
        #expect(config.style == .path)
        #expect(config.endpoint == URL(string: "https://minio.example.com:9000")!)
        #expect(config.bucket == "video")
        #expect(config.accessKey == "AK")
        #expect(config.secretKey == "SK")
        #expect(config.region == "ap-southeast-2")
    }

    @Test func makeS3ConfigMapsVirtualHostStyle() {
        let config = makeSettings(pathStyle: false).makeS3Config()
        #expect(config.style == .virtualHost)
    }
}
