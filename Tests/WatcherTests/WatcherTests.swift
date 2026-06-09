import Foundation
import Testing
@testable import Watcher
@testable import Models

@Suite final class WatcherTests {
    let tmpDir: URL
    let fm = FileManager.default

    init() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WatcherTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
    }

    deinit {
        try? fm.removeItem(at: tmpDir)
    }

    @Test func emitsOnNewFile() async throws {
        let watcher = FolderWatcher(path: tmpDir)
        try await watcher.start()

        try await Task.sleep(for: .milliseconds(200))

        let file = tmpDir.appendingPathComponent("hello.png")
        try Data("hi".utf8).write(to: file)

        let received = try await firstURL(from: watcher.events, timeout: .seconds(5))
        #expect(received.lastPathComponent == "hello.png")

        await watcher.stop()
    }

    @Test func startThrowsOnMissingPath() async throws {
        let missing = tmpDir.appendingPathComponent("does-not-exist")
        let watcher = FolderWatcher(path: missing)
        var caught = false
        do {
            try await watcher.start()
        } catch let SmithError.watcherFailedToStart(reason) {
            caught = true
            #expect(reason.contains("does not exist") || reason.contains("not a directory"))
        }
        #expect(caught)
    }

    @Test func dedupsRapidDuplicateEmissions() async throws {
        let watcher = FolderWatcher(path: tmpDir)
        try await watcher.start()
        try await Task.sleep(for: .milliseconds(200))

        for i in 0..<5 {
            try Data(String(i).utf8).write(to: tmpDir.appendingPathComponent("f\(i).png"))
        }

        let urls = try await collectURLs(from: watcher.events, count: 5, timeout: .seconds(5))
        let names = Set(urls.map { $0.lastPathComponent })
        #expect(names == Set((0..<5).map { "f\($0).png" }))

        let pathCounts = Dictionary(grouping: urls, by: { $0.path }).mapValues { $0.count }
        for (_, count) in pathCounts {
            #expect(count <= 1)
        }

        await watcher.stop()
    }

    private func firstURL(from stream: AsyncStream<URL>, timeout: Duration) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                for await url in stream { return url }
                throw SmithError.watcherFailedToStart(reason: "stream finished")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SmithError.watcherFailedToStart(reason: "timeout")
            }
            let url = try await group.next()!
            group.cancelAll()
            return url
        }
    }

    private func collectURLs(from stream: AsyncStream<URL>, count: Int, timeout: Duration) async throws -> [URL] {
        try await withThrowingTaskGroup(of: [URL].self) { group in
            group.addTask {
                var collected: [URL] = []
                for await url in stream {
                    collected.append(url)
                    if collected.count >= count { return collected }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SmithError.watcherFailedToStart(reason: "timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
