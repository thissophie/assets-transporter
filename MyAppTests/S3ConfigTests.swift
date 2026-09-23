import Foundation
import Testing
@testable import AssetsTransporter

struct S3ConfigTests {
    private func makeConfig(style: S3Config.AddressingStyle = .path) -> S3Config {
        S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                 bucket: "video", accessKey: "AK", secretKey: "SK",
                 style: style, region: "us-east-1")
    }

    @Test func pathStyleEncodesKeyAndPreservesSlashes() {
        let config = makeConfig()
        #expect(config.url(forKey: "acme/a b.mov").absoluteString
                == "https://minio.example.com:9000/video/acme/a%20b.mov")
    }

    @Test func valuelessQueryItemRendersWithoutEquals() {
        let config = makeConfig()
        #expect(config.url(forKey: "x", query: [URLQueryItem(name: "uploads", value: nil)]).absoluteString
                == "https://minio.example.com:9000/video/x?uploads")
    }

    @Test func virtualHostStylePrefixesBucketToHost() {
        let config = makeConfig(style: .virtualHost)
        #expect(config.url(forKey: "x").absoluteString
                == "https://video.minio.example.com:9000/x")
    }

    @Test func queryItemsWithValuesRenderInOrder() {
        let config = makeConfig()
        let url = config.url(forKey: "x", query: [
            URLQueryItem(name: "uploadId", value: "abc"),
            URLQueryItem(name: "partNumber", value: "2"),
        ])
        #expect(url.absoluteString
                == "https://minio.example.com:9000/video/x?uploadId=abc&partNumber=2")
    }

    @Test func bucketWithSpaceIsPercentEncodedPathStyle() {
        let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                              bucket: "my bucket", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        #expect(config.url(forKey: "a.mov").absoluteString
                == "https://minio.example.com:9000/my%20bucket/a.mov")
    }

    @Test func virtualHostInvalidBucketFallsBackToPathStyle() {
        let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                              bucket: "my bucket", accessKey: "AK", secretKey: "SK",
                              style: .virtualHost, region: "us-east-1")
        #expect(config.url(forKey: "x").absoluteString
                == "https://minio.example.com:9000/my%20bucket/x")
    }

    @Test func virtualHostValidBucketStaysVirtualHost() {
        let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                              bucket: "my-bucket.v2", accessKey: "AK", secretKey: "SK",
                              style: .virtualHost, region: "us-east-1")
        #expect(config.url(forKey: "x").absoluteString
                == "https://my-bucket.v2.minio.example.com:9000/x")
    }

    @Test func endpointWithoutPortWorks() {
        let config = S3Config(endpoint: URL(string: "https://s3.example.com")!,
                              bucket: "video", accessKey: "AK", secretKey: "SK",
                              style: .path, region: "us-east-1")
        #expect(config.url(forKey: "a.mov").absoluteString
                == "https://s3.example.com/video/a.mov")
    }
}
