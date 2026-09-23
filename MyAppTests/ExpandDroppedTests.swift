import Foundation
import Testing
@testable import AssetsTransporter

/// `expandDropped` must copy a dropped folder's video children into the temp
/// intake directory WHILE the folder's security scope is held: a child URL of
/// a scoped folder stops being readable once the scope is released, and
/// staging only happens later (after the camera-label sheet).
struct ExpandDroppedTests {
    @Test func folderChildrenAreCopiedToTempIntakeFilteredAndSorted() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appending(path: "ExpandDropped-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try Data("bbb".utf8).write(to: folder.appending(path: "b.mov"))
        try Data("aaa".utf8).write(to: folder.appending(path: "a.mov"))
        try Data("txt".utf8).write(to: folder.appending(path: "notes.txt"))

        let out = ProjectDetailView.expandDropped([folder])
        defer { for url in out { try? fm.removeItem(at: url.deletingLastPathComponent()) } }

        // Videos only, name-sorted, and every result is OUR temp copy (not a
        // child of the scoped folder), preserving the original filename.
        #expect(out.map(\.lastPathComponent) == ["a.mov", "b.mov"])
        for url in out {
            #expect(url.path.hasPrefix(IntakeModel.photoIntakeDirectory.path))
        }
        #expect(try Data(contentsOf: out[0]) == Data("aaa".utf8))
        #expect(try Data(contentsOf: out[1]) == Data("bbb".utf8))
    }

    @Test func directFilesPassThroughUnchanged() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appending(path: "ExpandDropped-\(UUID().uuidString).mov")
        try Data("mov".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        #expect(ProjectDetailView.expandDropped([file]) == [file])
    }
}
