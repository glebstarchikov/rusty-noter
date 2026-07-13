#!/usr/bin/env swift
import Foundation

// (name, lightHex, darkHex) from ~/design/tokens.css v2026-07-06
let tokens: [(String, String, String)] = [
    ("bg",           "fcfcfb", "131215"),
    ("elevated",     "ffffff", "1c1b1f"),
    ("fg",           "17161a", "ececea"),
    ("secondary",    "605f6a", "a7a6b0"),
    ("faint",        "6f6e79", "908f99"),
    ("border",       "e9e8e4", "2a292e"),
    ("borderStrong", "dcdbd6", "38373d"),
    ("accent",       "4b46f5", "8a86ff"),
    ("accentSoft",   "edecfe", "232244"),
    ("success",      "1a7a4d", "53b483"),
    ("warning",      "96660a", "d4a72c"),
    ("danger",       "c02f2f", "ef7066"),
]

func components(_ hex: String) -> (String, String, String) {
    let r = String(hex.prefix(2)), g = String(hex.dropFirst(2).prefix(2)), b = String(hex.suffix(2))
    return ("0x\(r.uppercased())", "0x\(g.uppercased())", "0x\(b.uppercased())")
}

func colorJSON(light: String, dark: String) -> String {
    let (lr, lg, lb) = components(light)
    let (dr, dg, db) = components(dark)
    return """
    {
      "colors" : [
        { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "\(lb)", "green" : "\(lg)", "red" : "\(lr)" } }, "idiom" : "universal" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "\(db)", "green" : "\(dg)", "red" : "\(dr)" } }, "idiom" : "universal" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
}

let root = URL(fileURLWithPath: "App/Resources/Assets.xcassets")
let fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true)
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#
    .write(to: root.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

for (name, light, dark) in tokens {
    let dir = root.appendingPathComponent("\(name).colorset")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try colorJSON(light: light, dark: dark)
        .write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
// AccentColor mirrors the accent token so system controls pick it up.
let accentDir = root.appendingPathComponent("AccentColor.colorset")
try fm.createDirectory(at: accentDir, withIntermediateDirectories: true)
try colorJSON(light: "4b46f5", dark: "8a86ff")
    .write(to: accentDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Generated \(tokens.count + 1) colorsets")
