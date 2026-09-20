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
}
