# Clip multi-select: download / delete just the selected clips

2026-09-22. Implements the "Per-clip download selection" deferral from
`TODO.md`, plus multi-delete. All changes are in `UI/ProjectDetailView.swift`
plus two small `Core/` additions; the bucket contract is untouched.

## Decisions (confirmed with the user)

- **macOS interaction**: standard list behavior — single click selects
  (⌘-click / ⇧-click extend), double-click plays. This replaces the current
  tap-to-play row gesture. The per-row ⓘ edit button stays.
- **Partial-download numbering**: filenames keep their *full-project*
  positions. Selecting clips #3 and #7 downloads `003_…` and `007_…` (same
  dedup suffixes too), so partial downloads slot alongside a full download.

## UI (`ProjectDetailView`)

- `List(selection:)` bound to `Set<Clip.ID>` (`Clip.ID` is the object key).
  Upload rows are `.selectionDisabled()`.
- The row-level tap gesture and context menu are replaced by a list-level
  `.contextMenu(forSelectionType: Clip.ID.self)` whose `primaryAction` plays
  the clip (double-click on macOS, tap on iOS) when exactly one row is
  targeted. The menu offers Play/Edit for a single clip, and
  Download…/Delete for any selection (pluralized labels for multiple).
- iOS gets an `EditButton`; edit mode provides the standard multi-select
  checkmarks. Row swipe-to-delete stays.
- Toolbar: the existing Download button becomes "Download Selected…" when a
  selection exists (downloads just the selection), otherwise it stays the
  whole-project download (which still writes the `project.json` copy;
  partial downloads skip it). A trash toolbar button appears while a
  selection exists. macOS also honors the Delete key via `.onDeleteCommand`.
- Deletion always confirms first — the existing dialog generalizes from one
  `Clip` to `[Clip]` ("Delete N clips?"). After any delete the list
  refreshes; the selection is pruned to surviving clips on every refresh.

## Core

- `DownloadNaming.selectedFilenames(forOrdered:selectedKeys:)` — computes
  `filenames(forOrdered:)` over the FULL ordered list, then filters to the
  selected keys, guaranteeing identical names to a whole-project download.
- `BucketWriter.deleteClips(_:)` — sequential `deleteClip` per clip, halting
  on the first failure (matching `deletePrefix` semantics); the UI refreshes
  afterward either way, so partial progress is visible.
- `DownloadController.start` takes prebuilt `[DownloadEngine.Item]` and an
  optional manifest instead of always deriving both from the whole list.

## Error handling

Unchanged patterns: delete failures land in the project view's dismissible
`loadError` line; download failures surface in the existing progress sheet.
A cancelled partial download keeps partial files for resume, as today.

## Testing

- `DownloadNamingTests`: subset filenames keep full-project index prefixes
  and dedup suffixes.
- `BucketWriterTests`: `deleteClips` deletes each file+sidecar in order via
  `RecordingTransport`; halts on first failure leaving later keys untouched.
- View wiring is exercised by build only (consistent with the rest of the
  UI layer); the unit-test scheme is still broken by the rename (TODO #1).
