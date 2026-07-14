import Foundation

/// Word count of markdown prose: links reduce to visible text, structural and
/// emphasis glyphs are dropped, bare URLs removed. Hyphenated tokens count once.
public enum WordCount {
    public static func count(of body: String) -> Int {
        var s = body
        // [text](url) -> text
        s = s.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // bare URLs -> removed
        s = s.replacingOccurrences(
            of: #"https?://\S+"#, with: " ", options: .regularExpression)
        // leading list markers per line -> removed
        s = s.replacingOccurrences(
            of: #"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, with: " ", options: .regularExpression)
        // inline/structural glyphs -> spaces (hyphen and underscore intentionally kept)
        s = s.replacingOccurrences(
            of: #"[#*`>~\[\]()]"#, with: " ", options: .regularExpression)
        return s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
