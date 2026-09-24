import SwiftUI

/// Rolls a server's live upload queue up into the things the browse UI shows
/// about it:
///
/// - `summary(for:)` — the Mail-style status block (thin bar + action line +
///   detail line) that replaced the old "Uploads" toolbar button.
/// - `clientColumnCarriesFooter(isCompact:columnVisibility:)` — which browse
///   column that block hangs under, so collapsing the sidebar doesn't take
///   upload state with it.
/// - `rowActivity(_:under:)` — the per-row "in progress" accessory on the
///   client or project whose subtree is currently receiving clips.
///
/// Pure and `nonisolated` so every mapping is unit-testable without a view.
nonisolated enum UploadActivity {
    /// Whether the client column is the one carrying the upload footer. When
    /// it isn't on screen the project column takes over, so a collapsed
    /// sidebar (macOS/iPad) or a drilled-in stack (iPhone) never hides upload
    /// state.
    ///
    /// `isCompact` wins outright: a collapsed split view ignores
    /// `columnVisibility` entirely, and the client list then sits behind
    /// whatever is pushed on top of it. Otherwise only `.all` shows the
    /// leading column — and because `.automatic` resolves to one of the
    /// concrete cases when read, the same comparison covers the default.
    static func clientColumnCarriesFooter(
        isCompact: Bool,
        columnVisibility: NavigationSplitViewVisibility
    ) -> Bool {
        !isCompact && columnVisibility == .all
    }

    /// Queue entries whose destination lies under `prefix` — a
    /// slash-terminated client (`acme-x1/`) or project (`acme-x1/gala-k9/`)
    /// prefix, which is exactly the head of the clip key.
    static func uploads(_ uploads: [IntakeModel.ActiveUpload],
                        under prefix: String) -> [IntakeModel.ActiveUpload] {
        let prefix = BucketKeys.ensuringTrailingSlash(prefix)
        return uploads.filter { $0.clipKey.hasPrefix(prefix) }
    }

    /// True while this entry still gets to the bucket on its own.
    ///
    /// `.failed` splits in two: a job waiting out its automatic-retry backoff
    /// *is* in progress (the queue will pick it up unprompted), while one that
    /// has exhausted its attempts needs a person and so isn't — showing it as
    /// motion in a row would misreport it as healthy.
    static func isInProgress(_ upload: IntakeModel.ActiveUpload) -> Bool {
        switch upload.state {
        case .waiting, .uploading: true
        case .failed: upload.nextAutoRetry != nil
        case .done: false
        }
    }

    /// The opposite end: failed with no automatic retry left, i.e. parked
    /// until the user retries or removes it.
    static func needsAttention(_ upload: IntakeModel.ActiveUpload) -> Bool {
        if case .failed = upload.state { return upload.nextAutoRetry == nil }
        return false
    }

    /// Row accessory for one client/project subtree, or nil when nothing is
    /// in progress under it. Failures alone produce nil: rows report activity,
    /// and the footer plus the queue screen report trouble.
    static func rowActivity(_ uploads: [IntakeModel.ActiveUpload],
                            under prefix: String) -> RowActivity? {
        let mine = self.uploads(uploads, under: prefix).filter(isInProgress)
        guard !mine.isEmpty else { return nil }
        return RowActivity(count: mine.count, fraction: transferFraction(mine))
    }

    /// The footer's status block, or nil when the queue holds nothing worth
    /// reporting (so the footer disappears entirely, as Mail's does when
    /// idle).
    static func summary(for uploads: [IntakeModel.ActiveUpload]) -> Summary? {
        let inProgress = uploads.filter(isInProgress)
        let parked = uploads.filter(needsAttention)
        guard !inProgress.isEmpty || !parked.isEmpty else { return nil }

        guard !inProgress.isEmpty else {
            // Nothing moving: say so plainly rather than animating a bar over
            // a queue that won't advance without the user.
            return Summary(title: parked.count == 1 ? "1 upload failed"
                                                    : "\(parked.count) uploads failed",
                           detail: parked.count == 1 ? parked[0].displayName : nil,
                           progress: nil,
                           isStalled: true)
        }

        let transferring = inProgress.first { if case .uploading = $0.state { true } else { false } }
        let details = [transferring?.displayName ?? "Waiting to start",
                       parked.isEmpty ? nil : "\(parked.count) failed"]
        return Summary(title: inProgress.count == 1 ? "Uploading 1 clip"
                                                    : "Uploading \(inProgress.count) clips",
                       detail: details.compactMap(\.self).joined(separator: " · "),
                       progress: transferring?.progress,
                       isStalled: false)
    }

    /// Progress of the clip actually on the wire, or nil when everything here
    /// is merely queued (or backing off).
    ///
    /// Deliberately *not* an average across the batch: finished jobs leave
    /// `active`, so a mean would shrink its own denominator and march the bar
    /// backwards as clips complete. Per-clip progress restarts visibly at each
    /// clip instead, which is honest about what the bar measures — the count
    /// in the title carries the batch.
    private static func transferFraction(_ uploads: [IntakeModel.ActiveUpload]) -> Double? {
        uploads.first { if case .uploading = $0.state { true } else { false } }?.progress
    }

    /// What a client/project row shows: how many uploads are in progress
    /// beneath it, and the fraction of the one on the wire (nil = queued, so
    /// the indicator spins indeterminately).
    struct RowActivity: Equatable {
        var count: Int
        var fraction: Double?

        var accessibilityLabel: String {
            count == 1 ? "1 upload in progress" : "\(count) uploads in progress"
        }
    }

    /// The footer's two lines and its bar.
    struct Summary: Equatable {
        /// Mail's "Downloading Messages" line.
        var title: String
        /// Mail's "6,342 new messages" line — the clip on the wire, plus any
        /// failure count.
        var detail: String?
        /// nil renders an indeterminate bar — unless `isStalled`, which shows
        /// no bar at all.
        var progress: Double?
        /// Nothing left is moving: the queue is only failures that have run
        /// out of automatic retries and now need the user.
        var isStalled: Bool
    }
}
