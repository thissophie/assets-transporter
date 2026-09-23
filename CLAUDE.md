# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A multiplatform SwiftUI app (macOS + iOS, deployment target 27.0) that moves event video into
S3-compatible storage and back: upload from Mac/iPhone, browse Client → Project → Clips,
rename/reorder, download, delete. It supports multiple *named servers* (S3 endpoint + bucket +
credentials): on macOS it behaves like a multi-document app — a "Servers" library window plus one
window per open server — and on iOS it swaps between the server list and the chosen server. No AWS SDK — the S3 client is hand-rolled on `URLSession`
with SigV4 signing. Design rationale lives in `docs/plans/2026-09-19-video-transfer-app-design.md`;
open work in `TODO.md`. The Xcode project is `AssetsTransporter.xcodeproj`; the app target,
scheme and source folder are `AssetsTransporter` (renamed from `MyApp` in commit `b85a196`).
The test targets kept their old names: `MyAppTests` (unit) and `MyAppUITests` (XCUITest), and
the entry point is still `AssetsTransporter/MyApp.swift` with `@main struct MyApp`. Both test
bundles build and run under the shared `AssetsTransporter` scheme; the rename is still unfinished
cosmetically (target/bundle-id names) — see the first item in `TODO.md`.

## Building and testing

`xcode-select` on this machine points at Command Line Tools, so bare `xcodebuild` fails.
Prefix every invocation with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. If the
Xcode MCP tools (`BuildProject`, `RunAllTests`, `RunSomeTests`, `XcodeRefreshCodeIssuesInFile`)
are available in the session, prefer them; they were how the project was originally built.

```sh
X="DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
P="AssetsTransporter.xcodeproj"

# Build (macOS)
env $X xcodebuild build -project "$P" -scheme AssetsTransporter -destination 'platform=macOS'

# Build for iOS (catches #if os(iOS) paths)
env $X xcodebuild build -project "$P" -scheme AssetsTransporter -destination 'generic/platform=iOS Simulator'

# All unit tests (Swift Testing, hosted in the AssetsTransporter app).
env $X xcodebuild test -project "$P" -scheme AssetsTransporter -destination 'platform=macOS' -only-testing:MyAppTests

# One suite / one test
env $X xcodebuild test -project "$P" -scheme AssetsTransporter -destination 'platform=macOS' -only-testing:MyAppTests/SlugTests
env $X xcodebuild test -project "$P" -scheme AssetsTransporter -destination 'platform=macOS' -only-testing:MyAppTests/SlugTests/basicSlugging

# Integration suite against a local ministack (skipped unless S3_IT_ENDPOINT is set).
# Needs an empty bucket `it-video`, path-style, any credentials.
env $X xcodebuild test -project "$P" -scheme AssetsTransporter -destination 'platform=macOS' \
  -only-testing:MyAppTests/IntegrationTests TEST_RUNNER_S3_IT_ENDPOINT=http://localhost:4566
```

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `@testable import AssetsTransporter`),
not XCTest. `MyAppUITests` is XCUITest; it shares the `AssetsTransporter` scheme's test action
(it also has its own standalone scheme for running just the UI tests). There is no linter configured.

The project uses Xcode file-system-synchronized groups: any `.swift` file dropped under
`AssetsTransporter/` or `MyAppTests/` is picked up automatically. Never hand-edit `project.pbxproj`.

## Concurrency rules (the #1 compile-error source)

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with approachable concurrency is on. Everything is
main-actor by default, so every type that must run off the main actor — models, S3 client,
stores, engines, pure helpers used from background tasks — must be declared `nonisolated`
(`nonisolated struct ClipSidecar`, `nonisolated enum Slug`, `nonisolated protocol S3Transport`).
Views and `@Observable` view-models stay main-actor. Off-main workers are `actor`s
(`UploadEngine`, `UploadQueueStore`) or `Sendable` structs.

## Architecture

**Self-describing bucket, no index.** Concurrency safety across devices comes from the layout:

```
<client-slug-id>/client.json                             (displayName, optional hidden)
<client-slug-id>/<project-slug-id>/project.json          (displayName, sortIndex, createdAt)
<client-slug-id>/<project-slug-id>/clips/<yyyy-MM-dd_HHmmss>_<camera>_<id>.<ext>
<client-slug-id>/<project-slug-id>/clips/<same key>.json  (ClipSidecar)
<client-slug-id>/<project-slug-id>/clips/<same key>.thumb.jpg  (optional poster frame)
```

Entities are discovered by prefix listing; an entity exists iff its manifest does. Each clip's
metadata lives only in its own sidecar, written strictly *after* the multipart upload completes,
so a clip "exists" only once fully uploaded. The poster-frame thumbnail is PUT just before the
sidecar, best effort: a failure never blocks the sidecar, and older clips have none. Manual clip reorder writes `orderOverride` into
that clip's sidecar; project reorder writes `sortIndex` into each `project.json`. Clip keys are
immutable; renames touch only the sidecar. Keep this contract when adding features — never
introduce a central index or rewrite a sibling's manifest. Timestamps are ISO8601 whole-second
(`ManifestCoding`), and `BucketWriter.createProject` truncates to seconds so it round-trips.

**Layers** (paths below are relative to `AssetsTransporter/`; `Core/` is UI-free and unit-tested;
`UI/` is SwiftUI + `@Observable` models):

