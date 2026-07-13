import AppKit

/// Fonts and colors per span kind. Colors resolve from the app's asset
/// catalog (main bundle) with system fallbacks so the package never crashes
/// standalone. Editor is a Reading surface: 16px body (design.md).
///
/// `@unchecked Sendable`: NSFont does not conform to Sendable in this SDK
/// (unlike NSColor), but it is an immutable, thread-safe-to-read value type,
/// and every instance here is built once by the @MainActor `standard()`
/// factory before being handed to SwiftUI/AppKit call sites.
public struct EditorTheme: @unchecked Sendable {
    public let bodyFont: NSFont
    public let boldFont: NSFont
    public let italicFont: NSFont
    public let monoFont: NSFont
    public let headingFonts: [Int: NSFont]
    public let fg: NSColor
    public let secondary: NSColor
    public let faint: NSColor
    public let accent: NSColor
    public let bg: NSColor

    @MainActor
    public static func standard() -> EditorTheme {
        func named(_ name: String, fallback: NSColor) -> NSColor {
            NSColor(named: name) ?? fallback
        }
        let body = NSFont.systemFont(ofSize: 16)
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        return EditorTheme(
            bodyFont: body,
            boldFont: NSFont.systemFont(ofSize: 16, weight: .semibold),
            italicFont: italic,
            monoFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            headingFonts: [
                1: NSFont.systemFont(ofSize: 24, weight: .semibold),
                2: NSFont.systemFont(ofSize: 20, weight: .semibold),
                3: NSFont.systemFont(ofSize: 18, weight: .semibold)
            ],
            fg: named("fg", fallback: .labelColor),
            secondary: named("secondary", fallback: .secondaryLabelColor),
            faint: named("faint", fallback: .tertiaryLabelColor),
            accent: named("accent", fallback: .controlAccentColor),
            bg: named("bg", fallback: .textBackgroundColor)
        )
    }

    func font(for level: Int) -> NSFont {
        headingFonts[min(level, 3)] ?? bodyFont
    }
}
