import Foundation

public enum Slug {
    /// Lowercase ASCII slug: transliterate, strip, hyphenate, cap at 60.
    public static func make(_ title: String) -> String {
        let latin = title.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? title
        let lowered = latin.lowercased()
        var out = ""
        var lastWasHyphen = true // suppress leading hyphen
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 60 {
            out = String(out.prefix(60))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "untitled" : out
    }

    /// `YYYY-MM-DD-slug.md`, suffixing `-2`, `-3`, ... until unique in `existing`.
    public static func uniqueFilename(date: Date, title: String, existing: Set<String>) -> String {
        let day = dayString(date)
        let base = "\(day)-\(make(title))"
        var candidate = base + ".md"
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(n).md"
            n += 1
        }
        return candidate
    }

    public static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
