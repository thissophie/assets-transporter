# TODO — AssetsTransporter

Everything in the original design is implemented and verified (see
`docs/plans/2026-09-19-video-transfer-app-design.md`). This is the honest list
of what could come next, compiled from the phase reviews, the final
whole-implementation review, and the E2E pass. Ordered by how soon each will
be felt in real use.

## Before relying on it in the field

- [ ] **Finish the `MyApp` → `AssetsTransporter` rename — cosmetic bits still old.** Commit
  `b85a196` renamed the project, app target, scheme and source folder. Done since: `MyAppTests`'
  `TEST_HOST`/`BUNDLE_LOADER` now point at `AssetsTransporter.app`/`AssetsTransporter`, every test
  file imports `@testable import AssetsTransporter`, both test targets' `DEVELOPMENT_TEAM` matches
  the app's (a mismatch there made the test bundle fail to load with a code-signature Team ID
  error), and a shared `AssetsTransporter.xcscheme` now has a Test action covering both `MyAppTests`
  and `MyAppUITests` (189 tests discovered; unit tests pass, `IntegrationTests` skip without
  `S3_IT_ENDPOINT`, `MyAppUITests` fails without the E2E ministack — all expected). Still old:
  the test target names, the `@main` struct and its file `MyApp.swift`, the `MyAppTests` bundle id
  (`devplaceholder.…MyApp.MyAppTests`), the `MyAppUITests` bundle id (`com.yourcompany.MyAppUITests`),
  and the app bundle id `com.tamatekapua.AssetTransporter` (no "s"). Fix in Xcode (never by
  hand-editing `project.pbxproj`) if these are worth chasing further.

- [ ] **Verify iPhone background uploads on a real device.** The background
  `URLSession` transport and the relaunch handler (`AppDelegate` in
  `AssetsTransporter/MyApp.swift`) are wired but only build-verified — the simulator can't
  exercise the OS-kills-and-relaunches path. One real-device test with a large
  upload and a force-suspend would confirm the story. Related known limitation:
  orphaned background tasks are not re-associated with jobs after relaunch;
  recovery falls back to `listParts` resume on next foreground launch (safe,
  just not seamless). `Core/Upload/BackgroundTransport.swift`.
- [ ] **Test iOS project reorder on device.** Drag-reorder fell back to
  `ForEach.onMove` because the modern `reorderable()`/`reorderContainer` API
  blocks List selection on macOS (framework defect — see comment in
  `UI/BrowseViews.swift`). macOS is XCUITest-verified; iOS long-press reorder
  is not.
- [ ] **Enable bucket versioning on the real provider.** The app has no trash;
  deletion is immediate. Versioning was always the intended safety net. (Not
  app work — provider configuration.)
- [ ] **Check the migrated server after first launch.** The single pre-multi-
  server settings blob is migrated into a named profile ("<bucket> on <host>")
  on first launch, along with its queue file and watch config. Rename it, and
  add the real endpoint as its own server; a stale `~/WatchDrop` watch config
  on the migrated server will warn until stopped or re-pointed.

## Features deferred from the plan

- [x] **Per-clip download selection.** Done 2026-09-22: row multi-select with
  download/delete of just the selected clips
  (`docs/plans/2026-09-22-clip-multi-select-design.md`).
- [x] **Remote clip thumbnails.** Done: the upload engine writes a best-effort
  `<clip key>.thumb.jpg` poster frame (`Core/Upload/ClipThumbnailer.swift`)
  just before the sidecar, and the clip list shows it. Clips uploaded before
  the feature still show the static video icon; backfilling them would need
  ranged GETs of the moov atom.
- [ ] **Batch deletion (`DeleteObjects`).** `deletePrefix` deletes one object
  per request; a 500-object client is 500 round trips. Add the S3 batch-delete
  call (≤1000 keys/request) to `S3Client` and use it in
  `Core/BucketWriter.swift`.

## UX improvements

- [ ] **Finer upload progress.** Progress ticks once per 64 MB part — a 1 GB
  clip has 16 jumps and nothing moves during a part. Needs per-task byte
  progress surfaced through the `S3Transport` abstraction (e.g. an optional
  progress callback on `perform`, fed by `URLSessionTask.progress`).
