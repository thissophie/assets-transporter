import Foundation
import Testing
@testable import MyApp

/// Tests the pure intake helpers; the staging/probe/enqueue pipeline is
/// network- and filesystem-coupled and exercised manually / in integration.
struct IntakeModelTests {
    // MARK: - stagedFilename

    @Test func stagedFilenameIsUUIDPlusSanitizedLowercaseExtension() {
        let name = IntakeModel.stagedFilename(
            originalURL: URL(fileURLWithPath: "/tmp/My Clip.MOV"))
        #expect(name.hasSuffix(".mov"))
        let stem = String(name.dropLast(".mov".count))
        #expect(UUID(uuidString: stem) != nil)
    }

    @Test func stagedFilenameWithoutExtensionIsBareUUID() {
        let name = IntakeModel.stagedFilename(originalURL: URL(fileURLWithPath: "/tmp/clip"))
        #expect(UUID(uuidString: name) != nil)
    }

    @Test func stagedFilenamesAreUniquePerCall() {
        let url = URL(fileURLWithPath: "/tmp/a.mp4")
        #expect(IntakeModel.stagedFilename(originalURL: url)
            != IntakeModel.stagedFilename(originalURL: url))
    }

    // MARK: - clipKeyComponents

    @Test func clipKeyComponentsSplitsProjectPrefix() {
        let parts = IntakeModel.clipKeyComponents(fromProjectPrefix: "acme-x1/gala-k9/")
        #expect(parts.client == "acme-x1")
        #expect(parts.project == "gala-k9")
    }

    @Test func clipKeyComponentsToleratesMissingTrailingSlash() {
        let parts = IntakeModel.clipKeyComponents(fromProjectPrefix: "acme-x1/gala-k9")
        #expect(parts.client == "acme-x1")
        #expect(parts.project == "gala-k9")
    }

    @Test func clipKeyComponentsWithClientOnlyPrefixHasEmptyProject() {
        let parts = IntakeModel.clipKeyComponents(fromProjectPrefix: "acme-x1/")
        #expect(parts.client == "acme-x1")
        #expect(parts.project.isEmpty)
    }

    // MARK: - shouldEnqueueRetry
    //
    // `retry` applies this guard twice — synchronously and again after the
    // store-load suspension — so a double-tap can never enqueue the same job
    // twice. Exercising the full double-tap at the model level would need a
    // real AppModel (Keychain + Application Support store), so the decision
    // logic is extracted and tested pure instead.

    @Test func retryAllowedForFailedJobNotRunningOrPending() {
        let id = UUID()
        #expect(IntakeModel.shouldEnqueueRetry(jobID: id, runningJobID: nil,
                                               pendingIDs: [],
                                               jobState: .failed(message: "boom")))
    }

    @Test func retryRejectedWhileSameJobIsRunning() {
        let id = UUID()
        #expect(!IntakeModel.shouldEnqueueRetry(jobID: id, runningJobID: id,
                                                pendingIDs: [], jobState: nil))
    }

    @Test func retryRejectedWhenAlreadyPending() {
        // The double-tap shape: the first tap appended the job, the second
        // tap's re-check must see it in `pending` and bail.
        let id = UUID()
        #expect(!IntakeModel.shouldEnqueueRetry(jobID: id, runningJobID: nil,
                                                pendingIDs: [UUID(), id],
                                                jobState: .failed(message: "boom")))
    }

    @Test func retryRejectedWhenStoredJobAlreadyDone() {
        let id = UUID()
        #expect(!IntakeModel.shouldEnqueueRetry(jobID: id, runningJobID: nil,
                                                pendingIDs: [], jobState: .done))
    }

    // MARK: - resumableJobs / orphanedStagingFiles
    //
    // Pure selection logic for the configure-time maintenance pass: which
    // persisted jobs get re-run, and which staged files are orphans.

    private func makeJob(state: UploadJob.State,
                         sourceURL: URL = URL(fileURLWithPath: "/tmp/x.mov")) -> UploadJob {
        UploadJob(id: UUID(), sourceURL: sourceURL, sourceBookmark: nil,
                  clipKey: "acme/gala/clips/x.mov",
                  sidecar: ClipSidecar(displayName: "X", cameraLabel: nil, notes: nil,
                                       capturedAt: nil, orderOverride: nil, duration: nil,
                                       width: nil, height: nil, codec: nil, fileSize: 1,
                                       originalFilename: "x.mov", sourceDevice: "test"),
                  state: state, partSize: 64, totalSize: 1, completedParts: [:])
    }

    @Test func resumableJobsSelectsWaitingAndUploadingInStoreOrder() {
        let waiting = makeJob(state: .waiting)
        let uploading = makeJob(state: .uploading(uploadId: "u1"))
        let failed = makeJob(state: .failed(message: "boom"))
        let done = makeJob(state: .done)

        let resumable = IntakeModel.resumableJobs(from: [failed, waiting, done, uploading])

        // Failed stays for the user's explicit Retry; done has nothing to do.
        #expect(resumable.map(\.id) == [waiting.id, uploading.id])
    }

    // MARK: - shouldRunDequeuedJob
    //
    // `runQueue` reloads each dequeued job from the store before running it;
    // this pins the skip decision: a job removed while queued (absent) or
    // finished by an earlier run (.done) must not run from a stale snapshot.

    @Test func dequeuedJobSkippedWhenRemovedFromStore() {
        #expect(!IntakeModel.shouldRunDequeuedJob(storedState: nil))
    }

    @Test func dequeuedJobSkippedWhenStoreSaysDone() {
        #expect(!IntakeModel.shouldRunDequeuedJob(storedState: .done))
    }

    @Test func dequeuedJobRunsInAllOtherStoredStates() {
        #expect(IntakeModel.shouldRunDequeuedJob(storedState: .waiting))
        #expect(IntakeModel.shouldRunDequeuedJob(storedState: .uploading(uploadId: "u1")))
        #expect(IntakeModel.shouldRunDequeuedJob(storedState: .failed(message: "boom")))
    }

    @Test func orphanedStagingFilesExcludesJobReferencedSources() {
        let referenced = URL(fileURLWithPath: "/staging/a.mov")
        let orphan = URL(fileURLWithPath: "/staging/b.mov")
        let job = makeJob(state: .failed(message: "boom"), sourceURL: referenced)

        let orphans = IntakeModel.orphanedStagingFiles(files: [referenced, orphan], jobs: [job])

        #expect(orphans == [orphan])
    }
}
