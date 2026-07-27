import SwiftUI

/// The 12 Crafted Minimal semantic tokens (light/dark variants live in the
/// asset catalog). Views reference these, never raw hex (design.md hard rule 2).
enum TokenColor {
    static let bg = Color("bg")
    static let elevated = Color("elevated")
    static let fg = Color("fg")
    static let secondary = Color("secondary")
    static let faint = Color("faint")
    static let border = Color("border")
    static let borderStrong = Color("borderStrong")
    static let accent = Color("accent")
    static let accentSoft = Color("accentSoft")
    static let success = Color("success")
    static let warning = Color("warning")
    static let danger = Color("danger")
}

/// Semantic typography roles for the app shell. Keeping sizes here prevents
/// nearby views from inventing almost-identical hierarchies independently.
enum TokenFont {
    static let metadata = Font.system(size: 11, design: .monospaced)
    static let finePrint = Font.system(size: 11)
    static let supporting = Font.system(size: 12)
    static let interface = Font.system(size: 13)
    static let rowTitle = Font.system(size: 14, weight: .medium)
    static let commandInput = Font.system(size: 15)
    static let wordmark = Font.system(size: 16, weight: .medium, design: .monospaced)
    static let editorTitle = Font.system(size: 26, weight: .semibold)
}

/// One quiet motion vocabulary: quick feedback for local state and a slightly
/// longer transition only when list structure or an overlay changes.
enum TokenMotion {
    static let micro = Animation.easeOut(duration: 0.15)
    static let structural = Animation.easeOut(duration: 0.18)
    static let presentation = Animation.easeOut(duration: 0.16)
}
