import Testing
@testable import AssetsTransporter

struct MediaTypesTests {

    @Test func mapsKnownVideoExtensions() {
        #expect(MediaTypes.contentType(forExtension: "mov") == "video/quicktime")
        #expect(MediaTypes.contentType(forExtension: "mp4") == "video/mp4")
        #expect(MediaTypes.contentType(forExtension: "m4v") == "video/x-m4v")
        #expect(MediaTypes.contentType(forExtension: "avi") == "video/x-msvideo")
        #expect(MediaTypes.contentType(forExtension: "mxf") == "application/mxf")
    }

    @Test func normalizesCaseAndLeadingDot() {
        #expect(MediaTypes.contentType(forExtension: "MOV") == "video/quicktime")
        #expect(MediaTypes.contentType(forExtension: ".mp4") == "video/mp4")
    }

    @Test func unknownOrEmptyFallsBackToOctetStream() {
        #expect(MediaTypes.contentType(forExtension: "bin") == "application/octet-stream")
        #expect(MediaTypes.contentType(forExtension: "") == "application/octet-stream")
    }
}
