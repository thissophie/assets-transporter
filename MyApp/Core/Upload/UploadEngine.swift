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
/// - `job.multipartCompleted` is persisted the moment `completeMultipartUpload`
///   succeeds (or is confirmed after the fact). From then on the only work a
///   retry may do is the sidecar PUT — never part uploads or another complete,
///   because the upload id ceases to exist server-side on completion.
/// - The JSON sidecar is written strictly AFTER completion: a sidecar must
///   never exist for a clip that isn't fully uploaded.
/// - A 404 (NoSuchUpload) from `uploadPart` or an unconfirmable 404 from
///   `completeMultipartUpload` clears `uploadId`/`completedParts` so the next
///   retry starts a fresh upload instead of looping on a dead upload id.
/// - Part files are staged to the temp directory with chunked (≤ 8 MB) reads
///   so multi-GB sources never load into memory, and are deleted on both
///   success and failure paths.
actor UploadEngine {
    /// Default multipart part size: 64 MB.
    static let defaultPartSize: Int64 = 64 * 1024 * 1024

    /// Read no more than this much of the source into memory at once.
    private static let readChunkSize: Int64 = 8 * 1024 * 1024

    private let client: S3Client
    private let store: any UploadJobStoring
    private let partSize: Int64

    init(client: S3Client, store: any UploadJobStoring,
         partSize: Int64 = UploadEngine.defaultPartSize) {
        self.client = client
        self.store = store
        self.partSize = partSize
    }

    /// Runs one job to completion (or failure). Progress callback receives 0.0...1.0.
    /// Never throws: errors land in the returned job's `.failed` state, with
    /// resume bookkeeping (`uploadId`, `completedParts`, `multipartCompleted`)
    /// retained or cleared as appropriate.
    func run(job: UploadJob, progress: (@Sendable (Double) -> Void)? = nil) async -> UploadJob {
        var job = job
        if case .done = job.state { return job }

        var scopedURL: URL?
        defer { scopedURL?.stopAccessingSecurityScopedResource() }

        do {
            // The multipart upload already completed on a previous attempt and
            // only the sidecar PUT is outstanding. Skip all part work — the
            // upload id no longer exists server-side, and the source file is
            // no longer needed.
            if job.multipartCompleted {
                try await finish(&job)
                return job
            }

            // Resolve source access (security-scoped bookmark if present).
            let sourceURL: URL
            if let bookmark = job.sourceBookmark {
                let (resolved, isStale) = try Self.resolveBookmark(bookmark)
                if resolved.startAccessingSecurityScopedResource() { scopedURL = resolved }
                if isStale, let refreshed = Self.makeBookmark(for: resolved) {
                    // Best effort: a refresh failure must not fail an upload
                    // that can proceed with the resolved URL.
                    job.sourceBookmark = refreshed
                    try await store.update(job)
                }
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
                    try await store.update(job)
                } catch S3Error.http(let status, _) where status == 404 {
                    // NoSuchUpload: the server no longer knows this upload.
                    job.uploadId = nil
                    try await store.update(job)
                }
            }

            // Start a fresh multipart upload if we don't own one.
            if job.uploadId == nil {
                let uploadId = try await client.createMultipartUpload(
                    key: job.clipKey,
                    contentType: MediaTypes.contentType(
                        forExtension: (job.clipKey as NSString).pathExtension))
                job.uploadId = uploadId
                job.state = .uploading(uploadId: uploadId)
                job.completedParts = [:]
                job.partSize = partSize   // the split is fixed at creation time
                try await store.update(job)
            }
            let uploadId = job.uploadId!  // set by one of the branches above

            // A failed job resuming with local part records skips the branches
            // above; make sure the persisted state reflects that we're uploading.
            if job.state != .uploading(uploadId: uploadId) {
                job.state = .uploading(uploadId: uploadId)
                try await store.update(job)
            }

            // Upload every missing part, in order.
            guard job.partSize > 0 else { throw UploadEngineError.invalidPartSize(job.partSize) }
            let partCount = max(Int((job.totalSize + job.partSize - 1) / job.partSize), 1)
            for partNumber in 1...partCount where job.completedParts[partNumber] == nil {
                let partURL = try Self.extractPart(from: sourceURL, partNumber: partNumber,
                                                   partSize: job.partSize, totalSize: job.totalSize)
                // Runs at the end of each iteration, including on throw.
                defer { try? FileManager.default.removeItem(at: partURL) }
                let etag: String
                do {
                    etag = try await client.uploadPart(key: job.clipKey, uploadId: uploadId,
                                                       partNumber: partNumber, fileURL: partURL)
                } catch {
                    // NoSuchUpload: our upload id is dead. Clear the local
                    // record so the next retry starts fresh instead of
                    // looping on the same 404 forever.
                    if case S3Error.http(let status, _) = error, status == 404 {
                        job.uploadId = nil
                        job.completedParts = [:]
                    }
                    throw error
                }
                job.completedParts[partNumber] = etag
                try await store.update(job)
                progress?(min(Double(job.completedParts.count) / Double(partCount), 1.0))
            }

            // Complete. A 404 here can mean the upload ALREADY completed but
            // the response was lost (S3 removes the upload id on completion),
            // so confirm via the object's size before deciding.
            let parts = job.completedParts
                .map { (partNumber: $0.key, etag: $0.value) }
                .sorted { $0.partNumber < $1.partNumber }
            do {
                try await client.completeMultipartUpload(key: job.clipKey, uploadId: uploadId,
                                                         parts: parts)
            } catch {
                guard case S3Error.http(let status, _) = error, status == 404 else { throw error }
                let confirmedSize: Int64?
                do {
                    confirmedSize = try await client.objectSize(key: job.clipKey)
                } catch S3Error.http(let headStatus, _) where headStatus == 404 {
                    confirmedSize = nil   // no object: the complete genuinely failed
                }
                guard confirmedSize == job.totalSize else {
                    // Upload id dead and no matching object: restart fresh next retry.
                    job.uploadId = nil
                    job.completedParts = [:]
                    throw error
                }
                // The object landed with exactly the expected size: completed.
            }

            // Record completion BEFORE the sidecar PUT: if the sidecar fails,
            // the retry must skip straight to it (see class comment).
            job.multipartCompleted = true
            try await store.update(job)

            try await finish(&job)
            return job
        } catch {
            job.state = .failed(message: Self.message(for: error))
            job.lastFailureRetryable = Self.isRetryable(error)
            try? await store.update(job)
            return job
        }
    }

    /// Whether a run failure looked transient — worth an automatic retry.
    /// Transient: network-shaped URL errors, HTTP 5xx, and 429 (throttling).
    /// Permanent: other 4xx (auth/config — the 404 recovery paths are already
    /// handled inside `run`), local file problems (`UploadEngineError`),
    /// bookmark/file-system failures (`CocoaError`), and cancellation.
    /// Unknown errors default to non-retryable so a broken job can't loop.
    nonisolated static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case let urlError as URLError:
            return urlError.code != .cancelled
        case S3Error.http(let status, _):
            return status >= 500 || status == 429
        default:
            return false
        }
    }

    /// Aborts server-side multipart uploads that no live job owns.
    ///
    /// `olderThan` is the cross-device guard: multiple devices upload into the
    /// same bucket, so "not in OUR store" says nothing about another device's
    /// in-flight upload. When set, only uploads whose `Initiated` date is
    /// known AND earlier than the cutoff are aborted — recent or unknown-age
    /// uploads are left alone.
    ///
    /// Individual abort failures are swallowed (best effort); listing errors propagate.
    /// Returns the number of uploads successfully aborted.
    func abandonStaleUploads(prefix: String, liveJobs: [UploadJob],
                             olderThan: Date? = nil) async throws -> Int {
        let uploads = try await client.listMultipartUploads(prefix: prefix)
        var aborted = 0
        for upload in uploads {
            let isLive = liveJobs.contains {
                $0.uploadId == upload.uploadId && $0.clipKey == upload.key
            }
            if isLive { continue }
            if let olderThan {
                guard let initiated = upload.initiated, initiated < olderThan else { continue }
            }
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

    /// Sidecar PUT — strictly after multipart completion — then `.done`.
    private func finish(_ job: inout UploadJob) async throws {
        try await client.putObject(key: BucketKeys.sidecarKey(forClipKey: job.clipKey),
                                   data: ManifestCoding.encode(job.sidecar),
                                   contentType: "application/json")
        job.state = .done
        job.lastFailureRetryable = nil   // stale hint from an earlier failure
        try await store.update(job)
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    /// Resolves a bookmark, preferring security-scoped resolution on macOS but
    /// falling back to plain resolution: a bookmark created WITHOUT security
    /// scope fails scoped resolution outright (Cocoa error 259), and vice
    /// versa a scoped bookmark still resolves plainly.
    private static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        isStale = false
        #endif
        let url = try URL(resolvingBookmarkData: data, relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// Best-effort re-creation of a stale bookmark against its resolved URL.
    private static func makeBookmark(for url: URL) -> Data? {
        #if os(macOS)
        if let data = try? url.bookmarkData(options: [.withSecurityScope]) { return data }
        #endif
        return try? url.bookmarkData()
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
