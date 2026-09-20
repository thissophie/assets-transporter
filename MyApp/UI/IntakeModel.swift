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
/// 4. **Run**: jobs run strictly one at a time through `AppModel.engine`;
///    `isRunning` guards against interleaved duplicate loops. Staged files are
///    deleted after `.done` and kept on `.failed` so `retry` can resume.
@Observable @MainActor final class IntakeModel {
    struct ActiveUpload: Identifiable, Equatable {
        let id: UUID
        var displayName: String
        var progress: Double
        var state: UploadJob.State
        /// Destination key — lets the view scope the list to one project.
        var clipKey: String
        /// Local staged copy, used for row thumbnails while it exists.
        var stagedURL: URL?
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
    private var runningJobID: UUID?

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

    // MARK: - Intake

    /// Stages, probes, and enqueues each file, then drains the queue
    /// sequentially. Fire-and-forget; progress surfaces through `active`.
    func enqueue(fileURLs: [URL], projectPrefix: String, cameraLabel: String?, app: AppModel) {
        guard !fileURLs.isEmpty else { return }
        Task {
            for url in fileURLs {
                await enqueueOne(url: url, projectPrefix: projectPrefix,
                                 cameraLabel: cameraLabel, app: app)
            }
            await runQueue(app: app)
        }
    }

    /// Reloads a failed job from the store and re-runs it (the staged file was
    /// kept on failure precisely for this).
    func retry(jobID: UUID, app: AppModel) {
        guard runningJobID != jobID, !pending.contains(where: { $0.id == jobID }) else { return }
        Task {
            guard let job = await app.store.load().first(where: { $0.id == jobID }) else {
                lastError = "That upload is no longer in the queue."
                return
            }
            if let index = active.firstIndex(where: { $0.id == jobID }) {
                active[index].state = .waiting
                active[index].progress = 0
            } else {
                active.append(ActiveUpload(id: job.id, displayName: job.sidecar.displayName,
                                           progress: 0, state: .waiting,
                                           clipKey: job.clipKey, stagedURL: job.sourceURL))
            }
            pending.append(job)
            await runQueue(app: app)
        }
    }

    // MARK: - Internals

    private func enqueueOne(url: URL, projectPrefix: String,
                            cameraLabel: String?, app: AppModel) async {
        let staged: StagedFile
        do {
            // Detached: multi-GB copies must not block the main actor.
            staged = try await Task.detached { try Self.stage(url) }.value
        } catch {
            lastError = "Could not stage \(url.lastPathComponent): \(String(describing: error))"
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
            try await app.store.update(job)
        } catch {
            lastError = "Could not queue \(staged.originalFilename): \(String(describing: error))"
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
    private func runQueue(app: AppModel) async {
        guard !isRunning, let engine = app.engine else { return }
        isRunning = true
        defer {
            isRunning = false
            runningJobID = nil
        }
        while !pending.isEmpty {
            let job = pending.removeFirst()
            runningJobID = job.id
            let jobID = job.id
            if let index = active.firstIndex(where: { $0.id == jobID }) {
                active[index].state = .uploading(uploadId: job.uploadId ?? "")
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
                // Staged copy no longer needed; failed jobs keep theirs for retry.
                try? FileManager.default.removeItem(at: finished.sourceURL)
                active.removeAll { $0.id == jobID }
                onClipsChanged?()
            }
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
