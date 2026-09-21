# TODO — Video Transfer App

Everything in the original design is implemented and verified (see
`docs/plans/2026-09-19-video-transfer-app-design.md`). This is the honest list
of what could come next, compiled from the phase reviews, the final
whole-implementation review, and the E2E pass. Ordered by how soon each will
be felt in real use.

## Before relying on it in the field

- [ ] **Verify iPhone background uploads on a real device.** The background
  `URLSession` transport and the relaunch handler (`AppDelegate` in
  `MyApp.swift`) are wired but only build-verified — the simulator can't
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
- [ ] **Re-point Settings at the real endpoint.** The app is currently
  configured against the local ministack (`localhost:4566` / `it-video`), and
  a stale `~/WatchDrop` watch config will warn until stopped or re-pointed.

## Features deferred from the plan

- [ ] **Per-clip download selection.** Downloads are whole-project only
  (deliberate deferral, noted in `UI/ProjectDetailView.swift`). Add row
  selection + a "Download Selected…" action reusing the same
  `DownloadEngine`/`DownloadNaming` path.
- [ ] **Remote clip thumbnails.** Remote clips show a static video icon; only
  in-flight uploads get real frames (from their local staged file). Real
  thumbnails need ranged GETs of the moov atom or server-side stills — or
  cheapest: upload a small JPEG poster next to the sidecar at intake time,
  which fits the bucket's self-describing design.
- [ ] **Batch deletion (`DeleteObjects`).** `deletePrefix` deletes one object
  per request; a 500-object client is 500 round trips. Add the S3 batch-delete
  call (≤1000 keys/request) to `S3Client` and use it in
  `Core/BucketWriter.swift`.

## UX improvements

- [ ] **Finer upload progress.** Progress ticks once per 64 MB part — a 1 GB
  clip has 16 jumps and nothing moves during a part. Needs per-task byte
  progress surfaced through the `S3Transport` abstraction (e.g. an optional
  progress callback on `perform`, fed by `URLSessionTask.progress`).
- [ ] **VoiceOver labels on form fields.** Settings, create/rename alerts, and
  the clip edit sheet rely on placeholders/prompts, so fields are unnamed to
  VoiceOver (E2E finding). The queue badge and chevrons were already fixed.
- [ ] **Surface maintenance results better.** The stale-upload sweep and
  staging-orphan cleanup report only into the Upload Queue footer
  (`maintenanceNote`) — easy to never see. Consider a transient toast or a
  line in Settings.
- [ ] **Camera-label prompt for watched folders.** The watch uses the
  session's last camera label without prompting (documented choice, since the
  watch runs unattended). A per-watch label in the watch setup flow would be
  more predictable — `UI/WatchManager.swift` already persists
  `WatchConfig.cameraLabel`.
- [ ] **Multi-window macOS support.** `IntakeModel.onClipsChanged` is a
  single-slot callback and intake state is app-global; a second window on a
  different project would steal the refresh hook. Fine single-window.

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
- `deleteClip`'s sidecar-404 tolerance never fires against real S3 (deletes of
  missing keys return 204) — kept for stricter S3-compatible backends.
