import Foundation

/// Local file-handling failures raised by `UploadEngine`.
nonisolated enum UploadEngineError: Error, Equatable, CustomStringConvertible {
    case invalidPartSize(Int64)
    case sourceTruncated(expected: Int64, got: Int64)
    case cannotCreatePartFile(String)

    var description: String {
        switch self {
        case .invalidPartSize(let size):
            return "invalid part size \(size)"
        case .sourceTruncated(let expected, let got):
            return "source file truncated: expected \(expected) bytes, read \(got)"
        case .cannotCreatePartFile(let path):
            return "cannot create temporary part file at \(path)"
        }
    }
}

/// Drives one multipart upload at a time to completion or failure.
///
/// Correctness rules:
/// - Every state transition is persisted via `store.update` before proceeding,
///   so a crash or network drop at any point leaves a resumable record.
/// - `job.uploadId` (not the `state` enum) is the source of truth for the
///   server-side upload; failures keep it and the completed-part ETags so a
///   retry re-uploads only the missing parts.
/// - The JSON sidecar is written strictly AFTER `completeMultipartUpload`
///   succeeds: a sidecar must never exist for a clip that isn't fully uploaded.
/// - Part files are staged to the temp directory with chunked (≤ 8 MB) reads
///   so multi-GB sources never load into memory, and are deleted on both
///   success and failure paths.
actor UploadEngine {
    private let client: S3Client
    private let store: UploadQueueStore
    private let partSize: Int64

    /// Read no more than this much of the source into memory at once.
    private static let readChunkSize: Int64 = 8 * 1024 * 1024

    init(client: S3Client, store: UploadQueueStore, partSize: Int64 = 64 * 1024 * 1024) {
        self.client = client
        self.store = store
        self.partSize = partSize
    }

    /// Runs one job to completion (or failure). Progress callback receives 0.0...1.0.
    /// Never throws: errors land in the returned job's `.failed` state, with
    /// `uploadId`/`completedParts` retained for resume.
    func run(job: UploadJob, progress: (@Sendable (Double) -> Void)? = nil) async -> UploadJob {
        var job = job
        if case .done = job.state { return job }

        var scopedURL: URL?
        defer { scopedURL?.stopAccessingSecurityScopedResource() }

        do {
            // Resolve source access (security-scoped bookmark if present).
            let sourceURL: URL
            if let bookmark = job.sourceBookmark {
                let resolved = try Self.resolveBookmark(bookmark)
                if resolved.startAccessingSecurityScopedResource() { scopedURL = resolved }
                sourceURL = resolved
            } else {
                sourceURL = job.sourceURL
            }

            // Recover server-side progress for an upload we know about but
            // have no local part records for (e.g. store lost mid-upload).
            if let uploadId = job.uploadId, job.completedParts.isEmpty {
                do {
                    let parts = try await client.listParts(key: job.clipKey, uploadId: uploadId)
                    job.completedParts = Dictionary(parts.map { ($0.partNumber, $0.etag) },
                                                    uniquingKeysWith: { _, new in new })
                    job.state = .uploading(uploadId: uploadId)
                    try store.update(job)
                } catch S3Error.http(let status, _) where status == 404 {
                    // NoSuchUpload: the server no longer knows this upload.
                    job.uploadId = nil
                    try store.update(job)
                }
            }

            // Start a fresh multipart upload if we don't own one.
            if job.uploadId == nil {
                let uploadId = try await client.createMultipartUpload(
                    key: job.clipKey,
                    contentType: Self.contentType(forKey: job.clipKey))
                job.uploadId = uploadId
                job.state = .uploading(uploadId: uploadId)
                job.completedParts = [:]
                job.partSize = partSize   // the split is fixed at creation time
                try store.update(job)
            }
            let uploadId = job.uploadId!  // set by one of the branches above

            // A failed job resuming with local part records skips the branches
            // above; make sure the persisted state reflects that we're uploading.
            if job.state != .uploading(uploadId: uploadId) {
                job.state = .uploading(uploadId: uploadId)
                try store.update(job)
            }

            // Upload every missing part, in order.
            guard job.partSize > 0 else { throw UploadEngineError.invalidPartSize(job.partSize) }
            let partCount = max(Int((job.totalSize + job.partSize - 1) / job.partSize), 1)
            for partNumber in 1...partCount where job.completedParts[partNumber] == nil {
                let partURL = try Self.extractPart(from: sourceURL, partNumber: partNumber,
                                                   partSize: job.partSize, totalSize: job.totalSize)
                // Runs at the end of each iteration, including on throw.
                defer { try? FileManager.default.removeItem(at: partURL) }
                let etag = try await client.uploadPart(key: job.clipKey, uploadId: uploadId,
                                                       partNumber: partNumber, fileURL: partURL)
                job.completedParts[partNumber] = etag
                try store.update(job)
                progress?(min(Double(job.completedParts.count) / Double(partCount), 1.0))
            }

            // Complete, then — strictly after success — write the sidecar.
            let parts = job.completedParts
                .map { (partNumber: $0.key, etag: $0.value) }
                .sorted { $0.partNumber < $1.partNumber }
            try await client.completeMultipartUpload(key: job.clipKey, uploadId: uploadId,
                                                     parts: parts)
            try await client.putObject(key: BucketKeys.sidecarKey(forClipKey: job.clipKey),
                                       data: ManifestCoding.encode(job.sidecar),
                                       contentType: "application/json")

            job.state = .done
            try store.update(job)
            return job
        } catch {
            // Keep uploadId + completedParts: the server-side parts survive for resume.
            job.state = .failed(message: Self.message(for: error))
            try? store.update(job)
            return job
        }
    }

    /// Aborts server-side multipart uploads that no live job owns.
    /// Individual abort failures are swallowed (best effort); listing errors propagate.
    /// Returns the number of uploads successfully aborted.
    func abandonStaleUploads(prefix: String, liveJobs: [UploadJob]) async throws -> Int {
        let uploads = try await client.listMultipartUploads(prefix: prefix)
        var aborted = 0
        for upload in uploads {
            let isLive = liveJobs.contains {
                $0.uploadId == upload.uploadId && $0.clipKey == upload.key
            }
            if isLive { continue }
            do {
                try await client.abortMultipartUpload(key: upload.key, uploadId: upload.uploadId)
                aborted += 1
            } catch {
                // Best effort: keep going; a stale upload can be reaped next time.
            }
        }
        return aborted
    }

    // MARK: - Helpers

    private static func contentType(forKey key: String) -> String {
        switch (key as NSString).pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        #if os(macOS)
        return try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                       relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        return try URL(resolvingBookmarkData: data, relativeTo: nil,
                       bookmarkDataIsStale: &isStale)
        #endif
    }

    /// Copies part `partNumber`'s byte range out of `source` into a fresh temp
    /// file (`<UUID>-part<N>`), reading at most `readChunkSize` bytes at a time.
    /// Caller is responsible for deleting the returned file.
    private static func extractPart(from source: URL, partNumber: Int,
                                    partSize: Int64, totalSize: Int64) throws -> URL {
        let offset = Int64(partNumber - 1) * partSize
        let length = max(min(partSize, totalSize - offset), 0)
        let partURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-part\(partNumber)")

        guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
            throw UploadEngineError.cannotCreatePartFile(partURL.path)
        }
        do {
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: partURL)
            defer { try? writer.close() }

            try reader.seek(toOffset: UInt64(offset))
            var remaining = length
            while remaining > 0 {
                let chunk = try reader.read(upToCount: Int(min(readChunkSize, remaining)))
                guard let chunk, !chunk.isEmpty else {
                    throw UploadEngineError.sourceTruncated(expected: length,
                                                            got: length - remaining)
                }
                try writer.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            return partURL
        } catch {
            // Never leave a half-written part file behind.
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
    }
}
