import Foundation
import Observation
import NoterCore

struct EditorDraft: Equatable, Sendable {
    let path: String
    let title: String
    let body: String
}

@MainActor @Observable
final class EditorDraftSession {
    struct SaveFailure: Equatable {
        let draft: EditorDraft
        let message: String
    }

    private(set) var path: String?
    private(set) var title = ""
    private(set) var body = ""
    private(set) var failure: SaveFailure?
    private(set) var isSaving = false

    private var lastSavedDraft: EditorDraft?
    private var scheduledTask: Task<Void, Never>?
    private var latestRequestID: [String: UUID] = [:]
    private let debounce: Duration
    @ObservationIgnored
    private let save: @Sendable (EditorDraft) async throws -> Void

    var isDirty: Bool {
        guard let draft = currentDraft else { return false }
        return draft != lastSavedDraft
    }

    init(
        debounce: Duration = .milliseconds(500),
        save: @escaping @Sendable (EditorDraft) async throws -> Void
    ) {
        self.debounce = debounce
        self.save = save
    }

    @discardableResult
    func load(_ note: Note) -> Task<Void, Never>? {
        guard path != note.relativePath else { return nil }
        let flushTask = flush()
        replaceDraft(with: note)
        return flushTask
    }

    func reload(_ note: Note) {
        scheduledTask?.cancel()
        scheduledTask = nil
        replaceDraft(with: note)
        if failure?.draft.path == note.relativePath {
            failure = nil
        }
    }

    func updateTitle(_ title: String) {
        self.title = title
        scheduleSave()
    }

    func updateBody(_ body: String) {
        self.body = body
        scheduleSave()
    }

    @discardableResult
    func flush() -> Task<Void, Never>? {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard let draft = currentDraft, draft != lastSavedDraft else { return nil }
        return submit(draft)
    }

    @discardableResult
    func retryFailedSave() -> Task<Void, Never>? {
        guard let failure else { return nil }
        self.failure = nil
        let draft = path == failure.draft.path ? (currentDraft ?? failure.draft) : failure.draft
        return submit(draft)
    }

    private var currentDraft: EditorDraft? {
        guard let path else { return nil }
        return EditorDraft(path: path, title: title, body: body)
    }

    private func replaceDraft(with note: Note) {
        path = note.relativePath
        title = note.metadata.title
        body = note.body
        lastSavedDraft = EditorDraft(
            path: note.relativePath,
            title: note.metadata.title,
            body: note.body)
        isSaving = false
    }

    private func scheduleSave() {
        scheduledTask?.cancel()
        guard let draft = currentDraft, draft != lastSavedDraft else { return }
        let delay = debounce
        scheduledTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.scheduledTask = nil
            _ = self.submit(draft)
        }
    }

    private func submit(_ draft: EditorDraft) -> Task<Void, Never> {
        let requestID = UUID()
        latestRequestID[draft.path] = requestID
        if path == draft.path {
            isSaving = true
        }
        let save = save
        return Task { [weak self] in
            do {
                try await save(draft)
                self?.didSave(draft, requestID: requestID)
            } catch {
                self?.didFail(draft, requestID: requestID, error: error)
            }
        }
    }

    private func didSave(_ draft: EditorDraft, requestID: UUID) {
        guard latestRequestID[draft.path] == requestID else { return }
        if path == draft.path {
            lastSavedDraft = draft
            isSaving = false
        }
        if failure?.draft.path == draft.path {
            failure = nil
        }
    }

    private func didFail(_ draft: EditorDraft, requestID: UUID, error: Error) {
        guard latestRequestID[draft.path] == requestID else { return }
        if path == draft.path {
            isSaving = false
        }
        failure = SaveFailure(
            draft: draft,
            message: error.localizedDescription)
    }
}
