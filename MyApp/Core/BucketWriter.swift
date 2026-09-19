import Foundation

/// Mutations for the self-describing bucket layout: creating and renaming
/// clients/projects (manifest writes), reordering projects, and sidecar updates.
nonisolated struct BucketWriter: Sendable {
    var client: S3Client

    /// Creates `<name-slug>-<shortID>/client.json` and returns a ref to it.
    func createClient(name: String) async throws -> ClientRef {
        let slug = Self.newSlug(for: name)
        try await putManifest(ClientManifest(displayName: name),
                              key: BucketKeys.clientManifestKey(client: slug))
        return ClientRef(prefix: slug + "/", displayName: name)
    }

    /// Creates `<clientPrefix><name-slug>-<shortID>/project.json` and returns a ref to it.
    func createProject(name: String, in clientPrefix: String) async throws -> ProjectRef {
        let clientPrefix = clientPrefix.hasSuffix("/") ? clientPrefix : clientPrefix + "/"
        let prefix = clientPrefix + Self.newSlug(for: name) + "/"
        let manifest = ProjectManifest(displayName: name, sortIndex: nil, createdAt: Date())
        try await putManifest(manifest, key: prefix + "project.json")
        return ProjectRef(prefix: prefix, manifest: manifest)
    }

    /// Rewrites just this client's manifest with the new display name.
    func renameClient(_ ref: ClientRef, to name: String) async throws {
        try await putManifest(ClientManifest(displayName: name),
                              key: ref.prefix + "client.json")
    }

    /// Rewrites just this project's manifest with the new display name,
    /// preserving sortIndex and createdAt.
    func renameProject(_ ref: ProjectRef, to name: String) async throws {
        var manifest = ref.manifest
        manifest.displayName = name
        try await putManifest(manifest, key: ref.prefix + "project.json")
    }

    /// Writes sortIndex = array position to each project's manifest,
    /// preserving displayName and createdAt.
    func setProjectOrder(_ refs: [ProjectRef]) async throws {
        for (index, ref) in refs.enumerated() {
            var manifest = ref.manifest
            manifest.sortIndex = index
            try await putManifest(manifest, key: ref.prefix + "project.json")
        }
    }

    /// Puts the encoded sidecar at `<clipKey>.json`.
    func updateClipSidecar(clipKey: String, sidecar: ClipSidecar) async throws {
        try await putManifest(sidecar, key: BucketKeys.sidecarKey(forClipKey: clipKey))
    }

    // MARK: - Internals

    private func putManifest(_ manifest: some Encodable & Sendable, key: String) async throws {
        try await client.putObject(key: key, data: ManifestCoding.encode(manifest),
                                   contentType: "application/json")
    }

    private static func newSlug(for name: String) -> String {
        var rng = SystemRandomNumberGenerator()
        return Slug.slugWithID(name, id: Slug.shortID(using: &rng))
    }
}
