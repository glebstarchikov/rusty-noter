import Foundation

public struct Note: Identifiable, Equatable, Sendable {
    public var relativePath: String
    public var metadata: NoteMetadata
    public var body: String

    public var id: String { relativePath }

    public init(relativePath: String, metadata: NoteMetadata, body: String) {
        self.relativePath = relativePath
        self.metadata = metadata
        self.body = body
    }

    /// First non-empty body line with markdown glyphs stripped, capped at 80 chars.
    public var snippet: String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var s = String(line)
            s = s.replacingOccurrences(of: #"^[#>\-\*\s]+"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            s = s.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            s = s.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return String(s.prefix(80)) }
        }
        return ""
    }
}
