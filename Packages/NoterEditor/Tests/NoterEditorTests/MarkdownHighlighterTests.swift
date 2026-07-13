import Testing
import Foundation
@testable import NoterEditor

/// NSRange of `substring` in `text` (first occurrence), UTF-16 based.
func range(of substring: String, in text: String) -> NSRange {
    (text as NSString).range(of: substring)
}

@Suite struct MarkdownHighlighterTests {
    @Test func headings() {
        let text = "# Title\n\n## Section two\n\nBody.\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownSpan(range: range(of: "# Title", in: text),
                                            kind: .heading(level: 1))))
        #expect(spans.contains(MarkdownSpan(range: range(of: "## Section two", in: text),
                                            kind: .heading(level: 2))))
    }

    @Test func inlineStyles() {
        let text = "Some **bold** and *italic* and `code` here.\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownSpan(range: range(of: "**bold**", in: text), kind: .bold)))
        #expect(spans.contains(MarkdownSpan(range: range(of: "*italic*", in: text), kind: .italic)))
        #expect(spans.contains(MarkdownSpan(range: range(of: "`code`", in: text), kind: .inlineCode)))
    }

    @Test func boldIsNotAlsoItalic() {
        let text = "**bold** only\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.filter { $0.kind == .italic }.isEmpty)
    }

    @Test func links() {
        let text = "See [the spec](docs/spec.md) for details.\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownSpan(range: range(of: "[the spec](docs/spec.md)", in: text),
                                            kind: .link)))
    }

    @Test func listsAndQuotes() {
        let text = "- item one\n1. numbered\n> quoted line\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownSpan(range: range(of: "- ", in: text), kind: .listMarker)))
        #expect(spans.contains(MarkdownSpan(range: range(of: "1. ", in: text), kind: .listMarker)))
        #expect(spans.contains(MarkdownSpan(range: range(of: "> quoted line", in: text),
                                            kind: .blockquote)))
    }

    @Test func fencedCodeBlocksSwallowInlineStyling() {
        let text = "```\n**not bold** here\n```\nafter **bold**\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let codeBlockSpans = spans.filter { $0.kind == .codeBlock }
        #expect(codeBlockSpans.count == 3) // fence, content line, fence
        let boldSpans = spans.filter { $0.kind == .bold }
        #expect(boldSpans == [MarkdownSpan(range: range(of: "**bold**", in: text), kind: .bold)])
    }

    @Test func utf16RangesSurviveEmoji() {
        let text = "## 🎉 Party plans\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let heading = spans.first { $0.kind == .heading(level: 2) }
        #expect(heading?.range == range(of: "## 🎉 Party plans", in: text))
        // Sanity: the range length is UTF-16 units (emoji = 2), not characters.
        #expect(heading?.range.length == ("## 🎉 Party plans" as NSString).length)
    }

    @Test func emptyAndPlainTextsProduceNoSpans() {
        #expect(MarkdownHighlighter.spans(in: "") == [])
        #expect(MarkdownHighlighter.spans(in: "just words\n") == [])
    }

    @Test func crlfLineEndingsDoNotLeakIntoSpans() {
        // Blockquote: the CR must not leak into the span range.
        let quote = "> quoted line\r\n"
        let quoteSpans = MarkdownHighlighter.spans(in: quote)
        let blockquote = quoteSpans.first { $0.kind == .blockquote }
        #expect((quote as NSString).substring(with: blockquote!.range) == "> quoted line")
        #expect(blockquote?.range.length == ("> quoted line" as NSString).length)

        // Fenced code block: no codeBlock span substring may contain a CR.
        let code = "```\r\ncode here\r\n```\r\n"
        let codeSpans = MarkdownHighlighter.spans(in: code)
        let codeBlockSpans = codeSpans.filter { $0.kind == .codeBlock }
        for span in codeBlockSpans {
            #expect(!(code as NSString).substring(with: span.range).contains("\r"))
        }
        // Middle content span is the code line, CR-free.
        #expect(codeBlockSpans.contains { (code as NSString).substring(with: $0.range) == "code here" })
    }
}
