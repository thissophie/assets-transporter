import SwiftUI

extension UploadJob.State {
    /// Fixed badge label for the upload queue screen. Kept as a pure mapping
    /// (pinned by tests); the view appends a live percentage to `.uploading`
    /// when it has one.
    nonisolated var badgeText: String {
        switch self {
        case .waiting: "Waiting"
        case .uploading: "Uploading"
        case .failed(let message): "Failed: \(message)"
        case .done: "Done"
        }
    }
}

/// The upload queue (Task 5.6): every persisted job from the shared store,
/// with retry/remove for failed jobs and remove for done ones.
///
/// Pull model: the store is reloaded on appear, on pull-to-refresh, and
/// whenever `IntakeModel.active` changes (the engine persists every state
/// transition, so a reload after any active change is always current).
struct UploadQueueView: View {
    @Environment(ServerSession.self) private var session
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var jobs: [UploadJob] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = session.intake.lastError {
                    errorLine(error) { session.intake.lastError = nil }
                }
                list
            }
            .navigationTitle("Uploads")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("Clear Completed") {
                        Task { await clearCompleted() }
                    }
                    .disabled(isLoading || completedJobs.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .task { await reload() }
        .onChange(of: session.intake.active) {
            Task { await reload() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    // MARK: - Pieces

    @ViewBuilder private var list: some View {
        if jobs.isEmpty {
            // In a ScrollView so pull-to-refresh is available from the empty
            // state; a bare ContentUnavailableView has no scroll surface.
            ScrollView {
                ContentUnavailableView("No uploads", systemImage: "tray",
                                       description: Text("Clips you add appear here while they upload."))
                    .containerRelativeFrame([.horizontal, .vertical])
            }
            .refreshable { await reload() }
        } else {
            List(jobs) { job in
                let live = session.intake.active.first { $0.id == job.id }
                UploadQueueRow(job: job,
                               liveProgress: liveProgress(for: job),
                               isRunning: job.id == session.intake.runningJobID,
                               nextAutoRetry: live?.nextAutoRetry,
                               onRetry: { session.intake.retry(jobID: job.id, session: session) },
                               onRemove: { remove(job) })
            }
            .refreshable { await reload() }
        }
    }

    /// Maintenance results surface here, subtly — e.g. "Cleaned 2 stale
    /// uploads" from this server's sweep, or the app-wide staging cleanup.
    @ViewBuilder private var footer: some View {
        let notes = [session.maintenanceNote, app.maintenanceNote].compactMap { $0 }
        if !notes.isEmpty {
            Text(notes.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    private func errorLine(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer()
            Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Data

    /// Live fraction for a job the in-memory intake loop is tracking; nil for
    /// jobs only known from the persisted store.
    private func liveProgress(for job: UploadJob) -> Double? {
        guard case .uploading = job.state else { return nil }
        return session.intake.active.first { $0.id == job.id }?.progress
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        jobs = await session.store.load()
    }

    private func remove(_ job: UploadJob) {
        Task {
            await session.intake.remove(jobID: job.id, session: session)
            await reload()
        }
    }

    private var completedJobs: [UploadJob] {
        jobs.filter { if case .done = $0.state { true } else { false } }
    }

    /// Removes every done job through the same path as the per-row Remove
    /// button, so staged copies are reclaimed too.
    private func clearCompleted() async {
        for job in completedJobs {
            await session.intake.remove(jobID: job.id, session: session)
        }
        await reload()
    }
}

/// One persisted job: name, destination key, state badge, size, and its
/// actions — Retry for failed jobs, Remove for anything not currently
/// running (the running job belongs to the loop; `IntakeModel.remove` also
/// refuses it as the authoritative guard).
private struct UploadQueueRow: View {
    var job: UploadJob
    var liveProgress: Double?
    var isRunning: Bool
    var nextAutoRetry: IntakeModel.AutoRetrySchedule?
    var onRetry: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.sidecar.displayName)
                    .lineLimit(1)
                Text(job.clipKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    badge
                    Text(job.totalSize, format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let retry = nextAutoRetry {
                    // Text(_, style: .timer) live-updates the countdown.
                    Text("Retrying in \(Text(retry.at, style: .timer)) (attempt \(retry.attempt)/\(IntakeModel.maxAutoRetries))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badge: some View {
        switch job.state {
        case .waiting:
            Text(job.state.badgeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .uploading:
            if let liveProgress {
                Text("\(job.state.badgeText) \(Int((liveProgress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .monospacedDigit()
            } else {
                Text(job.state.badgeText)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        case .failed:
            Text(job.state.badgeText)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .done:
            Label(job.state.badgeText, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder private var actions: some View {
        if case .failed = job.state {
            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.borderless)
        }
        if !isRunning {
            removeButton
        }
    }

    private var removeButton: some View {
        Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
    }
}

#Preview("Upload queue (placeholder server)") {
    UploadQueueView()
        .environment(ServerSession.preview())
        .environment(AppModel())
}
