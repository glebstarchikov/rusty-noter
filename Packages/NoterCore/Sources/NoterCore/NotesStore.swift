import Foundation

public enum NotesStoreError: Error, Equatable {
    case refusingToRewriteUnparseable
    case noteNotFound(String)
}

public actor NotesStore {
    public let vault: Vault
    private var cache: [String: Note] = [:]
    public private(set) var unparseablePaths: Set<String> = []
    /// Echo journal: relativePath -> time of our last write, so the folder
    /// watcher can distinguish self-writes from external edits.
    private var selfWrites: [String: Date] = [:]

    public init(vault: Vault) {
        self.vault = vault
    }

    @discardableResult
    public func loadAll() -> [Note] {
        cache.removeAll()
        unparseablePaths.removeAll()
        let paths = (try? vault.enumerateNoteFiles()) ?? []
        for rel in paths {
            if let note = readNote(rel) { cache[rel] = note }
        }
        return Array(cache.values)
    }

    public func note(at relativePath: String) -> Note? { cache[relativePath] }

    public func allNotes() -> [Note] { Array(cache.values) }

    public func create(title: String, now: Date = .now) throws -> Note {
        let existing = Set((try? vault.enumerateNoteFiles()) ?? []).union(cache.keys)
        let filename = Slug.uniqueFilename(date: now, title: title, existing: existing)
        let metadata = NoteMetadata(title: title, created: now, updated: now)
        let note = Note(relativePath: filename, metadata: metadata, body: "")
        try write(note)
        return note
    }

    public func updateBody(_ relativePath: String, body: String, now: Date = .now) throws -> Note {
        guard !unparseablePaths.contains(relativePath) else {
            throw NotesStoreError.refusingToRewriteUnparseable
        }
        guard var note = cache[relativePath] else {
            throw NotesStoreError.noteNotFound(relativePath)
        }
        note.body = body
        note.metadata.updated = now
        try write(note)
        return note
    }

    public func reloadFromDisk(_ relativePath: String) throws -> Note? {
        guard FileManager.default.fileExists(atPath: vault.noteURL(relativePath).path) else {
            cache[relativePath] = nil
            unparseablePaths.remove(relativePath)
            return nil
        }
        let note = readNote(relativePath)
        cache[relativePath] = note
        return note
    }

    public func remove(_ relativePath: String) {
        cache[relativePath] = nil
        unparseablePaths.remove(relativePath)
    }

    public func wasSelfWrite(path: String, within: TimeInterval) -> Bool {
        guard let t = selfWrites[path] else { return false }
        return Date.now.timeIntervalSince(t) <= within
    }

    // MARK: - Private

    private func readNote(_ relativePath: String) -> Note? {
        let url = vault.noteURL(relativePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if let parsed = try? FrontmatterCodec.parse(raw) {
            unparseablePaths.remove(relativePath)
            return Note(relativePath: relativePath, metadata: parsed.metadata, body: parsed.body)
        }
        // Salvage: never rewrite, still list (spec section 11).
        unparseablePaths.insert(relativePath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .now
        let stem = (relativePath as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
        let meta = NoteMetadata(title: stem, created: mtime, updated: mtime)
        return Note(relativePath: relativePath, metadata: meta, body: raw)
    }

    private func write(_ note: Note) throws {
        let url = vault.noteURL(note.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = FrontmatterCodec.serialize(metadata: note.metadata, body: note.body)
        try raw.write(to: url, atomically: true, encoding: .utf8)
        selfWrites[note.relativePath] = .now
        cache[note.relativePath] = note
    }
}
