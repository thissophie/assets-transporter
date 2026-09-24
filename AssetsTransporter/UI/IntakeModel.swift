import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Coordinates clip intake (Task 5.3): stage → probe → enqueue → run.
///
/// Pipeline per file:
/// 1. **Stage**: copy into `Application Support/Staging/<UUID>.<ext>` while
///    holding security-scoped access (picker/temp URLs don't outlive their
///    callback, so the copy happens immediately and off the main actor).
/// 2. **Probe**: `ClipProber` fills tech metadata; a probe failure downgrades
///    to nil fields instead of blocking the upload.
/// 3. **Enqueue**: build the clip key + sidecar, persist a `.waiting`
///    `UploadJob` via the shared store.
/// 4. **Run**: jobs run strictly one at a time through `ServerSession.engine`;
///    `isRunning` guards against interleaved duplicate loops. Staged files are
///    deleted after `.done` and kept on `.failed` so `retry` can resume.
@Observable @MainActor final class IntakeModel {
    /// A scheduled automatic retry: when it will run and which attempt
    /// (1-based, of `maxAutoRetries`) it will be.
    nonisolated struct AutoRetrySchedule: Equatable, Sendable {
        var at: Date
        var attempt: Int
    }

    /// `nonisolated` so the pure `UploadActivity` mappings (and their tests)
    /// can read these off the main actor.
    nonisolated struct ActiveUpload: Identifiable, Equatable {
        let id: UUID
        var displayName: String
        var progress: Double
        var state: UploadJob.State
        /// Destination key — lets the view scope the list to one project.
        var clipKey: String
        /// Local staged copy, used for row thumbnails while it exists.
        var stagedURL: URL?
        /// Set while a failed job waits out its automatic-retry backoff;
        /// rows render it as "Retrying in Xs (attempt N/4)".
        var nextAutoRetry: AutoRetrySchedule? = nil
    }

    private(set) var active: [ActiveUpload] = []
    /// Most recent intake failure (staging errors), dismissible in the UI.
    var lastError: String?
    /// Called on the main actor whenever a job finishes uploading, so the
    /// owning view can refresh the project's clip list.
    var onClipsChanged: (@MainActor () -> Void)?

    /// Jobs staged and persisted but not yet run.
    private var pending: [UploadJob] = []
    /// True while the sequential upload loop is draining `pending` — a second
    /// loop must never start or the same job could run twice concurrently.
    private var isRunning = false
    /// Read externally by the queue screen to hide Remove on the running row.
    private(set) var runningJobID: UUID?
    /// Earliest run time per backoff-scheduled job id (absent = run now).
    private var notBefore: [UUID: Date] = [:]
    /// Automatic-retry attempts used per job id, THIS SESSION ONLY (never
    /// persisted — a fresh launch gets fresh attempts; manual Retry resets).
    private var autoRetryAttempts: [UUID: Int] = [:]
    /// The loop's cancellable backoff sleep — cancelled by any nudge
    /// (enqueue / retry / remove / resume) so fresh work never waits it out.
    private var backoffSleeper: Task<Void, Never>?

    // MARK: - Locations

    /// Where staged copies live. Inside our container, so no security scope
    /// is needed to re-read them across launches.
    nonisolated static let stagingDirectory = URL.applicationSupportDirectory
        .appending(path: "Staging", directoryHint: .isDirectory)

    /// Where PhotosPicker imports land (temp; preserves the original filename
    /// under a UUID subfolder). Staging deletes these after copying.
    nonisolated static let photoIntakeDirectory = FileManager.default.temporaryDirectory
        .appending(path: "PhotoIntake", directoryHint: .isDirectory)

    // MARK: - Pure helpers

    /// Unique staging filename: `<UUID>.<sanitized lowercase ext>` (bare UUID
    /// when the original has no usable extension).
    nonisolated static func stagedFilename(originalURL: URL) -> String {
        let ext = originalURL.pathExtension.lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let base = UUID().uuidString
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Splits "acme-x1/gala-k9/" into (client "acme-x1", project "gala-k9").
    /// Tolerates a missing trailing slash; missing components come back empty.
    nonisolated static func clipKeyComponents(
        fromProjectPrefix prefix: String
    ) -> (client: String, project: String) {
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: true)
        return (parts.count > 0 ? String(parts[0]) : "",
                parts.count > 1 ? String(parts[1]) : "")
    }

