import Foundation
import Testing
@testable import MyApp

#if os(macOS)

/// Mutable clock the tests advance by hand (injected into `WatchedFolder.now`).
@MainActor
private final class TestClock {
    var current = Date(timeIntervalSince1970: 1_726_000_000)
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// Collects the URLs the `newVideo` callback fires with.
@MainActor
private final class FireRecorder {
    var urls: [URL] = []
}

@MainActor
struct WatchedFolderTests {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "watched-folder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFolder(dir: URL, clock: TestClock, recorder: FireRecorder,
                            stableInterval: TimeInterval = 2.0) -> WatchedFolder {
        let folder = WatchedFolder(url: dir, stableInterval: stableInterval) { url in
            recorder.urls.append(url)
        }
        folder.now = { clock.current }
        return folder
    }

    // MARK: - Tests

    @Test func firesOnceAfterSizeStableForInterval() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder)

        try Data(repeating: 7, count: 128).write(to: dir.appending(path: "clip.mov"))

        await folder.scanNow()                 // pass 1: records the size, must not fire
        #expect(recorder.urls.isEmpty)

        clock.advance(2.5)
        await folder.scanNow()                 // pass 2: size unchanged across interval
        #expect(recorder.urls.map(\.lastPathComponent) == ["clip.mov"])
    }

    @Test func growingFileWaitsUntilStable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder)

        let file = dir.appending(path: "recording.mp4")
        try Data(repeating: 1, count: 100).write(to: file)
        await folder.scanNow()                 // records size 100

        clock.advance(2.5)
        try Data(repeating: 1, count: 500).write(to: file)   // still being written
        await folder.scanNow()                 // size moved: restart the stability clock
        #expect(recorder.urls.isEmpty)

        clock.advance(2.5)
        await folder.scanNow()                 // stable at 500 across the interval
        #expect(recorder.urls.map(\.lastPathComponent) == ["recording.mp4"])
    }

    @Test func ignoresNonVideoExtensionsAndMatchesCaseInsensitively() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder)

        try Data(repeating: 2, count: 10).write(to: dir.appending(path: "notes.txt"))
        try Data(repeating: 3, count: 10).write(to: dir.appending(path: "UPPER.MOV"))

        await folder.scanNow()
        clock.advance(2.5)
        await folder.scanNow()

        #expect(recorder.urls.map(\.lastPathComponent) == ["UPPER.MOV"])
    }

    @Test func processedFileDoesNotRefire() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder)

        try Data(repeating: 9, count: 64).write(to: dir.appending(path: "done.m4v"))
        await folder.scanNow()
        clock.advance(2.5)
        await folder.scanNow()
        #expect(recorder.urls.count == 1)

        clock.advance(2.5)
        await folder.scanNow()
        clock.advance(2.5)
        await folder.scanNow()
        #expect(recorder.urls.count == 1)      // never re-fires for the same path
    }

    @Test func stopPreventsFurtherFires() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder)

        try folder.start()
        try Data(repeating: 4, count: 32).write(to: dir.appending(path: "late.mov"))
        await folder.scanNow()                 // records the candidate
        folder.stop()

        clock.advance(2.5)
        await folder.scanNow()                 // no-op after stop
        #expect(recorder.urls.isEmpty)
    }
}

#endif
