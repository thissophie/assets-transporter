import Foundation
import Testing
@testable import MyApp

struct DownloadNamingTests {
    private func clip(key: String, displayName: String, cameraLabel: String?) -> Clip {
        Clip(key: key,
             sidecar: ClipSidecar(displayName: displayName, cameraLabel: cameraLabel, notes: nil,
                                  capturedAt: nil, orderOverride: nil,
                                  duration: nil, width: nil, height: nil, codec: nil,
                                  fileSize: 0, originalFilename: key, sourceDevice: "test"))
    }

    @Test func indexWidthCases() {
        #expect(DownloadNaming.indexWidth(count: 9) == 3)
        #expect(DownloadNaming.indexWidth(count: 1200) == 4)
    }

    @Test func filenamesIncludeIndexCameraAndName() {
        let clips = [
            clip(key: "c/p/clips/2026-09-19_183042_cam-a_e51f.mov", displayName: "Intro!", cameraLabel: "Cam A"),
            clip(key: "c/p/clips/2026-09-19_190000_cam_a1b2.mp4", displayName: "Main Talk", cameraLabel: nil),
        ]
        #expect(DownloadNaming.filenames(forOrdered: clips) == ["001_cam-a_intro.mov", "002_main-talk.mp4"])
    }

    @Test func collisionsGetNumericSuffix() {
        let clips = [
            clip(key: "c/p/clips/2026-09-19_183042_cam-a_e51f.mov", displayName: "Intro", cameraLabel: "Cam A"),
            clip(key: "c/p/clips/2026-09-19_183042_cam-a_f62a.mov", displayName: "Intro", cameraLabel: "Cam A"),
        ]
        let names = DownloadNaming.filenames(forOrdered: clips)
        #expect(names == ["001_cam-a_intro.mov", "002_cam-a_intro-2.mov"])
    }

    // Subset filenames keep their FULL-project positions and dedup suffixes,
    // so a partial download slots alongside a whole-project download.
    @Test func selectedFilenamesKeepFullProjectPositions() {
        let clips = [
            clip(key: "c/p/clips/2026-09-19_183042_cam-a_e51f.mov", displayName: "Intro", cameraLabel: "Cam A"),
            clip(key: "c/p/clips/2026-09-19_183042_cam-a_f62a.mov", displayName: "Intro", cameraLabel: "Cam A"),
            clip(key: "c/p/clips/2026-09-19_190000_cam_a1b2.mp4", displayName: "Main Talk", cameraLabel: nil),
        ]
        let picked = DownloadNaming.selectedFilenames(forOrdered: clips,
                                                      selectedKeys: [clips[1].key, clips[2].key])
        #expect(picked.map(\.filename) == ["002_cam-a_intro-2.mov", "003_main-talk.mp4"])
        #expect(picked.map(\.clip.key) == [clips[1].key, clips[2].key])
    }

    @Test func selectedFilenamesWithUnknownKeysIsEmpty() {
        let clips = [
            clip(key: "c/p/clips/2026-09-19_183042_cam-a_e51f.mov", displayName: "Intro", cameraLabel: "Cam A"),
        ]
        #expect(DownloadNaming.selectedFilenames(forOrdered: clips,
                                                 selectedKeys: ["c/p/clips/other.mov"]).isEmpty)
    }
}
