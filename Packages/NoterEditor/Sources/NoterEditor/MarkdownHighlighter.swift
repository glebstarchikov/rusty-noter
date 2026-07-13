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
            return spans // headings get no inline styling in v1
        }
        if line.hasPrefix("> ") || line == ">" {
            spans.append(MarkdownSpan(range: shifted(full), kind: .blockquote))
            return spans
        }
        if let m = listRx.firstMatch(in: line, range: full) {
            spans.append(MarkdownSpan(range: shifted(m.range), kind: .listMarker))
        }

        var consumed: [NSRange] = []
        func addMatches(_ rx: NSRegularExpression, _ kind: MarkdownSpanKind) {
            for m in rx.matches(in: line, range: full) {
                let overlaps = consumed.contains { NSIntersectionRange($0, m.range).length > 0 }
                guard !overlaps else { continue }
                consumed.append(m.range)
                spans.append(MarkdownSpan(range: shifted(m.range), kind: kind))
            }
        }
        // Order matters: code first (inline code may contain asterisks),
        // then links, bold, italic.
        addMatches(codeRx, .inlineCode)
        addMatches(linkRx, .link)
        addMatches(boldRx, .bold)
        addMatches(italicRx, .italic)
        return spans
    }
}
