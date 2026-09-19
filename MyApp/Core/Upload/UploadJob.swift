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
    var state: State
    var partSize: Int64
    var totalSize: Int64
    var completedParts: [Int: String]  // partNumber -> ETag
}
