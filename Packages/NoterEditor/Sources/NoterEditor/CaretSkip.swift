import Foundation

/// Pure decision logic for R6d's caret-skip mechanic: given the caret's
/// proposed new (empty-selection) location and the set of currently-hidden
/// `.mdHidden` character ranges, decide where the caret should actually
/// land. The hidden characters are still real characters in the string --
/// glyph-nulling (see `MarkdownTextView`) only changes their rendering --
/// so without this the caret pauses, stepping through a hidden run one
/// character at a time instead of gliding across it in a single press.
/// Factored out of `MarkdownTextView.Coordinator` -- NSTextView-bound and
/// hard to drive headlessly -- so the direction/edge cases can be
/// unit-tested directly, mirroring `SyntaxMarkerVisibility`.
public enum CaretSkip {
    /// If `proposed` lands strictly inside one of `hiddenRanges`, returns
    /// the edge of that run in the direction of travel: comparing
    /// `proposed` to `old`, moving right (`proposed >= old`) lands at the
    /// run's end, moving left lands at the run's start. A `proposed`
    /// location that is NOT strictly inside a hidden run -- including
    /// exactly at one of its edges -- passes through unchanged.
    ///
    /// Note a length-1 hidden run (e.g. a lone ">" blockquote marker) has
    /// no position strictly between its start and end, so it never matches
    /// here -- which is fine, since a single hidden character never causes
    /// the multi-step "pause" this exists to fix in the first place.
    public static func adjustedLocation(old: Int, proposed: Int, hiddenRanges: [NSRange]) -> Int {
        guard let hit = hiddenRanges.first(where: { $0.location < proposed && proposed < NSMaxRange($0) }) else {
            return proposed
        }
        return proposed >= old ? NSMaxRange(hit) : hit.location
    }
}
