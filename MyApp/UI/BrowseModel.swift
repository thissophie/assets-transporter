import Foundation
import Observation

/// Browsing state for the client/project hierarchy: cached listings plus the
/// loading/offline/error flags the browse views render. All bucket calls go
/// through here so the views stay declarative.
///
/// Offline semantics: a *refresh* failure while cached data exists flips
/// `isOffline` (banner) instead of surfacing an error; any successful refresh
/// clears it. Refresh failures with nothing cached, and all mutation
/// failures, surface in `lastError` (dismissible).
@Observable @MainActor final class BrowseModel {
    private(set) var clients: [ClientRef] = []
    private(set) var projectsByClient: [String: [ProjectRef]] = [:]

    /// True while any refresh or mutation is running.
    var isLoading: Bool { activeOperations > 0 }
    /// True while a *mutation* (create/rename/reorder) is in flight — used to
    /// disable mutating controls so writes don't interleave.
    private(set) var isMutating = false
    /// Most recent failure, shown once and dismissible in the UI.
    var lastError: String?
    /// Set when a refresh fails but cached data is still on screen.
    private(set) var isOffline = false

    private var activeOperations = 0

    func projects(for clientPrefix: String) -> [ProjectRef] {
        projectsByClient[clientPrefix] ?? []
    }

    // MARK: - Refresh

    func refreshClients(reader: BucketReader) async {
        activeOperations += 1
        defer { activeOperations -= 1 }
        do {
            clients = try await reader.listClients()
            isOffline = false
        } catch {
            // A refresh cancelled by view teardown is not a failure.
            if Self.isCancellation(error) { return }
            if clients.isEmpty {
                lastError = "Could not load clients: \(ErrorText.describe(error))"
            } else {
                isOffline = true
            }
        }
    }

    func refreshProjects(reader: BucketReader, clientPrefix: String) async {
        activeOperations += 1
        defer { activeOperations -= 1 }
        do {
            projectsByClient[clientPrefix] = try await reader.listProjects(clientPrefix: clientPrefix)
            isOffline = false
        } catch {
            // A refresh cancelled by view teardown is not a failure.
            if Self.isCancellation(error) { return }
            if projectsByClient[clientPrefix]?.isEmpty == false {
                isOffline = true
            } else {
                lastError = "Could not load projects: \(ErrorText.describe(error))"
            }
        }
    }

    // MARK: - Mutations (write, then refresh the affected level)

    func createClient(name: String, writer: BucketWriter, reader: BucketReader) async {
        await mutate {
            _ = try await writer.createClient(name: name)
            await self.refreshClients(reader: reader)
        }
    }

    func createProject(name: String, in clientPrefix: String,
                       writer: BucketWriter, reader: BucketReader) async {
        await mutate {
            _ = try await writer.createProject(name: name, in: clientPrefix)
            await self.refreshProjects(reader: reader, clientPrefix: clientPrefix)
        }
    }

    func renameClient(_ ref: ClientRef, to name: String,
                      writer: BucketWriter, reader: BucketReader) async {
        await mutate {
            try await writer.renameClient(ref, to: name)
            await self.refreshClients(reader: reader)
        }
    }

    func renameProject(_ ref: ProjectRef, to name: String, in clientPrefix: String,
                       writer: BucketWriter, reader: BucketReader) async {
        await mutate {
            try await writer.renameProject(ref, to: name)
            await self.refreshProjects(reader: reader, clientPrefix: clientPrefix)
        }
    }

    /// Deletes every object under the client's prefix, then refreshes the
    /// client list. Halts on the first failure (surfaced in `lastError`), in
    /// which case the refresh shows whatever survived.
    func deleteClient(prefix: String, writer: BucketWriter, reader: BucketReader) async {
        await mutate {
            try await writer.deletePrefix(prefix)
            await self.refreshClients(reader: reader)
        }
    }

    /// Deletes every object under the project's prefix, then refreshes that
    /// client's project list.
    func deleteProject(prefix: String, in clientPrefix: String,
                       writer: BucketWriter, reader: BucketReader) async {
        await mutate {
            try await writer.deletePrefix(prefix)
            await self.refreshProjects(reader: reader, clientPrefix: clientPrefix)
        }
    }

    /// Applies the reorder locally first (optimistic), then persists
    /// sortIndex for *all* refs in their new order, then refreshes. On write
    /// failure the snapshot is restored and the error surfaced.
    func moveProjects(in clientPrefix: String, from: IndexSet, to: Int,
                      writer: BucketWriter, reader: BucketReader) async {
        guard let snapshot = projectsByClient[clientPrefix] else { return }
        let newOrder = Self.reordered(snapshot, from: from, to: to)
        guard newOrder != snapshot else { return }
        projectsByClient[clientPrefix] = newOrder
        activeOperations += 1
        isMutating = true
        defer {
            activeOperations -= 1
            isMutating = false
        }
        do {
            try await writer.setProjectOrder(newOrder)
            await refreshProjects(reader: reader, clientPrefix: clientPrefix)
        } catch {
            projectsByClient[clientPrefix] = snapshot
            lastError = "Could not save the new order: \(ErrorText.describe(error))"
        }
    }

    /// `items` with the elements at `from` moved to offset `to`. Same
    /// semantics as SwiftUI's `move(fromOffsets:toOffset:)`: `to` is an offset
    /// into the array *before* removal. Implemented here so the model (and its
    /// tests) stay Foundation-only.
    nonisolated static func reordered(_ items: [ProjectRef], from: IndexSet, to: Int) -> [ProjectRef] {
        let clampedTo = min(max(to, 0), items.count)
        let moved = from.compactMap { items.indices.contains($0) ? items[$0] : nil }
        var remaining = items.enumerated()
            .filter { !from.contains($0.offset) }
            .map(\.element)
        let removedBefore = from.count(in: 0..<clampedTo)
        remaining.insert(contentsOf: moved, at: clampedTo - removedBefore)
        return remaining
    }

    // MARK: - Internals

    private func mutate(_ body: () async throws -> Void) async {
        activeOperations += 1
        isMutating = true
        defer {
            activeOperations -= 1
            isMutating = false
        }
        do {
            try await body()
        } catch {
            lastError = ErrorText.describe(error)
        }
    }

    /// True for task/URL-session cancellation (view teardown), which is not
    /// a user-facing failure.
    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
