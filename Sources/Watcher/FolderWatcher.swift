import Foundation
import CoreServices
import Models

/// Watches a single folder via FSEvents and emits a URL for every new/renamed-in file.
///
/// Architecturally an actor so that public lifecycle calls (`start`, `stop`) are serialized.
/// The actual FSEvents stream lives on an internal `@unchecked Sendable` bridge class because
/// the C callback cannot enter actor isolation directly — it has to call back through a
/// non-isolated boundary. The bridge funnels events into an `AsyncStream<URL>` which is
/// safe to consume from any task.
public actor FolderWatcher {
    public nonisolated let events: AsyncStream<URL>
    private let bridge: WatcherBridge

    public init(path: URL) {
        let (stream, continuation) = AsyncStream<URL>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.bridge = WatcherBridge(path: path, continuation: continuation)
    }

    /// Start the FSEvents stream. Throws `SmithError.watcherFailedToStart` if the OS refuses.
    public func start() throws {
        try bridge.start()
        AppLog.watcher.info("Watcher started on \(self.bridge.path.path, privacy: .public)")
    }

    /// Stop the stream and finish the AsyncStream. Safe to call multiple times.
    public func stop() {
        bridge.stop()
        AppLog.watcher.info("Watcher stopped")
    }

    deinit {
        bridge.stop()
    }
}

/// Internal: holds the FSEvents stream and pipes events into an `AsyncStream` continuation.
///
/// `@unchecked Sendable` because the FSEvents callback is a C function pointer; we guard
/// mutable state (`streamRef`, `recentlyEmitted`) with `NSLock` and only touch the
/// continuation (already `Sendable`) from the callback.
fileprivate final class WatcherBridge: @unchecked Sendable {
    let path: URL
    private let continuation: AsyncStream<URL>.Continuation
    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    /// Path → last-emitted timestamp, for short-window dedup. FSEvents can coalesce or
    /// re-fire on near-simultaneous file ops; we squash repeats inside a 500ms window.
    private var recentlyEmitted: [String: Date] = [:]
    private let dedupWindow: TimeInterval = 0.5

    init(path: URL, continuation: AsyncStream<URL>.Continuation) {
        self.path = path
        self.continuation = continuation
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard streamRef == nil else { return }

        // Verify the watched directory exists. Per Prime Directive 6, fail safe — if the path
        // isn't there, refuse to start rather than silently watching nothing.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else {
            throw SmithError.watcherFailedToStart(reason: "Path does not exist or is not a directory: \(path.path)")
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, info, count, pathsRaw, flagsRaw, _) in
            guard let info = info else { return }
            let bridge = Unmanaged<WatcherBridge>.fromOpaque(info).takeUnretainedValue()

            // With kFSEventStreamCreateFlagUseCFTypes the paths come in as a CFArray of CFString.
            let pathsArray = unsafeBitCast(pathsRaw, to: CFArray.self) as? [String] ?? []
            let flagsBuf = UnsafeBufferPointer(start: flagsRaw, count: count)

            var urls: [URL] = []
            for i in 0..<count {
                guard i < pathsArray.count else { continue }
                let path = pathsArray[i]
                let flags = flagsBuf[i]

                let isFile  = (flags & UInt32(kFSEventStreamEventFlagItemIsFile))  != 0
                let created = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let renamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                let modified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0

                // We care about files that newly appeared. Some screenshot flows arrive as
                // "renamed" (atomic move from a tmp name) so we include that too.
                guard isFile && (created || renamed || modified) else { continue }

                // The file may have already been moved away — only emit if it's there now.
                guard FileManager.default.fileExists(atPath: path) else { continue }

                urls.append(URL(fileURLWithPath: path))
            }

            if !urls.isEmpty {
                bridge.emit(urls)
            }
        }

        let pathsCF = [path.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsCF,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // latency seconds — coalesce bursts but stay responsive
            flags
        ) else {
            throw SmithError.watcherFailedToStart(reason: "FSEventStreamCreate returned null")
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        streamRef = stream
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let s = streamRef {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            streamRef = nil
            continuation.finish()
        }
    }

    /// Called from the FSEvents callback. Dedups inside a short window, then yields.
    fileprivate func emit(_ urls: [URL]) {
        lock.lock()
        let now = Date()
        // GC anything older than the dedup window so the dictionary doesn't grow without bound.
        recentlyEmitted = recentlyEmitted.filter { now.timeIntervalSince($0.value) < dedupWindow }

        var fresh: [URL] = []
        for url in urls {
            if let last = recentlyEmitted[url.path], now.timeIntervalSince(last) < dedupWindow {
                continue
            }
            recentlyEmitted[url.path] = now
            fresh.append(url)
        }
        lock.unlock()

        for url in fresh {
            AppLog.watcher.debug("emit \(url.lastPathComponent, privacy: .public)")
            continuation.yield(url)
        }
    }

    deinit {
        stop()
    }
}
