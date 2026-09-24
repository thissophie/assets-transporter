import Foundation
import SwiftUI
import Testing
@testable import AssetsTransporter

/// Pins `UploadActivity`: which queue entries count as "in progress", how a
/// client/project subtree rolls up into a row indicator, and the Mail-style
/// footer summary. All pure — no view, no session.
struct UploadActivityTests {
    // MARK: - Fixtures

    private func upload(_ name: String,
                        key: String = "acme-x1/gala-k9/clips/2026-09-25_120000_cam_abc.mov",
                        state: UploadJob.State = .waiting,
                        progress: Double = 0,
                        retry: IntakeModel.AutoRetrySchedule? = nil) -> IntakeModel.ActiveUpload {
        IntakeModel.ActiveUpload(id: UUID(), displayName: name, progress: progress,
                                 state: state, clipKey: key, stagedURL: nil,
                                 nextAutoRetry: retry)
    }

    private func key(client: String, project: String, clip: String = "c.mov") -> String {
        "\(client)/\(project)/clips/2026-09-25_120000_cam_\(clip)"
    }

    private let uploading = UploadJob.State.uploading(uploadId: "u-1")
    private let failed = UploadJob.State.failed(message: "boom")

    // MARK: - 1. In-progress classification

    @Test func waitingAndUploadingAreInProgress() {
        #expect(UploadActivity.isInProgress(upload("a", state: .waiting)))
        #expect(UploadActivity.isInProgress(upload("b", state: uploading)))
    }

    @Test func doneIsNotInProgress() {
        #expect(!UploadActivity.isInProgress(upload("a", state: .done)))
    }

    /// A failure inside its automatic-retry backoff resumes unprompted, so it
    /// still counts; one with attempts exhausted needs a person and doesn't.
    @Test func failedCountsOnlyWhileAnAutomaticRetryIsScheduled() {
        let backingOff = upload("a", state: failed,
                                retry: .init(at: Date(timeIntervalSince1970: 1_800_000_000),
                                             attempt: 2))
        let parked = upload("b", state: failed)
        #expect(UploadActivity.isInProgress(backingOff))
        #expect(!UploadActivity.needsAttention(backingOff))
        #expect(!UploadActivity.isInProgress(parked))
        #expect(UploadActivity.needsAttention(parked))
    }

    @Test func needsAttentionIgnoresNonFailures() {
        #expect(!UploadActivity.needsAttention(upload("a", state: .waiting)))
        #expect(!UploadActivity.needsAttention(upload("b", state: uploading)))
        #expect(!UploadActivity.needsAttention(upload("c", state: .done)))
    }

    // MARK: - 2. Prefix scoping

    @Test func uploadsAreScopedToTheirClientAndProject() {
        let all = [upload("a", key: key(client: "acme-x1", project: "gala-k9")),
                   upload("b", key: key(client: "acme-x1", project: "expo-m3")),
                   upload("c", key: key(client: "brava-p2", project: "gala-k9"))]

        #expect(UploadActivity.uploads(all, under: "acme-x1/").map(\.displayName) == ["a", "b"])
        #expect(UploadActivity.uploads(all, under: "acme-x1/gala-k9/").map(\.displayName) == ["a"])
        #expect(UploadActivity.uploads(all, under: "brava-p2/").map(\.displayName) == ["c"])
    }

    /// A prefix is slash-terminated before matching, so a client can never
    /// pick up a sibling that merely shares its spelling.
    @Test func prefixMatchingNeverBleedsIntoASiblingWithTheSameStem() {
        let all = [upload("mine", key: key(client: "acme", project: "gala-k9")),
                   upload("theirs", key: key(client: "acme-two", project: "gala-k9"))]
        #expect(UploadActivity.uploads(all, under: "acme").map(\.displayName) == ["mine"])
        #expect(UploadActivity.uploads(all, under: "acme/").map(\.displayName) == ["mine"])
    }

    // MARK: - 3. Row indicator

    @Test func rowActivityCountsOnlyInProgressWorkUnderThePrefix() {
        let all = [upload("a", key: key(client: "acme-x1", project: "gala-k9"), state: uploading,
                          progress: 0.4),
                   upload("b", key: key(client: "acme-x1", project: "gala-k9")),
                   upload("c", key: key(client: "acme-x1", project: "gala-k9"), state: failed),
                   upload("d", key: key(client: "other-z9", project: "gala-k9"))]

        let client = UploadActivity.rowActivity(all, under: "acme-x1/")
        #expect(client == UploadActivity.RowActivity(count: 2, fraction: 0.4))
        #expect(UploadActivity.rowActivity(all, under: "acme-x1/expo-m3/") == nil)
    }

