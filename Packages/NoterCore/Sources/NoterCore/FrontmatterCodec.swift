import Foundation
import Yams

public enum FrontmatterError: Error, Equatable {
    case missingFrontmatter
    case malformedYAML(String)
}

/// Serializes/parses the note file format: `---\n<yaml>\n---\n\n<body>`.
/// Serialization is hand-rolled for stable key order (title first);
/// parsing uses Yams for real-YAML tolerance of external writers.
public enum FrontmatterCodec {

    public static func parse(_ raw: String) throws(FrontmatterError) -> (metadata: NoteMetadata, body: String) {
        // Fences are located in the original string — never pad `raw`, or the
        // padding leaks into the body and mutates user content on round-trip.
        guard raw.hasPrefix("---\n") else { throw .missingFrontmatter }
        let afterOpen = raw.index(raw.startIndex, offsetBy: 4)

        let yaml: String
        let body: String
        if let closeRange = raw.range(of: "\n---\n", range: afterOpen..<raw.endIndex) {
            yaml = String(raw[afterOpen..<closeRange.lowerBound])
            var rest = String(raw[closeRange.upperBound...])
            // Serializer emits exactly one blank line between fence and body; strip it on parse.
            if rest.hasPrefix("\n") { rest.removeFirst() }
            body = rest
        } else if raw.hasSuffix("\n---"),
                  let fenceNewline = raw.index(raw.endIndex, offsetBy: -4, limitedBy: afterOpen) {
            // Bare closing fence at EOF (no trailing newline): frontmatter only, empty body.
            // `limitedBy` rejects the degenerate "---\n---" where the suffix
            // would overlap the opening fence.
            yaml = String(raw[afterOpen..<fenceNewline])
            body = ""
        } else {
            throw .missingFrontmatter
        }

        let parsed: RawFrontmatter
        do {
            parsed = try YAMLDecoder().decode(RawFrontmatter.self, from: yaml)
        } catch {
            throw .malformedYAML(String(describing: error))
        }

        guard
            let created = Date.iso8601Local(parsed.created ?? ""),
            let updated = Date.iso8601Local(parsed.updated ?? "")
        else { throw .malformedYAML("created/updated missing or not ISO 8601") }

        let metadata = NoteMetadata(
            title: parsed.title ?? "",
            type: NoteType(rawValue: parsed.type ?? "note") ?? .note,
            created: created,
            updated: updated,
            tags: parsed.tags ?? [],
            audio: parsed.audio,
            duration: parsed.duration,
            status: parsed.status.flatMap(RecordingStatus.init(rawValue:))
        )
        return (metadata, body)
    }

    public static func serialize(metadata m: NoteMetadata, body: String, timeZone: TimeZone = .current) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yamlScalar(m.title))")
        lines.append("type: \(m.type.rawValue)")
        lines.append("created: \(m.created.iso8601LocalString(offset: timeZone))")
        lines.append("updated: \(m.updated.iso8601LocalString(offset: timeZone))")
        lines.append("tags: [\(m.tags.map(yamlScalar).joined(separator: ", "))]")
        if let audio = m.audio { lines.append("audio: \(yamlScalar(audio))") }
        if let duration = m.duration { lines.append("duration: \(yamlScalar(duration))") }
        if let status = m.status { lines.append("status: \(status.rawValue)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    /// Quotes a scalar only when YAML would misread it bare.
    private static func yamlScalar(_ s: String) -> String {
        let needsQuoting = s.isEmpty
            || s.lowercased() == "null" || s == "~" // bare YAML null tokens decode as nil
            || s.rangeOfCharacter(from: CharacterSet(charactersIn: ":#[]{}&*!|>'\"%@`,")) != nil
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.hasPrefix("-")
            || s.contains("\n") || s.contains("\r")
        guard needsQuoting else { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

/// Loose decoding surface: every key optional, unknown keys ignored,
/// so externally-authored frontmatter parses as long as the core keys exist.
private struct RawFrontmatter: Decodable {
    var title: String?
    var type: String?
    var created: String?
    var updated: String?
    var tags: [String]?
    var audio: String?
    var duration: String?
    var status: String?
}
