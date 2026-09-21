import Foundation

/// One queued clip upload, persisted across launches so multipart uploads can resume.
nonisolated struct UploadJob: Codable, Equatable, Sendable, Identifiable {
    nonisolated enum State: Codable, Equatable, Sendable {
        case waiting
        case uploading(uploadId: String)
        case failed(message: String)
        case done
    }

    var id: UUID
    var sourceURL: URL
    var sourceBookmark: Data?          // security-scoped bookmark for cross-launch access
    var clipKey: String                // destination object key
    var sidecar: ClipSidecar           // written after upload completes
    /// Source of truth for the in-progress multipart upload. Unlike
    /// `state`'s `.uploading(uploadId:)` payload this survives a `.failed`
    /// transition, so a failed job can resume its server-side upload.
    var uploadId: String? = nil
    /// True once `completeMultipartUpload` has succeeded. From then on the
    /// only outstanding work is the sidecar PUT: the engine must never touch
    /// parts or call complete again (the upload id is gone server-side).
    var multipartCompleted: Bool = false
    var state: State
    /// Whether the most recent failure looked transient (network drop, 5xx,
    /// timeout) — set by the engine whenever it records `.failed`, read by
    /// `IntakeModel` to decide automatic retry. nil until a failure occurs
    /// (and in records persisted before the field existed).
    var lastFailureRetryable: Bool? = nil
    var partSize: Int64
    var totalSize: Int64
    var completedParts: [Int: String]  // partNumber -> ETag

    private enum CodingKeys: String, CodingKey {
        case id, sourceURL, sourceBookmark, clipKey, sidecar
        case uploadId, multipartCompleted
        case state, lastFailureRetryable, partSize, totalSize, completedParts
    }
}

extension UploadJob {
    /// Custom decoding so records persisted before `uploadId` /
    /// `multipartCompleted` existed still load (missing keys take their
    /// defaults). Lives in an extension to keep the synthesized memberwise
    /// initializer; `encode(to:)` stays synthesized.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        sourceBookmark = try container.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        clipKey = try container.decode(String.self, forKey: .clipKey)
        sidecar = try container.decode(ClipSidecar.self, forKey: .sidecar)
        uploadId = try container.decodeIfPresent(String.self, forKey: .uploadId)
        multipartCompleted = try container.decodeIfPresent(Bool.self, forKey: .multipartCompleted) ?? false
        state = try container.decode(State.self, forKey: .state)
        lastFailureRetryable = try container.decodeIfPresent(Bool.self, forKey: .lastFailureRetryable)
        partSize = try container.decode(Int64.self, forKey: .partSize)
        totalSize = try container.decode(Int64.self, forKey: .totalSize)
        completedParts = try container.decode([Int: String].self, forKey: .completedParts)
    }
}
