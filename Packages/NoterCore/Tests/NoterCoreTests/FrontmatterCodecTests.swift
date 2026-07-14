import Testing
import Foundation
@testable import NoterCore

@Suite struct FrontmatterCodecTests {
    func sampleMetadata() -> NoteMetadata {
        NoteMetadata(
            title: "Standup with Anna",
            type: .meeting,
            created: Date.iso8601Local("2026-07-11T09:30:00+02:00")!,
            updated: Date.iso8601Local("2026-07-11T09:55:12+02:00")!,
            tags: ["work", "standup"],
            audio: "audio/2026-07-11-standup-with-anna.m4a",
            duration: "47m",
            status: nil
        )
    }

    @Test func roundTripPreservesEverything() throws {
        let original = sampleMetadata()
        let body = "## Notes\n\nSome **bold** text.\n"
        let raw = FrontmatterCodec.serialize(metadata: original, body: body)
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata == original)
        #expect(parsed.body == body)
    }

    @Test func serializeEmitsExpectedShape() {
        let tz = TimeZone(secondsFromGMT: 7200)!
        let raw = FrontmatterCodec.serialize(metadata: sampleMetadata(), body: "Hello\n", timeZone: tz)
        #expect(raw.hasPrefix("---\n"))
        #expect(raw.contains("title: Standup with Anna"))
        #expect(raw.contains("type: meeting"))
        #expect(raw.contains("created: 2026-07-11T09:30:00+02:00"))
        #expect(raw.contains("tags: [work, standup]"))
        #expect(raw.contains("audio: audio/2026-07-11-standup-with-anna.m4a"))
        #expect(raw.contains("duration: 47m"))
        // status is nil: the key must be absent entirely
        #expect(!raw.contains("status:"))
        #expect(raw.hasSuffix("---\n\nHello\n"))
    }

    @Test func statusRecordingSerializesAndParses() throws {
        var meta = sampleMetadata()
        meta.status = .recording
        let raw = FrontmatterCodec.serialize(metadata: meta, body: "")
        #expect(raw.contains("status: recording"))
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata.status == .recording)
    }

    @Test func minimalNoteOmitsOptionalKeys() throws {
        let meta = NoteMetadata(
            title: "Quick thought",
            type: .note,
            created: Date.iso8601Local("2026-07-13T10:00:00+02:00")!,
            updated: Date.iso8601Local("2026-07-13T10:00:00+02:00")!,
            tags: [],
            audio: nil, duration: nil, status: nil
        )
        let raw = FrontmatterCodec.serialize(metadata: meta, body: "x")
        #expect(!raw.contains("audio:"))
        #expect(!raw.contains("duration:"))
        #expect(raw.contains("tags: []"))
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata == meta)
        #expect(parsed.body == "x")
    }

    @Test func missingFrontmatterThrows() {
        #expect(throws: FrontmatterError.missingFrontmatter) {
            try FrontmatterCodec.parse("Just a plain markdown file\n")
        }
        #expect(throws: FrontmatterError.missingFrontmatter) {
            try FrontmatterCodec.parse("")
        }
    }

    @Test func malformedYAMLThrows() {
        let raw = "---\ntitle: [unclosed\n---\n\nbody"
        #expect(throws: FrontmatterError.self) {
            try FrontmatterCodec.parse(raw)
        }
    }

    @Test func hostileTitleRoundTrips() throws {
        // Colons, quotes, hash, pipe: all must survive YAML round-trip.
        var meta = sampleMetadata()
        meta.title = #"Q3: "the plan" | 50% #done"#
        let raw = FrontmatterCodec.serialize(metadata: meta, body: "")
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata.title == meta.title)
    }

    @Test func nullLikeTitlesRoundTrip() throws {
        // Bare "null"/"Null"/"NULL"/"~" are YAML null tokens: unquoted they
        // decode as nil and the title silently becomes "". Must be quoted.
        for hostile in ["null", "Null", "NULL", "~"] {
            var meta = sampleMetadata()
            meta.title = hostile
            let raw = FrontmatterCodec.serialize(metadata: meta, body: "")
            let parsed = try FrontmatterCodec.parse(raw)
            #expect(parsed.metadata.title == hostile)
        }
    }

    @Test func titleWithEmbeddedNewlineRoundTrips() throws {
        var meta = sampleMetadata()
        meta.title = "line one\nline two"
        let raw = FrontmatterCodec.serialize(metadata: meta, body: "")
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata.title == "line one\nline two")
    }

    @Test func bodyContainingTripleDashSurvives() throws {
        let body = "para one\n\n---\n\npara two after a thematic break\n"
        let raw = FrontmatterCodec.serialize(metadata: sampleMetadata(), body: body)
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.body == body)
    }

    @Test func bodyWithoutTrailingNewlineRoundTripsExactly() throws {
        // parse(serialize(b)) must return b byte-for-byte, even with no trailing newline.
        let raw = FrontmatterCodec.serialize(metadata: sampleMetadata(), body: "x")
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.body == "x")
    }

    @Test func bareClosingFenceAtEOFParsesWithEmptyBody() throws {
        // File ends exactly with "\n---" (no trailing newline, no body).
        let raw = "---\ntitle: T\ntype: note\ncreated: 2026-07-13T10:00:00+02:00\nupdated: 2026-07-13T10:00:00+02:00\ntags: []\n---"
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata.title == "T")
        #expect(parsed.body == "")
    }

    @Test func unknownFrontmatterKeysAreTolerated() throws {
        let raw = """
        ---
        title: External note
        type: note
        created: 2026-07-13T10:00:00+02:00
        updated: 2026-07-13T10:00:00+02:00
        tags: [x]
        somebody_elses_key: whatever
        ---

        body
        """
        let parsed = try FrontmatterCodec.parse(raw)
        #expect(parsed.metadata.title == "External note")
    }

    @Test func timestampsRoundTripWithOffset() {
        let date = Date.iso8601Local("2026-07-11T09:30:00+02:00")
        #expect(date != nil)
        let tz = TimeZone(secondsFromGMT: 7200)!
        #expect(date!.iso8601LocalString(offset: tz) == "2026-07-11T09:30:00+02:00")
    }
}
