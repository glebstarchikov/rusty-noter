import Testing
import Foundation
@testable import NoterEditor

/// Tests for R6d's pure "where should the caret land" logic (`CaretSkip`),
/// mirroring `SyntaxMarkerVisibilityTests`. See `MarkdownTextViewRestyleTests`
/// for the integration-level proof against a real `NSTextView` + `Coordinator`.
@Suite struct CaretSkipTests {
    @Test func movingRightIntoHiddenRunJumpsToItsEnd() {
        // "# " hidden at [0,2). Caret was at 0, natural one-step-right
        // landing is 1 (strictly inside) -> should jump past the run to 2.
        let hidden = [NSRange(location: 0, length: 2)]
        #expect(CaretSkip.adjustedLocation(old: 0, proposed: 1, hiddenRanges: hidden) == 2)
    }

    @Test func movingLeftIntoHiddenRunJumpsToItsStart() {
        let hidden = [NSRange(location: 0, length: 2)]
        #expect(CaretSkip.adjustedLocation(old: 2, proposed: 1, hiddenRanges: hidden) == 0)
    }

    @Test func positionExactlyAtRunStartPassesThroughUnchanged() {
        // The boundary itself is not "strictly inside" -- landing exactly
        // at a run's leading edge is a valid, unredirected position.
        let hidden = [NSRange(location: 5, length: 2)]
        #expect(CaretSkip.adjustedLocation(old: 4, proposed: 5, hiddenRanges: hidden) == 5)
    }

    @Test func positionExactlyAtRunEndPassesThroughUnchanged() {
        let hidden = [NSRange(location: 5, length: 2)]
        #expect(CaretSkip.adjustedLocation(old: 6, proposed: 7, hiddenRanges: hidden) == 7)
    }

    @Test func positionOutsideAnyHiddenRunPassesThroughUnchanged() {
        let hidden = [NSRange(location: 5, length: 2)]
        #expect(CaretSkip.adjustedLocation(old: 0, proposed: 20, hiddenRanges: hidden) == 20)
    }

    @Test func noHiddenRangesPassesThroughUnchanged() {
        #expect(CaretSkip.adjustedLocation(old: 0, proposed: 3, hiddenRanges: []) == 3)
    }

    @Test func picksTheHiddenRunThatActuallyContainsTheProposedLocation() {
        let hidden = [NSRange(location: 0, length: 2), NSRange(location: 10, length: 2)]
        #expect(CaretSkip.adjustedLocation(old: 9, proposed: 11, hiddenRanges: hidden) == 12)
        #expect(CaretSkip.adjustedLocation(old: 3, proposed: 1, hiddenRanges: hidden) == 0)
    }

    @Test func equalOldAndProposedDefaultsToForwardEdge() {
        // No real "direction" when old == proposed (e.g. a same-spot
        // re-selection); `>=` in the implementation means this defaults to
        // the "moving right" branch. Documenting the choice rather than
        // leaving it implicit/untested.
        let hidden = [NSRange(location: 0, length: 4)]
        #expect(CaretSkip.adjustedLocation(old: 2, proposed: 2, hiddenRanges: hidden) == 4)
    }

    @Test func singleCharacterHiddenRunHasNoStrictInterior() {
        // A length-1 run (e.g. a lone ">" blockquote marker) has no
        // position strictly between its start and end, so it never
        // matches -- which is fine, since a single hidden character never
        // causes the multi-step "pause" this exists to fix.
        let hidden = [NSRange(location: 5, length: 1)]
        #expect(CaretSkip.adjustedLocation(old: 4, proposed: 5, hiddenRanges: hidden) == 5)
        #expect(CaretSkip.adjustedLocation(old: 6, proposed: 5, hiddenRanges: hidden) == 5)
    }

    @Test func zeroLengthRangeNeverMatches() {
        // Defensive: a degenerate zero-length "hidden range" (shouldn't
        // occur in practice -- restyle() only ever marks non-empty marker
        // spans -- but the helper must not misbehave if one appears) has no
        // interior either.
        let hidden = [NSRange(location: 5, length: 0)]
        #expect(CaretSkip.adjustedLocation(old: 4, proposed: 5, hiddenRanges: hidden) == 5)
    }
}
