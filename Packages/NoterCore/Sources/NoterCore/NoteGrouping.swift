import Foundation

public struct NoteSection: Identifiable, Equatable, Sendable {
    public let title: String
    public let notes: [Note]
    public var id: String { title }
    public init(title: String, notes: [Note]) {
        self.title = title
        self.notes = notes
    }
}

/// Pure, deterministic date bucketing for the note list. Inject `now`/`calendar`.
public enum NoteGrouping {
    private enum Bucket: Hashable {
        case today, yesterday, prev7, prev30
        case month(Int, Int) // year, month
    }

    public static func sections(notes: [Note], now: Date, calendar: Calendar) -> [NoteSection] {
        let startOfToday = calendar.startOfDay(for: now)
        var buckets: [Bucket: [Note]] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.metadata.updated)
            let daysAgo = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 99999
            let bucket: Bucket
            if daysAgo <= 0 { bucket = .today }
            else if daysAgo == 1 { bucket = .yesterday }
            else if daysAgo <= 7 { bucket = .prev7 }
            else if daysAgo <= 30 { bucket = .prev30 }
            else {
                let c = calendar.dateComponents([.year, .month], from: note.metadata.updated)
                bucket = .month(c.year ?? 0, c.month ?? 0)
            }
            buckets[bucket, default: []].append(note)
        }

        func sorted(_ notes: [Note]) -> [Note] {
            notes.sorted { $0.metadata.updated > $1.metadata.updated }
        }

        var result: [NoteSection] = []
        for (bucket, title) in [(Bucket.today, "Today"), (.yesterday, "Yesterday"),
                                (.prev7, "Previous 7 Days"), (.prev30, "Previous 30 Days")] {
            if let notes = buckets[bucket], !notes.isEmpty {
                result.append(NoteSection(title: title, notes: sorted(notes)))
            }
        }
        // Month buckets, newest first.
        let months = buckets.keys.compactMap { key -> (Int, Int)? in
            if case let .month(y, m) = key { return (y, m) } else { return nil }
        }.sorted { ($0.0, $0.1) > ($1.0, $1.1) }
        for (y, m) in months {
            let notes = buckets[.month(y, m)] ?? []
            result.append(NoteSection(title: monthTitle(year: y, month: m, calendar: calendar),
                                      notes: sorted(notes)))
        }
        return result
    }

    public static func rowDateLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: date)
    }

    private static func monthTitle(year: Int, month: Int, calendar: Calendar) -> String {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        let date = calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }
}
