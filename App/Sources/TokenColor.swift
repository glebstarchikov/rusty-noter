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
