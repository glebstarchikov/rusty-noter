import Foundation
import Testing
import NoterCore
@testable import RustyNoter

@Suite struct EditorDraftSessionTests {
    @Test @MainActor
    func switchingNotesImmediatelySavesTheDirtyDraft() async {
        let recorder = DraftRecorder()
        let session = EditorDraftSession(debounce: .seconds(60)) { draft in
            try await recorder.save(draft)
        }
        _ = session.load(note("a.md", title: "A", body: "original"))
        session.updateBody("edited immediately before switching")

        let flushTask = session.load(note("b.md", title: "B", body: "second"))
        await flushTask?.value

        #expect(await recorder.savedDrafts() == [
            EditorDraft(
                path: "a.md",
                title: "A",
                body: "edited immediately before switching")
        ])
        #expect(session.title == "B")
        #expect(session.body == "second")
    }

    @Test @MainActor
    func titleChangesSaveWithoutRequiringSubmit() async {
        let recorder = DraftRecorder()
        let session = EditorDraftSession(debounce: .milliseconds(1)) { draft in
            try await recorder.save(draft)
        }
        _ = session.load(note("a.md", title: "Original", body: "body"))
        session.updateTitle("Changed without pressing Return")

        try? await Task.sleep(for: .milliseconds(30))

        #expect(await recorder.savedDrafts() == [
            EditorDraft(
                path: "a.md",
                title: "Changed without pressing Return",
                body: "body")
        ])
        #expect(!session.isDirty)
    }

    /// The guarantee the app delegate relies on when it defers termination:
    /// awaiting the flush task means the edit has actually been written, even
    /// though the debounce had not fired yet. Without it, quitting inside the
    /// debounce window silently drops the last edit.
    @Test @MainActor
    func awaitingTheFlushTaskPersistsAnEditStillInsideTheDebounceWindow() async {
        let recorder = DraftRecorder()
        let session = EditorDraftSession(debounce: .seconds(60)) { draft in
            try await recorder.save(draft)
        }
        _ = session.load(note("a.md", title: "A", body: "original"))
        session.updateBody("typed a keystroke before quitting")

        #expect(await recorder.savedDrafts().isEmpty)   // debounce has not fired

        await session.flush()?.value

        #expect(await recorder.savedDrafts() == [
            EditorDraft(
                path: "a.md",
                title: "A",
                body: "typed a keystroke before quitting")
        ])
        #expect(!session.isDirty)
    }

    @Test @MainActor
    func failedSaveKeepsTheDraftAvailableForRetry() async {
        let recorder = DraftRecorder(failuresRemaining: 1)
        let session = EditorDraftSession(debounce: .seconds(60)) { draft in
            try await recorder.save(draft)
        }
        _ = session.load(note("a.md", title: "A", body: "original"))
        session.updateBody("must survive the failure")

        let firstAttempt = session.flush()
        await firstAttempt?.value

        #expect(session.failure?.draft == EditorDraft(
            path: "a.md",
            title: "A",
            body: "must survive the failure"))

        let retry = session.retryFailedSave()
        await retry?.value

        #expect(session.failure == nil)
        #expect(await recorder.savedDrafts() == [
            EditorDraft(
                path: "a.md",
                title: "A",
                body: "must survive the failure")
        ])
    }

    private func note(_ path: String, title: String, body: String) -> Note {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return Note(
            relativePath: path,
            metadata: NoteMetadata(
                title: title,
                created: timestamp,
                updated: timestamp),
            body: body)
    }
}

private enum DraftRecorderError: Error {
    case plannedFailure
}

private actor DraftRecorder {
    private var drafts: [EditorDraft] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func save(_ draft: EditorDraft) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw DraftRecorderError.plannedFailure
        }
        drafts.append(draft)
    }

    func savedDrafts() -> [EditorDraft] {
        drafts
    }
}
