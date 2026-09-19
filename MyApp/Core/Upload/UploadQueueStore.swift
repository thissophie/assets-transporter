import Foundation

/// Persistence interface for the upload queue. Async so implementations can
/// serialize access (actor isolation) without blocking callers.
nonisolated protocol UploadJobStoring: Sendable {
    func load() async -> [UploadJob]
    func save(_ jobs: [UploadJob]) async throws
    func update(_ job: UploadJob) async throws
}

/// Persists the upload queue as a single JSON file so jobs survive relaunches.
/// Local state only; corruption degrades to an empty queue rather than crashing.
/// An actor so concurrent load-modify-save cycles serialize instead of racing
/// (two interleaved `update` calls can no longer drop each other's writes).
actor UploadQueueStore: UploadJobStoring {
    nonisolated let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "UploadQueue",
                                                                    directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appending(path: "jobs.json") }

    /// Missing or unreadable state is treated as an empty queue; never throws.
    func load() -> [UploadJob] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? ManifestCoding.decode([UploadJob].self, from: data)) ?? []
    }

    func save(_ jobs: [UploadJob]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ManifestCoding.encode(jobs)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Replaces the stored job with the same id, or appends it if unknown.
    func update(_ job: UploadJob) throws {
        var jobs = load()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        try save(jobs)
    }
}
