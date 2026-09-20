import Foundation
import Testing
@testable import MyApp

/// Pins the queue screen's state → badge text mapping (one case per
/// `UploadJob.State`). The live "%" suffix for uploading rows is view-level
/// and not part of this mapping.
struct UploadQueueBadgeTests {
    @Test func waitingBadge() {
        #expect(UploadJob.State.waiting.badgeText == "Waiting")
    }

    @Test func uploadingBadgeIgnoresUploadId() {
        #expect(UploadJob.State.uploading(uploadId: "u-123").badgeText == "Uploading")
    }

    @Test func failedBadgeCarriesTheMessage() {
        #expect(UploadJob.State.failed(message: "server returned HTTP 500").badgeText
            == "Failed: server returned HTTP 500")
    }

    @Test func doneBadge() {
        #expect(UploadJob.State.done.badgeText == "Done")
    }
}
