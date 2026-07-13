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

    public func upsert(_ note: Note) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts WHERE path = ?",
                           arguments: [note.relativePath])
            try Self.insert(note, into: db)
        }
    }

    public func remove(_ relativePath: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts WHERE path = ?", arguments: [relativePath])
        }
    }

    /// One write closure = one transaction (GRDB commits iff no error), so
    /// the DELETE and all INSERTs land atomically: a crash mid-rebuild can
    /// never leave a valid-looking index missing a subset of notes.
    public func rebuild(from notes: [Note]) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts")
            // The table is empty inside this transaction, so plain INSERTs
            // suffice (a per-note DELETE would be dead code here).
            for note in notes {
                try Self.insert(note, into: db)
            }
        }
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [String] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT path FROM notes_fts
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts, 0, 10.0, 5.0, 1.0, 0)
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    /// Shared by `upsert` and `rebuild`; static so the `@Sendable` database
    /// closures can call it without touching actor state.
    private static func insert(_ note: Note, into db: Database) throws {
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
