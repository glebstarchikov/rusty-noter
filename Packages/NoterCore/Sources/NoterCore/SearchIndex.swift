import Foundation
import GRDB

public actor SearchIndex {
    private let dbQueue: DatabaseQueue

    /// databasePath nil = in-memory (tests). The database is a disposable
    /// cache: schema is created on init if missing.
    public init(databasePath: String?) throws {
        if let path = databasePath {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try dbQueue.write { db in
            try db.create(virtualTable: "notes_fts", options: .ifNotExists, using: FTS5()) { t in
                t.column("path").notIndexed()
                t.column("title")
                t.column("tags")
                t.column("body")
                t.column("updated").notIndexed()
            }
        }
    }

    public func upsert(_ note: Note) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts WHERE path = ?",
                           arguments: [note.relativePath])
            try db.execute(
                sql: "INSERT INTO notes_fts (path, title, tags, body, updated) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    note.relativePath,
                    note.metadata.title,
                    note.metadata.tags.joined(separator: " "),
                    note.body,
                    note.metadata.updated.iso8601LocalString()
                ])
        }
    }

    public func remove(_ relativePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts WHERE path = ?", arguments: [relativePath])
        }
    }

    public func rebuild(from notes: [Note]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts")
        }
        for note in notes { try upsert(note) }
    }

    public func search(_ query: String, limit: Int = 50) throws -> [String] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT path FROM notes_fts
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts, 0, 10.0, 5.0, 1.0, 0)
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }
}
