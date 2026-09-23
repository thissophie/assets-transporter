import Foundation
import Testing
@testable import AssetsTransporter

struct S3ListParserTests {
    @Test func parsesTruncatedListingWithContentsAndPrefixes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Name>video</Name>
            <Prefix>acme/</Prefix>
            <KeyCount>2</KeyCount>
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>tok123</NextContinuationToken>
            <Contents>
                <Key>acme/a b.mov</Key>
                <LastModified>2026-09-19T18:30:42.000Z</LastModified>
                <Size>1048576</Size>
            </Contents>
            <Contents>
                <Key>acme/b &amp; c.mov</Key>
                <LastModified>2026-09-18T07:05:00Z</LastModified>
                <Size>42</Size>
            </Contents>
            <CommonPrefixes>
                <Prefix>acme/subfolder/</Prefix>
            </CommonPrefixes>
        </ListBucketResult>
        """
        let result = try S3ListParser.parse(Data(xml.utf8))

        #expect(result.objects.count == 2)
        #expect(result.objects[0].key == "acme/a b.mov")
        #expect(result.objects[0].size == 1_048_576)
        #expect(result.objects[0].lastModified != nil)
        #expect(result.objects[1].key == "acme/b & c.mov")
        #expect(result.objects[1].size == 42)
        #expect(result.objects[1].lastModified != nil)
        #expect(result.commonPrefixes == ["acme/subfolder/"])
        #expect(result.nextContinuationToken == "tok123")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 19, hour: 18, minute: 30, second: 42))!
        #expect(result.objects[0].lastModified == expected)
    }

    @Test func notTruncatedYieldsNilContinuationToken() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>x.mov</Key>
                <LastModified>2026-09-19T18:30:42.000Z</LastModified>
                <Size>1</Size>
            </Contents>
        </ListBucketResult>
        """
        let result = try S3ListParser.parse(Data(xml.utf8))
        #expect(result.nextContinuationToken == nil)
        #expect(result.objects.count == 1)
    }

    @Test func malformedXMLThrows() {
        let xml = "<ListBucketResult><Contents><Key>broken"
        #expect(throws: (any Error).self) {
            try S3ListParser.parse(Data(xml.utf8))
        }
    }
}
