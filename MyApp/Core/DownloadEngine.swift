import Foundation
import Synchronization

/// Downloads a project's clips into a local directory using the
/// order-prefixed filenames from `DownloadNaming`, resuming partial files
/// via ranged GETs.
///
/// An actor: driven from the UI but does network and file I/O. Objects are
/// fetched in bounded ranged chunks (`chunkSize`, ≤ 32 MB by default) so
/// memory stays flat, progress flows continuously, and `cancel()` can
/// interrupt between chunks.
///
/// Security-scoped access to the destination directory is the CALLER's
/// responsibility (start it before `download`, hold it until the await ends).
actor DownloadEngine {
    /// One clip to download, with its final on-disk filename
    /// (from `DownloadNaming.filenames(forOrdered:)`).
    nonisolated struct Item: Sendable {
        let clip: Clip
        let filename: String
    }

    /// Default ranged-fetch chunk size: 32 MB.
    static let defaultChunkSize: Int64 = 32 * 1024 * 1024

    private let client: S3Client
    private let chunkSize: Int64
    /// Cooperative-cancel flag: nonisolated + atomic so `cancel()` is callable
    /// synchronously from any context while `download` is mid-await.
    private nonisolated let isCancelled = Atomic(false)

    init(client: S3Client, chunkSize: Int64 = DownloadEngine.defaultChunkSize) {
        self.client = client
        self.chunkSize = max(1, chunkSize)
    }

    /// Requests cooperative cancellation: observed between chunks and between
    /// files; the in-flight `download` throws `CancellationError`.
    nonisolated func cancel() {
        isCancelled.store(true, ordering: .relaxed)
    }

    /// Downloads `items` into `directory`, resuming any partial files found
    /// there (ranged GET starting at the existing size, appended to the file).
    /// A file already at its expected size is skipped but still counted.
    ///
    /// `progress` reports (completedBytes, totalBytes) across the whole batch.
    /// Throws on the first failure. On success, writes `project.json`
    /// (`ManifestCoding`) alongside the clips when `projectManifest` is given.
    func download(items: [Item], into directory: URL,
                  projectManifest: ProjectManifest?,
                  progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        // Resolve expected sizes up front so totalBytes covers the whole batch.
        var sizes: [Int64] = []
        sizes.reserveCapacity(items.count)
        for item in items {
            let declared = item.clip.sidecar.fileSize
            if declared > 0 {
                sizes.append(declared)
            } else {
                sizes.append(try await client.objectSize(key: item.clip.key))
            }
        }
        let totalBytes = sizes.reduce(0, +)
        var completedBytes: Int64 = 0
        progress?(completedBytes, totalBytes)

        for (item, expectedSize) in zip(items, sizes) {
            try checkCancelled()
            let destination = directory.appending(path: item.filename)
            let existing = Self.fileSize(at: destination)

            // Complete file already present: count it and move on.
            if expectedSize > 0, existing >= expectedSize {
                completedBytes += expectedSize
                progress?(completedBytes, totalBytes)
                continue
            }

            if existing == 0, !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown,
                                     userInfo: [NSFilePathErrorKey: destination.path])
                }
            }
            if expectedSize == 0 { continue }

            // Resume point: bytes already on disk count as done.
            completedBytes += existing
            if existing > 0 { progress?(completedBytes, totalBytes) }

            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()

            var offset = existing
            while offset < expectedSize {
                try checkCancelled()
                let upper = min(offset + chunkSize, expectedSize) - 1
                let chunk = try await client.getObject(key: item.clip.key, range: offset...upper)
                guard !chunk.isEmpty else { throw S3Error.badResponse }
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                completedBytes += Int64(chunk.count)
                progress?(completedBytes, totalBytes)
            }
        }

        // Only after every item succeeded — never a project.json for a
        // partially downloaded batch.
        try checkCancelled()
        if let projectManifest {
            let data = try ManifestCoding.encode(projectManifest)
            try data.write(to: directory.appending(path: "project.json"), options: .atomic)
        }
    }

    // MARK: - Internals

    private func checkCancelled() throws {
        if isCancelled.load(ordering: .relaxed) { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
