import Foundation
import Testing
@testable import AssetsTransporter

/// Tests the pure reorder helper; the rest of BrowseModel is network-coupled
/// and exercised manually / in integration.
struct BrowseModelTests {
    private func project(_ name: String) -> ProjectRef {
        ProjectRef(prefix: "client-a1b2/\(name)/",
                   manifest: ProjectManifest(displayName: name, sortIndex: nil,
                                             createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private var abc: [ProjectRef] { [project("a"), project("b"), project("c")] }

    @Test func moveDown() {
        let result = BrowseModel.reordered(abc, from: IndexSet(integer: 0), to: 3)
        #expect(result.map(\.manifest.displayName) == ["b", "c", "a"])
    }

    @Test func moveUp() {
        let result = BrowseModel.reordered(abc, from: IndexSet(integer: 2), to: 0)
        #expect(result.map(\.manifest.displayName) == ["c", "a", "b"])
    }

    @Test func noOpMoveLeavesOrderUnchanged() {
        let result = BrowseModel.reordered(abc, from: IndexSet(integer: 1), to: 1)
        #expect(result.map(\.manifest.displayName) == ["a", "b", "c"])
    }
}
