import Testing
@testable import AssetsTransporter

struct SlugTests {
    @Test func basicSlugging() {
        #expect(Slug.make(from: "Acme Corp") == "acme-corp")
        #expect(Slug.make(from: "  Spring Gala 2026! ") == "spring-gala-2026")
        #expect(Slug.make(from: "Café Añejo") == "cafe-anejo")
        #expect(Slug.make(from: "***") == "untitled")
    }

    @Test func slugWithIDJoinsSlugAndID() {
        #expect(Slug.slugWithID("Acme Corp", id: "x7f2") == "acme-corp-x7f2")
    }

    @Test func shortIDIsFourSafeChars() {
        var rng = SystemRandomNumberGenerator()
        let id = Slug.shortID(using: &rng)
        #expect(id.count == 4)
        #expect(id.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
    }
}