    /// Queued-but-not-yet-transferring has no fraction to draw, so the row
    /// falls back to an indeterminate spinner.
    @Test func rowActivityHasNoFractionWhileEverythingIsMerelyQueued() {
        let all = [upload("a"), upload("b")]
        #expect(UploadActivity.rowActivity(all, under: "acme-x1/")
                == UploadActivity.RowActivity(count: 2, fraction: nil))
    }

    @Test func rowActivityIsNilWhenTheOnlyWorkThereHasFailed() {
        let all = [upload("a", state: failed), upload("b", state: .done)]
        #expect(UploadActivity.rowActivity(all, under: "acme-x1/") == nil)
    }

    @Test func rowActivityAccessibilityLabelIsInflected() {
        #expect(UploadActivity.RowActivity(count: 1, fraction: nil).accessibilityLabel
                == "1 upload in progress")
        #expect(UploadActivity.RowActivity(count: 3, fraction: 0.5).accessibilityLabel
                == "3 uploads in progress")
    }

    // MARK: - 4. Footer summary

    @Test func emptyQueueHasNoFooter() {
        #expect(UploadActivity.summary(for: []) == nil)
        // A finished job lingering in `active` is not worth a footer either.
        #expect(UploadActivity.summary(for: [upload("a", state: .done)]) == nil)
    }

    @Test func oneTransferringClipNamesItselfAndDrivesTheBar() {
        let summary = UploadActivity.summary(for: [upload("Interview A", state: uploading,
                                                          progress: 0.25)])
        #expect(summary?.title == "Uploading 1 clip")
        #expect(summary?.detail == "Interview A")
        #expect(summary?.progress == 0.25)
        #expect(summary?.isStalled == false)
    }

    /// The count carries the batch; the bar and the detail line track the clip
    /// actually on the wire (see `UploadActivity.transferFraction`).
    @Test func batchTitleCountsInProgressClipsAndBarTracksTheCurrentOne() {
        let summary = UploadActivity.summary(for: [upload("first", state: uploading, progress: 0.6),
                                                   upload("second"),
                                                   upload("third")])
        #expect(summary?.title == "Uploading 3 clips")
        #expect(summary?.detail == "first")
        #expect(summary?.progress == 0.6)
    }

    @Test func queuedOnlyBatchIsIndeterminateAndSaysSo() {
        let summary = UploadActivity.summary(for: [upload("a"), upload("b")])
        #expect(summary?.title == "Uploading 2 clips")
        #expect(summary?.detail == "Waiting to start")
        #expect(summary?.progress == nil)
        #expect(summary?.isStalled == false)
    }

    @Test func failureCountRidesAlongWithLiveProgress() {
        let summary = UploadActivity.summary(for: [upload("live", state: uploading, progress: 0.1),
                                                   upload("dead", state: failed)])
        #expect(summary?.title == "Uploading 1 clip")
        #expect(summary?.detail == "live · 1 failed")
        #expect(summary?.isStalled == false)
    }

    @Test func aQueueOfNothingButFailuresIsStalledWithNoBar() {
        let one = UploadActivity.summary(for: [upload("Interview A", state: failed)])
        #expect(one?.title == "1 upload failed")
        #expect(one?.detail == "Interview A")
        #expect(one?.progress == nil)
        #expect(one?.isStalled == true)

        let many = UploadActivity.summary(for: [upload("a", state: failed),
                                                 upload("b", state: failed)])
        #expect(many?.title == "2 uploads failed")
        // No single clip to name once there's more than one failure.
        #expect(many?.detail == nil)
        #expect(many?.isStalled == true)
    }

    // MARK: - 5. Footer placement

    @Test func clientColumnKeepsTheFooterWhileTheSidebarIsShowing() {
        #expect(UploadActivity.clientColumnCarriesFooter(isCompact: false,
                                                         columnVisibility: .all))
    }

    /// Collapsing the sidebar (macOS/iPad) hands the footer to the project
    /// column — `.doubleColumn` is content + detail, with the leading column
    /// gone.
    @Test func collapsingTheSidebarHandsTheFooterToTheProjectColumn() {
        #expect(!UploadActivity.clientColumnCarriesFooter(isCompact: false,
                                                          columnVisibility: .doubleColumn))
        #expect(!UploadActivity.clientColumnCarriesFooter(isCompact: false,
                                                          columnVisibility: .detailOnly))
    }

    /// A collapsed split view ignores `columnVisibility` altogether, so the
    /// compact flag has to win whatever it reads.
    @Test func compactWidthAlwaysHandsTheFooterToTheProjectColumn() {
        for visibility in [NavigationSplitViewVisibility.all, .doubleColumn, .detailOnly,
                           .automatic] {
            #expect(!UploadActivity.clientColumnCarriesFooter(isCompact: true,
                                                              columnVisibility: visibility))
        }
    }

    /// Backing off is progress, not stall: the footer keeps the "uploading"
    /// framing because the queue will resume on its own.
    @Test func backingOffJobKeepsTheFooterLive() {
        let summary = UploadActivity.summary(for: [
            upload("a", state: failed,
                   retry: .init(at: Date(timeIntervalSince1970: 1_800_000_000), attempt: 1))
        ])
        #expect(summary?.title == "Uploading 1 clip")
        #expect(summary?.detail == "Waiting to start")
        #expect(summary?.isStalled == false)
    }
}
