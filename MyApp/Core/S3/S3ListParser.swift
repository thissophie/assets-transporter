import Foundation

/// One object entry from a ListObjectsV2 response.
nonisolated struct S3Object: Equatable, Sendable {
    var key: String
    var size: Int64
    var lastModified: Date?
}

/// Parsed ListObjectsV2 response page.
nonisolated struct S3ListResult: Equatable, Sendable {
    var objects: [S3Object]
    var commonPrefixes: [String]
    var nextContinuationToken: String?
}

/// Parses S3 ListObjectsV2 XML responses.
nonisolated enum S3ListParser {

    enum ParseError: Error {
        case malformedXML(underlying: (any Error)?)
    }

    static func parse(_ data: Data) throws -> S3ListResult {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.malformedXML(underlying: parser.parserError)
        }
        return S3ListResult(objects: delegate.objects,
                            commonPrefixes: delegate.commonPrefixes,
                            nextContinuationToken: delegate.isTruncated ? delegate.nextContinuationToken : nil)
    }

    private nonisolated final class Delegate: NSObject, XMLParserDelegate {
        var objects: [S3Object] = []
        var commonPrefixes: [String] = []
        var nextContinuationToken: String?
        var isTruncated = false

        private var text = ""
        private var inContents = false
        private var inCommonPrefixes = false
        private var currentKey: String?
        private var currentSize: Int64 = 0
        private var currentLastModified: Date?

        private static let iso8601Fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let iso8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        private static func parseDate(_ string: String) -> Date? {
            iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "Contents":
                inContents = true
                currentKey = nil
                currentSize = 0
                currentLastModified = nil
            case "CommonPrefixes":
                inCommonPrefixes = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "Key" where inContents:
                currentKey = text
            case "Size" where inContents:
                currentSize = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case "LastModified" where inContents:
                currentLastModified = Self.parseDate(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "Contents":
                if let key = currentKey {
                    objects.append(S3Object(key: key, size: currentSize, lastModified: currentLastModified))
                }
                inContents = false
            case "Prefix" where inCommonPrefixes:
                commonPrefixes.append(text)
            case "CommonPrefixes":
                inCommonPrefixes = false
            case "IsTruncated":
                isTruncated = text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            case "NextContinuationToken":
                nextContinuationToken = text
            default:
                break
            }
        }
    }
}
