#!/usr/bin/env swift
import Foundation

let args = CommandLine.arguments
let target = args.count > 1 ? args[1] : "/tmp/noter-fixture-vault"
let count = args.count > 2 ? (Int(args[2]) ?? 1000) : 1000

let words = ["pricing", "roadmap", "standup", "design", "api", "launch",
             "budget", "hiring", "retro", "ideas", "review", "metrics"]
let tags = ["work", "product", "personal", "urgent", "later"]

let fm = FileManager.default
try fm.createDirectory(atPath: target + "/meetings", withIntermediateDirectories: true)

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]
formatter.timeZone = TimeZone(secondsFromGMT: 7200)
let base = formatter.date(from: "2026-07-13T12:00:00+02:00")!

var generated = 0
for i in 0..<count {
    let isMeeting = i % 10 == 0
    let w1 = words[i % words.count]
    let w2 = words[(i * 5 + 3) % words.count]
    let title = "\(w1.capitalized) \(w2) \(i)"
    let date = base.addingTimeInterval(TimeInterval(-i * 3600))
    let stamp = formatter.string(from: date)
    let day = String(stamp.prefix(10))
    let tag = tags[i % tags.count]
    let body = """
    Discussion about \(w1) and \(w2). Item \(i) covers the \(w1) plan, \
    open questions on \(w2), and next steps.

    - follow up on \(w1)
    - draft the \(w2) doc
    """
    let content = """
    ---
    title: \(title)
    type: \(isMeeting ? "meeting" : "note")
    created: \(stamp)
    updated: \(stamp)
    tags: [\(tag)]
    ---

    \(body)
    """
    let dir = isMeeting ? "\(target)/meetings" : target
    let path = "\(dir)/\(day)-\(w1)-\(w2)-\(i).md"
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    generated += 1
}
print("Generated \(generated) notes in \(target)")
