import Testing
import Foundation
@testable import NoterEditor

/// Tests for R6e's pure "which bar segments belong on one continuous run"
/// logic (`RectMerge`), mirroring `CaretSkipTests`/`BlockDecorationsTests`.
/// All rects here use the same x/width (3, matching the real blockquote
/// bar) since that's the precondition `RectMerge.mergeVertically` assumes
/// -- only Y-extent varies, as it does for real per-line-fragment segments.
@Suite struct RectMergeTests {
    @Test func emptyInputReturnsEmpty() {
        #expect(RectMerge.mergeVertically([], tolerance: 1.5).isEmpty)
    }

    @Test func singleRectPassesThroughUnchanged() {
        let rect = NSRect(x: 34, y: 40, width: 3, height: 20)
        #expect(RectMerge.mergeVertically([rect], tolerance: 1.5) == [rect])
    }

    @Test func exactlyAbuttingRectsMergeIntoOneRun() {
        // Two line fragments stacked with zero gap -- the case
        // `drawBackground` produces now that it uses full fragment rects.
        let top = NSRect(x: 34, y: 40, width: 3, height: 20)
        let bottom = NSRect(x: 34, y: 60, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([top, bottom], tolerance: 1.5)
        #expect(merged == [NSRect(x: 34, y: 40, width: 3, height: 40)])
    }

    @Test func overlappingRectsMergeIntoOneRun() {
        let top = NSRect(x: 34, y: 40, width: 3, height: 20)
        let bottom = NSRect(x: 34, y: 55, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([top, bottom], tolerance: 1.5)
        #expect(merged == [NSRect(x: 34, y: 40, width: 3, height: 35)])
    }

    @Test func rectsWithinToleranceMergeIntoOneRun() {
        // A sub-pixel/line-spacing gap that isn't literal zero should still
        // read as one continuous bar -- that's what `tolerance` is for.
        let top = NSRect(x: 34, y: 40, width: 3, height: 20)
        let bottom = NSRect(x: 34, y: 61, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([top, bottom], tolerance: 1.5)
        #expect(merged == [NSRect(x: 34, y: 40, width: 3, height: 41)])
    }

    @Test func gapBeyondTolerancePreservesSeparateRuns() {
        // A real paragraph's worth of gap between two quote blocks --
        // e.g. an intervening non-quoted line -- must NOT bridge into one
        // bar; each quote keeps its own independently-rounded run.
        let first = NSRect(x: 34, y: 40, width: 3, height: 20)
        let second = NSRect(x: 34, y: 90, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([first, second], tolerance: 1.5)
        #expect(merged == [first, second])
    }

    @Test func gapExactlyAtToleranceBoundaryStillMerges() {
        // `<=` in the implementation means a gap exactly equal to
        // `tolerance` merges -- documenting the boundary rather than
        // leaving it implicit/untested, mirroring `CaretSkipTests`.
        let top = NSRect(x: 34, y: 40, width: 3, height: 20)
        let bottom = NSRect(x: 34, y: 61.5, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([top, bottom], tolerance: 1.5)
        #expect(merged.count == 1)
    }

    @Test func fourLineQuoteMergesIntoASingleRun() {
        // Simulates the reported bug: a 4-line blockquote's four
        // per-fragment segments must collapse to exactly one run spanning
        // top to bottom, so only its outer corners are rounded.
        let lines = (0..<4).map { i in NSRect(x: 34, y: CGFloat(i) * 20, width: 3, height: 20) }
        let merged = RectMerge.mergeVertically(lines, tolerance: 1.5)
        #expect(merged == [NSRect(x: 34, y: 0, width: 3, height: 80)])
    }

    @Test func twoSeparateSingleLineQuotesStayAsTwoRuns() {
        // The other half of the reported scenario: two SEPARATE one-line
        // blockquotes (not a single multi-line one) must each keep their
        // own bar, not merge into one spanning the gap between them.
        let quoteA = NSRect(x: 34, y: 0, width: 3, height: 20)
        let quoteB = NSRect(x: 34, y: 120, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([quoteA, quoteB], tolerance: 1.5)
        #expect(merged == [quoteA, quoteB])
    }

    @Test func unsortedInputMergesTheSameAsSortedInput() {
        // Callers collect segments in enumeration order across possibly
        // multiple blockquote ranges -- merging must not depend on the
        // caller having already sorted them.
        let top = NSRect(x: 34, y: 40, width: 3, height: 20)
        let middle = NSRect(x: 34, y: 60, width: 3, height: 20)
        let bottom = NSRect(x: 34, y: 80, width: 3, height: 20)
        let merged = RectMerge.mergeVertically([bottom, top, middle], tolerance: 1.5)
        #expect(merged == [NSRect(x: 34, y: 40, width: 3, height: 60)])
    }
}