    /// Persisted jobs worth re-running when the session starts:
    /// `.waiting` and `.uploading` (the engine's `run` resumes both safely —
    /// it recovers server-side part state and restarts dead upload ids).
    /// `.failed` stays for the user's explicit Retry; `.done` has nothing to do.
    nonisolated static func resumableJobs(from jobs: [UploadJob]) -> [UploadJob] {
        jobs.filter {
            switch $0.state {
            case .waiting, .uploading: true
            case .failed, .done: false
            }
        }
    }

    /// Files under `stagingDirectory` that no stored job references — orphans
    /// from crashed or superseded runs, safe to delete.
    nonisolated static func orphanedStagingFiles(files: [URL], jobs: [UploadJob]) -> [URL] {
        let referenced = Set(jobs.map { $0.sourceURL.standardizedFileURL.path })
        return files.filter { !referenced.contains($0.standardizedFileURL.path) }
    }

    /// Automatic-retry backoff schedule, in seconds. Roughly exponential and
    /// deliberately short: transient failures (network blips, 5xx) usually
    /// clear quickly, and after the last delay the job stays `.failed` for
    /// manual Retry.
    nonisolated static let autoRetrySchedule: [TimeInterval] = [5, 15, 60, 300]

    /// Maximum automatic retries per job per session.
    nonisolated static var maxAutoRetries: Int { autoRetrySchedule.count }

