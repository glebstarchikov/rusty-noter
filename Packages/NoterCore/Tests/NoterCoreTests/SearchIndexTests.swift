import Testing
import Foundation
@testable import NoterCore

@Suite struct SearchIndexTests {
    func note(_ path: String, _ title: String, tags: [String] = [], body: String = "") -> Note {
        Note(relativePath: path,
             metadata: NoteMetadata(title: title, created: .now, updated: .now, tags: tags),
             body: body)
    }

    @Test func findsByTitleTagsAndBody() async throws {
        let index = try SearchIndex(databasePath: nil)
        try await index.upsert(note("a.md", "API pricing ideas", body: "value metric"))
        try await index.upsert(note("b.md", "Groceries", tags: ["home"], body: "milk, eggs"))
        try await index.upsert(note("c.md", "Standup", body: "we discussed the pricing page"))

        #expect(try await index.search("groceries") == ["b.md"])
        #expect(try await index.search("home") == ["b.md"])
        #expect(Set(try await index.search("pricing")) == ["a.md", "c.md"])
        // Title match must outrank body match:
        #expect(try await index.search("pricing").first == "a.md")
    }

    @Test func prefixMatchingWorks() async throws {
        let index = try SearchIndex(databasePath: nil)
        try await index.upsert(note("a.md", "Transcription pipeline"))
        #expect(try await index.search("transcr") == ["a.md"])
        #expect(try await index.search("transcr pipe") == ["a.md"])
    }

    @Test func upsertReplacesAndRemoveRemoves() async throws {
        let index = try SearchIndex(databasePath: nil)
        try await index.upsert(note("a.md", "Old title"))
        try await index.upsert(note("a.md", "New title"))
        #expect(try await index.search("old") == [])
        #expect(try await index.search("new") == ["a.md"])
        try await index.remove("a.md")
        #expect(try await index.search("new") == [])
    }

    @Test func garbageQueriesReturnEmpty() async throws {
        let index = try SearchIndex(databasePath: nil)
        try await index.upsert(note("a.md", "Anything"))
        #expect(try await index.search("") == [])
        #expect(try await index.search("   ") == [])
        #expect(try await index.search("\"*") == [])
    }

    @Test func rebuildReplacesEverything() async throws {
        let index = try SearchIndex(databasePath: nil)
        try await index.upsert(note("stale.md", "Stale"))
        try await index.rebuild(from: [note("fresh.md", "Fresh")])
        #expect(try await index.search("stale") == [])
        #expect(try await index.search("fresh") == ["fresh.md"])
    }

    @Test func thousandNotesSearchUnder50ms() async throws {
        let index = try SearchIndex(databasePath: nil)
        var notes: [Note] = []
        for i in 0..<1000 {
            notes.append(note("n\(i).md", "Note number \(i)",
                              tags: i % 7 == 0 ? ["weekly"] : [],
                              body: "filler content \(i) lorem ipsum pricing meeting agenda"))
        }
        try await index.rebuild(from: notes)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await index.search("pricing meeting")
        }
        #expect(elapsed < .milliseconds(50))
    }
}
