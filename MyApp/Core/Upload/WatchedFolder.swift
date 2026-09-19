#if os(macOS)
import Foundation

nonisolated enum WatchedFolderError: Error, Equatable {
    case cannotOpenDirectory(path: String, code: Int32)
}

/// Watches one directory (non-recursive) for new video files.
///
/// A file only counts as "arrived" once its size has been observed unchanged
/// across two scans spaced at least `stableInterval` apart — recorders write
/// clips incrementally, so a fresh file keeps growing until the take is done.
///
/// Lifecycle: `start()` opens the directory with `O_EVTONLY` and installs a
/// `DispatchSource` for `.write` events (each event triggers a scan); `stop()`
/// cancels the source — the cancel handler closes the file descriptor — and
/// makes further scans no-ops. The event handler captures `self` weakly, so
/// there is no retain cycle even if a caller forgets `stop()`; `deinit` also
/// cancels the source so the descriptor cannot leak.
///
/// Security-scoped bookmark access is the caller's concern (Phase 5); this
/// class only needs a readable directory.
@MainActor
final class WatchedFolder {
    /// Injectable clock so tests can drive the stability handshake deterministically.
    var now: () -> Date = { Date() }

    private let url: URL
    private let videoExtensions: Set<String>
    private let stableInterval: TimeInterval
    private let newVideo: @MainActor (URL) -> Void

    private var source: DispatchSourceFileSystemObject?
    /// Candidates: last observed size and when that size was first seen.
    private var pending: [URL: (size: Int64, firstSeenStable: Date)] = [:]
    /// Paths already reported; never re-fired until the next `start()`.
    private var processed: Set<URL> = []
    private var recheckTask: Task<Void, Never>?
    private var isStopped = false

    /// `newVideo` fires exactly once per new video file whose size has been
    /// stable for `stableInterval`.
    init(url: URL,
         videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mxf"],
         stableInterval: TimeInterval = 2.0,
         newVideo: @escaping @MainActor (URL) -> Void) {
        self.url = url
        self.videoExtensions = Set(videoExtensions.map { $0.lowercased() })
        self.stableInterval = stableInterval
        self.newVideo = newVideo
    }

    deinit {
        // Safety net if a caller drops the instance without stop():
        // cancelling runs the cancel handler, which closes the descriptor.
        source?.cancel()
        recheckTask?.cancel()
    }

    /// Begins watching. Also performs an initial sweep so files already
    /// present when watching starts are noticed.
    func start() throws {
        guard source == nil else { return }
        isStopped = false
        processed.removeAll()
        pending.removeAll()

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw WatchedFolderError.cannotOpenDirectory(path: url.path, code: errno)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.scanNow() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source

        Task { @MainActor [weak self] in await self?.scanNow() }
    }

    /// Cancels the dispatch source (closing the directory descriptor) and any
    /// scheduled re-check; `scanNow()` becomes a no-op until `start()`.
    func stop() {
        isStopped = true
        recheckTask?.cancel()
        recheckTask = nil
        source?.cancel()
        source = nil
        pending.removeAll()
    }

    /// One observation pass. Exposed (rather than private) so tests can drive
    /// the two-scan stability handshake with an injected clock.
    func scanNow() async {
        guard !isStopped else { return }
        let timestamp = now()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []

        var seen: Set<URL> = []
        for item in contents {
            guard videoExtensions.contains(item.pathExtension.lowercased()) else { continue }
            let file = item.standardizedFileURL
            guard !processed.contains(file) else { continue }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize.map(Int64.init) else { continue }
            seen.insert(file)

            if let record = pending[file], record.size == size {
                if timestamp.timeIntervalSince(record.firstSeenStable) >= stableInterval {
                    pending[file] = nil
                    processed.insert(file)
                    newVideo(file)
                }
                // else: unchanged but not stable long enough; keep waiting.
            } else {
                // New candidate, or the size moved: (re)start the stability clock.
                pending[file] = (size: size, firstSeenStable: timestamp)
            }
        }

        // Forget candidates that vanished before stabilizing.
        pending = pending.filter { seen.contains($0.key) }

        scheduleRecheckIfNeeded()
    }

    /// While watching (started, not stopped) with candidates outstanding, poll
    /// again after `stableInterval`: a recorder that finished writing produces
    /// no further `.write` events, so stability must be detected by re-checking.
    /// Tests drive `scanNow()` directly without `start()`, so no background
    /// re-check ever races an injected clock.
    private func scheduleRecheckIfNeeded() {
        recheckTask?.cancel()
        recheckTask = nil
        guard source != nil, !isStopped, !pending.isEmpty else { return }
        let interval = stableInterval
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.scanNow()
        }
    }
}
#endif
