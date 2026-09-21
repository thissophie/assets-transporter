import Foundation

/// Abstraction over the network layer so S3Client can be tested with canned responses.
nonisolated protocol S3Transport: Sendable {
    /// `uploadFile` non-nil => stream the request body from that file.
    func perform(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by URLSession.
nonisolated struct URLSessionTransport: S3Transport {
    var session: URLSession = .shared

    func perform(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        if let uploadFile {
            (data, response) = try await session.upload(for: request, fromFile: uploadFile)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw S3Error.badResponse }
        return (data, http)
    }
}

nonisolated enum S3Error: Error, Equatable {
    case http(status: Int, body: String)
    case badResponse
}

/// Minimal S3 client: put/get/delete/list plus multipart upload operations.
/// Every request is SigV4-signed with the credentials in `config`.
nonisolated struct S3Client: Sendable {
    var config: S3Config
    var transport: S3Transport

    // MARK: - Objects

    func putObject(key: String, data: Data, contentType: String) async throws {
        var request = signedRequest(method: "PUT", key: key,
                                    headers: ["Content-Type": contentType])
        request.httpBody = data
        try await execute(request)
    }

    func putObject(key: String, fileURL: URL, contentType: String) async throws {
        let request = signedRequest(method: "PUT", key: key,
                                    headers: ["Content-Type": contentType])
        try await execute(request, uploadFile: fileURL)
    }

    func getObject(key: String, range: ClosedRange<Int64>? = nil) async throws -> Data {
        var headers: [String: String] = [:]
        if let range {
            headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        }
        let request = signedRequest(method: "GET", key: key, headers: headers)
        let (data, _) = try await execute(request)
        return data
    }

    /// HEAD the object and return its size from the Content-Length header.
    func objectSize(key: String) async throws -> Int64 {
        let request = signedRequest(method: "HEAD", key: key)
        let (_, response) = try await execute(request)
        guard let text = response.value(forHTTPHeaderField: "Content-Length"),
              let size = Int64(text) else {
            throw S3Error.badResponse
        }
        return size
    }

    func deleteObject(key: String) async throws {
        try await execute(signedRequest(method: "DELETE", key: key))
    }

    /// ListObjectsV2, auto-following continuation tokens and concatenating pages.
    func listObjects(prefix: String, delimiter: String? = nil) async throws -> S3ListResult {
        var objects: [S3Object] = []
        var commonPrefixes: [String] = []
        var continuationToken: String?

        repeat {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let delimiter {
                query.append(URLQueryItem(name: "delimiter", value: delimiter))
            }
            if let continuationToken {
                query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }
            let request = signedRequest(method: "GET", key: "", query: query)
            let (data, _) = try await execute(request)
            let page = try S3ListParser.parse(data)
            objects.append(contentsOf: page.objects)
            commonPrefixes.append(contentsOf: page.commonPrefixes)
            continuationToken = page.nextContinuationToken
        } while continuationToken != nil

        return S3ListResult(objects: objects, commonPrefixes: commonPrefixes,
                            nextContinuationToken: nil)
    }

    // MARK: - Multipart upload

    /// POST `?uploads`; returns the UploadId from the XML response.
    func createMultipartUpload(key: String, contentType: String) async throws -> String {
        let request = signedRequest(method: "POST", key: key,
                                    query: [URLQueryItem(name: "uploads", value: nil)],
                                    headers: ["Content-Type": contentType])
        let (data, _) = try await execute(request)
        guard let collector = XMLCollector.parse(data, groupedBy: nil),
              let uploadId = collector.topLevel["UploadId"], !uploadId.isEmpty else {
            throw S3Error.badResponse
        }
        return uploadId
    }

    /// PUT `?partNumber=N&uploadId=...` streaming from `fileURL`; returns the unquoted ETag.
    func uploadPart(key: String, uploadId: String, partNumber: Int, fileURL: URL) async throws -> String {
        let request = signedRequest(method: "PUT", key: key, query: [
            URLQueryItem(name: "partNumber", value: String(partNumber)),
            URLQueryItem(name: "uploadId", value: uploadId),
        ])
        let (_, response) = try await execute(request, uploadFile: fileURL)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw S3Error.badResponse
        }
        return Self.unquote(etag)
    }

    /// POST `?uploadId=...` with a CompleteMultipartUpload body, parts sorted by partNumber.
    func completeMultipartUpload(key: String, uploadId: String,
                                 parts: [(partNumber: Int, etag: String)]) async throws {
        let sorted = parts.sorted { $0.partNumber < $1.partNumber }
        var xml = "<CompleteMultipartUpload>"
        for part in sorted {
            xml += "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\"\(part.etag)\"</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"

        var request = signedRequest(method: "POST", key: key,
                                    query: [URLQueryItem(name: "uploadId", value: uploadId)],
                                    headers: ["Content-Type": "application/xml"])
        request.httpBody = Data(xml.utf8)
        let (data, response) = try await execute(request)

        // S3 can return HTTP 200 with an <Error> body for this operation;
        // only a CompleteMultipartUploadResult document counts as success.
        guard let collector = XMLCollector.parse(data, groupedBy: nil),
              collector.rootElement == "CompleteMultipartUploadResult" else {
            throw S3Error.http(status: response.statusCode,
                               body: String(decoding: data, as: UTF8.self))
        }
    }

    func abortMultipartUpload(key: String, uploadId: String) async throws {
        let request = signedRequest(method: "DELETE", key: key,
                                    query: [URLQueryItem(name: "uploadId", value: uploadId)])
        try await execute(request)
    }

    /// GET `?uploadId=...`, following `part-number-marker` pagination.
    func listParts(key: String, uploadId: String) async throws -> [(partNumber: Int, etag: String, size: Int64)] {
        var parts: [(partNumber: Int, etag: String, size: Int64)] = []
        var marker: String?

        repeat {
            var query = [URLQueryItem(name: "uploadId", value: uploadId)]
            if let marker {
                query.append(URLQueryItem(name: "part-number-marker", value: marker))
            }
            let request = signedRequest(method: "GET", key: key, query: query)
            let (data, _) = try await execute(request)
            guard let collector = XMLCollector.parse(data, groupedBy: "Part") else {
                throw S3Error.badResponse
            }
            for group in collector.groups {
                guard let numberText = group["PartNumber"], let number = Int(numberText) else { continue }
                parts.append((partNumber: number,
                              etag: Self.unquote(group["ETag"] ?? ""),
                              size: Int64(group["Size"] ?? "") ?? 0))
            }
            marker = collector.topLevel["IsTruncated"] == "true"
                ? collector.topLevel["NextPartNumberMarker"]
                : nil
        } while marker != nil

        return parts
    }

    /// GET `?uploads&prefix=...`; returns in-progress multipart uploads,
    /// following key-marker/upload-id-marker pagination. `initiated` is the
    /// upload's start time (nil when the server omits it or it fails to
    /// parse) — used to age-gate the stale-upload sweep.
    func listMultipartUploads(
        prefix: String
    ) async throws -> [(key: String, uploadId: String, initiated: Date?)] {
        var uploads: [(key: String, uploadId: String, initiated: Date?)] = []
        var markers: (key: String, uploadId: String)?

        repeat {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "uploads", value: nil),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let markers {
                query.append(URLQueryItem(name: "key-marker", value: markers.key))
                query.append(URLQueryItem(name: "upload-id-marker", value: markers.uploadId))
            }
            let request = signedRequest(method: "GET", key: "", query: query)
            let (data, _) = try await execute(request)
            guard let collector = XMLCollector.parse(data, groupedBy: "Upload") else {
                throw S3Error.badResponse
            }
            uploads.append(contentsOf: collector.groups.compactMap { group in
                guard let key = group["Key"], let uploadId = group["UploadId"] else { return nil }
                return (key: key, uploadId: uploadId,
                        initiated: group["Initiated"].flatMap(S3Timestamp.parse))
            })
            if collector.topLevel["IsTruncated"] == "true",
               let nextKey = collector.topLevel["NextKeyMarker"],
               let nextUploadId = collector.topLevel["NextUploadIdMarker"] {
                markers = (key: nextKey, uploadId: nextUploadId)
            } else {
                markers = nil
            }
        } while markers != nil

        return uploads
    }

    // MARK: - Internals

    /// Builds the URL via `config`, applies method and headers, and stamps SigV4.
    private func signedRequest(method: String, key: String,
                               query: [URLQueryItem]? = nil,
                               headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: config.url(forKey: key, query: query))
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return SigV4.sign(request: request, accessKey: config.accessKey,
                          secretKey: config.secretKey, region: config.region, date: Date())
    }

    /// Performs the request and maps non-2xx statuses to `S3Error.http`.
    @discardableResult
    private func execute(_ request: URLRequest, uploadFile: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.perform(request, uploadFile: uploadFile)
        guard (200...299).contains(response.statusCode) else {
            throw S3Error.http(status: response.statusCode,
                               body: String(decoding: data, as: UTF8.self))
        }
        return (data, response)
    }

    private static func unquote(_ etag: String) -> String {
        var value = etag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        return value
    }
}

/// Small XML helper: collects text of top-level elements, and — when `groupElement`
/// is given — one dictionary of child-element text per occurrence of that element.
/// All values are whitespace-trimmed.
private nonisolated final class XMLCollector: NSObject, XMLParserDelegate {
    private let groupElement: String?
    private(set) var rootElement: String?
    private(set) var groups: [[String: String]] = []
    private(set) var topLevel: [String: String] = [:]
    private var current: [String: String]?
    private var text = ""

    private init(groupElement: String?) {
        self.groupElement = groupElement
    }

    static func parse(_ data: Data, groupedBy groupElement: String?) -> XMLCollector? {
        let collector = XMLCollector(groupElement: groupElement)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        text = ""
        if rootElement == nil { rootElement = elementName }
        if elementName == groupElement { current = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == groupElement {
            if let current { groups.append(current) }
            current = nil
        } else if current != nil {
            current?[elementName] = value
        } else {
            topLevel[elementName] = value
        }
        text = ""
    }
}