    /// Delay before automatic retry number `attempt` (1-based); nil when
    /// attempts are exhausted (or the attempt number is nonsense).
    nonisolated static func autoRetryDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= autoRetrySchedule.count else { return nil }
        return autoRetrySchedule[attempt - 1]
    }

    /// Whether a dequeued job may run, given its freshly-loaded store state:
    /// absent (Removed while it sat in `pending`) or `.done` (finished by an
    /// earlier run) means skip — running the queued snapshot instead could
    /// resurrect a deleted job or repeat a completed one.
    nonisolated static func shouldRunDequeuedJob(storedState: UploadJob.State?) -> Bool {
        guard let storedState else { return false }
        return storedState != .done
    }

    /// True when a retry of `jobID` may be enqueued: not currently running,
    /// not already pending, and — when the stored state is known — not already
    /// uploaded. `retry` applies this twice: synchronously on entry (cheap
    /// fast path) and again after the store-load suspension, because a rapid
    /// double-tap can pass the first check twice.
    nonisolated static func shouldEnqueueRetry(jobID: UUID, runningJobID: UUID?,
                                               pendingIDs: [UUID],
                                               jobState: UploadJob.State?) -> Bool {
        guard runningJobID != jobID, !pendingIDs.contains(jobID) else { return false }
        if jobState == .done { return false }
        return true
    }

    // MARK: - Intake

    /// Stages, probes, and enqueues each file, then drains the queue
    /// sequentially. Fire-and-forget; progress surfaces through `active`.
    func enqueue(fileURLs: [URL], projectPrefix: String, cameraLabel: String?, session: ServerSession) {
        guard !fileURLs.isEmpty else { return }
        Task {
            for url in fileURLs {
                await enqueueOne(url: url, projectPrefix: projectPrefix,
                                 cameraLabel: cameraLabel, session: session)
            }
            await runQueue(session: session)
        }
    }

    /// Reloads a failed job from the store and re-runs it (the staged file was
    /// kept on failure precisely for this).
    func retry(jobID: UUID, session: ServerSession) {
        // A backoff-scheduled job is already queued: manual Retry means "run
        // it NOW, with fresh automatic attempts", not a second enqueue.
        if notBefore[jobID] != nil {
            notBefore[jobID] = nil
            autoRetryAttempts[jobID] = nil
            if let index = active.firstIndex(where: { $0.id == jobID }) {
                active[index].state = .waiting
                active[index].progress = 0
                active[index].nextAutoRetry = nil
            }
            backoffSleeper?.cancel()
            return
        }
        guard Self.shouldEnqueueRetry(jobID: jobID, runningJobID: runningJobID,
                                      pendingIDs: pending.map(\.id), jobState: nil) else { return }
        Task {
            guard let job = await session.store.load().first(where: { $0.id == jobID }) else {
                lastError = "That upload is no longer in the queue."
                return
            }
            // Re-check after the store-load suspension: a rapid double-tap
            // passes the synchronous guard twice, and only the first may
            // enqueue (the second would re-run a stale snapshot and could
            // persist .failed over the store's .done). No suspension between
            // this check and the append below, so the decision stays valid.
            guard Self.shouldEnqueueRetry(jobID: jobID, runningJobID: runningJobID,
                                          pendingIDs: pending.map(\.id),
                                          jobState: job.state) else { return }
            if let index = active.firstIndex(where: { $0.id == jobID }) {
                active[index].state = .waiting
                active[index].progress = 0
                active[index].nextAutoRetry = nil
            } else {
                active.append(ActiveUpload(id: job.id, displayName: job.sidecar.displayName,
                                           progress: 0, state: .waiting,
                                           clipKey: job.clipKey, stagedURL: job.sourceURL))
            }
            autoRetryAttempts[jobID] = nil   // manual retry restarts the count
            pending.append(job)
            await runQueue(session: session)
        }
    }

    /// Re-runs persisted jobs from a previous session (`.waiting` and
    /// `.uploading` — see `resumableJobs`). Called when the server's session
    /// starts; without this, jobs interrupted by a relaunch would sit in
    /// the store forever, since `pending` is memory-only. Fire-and-forget.
    func resumePersistedJobs(session: ServerSession) {
        Task {
            let stored = await session.store.load()
            for job in Self.resumableJobs(from: stored) {
                // Skip anything this session already tracks.
                guard runningJobID != job.id,
                      !pending.contains(where: { $0.id == job.id }) else { continue }
                if !active.contains(where: { $0.id == job.id }) {
                    let isStagedCopy = job.sourceBookmark == nil
                        && job.sourceURL.path.hasPrefix(Self.stagingDirectory.path)
                    active.append(ActiveUpload(id: job.id,
                                               displayName: job.sidecar.displayName,
                                               progress: 0, state: .waiting,
                                               clipKey: job.clipKey,
                                               stagedURL: isStagedCopy ? job.sourceURL : nil))
                }
                pending.append(job)
            }
            await runQueue(session: session)
        }
    }

    /// Removes a job from the queue (queue screen's Remove button). Refuses
    /// the currently-running job — the sequential loop owns it, and removing
    /// it mid-flight would race the engine's own store updates. Waiting jobs
    /// are pulled out of `pending` synchronously (before any suspension), so
    /// the loop can never start a job that was just removed.
    func remove(jobID: UUID, session: ServerSession) async {
        guard runningJobID != jobID else {
            lastError = "That upload is running — wait for it to finish or fail first."
            return
        }
        pending.removeAll { $0.id == jobID }
        active.removeAll { $0.id == jobID }
        notBefore[jobID] = nil
        autoRetryAttempts[jobID] = nil
        // Wake a loop sleeping out this job's backoff so it re-scans now.
        backoffSleeper?.cancel()
        do {
            let stored = await session.store.load().first { $0.id == jobID }
            try await session.store.remove(jobID: jobID)
            // Only after the store removal is durable: reclaim the staged
            // copy for jobs we staged ourselves (inside our container). Never
            // touch bookmarked sources — those are the user's own files.
            if let job = stored, job.sourceBookmark == nil,
               job.sourceURL.path.hasPrefix(Self.stagingDirectory.path) {
                try? FileManager.default.removeItem(at: job.sourceURL)
            }
        } catch {
            lastError = "Could not remove the upload: \(ErrorText.describe(error))"
        }
    }

    // MARK: - Internals

    private func enqueueOne(url: URL, projectPrefix: String,
                            cameraLabel: String?, session: ServerSession) async {
        let staged: StagedFile
        do {
            // Detached: multi-GB copies must not block the main actor.
            staged = try await Task.detached { try Self.stage(url) }.value
        } catch {
            lastError = "Could not stage \(url.lastPathComponent): \(ErrorText.describe(error))"
            return
        }

        // Probe failures tolerated: tech fields just stay nil.
        let probe = try? await ClipProber.probe(url: staged.url)

        let components = Self.clipKeyComponents(fromProjectPrefix: projectPrefix)
        var rng = SystemRandomNumberGenerator()
        let label = cameraLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = (label?.isEmpty ?? true) ? nil : label
        let clipKey = BucketKeys.clipKey(client: components.client,
                                         project: components.project,
                                         capturedAt: probe?.capturedAt ?? staged.fileDate ?? Date(),
                                         cameraLabel: normalizedLabel,
                                         id: Slug.shortID(using: &rng),
                                         ext: staged.url.pathExtension)
        let baseName = (staged.originalFilename as NSString).deletingPathExtension
        let sidecar = ClipSidecar(displayName: baseName.isEmpty ? staged.originalFilename : baseName,
                                  cameraLabel: normalizedLabel,
                                  notes: nil,
                                  capturedAt: probe?.capturedAt ?? staged.fileDate,
                                  orderOverride: nil,
                                  duration: probe?.duration,
                                  width: probe?.width,
                                  height: probe?.height,
                                  codec: probe?.codec,
                                  fileSize: staged.size,
                                  originalFilename: staged.originalFilename,
                                  sourceDevice: Self.deviceName)
        let job = UploadJob(id: UUID(),
                            sourceURL: staged.url,
                            sourceBookmark: nil,   // staged copy is in our container
                            clipKey: clipKey,
                            sidecar: sidecar,
                            state: .waiting,
                            partSize: UploadEngine.defaultPartSize,
                            totalSize: staged.size,
                            completedParts: [:])
        do {
            try await session.store.update(job)
        } catch {
            lastError = "Could not queue \(staged.originalFilename): \(ErrorText.describe(error))"
            try? FileManager.default.removeItem(at: staged.url)
            return
        }
        active.append(ActiveUpload(id: job.id, displayName: sidecar.displayName,
                                   progress: 0, state: .waiting,
                                   clipKey: clipKey, stagedURL: staged.url))
        pending.append(job)
    }

    /// Drains `pending` one job at a time. The `isRunning` guard means at most
    /// one loop exists; late enqueues append to `pending` and are picked up by
    /// the live loop.
    ///
    /// Backoff design (documented choice): a failed-but-retryable job goes to
    /// the BACK of the queue with a not-before time rather than sleeping the
    /// loop, so other queued jobs are never blocked by one job's backoff. The
    /// loop only sleeps when *everything* left is waiting out a backoff, and
    /// that sleep is a separate cancellable task — any nudge (new enqueue,
    /// manual retry, remove, resume) cancels it so fresh work runs immediately.
    private func runQueue(session: ServerSession) async {
        // Entering runQueue is the universal nudge: wake a sleeping loop.
        backoffSleeper?.cancel()
        guard !isRunning else { return }
        let engine = session.engine
        isRunning = true
        defer {
            isRunning = false
            runningJobID = nil
        }
        while !pending.isEmpty {
            // Next runnable job: first whose backoff (if any) has elapsed.
            let now = Date()
            guard let index = pending.firstIndex(where: {
                (notBefore[$0.id] ?? .distantPast) <= now
            }) else {
                // Only backoff-pending work remains: sleep until the earliest
                // not-before, then re-scan. (0.1s floor avoids a hot loop when
                // the deadline lands between the check and the sleep.)
                let earliest = pending.compactMap { notBefore[$0.id] }.min() ?? now
                let sleeper = Task {
                    do {
                        try await Task.sleep(for: .seconds(max(earliest.timeIntervalSinceNow, 0.1)))
                    } catch {
                        // Cancelled by a nudge — just wake and re-scan.
                    }
                }
                backoffSleeper = sleeper
                await sleeper.value
                backoffSleeper = nil
                continue
            }
            let queued = pending.remove(at: index)
            let jobID = queued.id
            notBefore[jobID] = nil
            // Claim the id BEFORE the store-load suspension so remove() and
            // retry() treat the job as running for this whole iteration.
            runningJobID = jobID
            // Run the STORE's copy, never the queued snapshot: while the job
            // sat in `pending` it may have been Removed (store entry gone) or
            // completed by an earlier loop (.done) — see shouldRunDequeuedJob.
            let job = await session.store.load().first { $0.id == jobID }
            guard let job, Self.shouldRunDequeuedJob(storedState: job.state) else {
                active.removeAll { $0.id == jobID }
                autoRetryAttempts[jobID] = nil
                runningJobID = nil
                continue
            }
            if let index = active.firstIndex(where: { $0.id == jobID }) {
                active[index].state = .uploading(uploadId: job.uploadId ?? "")
                active[index].nextAutoRetry = nil
            }
            // The running loop is a method on self, so self necessarily
            // outlives the progress callbacks — a strong capture is fine.
            let finished = await engine.run(job: job) { value in
                Task { @MainActor in
                    guard let index = self.active.firstIndex(where: { $0.id == jobID })
                    else { return }
                    self.active[index].progress = value
                }
            }
            if let index = active.firstIndex(where: { $0.id == jobID }) {
                active[index].state = finished.state
                active[index].progress = finished.state == .done ? 1 : active[index].progress
            }
            if finished.state == .done {
                autoRetryAttempts[jobID] = nil
                // Staged copy no longer needed; failed jobs keep theirs for retry.
                try? FileManager.default.removeItem(at: finished.sourceURL)
                active.removeAll { $0.id == jobID }
                onClipsChanged?()
            } else if case .failed = finished.state {
                scheduleAutoRetryIfEligible(finished)
            }
            runningJobID = nil
        }
    }

    /// Requeues a failed job for an automatic retry when the engine judged
    /// the failure transient (`lastFailureRetryable`) and session attempts
    /// remain; otherwise the job stays `.failed` for manual Retry (which
    /// resets the attempt count). Attempt counts are memory-only by design —
    /// a fresh launch gets fresh attempts.
    private func scheduleAutoRetryIfEligible(_ job: UploadJob) {
        let attempt = (autoRetryAttempts[job.id] ?? 0) + 1
        guard job.lastFailureRetryable == true,
              let delay = Self.autoRetryDelay(attempt: attempt) else { return }
        autoRetryAttempts[job.id] = attempt
        let at = Date().addingTimeInterval(delay)
        notBefore[job.id] = at
        pending.append(job)
        if let index = active.firstIndex(where: { $0.id == job.id }) {
            active[index].nextAutoRetry = AutoRetrySchedule(at: at, attempt: attempt)
        }
    }

    // MARK: - Staging

    nonisolated struct StagedFile: Sendable {
        var url: URL
        var originalFilename: String
        var fileDate: Date?
        var size: Int64
    }

    /// Copies `source` into the staging directory while holding
    /// security-scoped access (released before returning). Sources under
    /// `photoIntakeDirectory` are our own temp copies and are deleted after
    /// the copy succeeds.
    nonisolated private static func stage(_ source: URL) throws -> StagedFile {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let values = try? source.resourceValues(forKeys: [.creationDateKey,
                                                          .contentModificationDateKey])
        let fileDate = values?.creationDate ?? values?.contentModificationDate

        let destination = stagingDirectory.appending(path: stagedFilename(originalURL: source))
        try fm.copyItem(at: source, to: destination)
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        if source.path.hasPrefix(photoIntakeDirectory.path) {
            // Our own PhotosPicker import (PhotoIntake/<UUID>/<name>): remove
            // the whole UUID subfolder now that the staged copy exists.
            try? fm.removeItem(at: source.deletingLastPathComponent())
        }
        return StagedFile(url: destination,
                          originalFilename: source.lastPathComponent,
                          fileDate: fileDate,
                          size: size)
    }

    /// Host/device name recorded in sidecars as `sourceDevice`.
    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}
