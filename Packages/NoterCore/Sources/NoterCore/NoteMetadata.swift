import Foundation

public enum NoteType: String, Codable, Sendable, CaseIterable {
    case note
    case meeting
}

public enum RecordingStatus: String, Codable, Sendable {
    case recording
}

public struct NoteMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var type: NoteType
    public var created: Date
    public var updated: Date
    public var tags: [String]
    public var audio: String?
    public var duration: String?
    public var status: RecordingStatus?

    public init(
        title: String,
        type: NoteType = .note,
        created: Date,
        updated: Date,
        tags: [String] = [],
        audio: String? = nil,
        duration: String? = nil,
        status: RecordingStatus? = nil
    ) {
        self.title = title
        self.type = type
        self.created = created
        self.updated = updated
        self.tags = tags
        self.audio = audio
        self.duration = duration
        self.status = status
    }
}

extension Date {
    /// Parses ISO 8601 with offset, e.g. "2026-07-11T09:30:00+02:00".
    public static func iso8601Local(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Serializes with the given zone's offset, second precision.
    public func iso8601LocalString(offset: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = offset
        return f.string(from: self)
    }
}
