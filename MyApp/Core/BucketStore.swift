import Foundation

/// Reference to a client folder at the bucket root.
nonisolated struct ClientRef: Equatable, Sendable, Identifiable {
    var prefix: String        // "acme-corp-x7f2/" (always trailing slash)
    var displayName: String
    var id: String { prefix }
}

/// Reference to a project folder under a client.
nonisolated struct ProjectRef: Equatable, Sendable, Identifiable {
    var prefix: String        // "acme-corp-x7f2/spring-gala-k9q1/"
    var manifest: ProjectManifest
    var id: String { prefix }
}

/// Reads the self-describing bucket layout: clients at the root, projects under
/// each client, clips (+ `.json` sidecars) under `<project>/clips/`.
/// A missing or unreadable manifest never hides an entry — a fallback is
/// synthesized from the key and listing metadata instead.
nonisolated struct BucketReader: Sendable {
    var client: S3Client

    /// Top-level client folders, sorted by displayName (case-insensitive), then prefix.
    func listClients() async throws -> [ClientRef] {
        let listing = try await client.listObjects(prefix: "", delimiter: "/")
        let refs = await mapConcurrently(listing.commonPrefixes) { prefix in
            let manifest = await fetchManifest(ClientManifest.self, key: prefix + "client.json")
            return ClientRef(prefix: prefix,
                             displayName: manifest?.displayName ?? Self.strippingTrailingSlash(prefix))
        }
        return refs.sorted { a, b in
            switch a.displayName.caseInsensitiveCompare(b.displayName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.prefix < b.prefix
            }
        }
    }

    /// Projects under a client, sorted by (sortIndex ?? Int.max), createdAt, displayName.
    func listProjects(clientPrefix: String) async throws -> [ProjectRef] {
        let clientPrefix = Self.ensuringTrailingSlash(clientPrefix)
        let listing = try await client.listObjects(prefix: clientPrefix, delimiter: "/")
        let refs = await mapConcurrently(listing.commonPrefixes) { prefix in
            let manifest = await fetchManifest(ProjectManifest.self, key: prefix + "project.json")
                ?? ProjectManifest(displayName: Self.lastPathComponent(of: prefix),
                                   sortIndex: nil, createdAt: .distantPast)
            return ProjectRef(prefix: prefix, manifest: manifest)
        }
        return refs.sorted { a, b in
            (a.manifest.sortIndex ?? Int.max, a.manifest.createdAt, a.manifest.displayName)
                < (b.manifest.sortIndex ?? Int.max, b.manifest.createdAt, b.manifest.displayName)
        }
    }

    /// Clips under `<project>/clips/`, each merged with its decoded sidecar when
    /// one exists in the same listing; otherwise (or on decode failure) a fallback
    /// sidecar is synthesized. Ordered by effectiveTime.
    func listClips(projectPrefix: String) async throws -> [Clip] {
        let projectPrefix = Self.ensuringTrailingSlash(projectPrefix)
        let listing = try await client.listObjects(prefix: projectPrefix + "clips/", delimiter: nil)
        let allKeys = Set(listing.objects.map(\.key))
        let clipObjects = listing.objects.filter { BucketKeys.isClipFile($0.key) }

        let clips = await mapConcurrently(clipObjects) { object in
            let sidecarKey = BucketKeys.sidecarKey(forClipKey: object.key)
            let sidecar = allKeys.contains(sidecarKey)
                ? await fetchManifest(ClipSidecar.self, key: sidecarKey)
                : nil
            return Clip(key: object.key, sidecar: sidecar ?? Self.fallbackSidecar(for: object))
        }
        return ClipOrdering.sorted(clips)
    }

    // MARK: - Internals

    /// Fetches and decodes a JSON manifest; nil on any S3 or decode error so
    /// callers can substitute a fallback (unreadable manifests must not hide entries).
    private func fetchManifest<T: Decodable & Sendable>(_ type: T.Type, key: String) async -> T? {
        guard let data = try? await client.getObject(key: key) else { return nil }
        return try? ManifestCoding.decode(T.self, from: data)
    }

    /// Sidecar synthesized for a clip whose sidecar is missing or unreadable
    /// (e.g. still uploading from another device).
    private static func fallbackSidecar(for object: S3Object) -> ClipSidecar {
        let filename = object.key.split(separator: "/").last.map(String.init) ?? object.key
        let baseName = filename.lastIndex(of: ".").map { String(filename[..<$0]) } ?? filename
        return ClipSidecar(displayName: baseName,
                           cameraLabel: nil, notes: nil,
                           capturedAt: BucketKeys.parseClipTimestamp(fromKey: object.key),
                           orderOverride: nil, duration: nil, width: nil, height: nil, codec: nil,
                           fileSize: object.size,
                           originalFilename: filename,
                           sourceDevice: "unknown")
    }

    /// Runs `transform` over `inputs` concurrently, preserving input order.
    private func mapConcurrently<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        transform: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { (index, await transform(input)) }
            }
            var results = [Output?](repeating: nil, count: inputs.count)
            for await (index, output) in group {
                results[index] = output
            }
            return results.compactMap { $0 }
        }
    }

    private static func strippingTrailingSlash(_ prefix: String) -> String {
        prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
    }

    private static func ensuringTrailingSlash(_ prefix: String) -> String {
        prefix.hasSuffix("/") ? prefix : prefix + "/"
    }

    private static func lastPathComponent(of prefix: String) -> String {
        let trimmed = strippingTrailingSlash(prefix)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
