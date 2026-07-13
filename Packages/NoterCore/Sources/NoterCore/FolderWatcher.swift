import Foundation
import CoreServices

/// FSEvents wrapper: emits debounced batches of changed absolute paths.
/// @unchecked Sendable: all mutable state is confined to `queue`.
public final class FolderWatcher: @unchecked Sendable {
    public let events: AsyncStream<Set<String>>

    private let root: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "nl.glebstarchikov.rustynoter.watcher")
    private let continuation: AsyncStream<Set<String>>.Continuation
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var flushWork: DispatchWorkItem?

    public init(root: URL, debounce: TimeInterval = 0.3) {
        self.root = root
        self.debounce = debounce
        var cont: AsyncStream<Set<String>>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                // kFSEventStreamCreateFlagUseCFTypes makes `paths` a CFArray of CFString.
                let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
                guard let pathArray = cfPaths as? [String] else { return }
                watcher.enqueue(Array(pathArray.prefix(count)))
            }
            guard let s = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer)
            ) else { return }
            stream = s
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
        }
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            flushWork?.cancel()
            flushWork = nil
        }
    }

    deinit {
        stop()
        continuation.finish()
    }

    /// Called on `queue` (FSEvents dispatch queue is `queue`).
    private func enqueue(_ paths: [String]) {
        pending.formUnion(paths)
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending.removeAll()
            guard !batch.isEmpty else { return }
            self.continuation.yield(batch)
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
