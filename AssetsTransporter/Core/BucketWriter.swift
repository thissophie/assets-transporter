import Foundation

/// What deleting a prefix would remove: how many objects, totalling how many bytes.
nonisolated struct DeletionPreview: Equatable, Sendable {
    var objectCount: Int
    var totalBytes: Int64
}

/// Mutations for the self-describing bucket layout: creating and renaming
/// clients/projects (manifest writes), reordering projects, and sidecar updates.
nonisolated struct BucketWriter: Sendable {
    var client: S3Client
    /// Injectable clock (tests). `createProject` truncates it to whole seconds
    /// so a written createdAt round-trips exactly through ISO8601.
    var now: @Sendable () -> Date = Date.init

    /// Creates `<name-slug>-<shortID>/client.json` and returns a ref to it.
    func createClient(name: String) async throws -> ClientRef {
        let slug = Self.newSlug(for: name)
        try await putManifest(ClientManifest(displayName: name),
                              key: BucketKeys.clientManifestKey(client: slug))
        return ClientRef(prefix: slug + "/", displayName: name)
    }

    /// Creates `<clientPrefix><name-slug>-<shortID>/project.json` and returns a ref to it.
    func createProject(name: String, in clientPrefix: String) async throws -> ProjectRef {
        let prefix = BucketKeys.ensuringTrailingSlash(clientPrefix) + Self.newSlug(for: name) + "/"
        let createdAt = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let manifest = ProjectManifest(displayName: name, sortIndex: nil, createdAt: createdAt)
        try await putManifest(manifest, key: prefix + "project.json")
        return ProjectRef(prefix: prefix, manifest: manifest)
    }

    /// Rewrites just this client's manifest with the new display name,
    /// preserving the hidden flag.
    func renameClient(_ ref: ClientRef, to name: String) async throws {
        try await putManifest(ClientManifest(displayName: name,
                                             hidden: ref.isHidden ? true : nil),
                              key: ref.prefix + "client.json")
    }

    /// Rewrites just this client's manifest with the new hidden flag,
    /// preserving the display name. Visible is written as an absent key so
    /// unhiding restores the pre-feature manifest shape.
    func setClientHidden(_ ref: ClientRef, hidden: Bool) async throws {
        try await putManifest(ClientManifest(displayName: ref.displayName,
                                             hidden: hidden ? true : nil),
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

    // MARK: - Deletion

    /// What a `deletePrefix` would remove: object count and total byte size.
    func deletionPreview(prefix: String) async throws -> DeletionPreview {
        let listing = try await client.listObjects(prefix: BucketKeys.ensuringTrailingSlash(prefix),
                                                   delimiter: nil)
        return DeletionPreview(objectCount: listing.objects.count,
                               totalBytes: listing.objects.reduce(0) { $0 + $1.size })
    }

    /// Deletes the clip file, then its sidecar. A 404 on the sidecar delete is
    /// tolerated (the sidecar may not exist); any other error propagates.
    func deleteClip(_ clip: Clip) async throws {
        try await client.deleteObject(key: clip.key)
        do {
            try await client.deleteObject(key: BucketKeys.sidecarKey(forClipKey: clip.key))
        } catch S3Error.http(status: 404, body: _) {
            // Sidecar was already absent — nothing to clean up.
        }
    }

    /// Deletes each clip in order via `deleteClip`, halting on the first
    /// failure (matching `deletePrefix` semantics) — clips deleted before the
    /// failure stay deleted.
    func deleteClips(_ clips: [Clip]) async throws {
        for clip in clips {
            try await deleteClip(clip)
        }
    }

    /// Deletes every object under `prefix`, sequentially, halting on the first
    /// failure. Used for both projects and clients. The prefix is normalized to
    /// end in "/" so it can never match a sibling folder's keys.
    func deletePrefix(_ prefix: String) async throws {
        let listing = try await client.listObjects(prefix: BucketKeys.ensuringTrailingSlash(prefix),
                                                   delimiter: nil)
        for object in listing.objects {
            try await client.deleteObject(key: object.key)
        }
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
