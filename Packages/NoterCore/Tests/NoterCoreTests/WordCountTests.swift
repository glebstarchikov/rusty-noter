import Testing
@testable import NoterCore

@Suite struct WordCountTests {
    @Test func plainText() {
        #expect(WordCount.count(of: "hello world") == 2)
        #expect(WordCount.count(of: "one two three four") == 4)
    }

    @Test func stripsMarkdownGlyphs() {
        #expect(WordCount.count(of: "# Heading\n\nsome **bold** text") == 4) // Heading some bold text
        #expect(WordCount.count(of: "- item one\n- item two") == 4)
        #expect(WordCount.count(of: "> a quoted line") == 3)
    }

    @Test func linksCountVisibleTextNotURL() {
        #expect(WordCount.count(of: "see [the spec](https://x.com/a/b) now") == 4) // see the spec now
        #expect(WordCount.count(of: "bare https://example.com/path url") == 2)     // bare url
    }

    @Test func inlineCodeCountsAsOneWord() {
        #expect(WordCount.count(of: "the `value_metric` field") == 3)
    }

    @Test func hyphenatedIsOneWord() {
        #expect(WordCount.count(of: "a value-add proposition") == 3)
    }

    @Test func emptyAndWhitespace() {
        #expect(WordCount.count(of: "") == 0)
        #expect(WordCount.count(of: "   \n\t  ") == 0)
    }
}