- [ ] **Re-check VoiceOver on form fields.** The E2E pass found fields named
  only by placeholders. Every `TextField`/`SecureField` (server editor,
  create/rename alerts, camera-label and clip edit sheets) now has a title,
  which SwiftUI uses as the accessibility label — confirm with VoiceOver and
  close. The queue badge and chevrons were already fixed.
- [ ] **Surface maintenance results better.** The stale-upload sweep and
  staging-orphan cleanup report only into the Upload Queue footer
  (`maintenanceNote`) — easy to never see. Consider a transient toast or a
  line in the Servers window.
- [ ] **Camera-label prompt for watched folders.** The watch uses the
  session's last camera label without prompting (documented choice, since the
  watch runs unattended). A per-watch label in the watch setup flow would be
  more predictable — `UI/WatchManager.swift` already persists
  `WatchConfig.cameraLabel`.
- [ ] **Two windows on the same server.** Servers each get one window
  (reopening raises it), so this can't happen from the UI today — but
  `IntakeModel.onClipsChanged` is still a single-slot callback per server; if
  per-server multi-window is ever added, make it a set of observers.
- [ ] **UI-test the multi-window flow on a real ministack.** The XCUITest
  scenario was rewritten around the "E2E ministack" server (create in the
  Servers window → double-click to open its window) and compiles, but it needs
  the ministack + `~/WatchDrop` harness to run; it has not been re-run since.
- [ ] **iPad multi-scene.** iOS swaps the server list and one server in place
  (`ContentView`); iPad could open servers as separate scenes like macOS.

## Hardening / internals

- [ ] **Pagination loop caps.** `listObjects` / `listParts` /
  `listMultipartUploads` follow truncation tokens with no iteration cap; a
  broken server repeating a token loops forever. Add a same-token check or a
  page cap that errors instead of hanging. `Core/S3/S3Client.swift`.
- [ ] **Cap stored `S3Error.http` bodies** (e.g. first 4 KB). Never shown in
  UI (`ErrorText` strips bodies) but held in memory/job messages uncapped.
- [ ] **Streaming `getObject`.** Downloads are already bounded by 32 MB
  chunking in `DownloadEngine`, so memory is flat in practice — the gap is
  only for hypothetical un-ranged GETs of huge objects.
- [ ] **Extract and unit-test `BackgroundTransport`'s inflight table.** The
  lock/continuation bookkeeping (exactly-once resume, invalidation drain) is
  the testable core of an otherwise untestable class (~40-line extraction,
  suggested in the Phase 4 review).
- [ ] **Merge the two XML collector delegates** (`XMLCollector` in
  `S3Client.swift` vs `S3ListParser.Delegate`). Harmless duplication.
- [ ] **Widen `MediaTypes`.** Five known extensions (mov/mp4/m4v/avi/mxf);
  anything else uploads as `application/octet-stream`, and the file importer
  permits `.item`. Add codecs you actually shoot (e.g. `mts`, `braw`, `crm`)
  as they come up.
- [ ] **Off-main folder-drop copies show progress.** Cross-volume folder drops
  (SD cards) copy on a background task with a "Preparing dropped files…"
  spinner, but there's no per-file progress or cancel for a 100 GB card.

## Notes / accepted trade-offs (no action planned)

- The 48 h stale-upload sweep aborts any unowned multipart upload in the
  bucket — correct for an app-owned bucket; don't share the bucket with other
  multipart-uploading tools.
- Intake stages (copies) every file before upload; ingesting a full card needs
  comparable free disk until uploads complete. Required on iOS (background
  sessions upload from files); accepted on macOS for one code path.
- Auto-retry attempts (4, backoff 5 s→5 min) reset per session by design;
  jobs are never dropped and manual Retry always works.
- ISO8601 timestamps in manifests/sidecars are whole-second precision — a
  deliberate bucket-format contract; clip ordering tie-breaks on key.
- Watched-folder processed log caps at the most recent 1000 files.
- `deleteClip`'s sidecar/thumbnail-404 tolerance never fires against real S3 (deletes of
  missing keys return 204) — kept for stricter S3-compatible backends.
