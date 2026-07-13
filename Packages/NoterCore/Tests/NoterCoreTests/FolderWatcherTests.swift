import Testing
import Foundation
@testable import NoterCore

@Suite struct FolderWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func detectsExternalCreateModifyDelete() async throws {
        let vault = try makeTempVault()
        let watcher = FolderWatcher(root: vault.root)
        watcher.start()
        defer { watcher.stop() }
        var iterator = watcher.events.makeAsyncIterator()

        // FSEvents streams need a beat to arm; give it one.
        try await Task.sleep(for: .milliseconds(500))

        // CREATE. Diagnosed leading-batch flake (see file-level doc comment on
        // `nextBatch`): collect until the path appears, keeping this strict in
        // the sense that only CREATE's own resulting events can satisfy it —
        // MODIFY/DELETE haven't happened yet at this point in the test.
        let url = try writeFile(vault, "watched.md", sampleRaw(title: "W"))
        let createBatch = await nextBatch(containing: "watched.md", from: &iterator)
        #expect(createBatch?.contains { $0.hasSuffix("watched.md") } == true)

        // MODIFY
        try "changed".write(to: url, atomically: true, encoding: .utf8)
        let modifyBatch = await iterator.next()
        #expect(modifyBatch?.contains { $0.hasSuffix("watched.md") } == true)

        // DELETE. The modify batch was already flushed and consumed above, so
        // the delete event necessarily lands in a FRESH batch (coalescing can
        // only merge into a batch not yet delivered); fetch it with the same
        // collect-until-match loop as CREATE.
        try FileManager.default.removeItem(at: url)
        let deleteBatch = await nextBatch(containing: "watched.md", from: &iterator)
        #expect(deleteBatch?.contains { $0.hasSuffix("watched.md") } == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func batchesRapidChangesIntoFewEvents() async throws {
        let vault = try makeTempVault()
        let watcher = FolderWatcher(root: vault.root, debounce: 0.4)
        watcher.start()
        defer { watcher.stop() }
        var iterator = watcher.events.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(500))

        for i in 0..<20 {
            try writeFile(vault, "n\(i).md", sampleRaw(title: "N\(i)"))
        }
        let batch = await nextBatch(containing: ".md", from: &iterator)
        // All 20 fall inside one debounce window (writes take microseconds).
        #expect((batch?.count ?? 0) >= 15)
    }
}

/// FSEvents can emit a leading batch unrelated to the operation under test:
/// `kFSEventStreamEventIdSinceNow`'s cutoff can still include the tail of a
/// transaction that's technically concurrent with "now", so the vault root's
/// own just-happened `mkdir` (from `makeTempVault()`, milliseconds before
/// `watcher.start()`) leaks through as a one-off batch containing only the
/// root path. Confirmed via a diagnostic harness (not committed): inserting a
/// multi-second gap between `mkdir` and `start()` makes it disappear, and
/// re-running with the gap removed reproduces it 100% of the time in this
/// environment. It is a real FSEvents characteristic, not a `FolderWatcher`
/// bug — the watcher is a deliberately unmodified pass-through of whatever
/// FSEvents reports (see task context), so filtering belongs in the test, not
/// the implementation.
///
/// This mirrors the task brief's own prescribed DELETE-batch flake guidance
/// (collect batches in a loop until the path appears or 5 seconds elapse),
/// generalized to the leading-batch case: keep discarding batches that don't
/// contain `suffix` until one does, or the deadline passes.
private func nextBatch(
    containing suffix: String,
    from iterator: inout AsyncStream<Set<String>>.AsyncIterator,
    within seconds: TimeInterval = 5
) async -> Set<String>? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let batch = await iterator.next() else { return nil }
        if batch.contains(where: { $0.hasSuffix(suffix) }) { return batch }
    }
    return nil
}
