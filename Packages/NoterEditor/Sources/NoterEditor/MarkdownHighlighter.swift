import Foundation

public enum MarkdownSpanKind: Equatable, Sendable {
    case heading(level: Int)
    case bold
    case italic
    case inlineCode
    case codeBlock
    case link
    case listMarker
    case blockquote
    /// A markdown delimiter glyph (`#`, `**`, `*`, backtick, `>`, link
    /// brackets/URL, code fence line) — rendered faint so the syntax recedes
    /// while the content it wraps keeps its normal styling. Overlaps content
    /// spans by design; renderers must apply it in a pass after content spans.
    case syntaxMarker
}

public struct MarkdownSpan: Equatable, Sendable {
    public let range: NSRange
    public let kind: MarkdownSpanKind
    public init(range: NSRange, kind: MarkdownSpanKind) {
        self.range = range
        self.kind = kind
    }
}

public enum MarkdownHighlighter {
    // Compiled once; NSRegularExpression is thread-safe.
    private static let boldRx = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
    private static let italicRx = try! NSRegularExpression(pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)"#)
    private static let codeRx = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let linkRx = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let headingRx = try! NSRegularExpression(pattern: #"^#{1,6} .*$"#)
    private static let listRx = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+\.) "#)

    public static func spans(in text: String) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        let ns = text as NSString
        var inCodeBlock = false
        var lineStart = 0
        while lineStart < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            // Content range without the trailing newline:
            var content = lineRange
            if content.length > 0,
               ns.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1)) == "\n" {
                content.length -= 1
            }
            if content.length > 0,
               ns.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1)) == "\r" {
                content.length -= 1
            }
            let line = ns.substring(with: content)

            if line.hasPrefix("```") {
                spans.append(MarkdownSpan(range: content, kind: .codeBlock))
                spans.append(MarkdownSpan(range: content, kind: .syntaxMarker))
                inCodeBlock.toggle()
            } else if inCodeBlock {
                spans.append(MarkdownSpan(range: content, kind: .codeBlock))
            } else {
                spans.append(contentsOf: lineSpans(line: line, at: content.location))
            }
            lineStart = NSMaxRange(lineRange)
        }
        return spans
    }

    private static func lineSpans(line: String, at offset: Int) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }

        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }

        if let m = headingRx.firstMatch(in: line, range: full) {
            let level = line.prefix(while: { $0 == "#" }).count
            spans.append(MarkdownSpan(range: shifted(m.range), kind: .heading(level: level)))
            // Marker = the hashes plus the single following space, e.g. "## ".
            spans.append(MarkdownSpan(range: shifted(NSRange(location: 0, length: level + 1)), kind: .syntaxMarker))
            return spans // headings get no inline styling in v1
        }
        if line.hasPrefix("> ") || line == ">" {
            spans.append(MarkdownSpan(range: shifted(full), kind: .blockquote))
            let markerLength = line.hasPrefix("> ") ? 2 : 1
            spans.append(MarkdownSpan(range: shifted(NSRange(location: 0, length: markerLength)), kind: .syntaxMarker))
            return spans
        }
        if let m = listRx.firstMatch(in: line, range: full) {
            spans.append(MarkdownSpan(range: shifted(m.range), kind: .listMarker))
        }

        var consumed: [NSRange] = []
        // Adds a content span plus two fixed-width marker spans (leading/trailing
        // delimiter glyphs), skipping matches that overlap an already-consumed range.
        func addMatches(_ rx: NSRegularExpression, _ kind: MarkdownSpanKind, markerLead: Int, markerTrail: Int) {
            for m in rx.matches(in: line, range: full) {
                let overlaps = consumed.contains { NSIntersectionRange($0, m.range).length > 0 }
                guard !overlaps else { continue }
                consumed.append(m.range)
                spans.append(MarkdownSpan(range: shifted(m.range), kind: kind))
                spans.append(MarkdownSpan(range: shifted(NSRange(location: m.range.location, length: markerLead)),
                                          kind: .syntaxMarker))
                spans.append(MarkdownSpan(range: shifted(NSRange(location: NSMaxRange(m.range) - markerTrail, length: markerTrail)),
                                          kind: .syntaxMarker))
            }
        }
        // Links dim "[" plus "](url)" (from the closing label bracket through
        // the match end), keeping only the visible label text styled as `.link`.
        func addLinkMatches() {
            for m in linkRx.matches(in: line, range: full) {
                let overlaps = consumed.contains { NSIntersectionRange($0, m.range).length > 0 }
                guard !overlaps else { continue }
                consumed.append(m.range)
                spans.append(MarkdownSpan(range: shifted(m.range), kind: .link))
                spans.append(MarkdownSpan(range: shifted(NSRange(location: m.range.location, length: 1)), kind: .syntaxMarker))
                // The label body excludes "]" by construction (linkRx), so the
                // first "]" found after the opening bracket is the label's close.
                let labelBody = NSRange(location: m.range.location + 1, length: m.range.length - 1)
                let closeBracket = ns.range(of: "]", options: [], range: labelBody)
                if closeBracket.location != NSNotFound {
                    let trail = NSRange(location: closeBracket.location, length: NSMaxRange(m.range) - closeBracket.location)
                    spans.append(MarkdownSpan(range: shifted(trail), kind: .syntaxMarker))
                }
            }
        }
        // Order matters: code first (inline code may contain asterisks),
        // then links, bold, italic.
        addMatches(codeRx, .inlineCode, markerLead: 1, markerTrail: 1)
        addLinkMatches()
        addMatches(boldRx, .bold, markerLead: 2, markerTrail: 2)
        addMatches(italicRx, .italic, markerLead: 1, markerTrail: 1)
        return spans
    }
}
