import Testing
import Foundation
@testable import NoterCore

@Suite struct NoteGroupingTests {
    // Fixed reference "now": 2026-07-14 12:00 UTC.
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    var now: Date { Date.iso8601Local("2026-07-14T12:00:00+00:00")! }

    func note(_ path: String, updated: String, title: String = "N", pinned: Bool = false) -> Note {
        Note(relativePath: path,
             metadata: NoteMetadata(title: title,
                                    created: Date.iso8601Local(updated)!,
                                    updated: Date.iso8601Local(updated)!,
                                    pinned: pinned),
             body: "")
    }

    @Test func bucketsByRelativeDay() {
        let notes = [
            note("t.md",  updated: "2026-07-14T09:00:00+00:00"), // today
            note("y.md",  updated: "2026-07-13T09:00:00+00:00"), // yesterday
            note("w.md",  updated: "2026-07-10T09:00:00+00:00"), // 4 days -> prev 7
            note("m.md",  updated: "2026-06-30T09:00:00+00:00"), // 14 days -> prev 30
            note("o.md",  updated: "2026-05-02T09:00:00+00:00"), // older -> May 2026
        ]
        let titles = NoteGrouping.sections(notes: notes, now: now, calendar: utc).map(\.title)
        #expect(titles == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "May 2026"])
    }

    @Test func boundaryDays() {
        // exactly 7 days ago -> Previous 7 Days; exactly 8 -> Previous 30 Days
        let seven = note("7.md", updated: "2026-07-07T09:00:00+00:00")
        let eight = note("8.md", updated: "2026-07-06T09:00:00+00:00")
        let thirty = note("30.md", updated: "2026-06-14T09:00:00+00:00")
        let thirtyOne = note("31.md", updated: "2026-06-13T09:00:00+00:00")
        let s = NoteGrouping.sections(notes: [seven, eight, thirty, thirtyOne], now: now, calendar: utc)
        let map = Dictionary(uniqueKeysWithValues: s.map { ($0.title, $0.notes.map(\.relativePath)) })
        #expect(map["Previous 7 Days"] == ["7.md"])
        #expect(map["Previous 30 Days"]?.sorted() == ["30.md", "8.md"])
        #expect(map["June 2026"] == ["31.md"])
    }

    @Test func withinBucketSortedByUpdatedDesc() {
        let a = note("a.md", updated: "2026-07-14T08:00:00+00:00")
        let b = note("b.md", updated: "2026-07-14T11:00:00+00:00")
        let s = NoteGrouping.sections(notes: [a, b], now: now, calendar: utc)
        #expect(s.first?.notes.map(\.relativePath) == ["b.md", "a.md"])
    }

    @Test func monthBucketsDescending() {
        let may = note("may.md", updated: "2026-05-10T09:00:00+00:00")
        let apr = note("apr.md", updated: "2026-04-10T09:00:00+00:00")
        let titles = NoteGrouping.sections(notes: [apr, may], now: now, calendar: utc).map(\.title)
        #expect(titles == ["May 2026", "April 2026"])
    }

    @Test func emptyBucketsOmittedAndEmptyInput() {
        #expect(NoteGrouping.sections(notes: [], now: now, calendar: utc).isEmpty)
        let onlyToday = NoteGrouping.sections(
            notes: [note("t.md", updated: "2026-07-14T09:00:00+00:00")], now: now, calendar: utc)
        #expect(onlyToday.map(\.title) == ["Today"])
    }

    @Test func futureDatedNoteFallsInToday() {
        let future = note("f.md", updated: "2026-07-20T09:00:00+00:00")
        let s = NoteGrouping.sections(notes: [future], now: now, calendar: utc)
        #expect(s.map(\.title) == ["Today"])
    }

    @Test func rowDateLabelFormats() {
        #expect(NoteGrouping.rowDateLabel(
            for: Date.iso8601Local("2026-07-14T09:05:00+00:00")!, now: now, calendar: utc) == "09:05")
        #expect(NoteGrouping.rowDateLabel(
            for: Date.iso8601Local("2026-07-10T09:00:00+00:00")!, now: now, calendar: utc) == "Jul 10")
        #expect(NoteGrouping.rowDateLabel(
            for: Date.iso8601Local("2025-12-30T09:00:00+00:00")!, now: now, calendar: utc) == "2025-12-30")
    }

    @Test func pinnedNotesGoInPinnedSectionFirst() {
        let notes = [
            note("t.md", updated: "2026-07-14T09:00:00+00:00"),               // today
            note("p.md", updated: "2026-05-01T09:00:00+00:00", pinned: true), // old, but pinned
        ]
        let sections = NoteGrouping.sections(notes: notes, now: now, calendar: utc)
        #expect(sections.first?.title == "Pinned")
        #expect(sections.first?.notes.map(\.relativePath) == ["p.md"])
        // Pinned note is excluded from the time buckets:
        #expect(!sections.dropFirst().contains { $0.notes.contains { $0.relativePath == "p.md" } })
        // Unpinned note is still bucketed normally:
        #expect(sections.map(\.title).contains("Today"))
    }

    @Test func pinnedSectionSortsByUpdatedDesc() {
        let notes = [
            note("a.md", updated: "2026-07-10T09:00:00+00:00", pinned: true),
            note("b.md", updated: "2026-07-12T09:00:00+00:00", pinned: true),
        ]
        let pinned = NoteGrouping.sections(notes: notes, now: now, calendar: utc).first
        #expect(pinned?.title == "Pinned")
        #expect(pinned?.notes.map(\.relativePath) == ["b.md", "a.md"])
    }

    @Test func noPinnedSectionWhenNonePinned() {
        let sections = NoteGrouping.sections(
            notes: [note("t.md", updated: "2026-07-14T09:00:00+00:00")], now: now, calendar: utc)
        #expect(!sections.map(\.title).contains("Pinned"))
    }
}
