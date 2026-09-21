# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A multiplatform SwiftUI app (macOS + iOS, deployment target 27.0) that moves event video into
S3-compatible storage and back: upload from Mac/iPhone, browse Client → Project → Clips,
rename/reorder, download, delete. No AWS SDK — the S3 client is hand-rolled on `URLSession`
with SigV4 signing. Design rationale lives in `docs/plans/2026-09-19-video-transfer-app-design.md`;
open work in `TODO.md`. The Xcode project is literally named `Untitled Project.xcodeproj`; the
app target and module are `MyApp`.

## Building and testing

`xcode-select` on this machine points at Command Line Tools, so bare `xcodebuild` fails.
Prefix every invocation with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(quote the project path — it contains a space). If the Xcode MCP tools (`BuildProject`,
`RunAllTests`, `RunSomeTests`, `XcodeRefreshCodeIssuesInFile`) are available in the session,
prefer them; they were how the project was originally built.

```sh
X="DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
P="Untitled Project.xcodeproj"

# Build (macOS)
env $X xcodebuild build -project "$P" -scheme MyApp -destination 'platform=macOS'

# Build for iOS (catches #if os(iOS) paths)
env $X xcodebuild build -project "$P" -scheme MyApp -destination 'generic/platform=iOS Simulator'

# All unit tests (Swift Testing, hosted in MyApp)
env $X xcodebuild test -project "$P" -scheme MyApp -destination 'platform=macOS' -only-testing:MyAppTests

# One suite / one test
env $X xcodebuild test -project "$P" -scheme MyApp -destination 'platform=macOS' -only-testing:MyAppTests/SlugTests
env $X xcodebuild test -project "$P" -scheme MyApp -destination 'platform=macOS' -only-testing:MyAppTests/SlugTests/basicSlugging

# Integration suite against a local ministack (skipped unless S3_IT_ENDPOINT is set).
# Needs an empty bucket `it-video`, path-style, any credentials.
env $X xcodebuild test -project "$P" -scheme MyApp -destination 'platform=macOS' \
  -only-testing:MyAppTests/IntegrationTests TEST_RUNNER_S3_IT_ENDPOINT=http://localhost:4566
```

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `@testable import MyApp`), not
XCTest. `MyAppUITests` is XCUITest and has its own scheme. There is no linter configured.

The project uses Xcode file-system-synchronized groups: any `.swift` file dropped under
`MyApp/` or `MyAppTests/` is picked up automatically. Never hand-edit `project.pbxproj`.

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
<client-slug-id>/client.json
<client-slug-id>/<project-slug-id>/project.json          (displayName, sortIndex, createdAt)
<client-slug-id>/<project-slug-id>/clips/<yyyy-MM-dd_HHmmss>_<camera>_<id>.<ext>
<client-slug-id>/<project-slug-id>/clips/<same key>.json  (ClipSidecar)
```

Entities are discovered by prefix listing; an entity exists iff its manifest does. Each clip's
metadata lives only in its own sidecar, written strictly *after* the multipart upload completes,
so a clip "exists" only once fully uploaded. Manual clip reorder writes `orderOverride` into
that clip's sidecar; project reorder writes `sortIndex` into each `project.json`. Clip keys are
immutable; renames touch only the sidecar. Keep this contract when adding features — never
introduce a central index or rewrite a sibling's manifest. Timestamps are ISO8601 whole-second
(`ManifestCoding`), and `BucketWriter.createProject` truncates to seconds so it round-trips.

**Layers** (`MyApp/Core` is UI-free and unit-tested; `MyApp/UI` is SwiftUI + `@Observable` models):

- `Core/S3/` — `S3Client` (put/get/delete/list/multipart/listParts) over an `S3Transport`
  protocol. `URLSessionTransport` for macOS, `BackgroundTransport.shared` (background
  `URLSession`, upload-from-file only, continuation table) for iOS. `SigV4` signs, `S3Config`
  builds path- or virtual-host URLs, `S3ListParser` parses ListObjectsV2 XML.
- `Core/BucketKeys`, `Slug`, `Manifests`, `ClipOrdering`, `DownloadNaming` — pure value logic.
- `Core/BucketStore.swift` (`BucketReader`) and `BucketWriter` — read/mutate the layout above.
  Unreadable manifests never hide entries; a fallback is synthesized.
- `Core/Upload/` — `UploadJob` (persisted record; `uploadId` + `completedParts` +
  `multipartCompleted` are the resume source of truth, not `state`), `UploadQueueStore`
  (single JSON file in Application Support, actor-serialized), `UploadEngine` (one job at a
  time; persists every transition before proceeding; resumes via `listParts`; stages ≤64 MB part
  files with chunked reads), `ClipProber` (AVFoundation), `WatchedFolder` (macOS DispatchSource).
- `Core/DownloadEngine` — ranged, resumable `getObject` in 32 MB chunks; writes
  `NNN_camera_name.ext` files plus a copy of `project.json`.
- `UI/AppModel` — builds the whole stack from `StoredS3Settings` (Keychain via
  `CredentialStore`); owns the single `UploadQueueStore`, `IntakeModel`, and (macOS) `WatchManager`.
  Runs a maintenance pass on configure (aborts unowned multipart uploads older than 48 h, deletes
  orphaned staging files). `AppModel.buildStack` is the pure, testable construction point.
- `UI/IntakeModel` — stage (copy into `Application Support/Staging`) → probe → enqueue → run
  sequentially through `AppModel.engine`, with per-session auto-retry backoff. App-global, single
  `onClipsChanged` slot.
- `UI/BrowseModel`, `BrowseViews`, `ProjectDetailView`, `UploadQueueView`, `SettingsView` — the
  navigation is `NavigationSplitView` on macOS, stack on iOS; downloads are whole-project only.

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
- The app is currently pointed at the local ministack (`localhost:4566`, bucket `it-video`) in
  saved settings — see `TODO.md` before assuming a real endpoint.
