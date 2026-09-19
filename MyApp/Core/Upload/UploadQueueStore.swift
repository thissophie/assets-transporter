import Foundation

/// Persists the upload queue as a single JSON file so jobs survive relaunches.
/// Local state only; corruption degrades to an empty queue rather than crashing.
nonisolated struct UploadQueueStore: Sendable {
    var directory: URL

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
