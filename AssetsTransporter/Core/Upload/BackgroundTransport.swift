import Foundation

nonisolated enum BackgroundTransportError: Error, Equatable {
    /// The in-memory request body could not be written to a temporary file.
    case cannotStageBody(String)
}

/// `S3Transport` backed by a background `URLSession`, so uploads keep running
/// while the app is suspended and the app is relaunched when they finish.
/// Compiles on both iOS and macOS (background sessions exist on both), so no
/// platform conditionals are needed; the launch-event plumbing simply never
/// fires on macOS, where the process is not suspended.
///
/// Background sessions impose two constraints this class works around:
///
///  1. Delegate-based callbacks only — the async/await conveniences are
///     unavailable. `perform` bridges the delegate machinery to async via a
///     lock-protected table of checked continuations keyed by task identifier.
///     Every continuation resumes exactly once: completion removes the entry
///     under the lock before resuming, and session invalidation drains
///     whatever remains.
///
///  2. Upload-from-file only — in-memory bodies (`httpBody`) are ignored by
///     background sessions. `perform` therefore stages any `httpBody` to a
///     temporary file and uploads from it (deleting it afterwards); bodyless
///     requests (GET / DELETE / POST `?uploads`) upload from an empty staged
///     file, which S3 treats identically to no body — the SigV4 signature
///     already covers the empty payload hash, so signatures stay valid. This
///     is the simplest approach that keeps every `S3Client` operation working
///     unchanged on this transport.
///
/// Relaunch plumbing: when the system relaunches the app for
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`,
/// store the completion handler in `shared.backgroundCompletionHandler`; it is
/// invoked on the main actor from
/// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
///
/// Known limitation (this phase): after an app relaunch, the recreated session
/// may still hold tasks from the previous run that no longer have a waiting
/// continuation. Their delegate callbacks are ignored here ("orphaned" tasks);
/// correctness is recovered by `UploadEngine`'s listParts-based resume, which
/// re-discovers server-side parts and re-uploads only what is missing. Full
/// re-association of orphaned tasks with persisted jobs is future work.
nonisolated final class BackgroundTransport: NSObject, S3Transport, URLSessionDataDelegate, @unchecked Sendable {

    static let shared = BackgroundTransport()

    static let sessionIdentifier = "video-transfer.upload"

    private struct Inflight {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var data = Data()
    }

    private let lock = NSLock()
    private var inflight: [Int: Inflight] = [:]
    private var storedCompletionHandler: (@Sendable () -> Void)?
    private var session: URLSession!

    /// Stored by the app delegate on background relaunch; invoked on the main
    /// actor once the session has delivered all queued events.
    var backgroundCompletionHandler: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedCompletionHandler }
        set { lock.lock(); storedCompletionHandler = newValue; lock.unlock() }
    }

    /// Use `shared`: a background session identifier must map to exactly one
    /// live session, so a second instance would corrupt delegate delivery.
    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "BackgroundTransport.delegate"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    // MARK: - S3Transport

    func perform(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let fileURL: URL
        var staged: URL?

        if let uploadFile {
            fileURL = uploadFile
        } else {
            // Stage the in-memory body (or an empty one for bodyless methods)
            // to a temp file: background sessions only upload from files.
            let stagedURL = FileManager.default.temporaryDirectory
                .appending(path: "bg-body-\(UUID().uuidString)")
            do {
                try (request.httpBody ?? Data()).write(to: stagedURL)
            } catch {
                throw BackgroundTransportError.cannotStageBody(String(describing: error))
            }
            request.httpBody = nil
            staged = stagedURL
            fileURL = stagedURL
        }
        // Runs after the continuation resumes, so the file outlives the task.
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }

        let task = session.uploadTask(with: request, fromFile: fileURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                inflight[task.taskIdentifier] = Inflight(continuation: continuation)
                lock.unlock()
                task.resume()
                // Pre-cancelled race: if the awaiting Task was cancelled before
                // this body ran, `onCancel` already fired — its `task.cancel()`
                // hit a task that had never been resumed and may be dropped
                // without a completion callback, which would leave this
                // continuation waiting forever. Re-issue the cancel now that
                // the task is running so didCompleteWithError(.cancelled) is
                // guaranteed to arrive and resume the continuation (exactly
                // once — completion removes the entry under the lock).
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            // Cancelling surfaces as didCompleteWithError(URLError.cancelled),
            // which resumes the continuation through the normal path.
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        inflight[dataTask.taskIdentifier]?.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let entry = inflight.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        // No entry: an orphaned task from a previous app run (see class comment).
        guard let entry else { return }
        if let error {
            entry.continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse {
            entry.continuation.resume(returning: (entry.data, http))
        } else {
            entry.continuation.resume(throwing: S3Error.badResponse)
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        lock.lock()
        let entries = inflight
        inflight.removeAll()
        lock.unlock()
        for entry in entries.values {
            entry.continuation.resume(throwing: error ?? URLError(.cancelled))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = storedCompletionHandler
        storedCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }
        // UIKit requires this handler to run on the main thread.
        Task { @MainActor in handler() }
    }
}