- `Core/S3/` — `S3Client` (put/get/delete/list/multipart/listParts) over an `S3Transport`
  protocol. `URLSessionTransport` for macOS, `BackgroundTransport.shared` (background
  `URLSession`, upload-from-file only, continuation table) for iOS. `SigV4` signs, `S3Config`
  builds path- or virtual-host URLs, `S3ListParser` parses ListObjectsV2 XML.
  `S3Client.presignedGetURL` (via `SigV4.presignedURL`) backs in-app streaming, since `AVPlayer`
  can't send `Authorization` headers.
- `Core/BucketKeys`, `Slug`, `Manifests`, `ClipOrdering`, `DownloadNaming` — pure value logic.
- `Core/BucketStore.swift` (`BucketReader`) and `BucketWriter` — read/mutate the layout above.
  Unreadable manifests never hide entries; a fallback is synthesized.
- `Core/Upload/` — `UploadJob` (persisted record; `uploadId` + `completedParts` +
  `multipartCompleted` are the resume source of truth, not `state`), `UploadQueueStore`
  (single JSON file in Application Support, actor-serialized), `UploadEngine` (one job at a
  time; persists every transition before proceeding; resumes via `listParts`; stages ≤64 MB part
  files with chunked reads; writes the thumbnail then the sidecar after completion), `ClipProber`
  (AVFoundation), `ClipThumbnailer` (first-frame JPEG, ≤320 px), `WatchedFolder` (macOS
  DispatchSource).
- `Core/DownloadEngine` — ranged, resumable `getObject` in 32 MB chunks; writes
  `NNN_camera_name.ext` files; whole-project downloads also write a copy of `project.json`.
- `Core/ServerProfile` — `ServerProfile` (`id`, user-chosen `name`, `StoredS3Settings`); identity is
  the id, never the URL. `ServerLocalState` owns the per-server local layout
  (`UploadQueue/<id>/jobs.json`, defaults keys `watchConfig.<id>` / `watchProcessed.<id>`) and the
  one-time migration from the pre-multi-server single settings/queue/watch. `CredentialStore` keeps
  the whole `[ServerProfile]` list in one Keychain item and migrates the legacy item on first load.
- `UI/AppModel` — the server registry: `servers`, add/update/remove/move (Keychain first, then
  memory), and `session(for:)` which lazily builds a `ServerSession` per server and keeps it for
  the app's lifetime (closing a window never stops an upload or a watch). At launch it eagerly
  starts sessions for servers with local background work (persisted watch or queue file) and runs
  the app-wide orphaned-staging sweep across *every* server's queue.
- `UI/ServerSession` — one server's stack: client/reader/writer/engine built from its profile,
  its own `UploadQueueStore`, `IntakeModel`, and (macOS) `WatchManager`; runs the stale-multipart
  sweep on start. `ServerSession.buildStack` is the pure, testable construction point. Editing a
  profile's connection settings rebuilds the stack in place; a rename doesn't.
- `UI/IntakeModel` — stage (copy into `Application Support/Staging`, app-global) → probe →
  enqueue → run sequentially through `ServerSession.engine`, with per-session auto-retry backoff.
  Per server, single `onClipsChanged` slot.
- `UI/ServerListView` (library: open/add/edit/delete/reorder), `ServerEditorView` (create/edit
  sheet with Test Connection; `SettingsValidation` lives here), `ServerWindowView` (resolves the
  session for a server id and injects it as `@Environment(ServerSession.self)`).
- `UI/BrowseModel`, `BrowseViews`, `ProjectDetailView`, `UploadQueueView` — all read the
  `ServerSession` from the environment; navigation is `NavigationSplitView` on macOS, stack on
  iOS; every list supports pull-to-refresh. Downloads are whole-project or a multi-selection of
  clips; clips stream in-app through `AVPlayer` from a presigned URL. Clients can be hidden
  (`client.json` `hidden`, toggled via the context menu; `BrowseModel.showHiddenClients`).
- `UI/RefreshCommands` — macOS View ▸ Refresh ⌘R, forwarding to the focused server window's
  `refreshAction` focused value (published by `BrowseRootView`).
- `MyApp.swift` (the `@main` app struct; the file kept its old name) — macOS scenes:
  `Window("Servers")` (launch window; File ▸ New Server… ⌘N, Window ▸ Servers ⇧⌘0, View ▸ Refresh ⌘R) and
  `WindowGroup(id: "server", for: ServerProfile.ID.self)` (one window per server; reopening the
  same id raises it). iOS: a single `WindowGroup` with `ContentView` (`ContentView.swift` swaps
  between the server list and the chosen server).

**Testing seams.** `S3Transport` is the injection point: `RecordingTransport` in
`S3ClientTests.swift` returns canned responses and captures requests; `FlakyTransport` in
`IntegrationTests.swift` injects failures to prove resume. `UploadJobStoring` lets engine tests
use an in-memory store. `BucketWriter.now` is an injectable clock. Add new network-dependent
logic behind these seams rather than hitting `URLSession` directly.

## Conventions worth knowing

- Commit messages follow `type: summary` (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).
- Sandbox is on with outgoing network and read-write user-selected files; source files opened
  via pickers are held as security-scoped bookmarks on the `UploadJob`.
- `MediaTypes` knows only mov/mp4/m4v/avi/mxf; anything else uploads as octet-stream.
- The XCUITest scenario creates and uses its own server named `E2E ministack`
  (`localhost:4566`, bucket `it-video`); it never edits other saved servers, so running it no
  longer clobbers a real endpoint.
