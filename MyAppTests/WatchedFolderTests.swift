import Foundation
import Testing
@testable import AssetsTransporter

#if os(macOS)

/// Mutable clock the tests advance by hand (injected into `WatchedFolder.now`).
@MainActor
private final class TestClock {
    var current = Date(timeIntervalSince1970: 1_726_000_000)
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// Collects the URLs and identities the `newVideo` callback fires with.
@MainActor
private final class FireRecorder {
    var urls: [URL] = []
    var identities: [FileIdentity] = []
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
                            stableInterval: TimeInterval = 2.0,
                            initiallyProcessed: Set<FileIdentity> = []) -> WatchedFolder {
        let folder = WatchedFolder(url: dir, stableInterval: stableInterval,
                                   initiallyProcessed: initiallyProcessed) { url, identity in
            recorder.urls.append(url)
            recorder.identities.append(identity)
        }
        folder.now = { clock.current }
        return folder
    }

    /// The on-disk identity of `file`, exactly as `WatchedFolder` computes it.
    private func identity(of file: URL) throws -> FileIdentity {
        let values = try file.resourceValues(forKeys: [.fileSizeKey,
                                                       .contentModificationDateKey])
        return FileIdentity(name: file.lastPathComponent,
                            size: Int64(values.fileSize ?? 0),
                            modifiedAt: values.contentModificationDate ?? .distantPast)
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

    @Test func firedCallbackReportsOnDiskIdentity() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder)

        let file = dir.appending(path: "clip.mov")
        try Data(repeating: 7, count: 128).write(to: file)
        await folder.scanNow()
        clock.advance(2.5)
        await folder.scanNow()

        #expect(recorder.identities == [try identity(of: file)])
    }

    @Test func seededProcessedIdentityNeverFires() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let recorder = FireRecorder()

        // The file was processed in a "previous launch": its identity is seeded.
        let file = dir.appending(path: "cam-a-clip.mov")
        try Data(repeating: 7, count: 128).write(to: file)
        let folder = makeFolder(dir: dir, clock: clock, recorder: recorder,
                                initiallyProcessed: [try identity(of: file)])

        await folder.scanNow()
        clock.advance(2.5)
        await folder.scanNow()
        clock.advance(2.5)
        await folder.scanNow()
        #expect(recorder.urls.isEmpty)
    }

    @Test func seededNameWithDifferentSizeOrMtimeStillFires() async throws {
        let clock = TestClock()
        let recorder = FireRecorder()

        // Same name, different size: must fire (the file changed while the
        // app was closed).
        let sizeDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sizeDir) }
        let sizeFile = sizeDir.appending(path: "clip.mov")
        try Data(repeating: 7, count: 128).write(to: sizeFile)
        var staleSize = try identity(of: sizeFile)
        staleSize.size += 1
        let sizeFolder = makeFolder(dir: sizeDir, clock: clock, recorder: recorder,
                                    initiallyProcessed: [staleSize])
        await sizeFolder.scanNow()
        clock.advance(2.5)
        await sizeFolder.scanNow()
        #expect(recorder.urls.map(\.lastPathComponent) == ["clip.mov"])

        // Same name and size, different modification time: must also fire.
        let mtimeDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: mtimeDir) }
        let mtimeFile = mtimeDir.appending(path: "take.mp4")
        try Data(repeating: 1, count: 64).write(to: mtimeFile)
        let current = try identity(of: mtimeFile)
        let staleMtime = FileIdentity(name: current.name, size: current.size,
                                      modifiedAt: Date(timeIntervalSince1970: 1))
        let mtimeFolder = makeFolder(dir: mtimeDir, clock: clock, recorder: recorder,
                                     initiallyProcessed: [staleMtime])
        await mtimeFolder.scanNow()
        clock.advance(2.5)
        await mtimeFolder.scanNow()
        #expect(recorder.urls.map(\.lastPathComponent) == ["clip.mov", "take.mp4"])
    }
}

#endif
