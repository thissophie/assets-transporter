import Foundation
import Testing
@testable import AssetsTransporter

struct SigV4Tests {
    // Vector from AWS docs "Deriving the signing key". If this fails, verify against
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
    // — trust the docs over this file.
    @Test func signingKeyDerivation() {
        let key = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                   date: "20120215", region: "us-east-1", service: "iam")
        #expect(key.map { String(format: "%02x", $0) }.joined()
                == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    @Test func canonicalRequestShape() {
        var req = URLRequest(url: URL(string: "https://s3.example.com/bucket/a%20b.mov")!)
        req.httpMethod = "PUT"
        req.setValue("s3.example.com", forHTTPHeaderField: "Host")
        req.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue("20260919T183042Z", forHTTPHeaderField: "x-amz-date")
        let canonical = SigV4.canonicalRequest(for: req, payloadHash: "UNSIGNED-PAYLOAD")
        let lines = canonical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "PUT")
        #expect(lines[1] == "/bucket/a%20b.mov")
        #expect(lines[2] == "")
        #expect(lines.contains("host:s3.example.com"))
        #expect(lines.last == "UNSIGNED-PAYLOAD")
    }

    @Test func canonicalQueryString() {
        var req = URLRequest(url: URL(string: "https://s3.example.com/bucket/x.mov?uploadId=abc&partNumber=2")!)
        req.httpMethod = "PUT"
        req.setValue("s3.example.com", forHTTPHeaderField: "Host")
        let canonical = SigV4.canonicalRequest(for: req, payloadHash: "UNSIGNED-PAYLOAD")
        let lines = canonical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[2] == "partNumber=2&uploadId=abc")

        var req2 = URLRequest(url: URL(string: "https://s3.example.com/bucket/x?uploads")!)
        req2.httpMethod = "POST"
        req2.setValue("s3.example.com", forHTTPHeaderField: "Host")
        let canonical2 = SigV4.canonicalRequest(for: req2, payloadHash: "UNSIGNED-PAYLOAD")
        let lines2 = canonical2.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines2[2] == "uploads=")
    }

    @Test func authorizationHeaderFormat() throws {
        var req = URLRequest(url: URL(string: "https://s3.example.com/bucket/x?uploads")!)
        req.httpMethod = "POST"
        let signed = SigV4.sign(request: req, accessKey: "AKIDEXAMPLE", secretKey: "SECRET",
                                region: "us-east-1", date: Date(timeIntervalSince1970: 1_789_000_000))
        let auth = try #require(signed.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260910/us-east-1/s3/aws4_request, SignedHeaders="))
        #expect(auth.contains("host;x-amz-content-sha256;x-amz-date"))
        let sig = try #require(auth.components(separatedBy: "Signature=").last)
        #expect(sig.count == 64)
        #expect(sig.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(signed.value(forHTTPHeaderField: "x-amz-date") == "20260910T002640Z")
    }

    // Vector from AWS docs "Authenticating Requests: Using Query Parameters
    // (AWS Signature Version 4)". If this fails, trust the docs over this file.
    @Test func presignedURLMatchesAWSVector() {
        let url = SigV4.presignedURL(
            url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            accessKey: "AKIAIOSFODNN7EXAMPLE",
            secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1", expires: 86400,
            date: Date(timeIntervalSince1970: 1_369_353_600)) // 20130524T000000Z
        #expect(url.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt"
            + "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    /// A non-default port is part of the signed host, so changing it must
    /// change the signature (and re-signing the same URL must not).
    @Test func presignedURLSignsNonDefaultPort() throws {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        func signature(port: Int) throws -> String {
            let url = SigV4.presignedURL(url: URL(string: "http://localhost:\(port)/it-video/x.mov")!,
                                         accessKey: "AK", secretKey: "SK",
                                         region: "us-east-1", expires: 3600, date: date)
            return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "X-Amz-Signature" }?.value)
        }
        let sig = try signature(port: 4566)
        #expect(sig.count == 64)
        #expect(sig.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(try signature(port: 4566) == sig)
        #expect(try signature(port: 9000) != sig)
    }

    @Test func signingIsDeterministic() {
        var req = URLRequest(url: URL(string: "https://s3.example.com/b/k.mov")!)
        req.httpMethod = "GET"
        let d = Date(timeIntervalSince1970: 1_789_000_000)
        let s1 = SigV4.sign(request: req, accessKey: "AK", secretKey: "SK", region: "r", date: d)
        let s2 = SigV4.sign(request: req, accessKey: "AK", secretKey: "SK", region: "r", date: d)
        #expect(s1.value(forHTTPHeaderField: "Authorization") == s2.value(forHTTPHeaderField: "Authorization"))
    }
}
