import Testing
import Foundation
@testable import NoterCore

@Suite struct SlugTests {
    @Test func basics() {
        #expect(Slug.make("API pricing ideas") == "api-pricing-ideas")
        #expect(Slug.make("  Hello,   World!  ") == "hello-world")
        #expect(Slug.make("Standup with Anna") == "standup-with-anna")
    }

    @Test func transliteratesNonASCII() {
        #expect(Slug.make("Встреча с Анной") == "vstreca-s-annoj")
        #expect(Slug.make("Über café") == "uber-cafe")
    }

    @Test func emptyAndSymbolOnlyFallBack() {
        #expect(Slug.make("") == "untitled")
        #expect(Slug.make("!!! ???") == "untitled")
    }

    @Test func capsAt60Chars() {
        let long = String(repeating: "word ", count: 30)
        let slug = Slug.make(long)
        #expect(slug.count <= 60)
        #expect(!slug.hasSuffix("-"))
    }

    @Test func uniqueFilenameFormatsAndCollides() {
        let date = Date.iso8601Local("2026-07-13T10:00:00+02:00")!
        var existing: Set<String> = []
        let first = Slug.uniqueFilename(date: date, title: "Untitled", existing: existing)
        #expect(first == "2026-07-13-untitled.md")
        existing.insert(first)
        let second = Slug.uniqueFilename(date: date, title: "Untitled", existing: existing)
        #expect(second == "2026-07-13-untitled-2.md")
        existing.insert(second)
        let third = Slug.uniqueFilename(date: date, title: "Untitled", existing: existing)
        #expect(third == "2026-07-13-untitled-3.md")
    }
}
