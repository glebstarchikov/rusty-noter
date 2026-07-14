import Foundation

public enum NotesStoreError: Error, Equatable {
    case refusingToRewriteUnparseable
    case noteNotFound(String)
}

public actor NotesStore {
    public let vault: Vault
    private var cache: [String: Note] = [:]
    public private(set) var unparseablePaths: Set<String> = []
    /// Echo journal: relativePath -> the exact raw string of our last write, so
    /// the folder watcher can distinguish self-write echoes (on-disk bytes still
    /// equal what we wrote) from real external edits (bytes differ). Content-based
    /// per spec 5: a same-path external edit arriving inside any time window is
    /// still processed, because its bytes no longer match what we wrote.
    private var selfWriteContent: [String: String] = [:]

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

    public func updateTitle(_ relativePath: String, title: String, now: Date = .now) throws -> Note {
        guard !unparseablePaths.contains(relativePath) else {
            throw NotesStoreError.refusingToRewriteUnparseable
        }
        guard var note = cache[relativePath] else {
            throw NotesStoreError.noteNotFound(relativePath)
        }
        note.metadata.title = title
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
        guard let note = readNote(relativePath) else {
            // Exists but unreadable (e.g. permissions): evict like a vanished file
            // so a later updateBody reports noteNotFound, not a stale
            // refusingToRewriteUnparseable.
            cache[relativePath] = nil
            unparseablePaths.remove(relativePath)
            return nil
        }
        cache[relativePath] = note
        return note
    }

    public func remove(_ relativePath: String) {
        cache[relativePath] = nil
        unparseablePaths.remove(relativePath)
        selfWriteContent[relativePath] = nil
    }

    /// True iff `path`'s current on-disk bytes exactly equal what we last wrote
    /// there: our own write's FSEvents echo. False when there is no record or the
    /// bytes differ (a real external edit) — biasing toward processing, never
    /// dropping a genuine change. A confirmed echo evicts the record to bound
    /// memory; a rare second, non-coalesced echo then reloads identical bytes as
    /// a harmless no-op.
    public func isSelfWriteEcho(_ path: String) -> Bool {
        guard let recorded = selfWriteContent[path] else { return false }
        guard let data = try? Data(contentsOf: vault.noteURL(path)),
              data == Data(recorded.utf8) else { return false }
        selfWriteContent[path] = nil
        return true
    }

    // MARK: - Private

    private func readNote(_ relativePath: String) -> Note? {
        let url = vault.noteURL(relativePath)
        // Raw bytes first, decoded lossily: nil means ONLY "unreadable/gone".
        // Non-UTF-8 files are salvaged below (listed, never rewritten thanks to
        // the refusingToRewriteUnparseable guard) instead of silently hidden.
        guard let data = try? Data(contentsOf: url) else { return nil }
        let raw = String(decoding: data, as: UTF8.self)
        if let parsed = try? FrontmatterCodec.parse(raw) {
            unparseablePaths.remove(relativePath)
            return Note(relativePath: relativePath, metadata: parsed.metadata, body: parsed.body)
        }
        // Salvage: never rewrite, still list (spec section 11).
        unparseablePaths.insert(relativePath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .now
        let stem = ((relativePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let meta = NoteMetadata(title: stem, created: mtime, updated: mtime)
        return Note(relativePath: relativePath, metadata: meta, body: raw)
    }

    private func write(_ note: Note) throws {
        let url = vault.noteURL(note.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = FrontmatterCodec.serialize(metadata: note.metadata, body: note.body)
        try raw.write(to: url, atomically: true, encoding: .utf8)
        selfWriteContent[note.relativePath] = raw
        cache[note.relativePath] = note
    }
}
