import Foundation
import Testing
@testable import MyApp

struct UploadQueueStoreTests {

    /// Runs `body` with a store rooted in a unique temp directory, cleaning up after.
    private func withStore(_ body: (UploadQueueStore) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(UploadQueueStore(directory: dir))
    }

    private func makeJob(state: UploadJob.State = .waiting,
                         uploadId: String? = nil,
                         completedParts: [Int: String] = [:]) -> UploadJob {
        UploadJob(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
            sourceBookmark: Data([0x01, 0x02, 0x03]),
            clipKey: "acme/gala/clips/2026-09-19_183042_cam-a_e51f.mov",
            sidecar: ClipSidecar(displayName: "Clip", cameraLabel: "Cam A", notes: nil,
                                 capturedAt: Date(timeIntervalSince1970: 1_758_300_000),
                                 orderOverride: nil, duration: 12.5, width: 3840, height: 2160,
                                 codec: "hvc1", fileSize: 1_000_000,
                                 originalFilename: "clip.mov", sourceDevice: "test"),
            uploadId: uploadId,
            state: state,
            partSize: 8_388_608,
            totalSize: 1_000_000,
            completedParts: completedParts
        )
    }

    // 1. Nothing on disk yet -> empty queue, no throw.
    @Test func loadOnNonexistentDirectoryReturnsEmpty() throws {
        try withStore { store in
            #expect(store.load() == [])
        }
    }

    // 2. Full round-trip including associated values and part maps.
    @Test func saveThenLoadRoundTripsJobsExactly() throws {
        try withStore { store in
            let uploading = makeJob(state: .uploading(uploadId: "upload-abc-123"),
                                    uploadId: "upload-abc-123",
                                    completedParts: [1: "etag1", 2: "etag2"])
            // A failed job must still round-trip its uploadId so it can resume.
            let failed = makeJob(state: .failed(message: "network down"),
                                 uploadId: "upload-kept-456")
            try store.save([uploading, failed])
            #expect(store.load() == [uploading, failed])
        }
    }

    // 3. update() replaces by id and appends unknown ids.
    @Test func updateReplacesByIdAndAppendsUnknown() throws {
        try withStore { store in
            var first = makeJob()
            let second = makeJob()
            try store.save([first, second])

            first.state = .done
            try store.update(first)
            #expect(store.load() == [first, second])

            let newcomer = makeJob(state: .failed(message: "boom"))
            try store.update(newcomer)
            #expect(store.load() == [first, second, newcomer])
        }
    }

    // 4. Corruption must never crash or throw from load().
    @Test func corruptedFileLoadsAsEmpty() throws {
        try withStore { store in
            try store.save([makeJob()])
            let fileURL = store.directory.appending(path: "jobs.json")
            try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: fileURL)
            #expect(store.load() == [])
        }
    }
}
