import Foundation

public actor VaultCoordinator {
    public let vault: Vault
    public nonisolated let updates: AsyncStream<[Note]>

    private let store: NotesStore
    private let index: SearchIndex
    private let watcher: FolderWatcher
    private let indexMdDelay: TimeInterval
    private let updatesContinuation: AsyncStream<[Note]>.Continuation
    private var processingTask: Task<Void, Never>?
    private var indexMdTask: Task<Void, Never>?
    /// Monotonic publish counter: a publishSnapshot suspended at `allNotes()`
    /// that resumes after a newer publish has started drops its now-stale yield,
    /// so `.bufferingNewest(1)` never holds an out-of-order snapshot.
    private var publishSeq = 0

    public init(vault: Vault, indexDatabasePath: String?,
                watcherDebounce: TimeInterval = 0.3,
                indexMdDelay: TimeInterval = 2.0) throws {
        self.vault = vault
        self.store = NotesStore(vault: vault)
        self.index = try SearchIndex(databasePath: indexDatabasePath)
        self.watcher = FolderWatcher(root: vault.root, debounce: watcherDebounce)
        self.indexMdDelay = indexMdDelay
        var cont: AsyncStream<[Note]>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.updatesContinuation = cont
    }

    @discardableResult
    public func start() async -> [Note] {
        let notes = await store.loadAll()
        try? await index.rebuild(from: notes)
        try? IndexWriter.write(notes: notes, to: vault)
        try? AgentDocsWriter.writeIfMissingOrStale(to: vault)
        watcher.start()
        let stream = watcher.events
        processingTask = Task { [weak self] in
            for await batch in stream {
                await self?.process(batch: batch)
            }
        }
        return notes.sorted { $0.metadata.updated > $1.metadata.updated }
    }

    public func stop() {
        watcher.stop()
        processingTask?.cancel()
        indexMdTask?.cancel()
        updatesContinuation.finish()
    }

    // MARK: - App-originated mutations (index inline, echo dropped later)

    public func createNote(title: String) async throws -> Note {
        let note = try await store.create(title: title)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func updateBody(_ relativePath: String, body: String) async throws -> Note {
        let note = try await store.updateBody(relativePath, body: body)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func updateTitle(_ relativePath: String, title: String) async throws -> Note {
        let note = try await store.updateTitle(relativePath, title: title)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func startMeeting(title: String) async throws -> Note {
        let note = try await store.startMeeting(title: title)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func finishMeeting(
        _ relativePath: String,
        audio: String,
        duration: String
    ) async throws -> Note {
        let note = try await store.finishMeeting(
            relativePath, audio: audio, duration: duration)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func updateDraft(
        _ relativePath: String,
        title: String,
        body: String
    ) async throws -> Note {
        let note = try await store.updateDraft(relativePath, title: title, body: body)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    /// Moves the note to Trash (via the store), drops it from the index, and
    /// republishes the list.
    public func deleteNote(_ relativePath: String) async throws {
        try await store.delete(relativePath)
        try? await index.remove(relativePath)
        scheduleIndexMd()
        await publishSnapshot()
    }

    @discardableResult
    public func setPinned(_ relativePath: String, pinned: Bool) async throws -> Note {
        let note = try await store.setPinned(relativePath, pinned: pinned)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func search(_ query: String) async -> [String] {
        (try? await index.search(query)) ?? []
    }

    public func note(at relativePath: String) async -> Note? {
        await store.note(at: relativePath)
    }

    // MARK: - External change pipeline

    private func process(batch: Set<String>) async {
        var touchedNotes = false
        for absolutePath in batch {
            let url = URL(fileURLWithPath: absolutePath)
            guard let rel = vault.relativePath(of: url), vault.isNotePath(rel) else { continue }
            guard await !store.isSelfWriteEcho(rel) else { continue }
            touchedNotes = true
            if let note = try? await store.reloadFromDisk(rel) {
                try? await index.upsert(note)
            } else {
                await store.remove(rel)
                try? await index.remove(rel)
            }
        }
        guard touchedNotes else { return }
        scheduleIndexMd()
        await publishSnapshot()
    }

    private func publishSnapshot() async {
        publishSeq += 1
        let mySeq = publishSeq
        let all = await store.allNotes().sorted { $0.metadata.updated > $1.metadata.updated }
        guard mySeq == publishSeq else { return }   // superseded by a newer publish
        updatesContinuation.yield(all)
    }

    private func scheduleIndexMd() {
        indexMdTask?.cancel()
        let delay = indexMdDelay
        indexMdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let notes = await self.storeNotes()
            try? IndexWriter.write(notes: notes, to: self.vault)
        }
    }

    private func storeNotes() async -> [Note] {
        await store.allNotes()
    }
}
