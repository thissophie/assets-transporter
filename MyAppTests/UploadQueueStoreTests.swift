import Foundation
import Testing
@testable import MyApp

struct UploadQueueStoreTests {

    /// Runs `body` with a store rooted in a unique temp directory, cleaning up after.
    private func withStore(_ body: (UploadQueueStore) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(UploadQueueStore(directory: dir))
    }

    private func makeJob(state: UploadJob.State = .waiting,
                         uploadId: String? = nil,
                         multipartCompleted: Bool = false,
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
            multipartCompleted: multipartCompleted,
            state: state,
            partSize: 8_388_608,
            totalSize: 1_000_000,
            completedParts: completedParts
        )
    }

    // 1. Nothing on disk yet -> empty queue, no throw.
    @Test func loadOnNonexistentDirectoryReturnsEmpty() async throws {
        try await withStore { store in
            #expect(await store.load() == [])
        }
    }

    // 2. Full round-trip including associated values and part maps.
    @Test func saveThenLoadRoundTripsJobsExactly() async throws {
        try await withStore { store in
            let uploading = makeJob(state: .uploading(uploadId: "upload-abc-123"),
                                    uploadId: "upload-abc-123",
                                    completedParts: [1: "etag1", 2: "etag2"])
            // A failed job must still round-trip its uploadId and completion
            // flag so it can resume.
            let failed = makeJob(state: .failed(message: "network down"),
                                 uploadId: "upload-kept-456",
                                 multipartCompleted: true)
            try await store.save([uploading, failed])
            #expect(await store.load() == [uploading, failed])
        }
    }

    // 3. update() replaces by id and appends unknown ids.
    @Test func updateReplacesByIdAndAppendsUnknown() async throws {
        try await withStore { store in
            var first = makeJob()
            let second = makeJob()
            try await store.save([first, second])

            first.state = .done
            try await store.update(first)
            #expect(await store.load() == [first, second])

            let newcomer = makeJob(state: .failed(message: "boom"))
            try await store.update(newcomer)
            #expect(await store.load() == [first, second, newcomer])
        }
    }

    // 4. Corruption must never crash or throw from load().
    @Test func corruptedFileLoadsAsEmpty() async throws {
        try await withStore { store in
            try await store.save([makeJob()])
            let fileURL = store.directory.appending(path: "jobs.json")
            try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: fileURL)
            #expect(await store.load() == [])
        }
    }

    // 5. Records persisted before uploadId/multipartCompleted existed must
    //    still decode (missing keys take their defaults).
    @Test func legacyRecordsWithoutNewFieldsStillDecode() async throws {
        try await withStore { store in
            try await store.save([makeJob(uploadId: "u1", multipartCompleted: true)])
            let fileURL = store.directory.appending(path: "jobs.json")
            var array = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])
            array[0].removeValue(forKey: "uploadId")
            array[0].removeValue(forKey: "multipartCompleted")
            try JSONSerialization.data(withJSONObject: array).write(to: fileURL)

            let loaded = await store.load()
            #expect(loaded.count == 1)
            #expect(loaded.first?.uploadId == nil)
            #expect(loaded.first?.multipartCompleted == false)
        }
    }
}
