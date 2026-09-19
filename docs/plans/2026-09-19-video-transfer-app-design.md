# Video Transfer App — Design

**Date:** 2026-09-19
**Status:** Validated with user

## Purpose

A multiplatform SwiftUI app (macOS + iOS) for moving event/art-project video from
capture devices (Mac or iPhone) into S3-compatible storage, and pulling it back
down for editing. The app is the bucket's manager: upload, browse, rename,
reorder, download, and delete.

## Requirements (confirmed)

- Scope: full pipeline — upload from Mac/iPhone, browse the bucket, download to
  the editing machine, delete clips/projects/clients (with confirmation).
- Hierarchy: Client → Project → Clips. Clip ordering by time is important.
- Auth: endpoint + bucket + access key + secret only (no other AWS auth modes).
  Single destination; credentials in the Keychain.
- Intake: iPhone Photos library, Files/document picker, Mac drag & drop
  (files or folders), and a watched folder on Mac.
- Clip time: capture timestamp from video metadata, fall back to file dates,
  manual override/reorder allowed.
- Object keys: readable slug + 4-char short id (collision-proof, human-readable).
- Uploads: multipart, resumable across restarts and network drops; background
  uploads on iPhone where the system allows.
- Concurrency: multiple devices may add clips to the same project at once; the
  metadata design must not let one device clobber another's writes.
- Per-clip metadata: display name, camera/source label, free-text notes, plus
  automatic facts (capture time, duration, resolution, codec, file size,
  original filename, source device).
- Download naming: order-prefixed (`001_cam-a_intro.mov`, `002_…`).
- One multiplatform SwiftUI app built from this Xcode project, shared core,
  platform-adapted UI.

## Bucket layout & metadata

Self-describing bucket, no central index — this is what makes concurrent
devices safe.

```
acme-corp-x7f2/                          ← client (slug + 4-char id)
  client.json                            ← client display name
  spring-gala-k9q1/                      ← project (slug + id)
    project.json                         ← display name, sortIndex, createdAt
    clips/
      2026-09-19_183042_cam-a_e51f.mov   ← clip file
      2026-09-19_183042_cam-a_e51f.json  ← sidecar: this clip's metadata
```

Rules:

1. **Discovery by listing, not by index.** Clients/projects are found by
   listing prefixes; an entity exists iff its `client.json` / `project.json`
   does. Devices creating different projects concurrently never touch the same
   object.
2. **One sidecar JSON per clip.** All clip metadata lives next to the clip. A
   device only writes sidecars for clips it uploaded, so concurrent uploads to
   the same project cannot conflict.
3. **Ordering without shared writes.** Clips sort by capture time; a manual
   reorder writes an override into the affected clip's own sidecar. Projects
   sort by `sortIndex` in each `project.json` (fallback: `createdAt`), so
   reordering projects doesn't rewrite `client.json`.

Only `client.json` and `project.json` are last-writer-wins, and only on rare,
human-initiated rename/reorder actions.

Clip object keys are immutable once uploaded: `date_time_cameralabel_shortid.ext`.
Renaming a clip changes only its sidecar. Sidecar is written **after** the video
completes, so a clip only "exists" once fully uploaded.

## S3 client

Hand-rolled minimal client on `URLSession` with AWS Signature V4 signing — no
AWS SDK dependency. Operations: `PutObject`, `GetObject` (with Range),
`DeleteObject`, `ListObjectsV2`, `CreateMultipartUpload`, `UploadPart`,
`CompleteMultipartUpload`, `AbortMultipartUpload`, `ListParts`.
Path-style addressing by default with a virtual-host toggle (S3-compatible
providers vary). Credentials in Keychain; endpoint/bucket in settings.

## Upload pipeline

Persistent on-disk queue that survives restarts. Per job:
probe (AVFoundation: capture time, duration, resolution, codec) →
multipart upload → sidecar `PutObject` last. On relaunch/failure, `ListParts`
resumes from the first missing part.

**iPhone background uploads:** background `URLSession` requires
upload-from-file, so videos are split into ~64 MB part files in temp storage,
each enqueued as a background upload task. The app wakes to sign/enqueue the
next batch and finally complete the multipart upload. On Mac the same pipeline
runs in a plain session, streaming parts directly from the source file.

**Watched folder (Mac only):** dispatch file-system events monitor a designated
folder and auto-queue new videos into a pre-chosen client/project.

## App structure & UI

Shared core: `S3Client`, `BucketStore` (lists/caches clients → projects →
clips), `UploadQueue`, `ClipProber`, `Codable` metadata models.

Navigation: clients → projects (by `sortIndex`) → project detail with clips
ordered by effective time; rows show thumbnail, display name, camera label,
duration, transfer state. Mac: `NavigationSplitView`; iPhone: stack. Renames,
notes, labels, drag-reorder are inline and write back only the affected JSON.

## Download

Select project or clips → destination folder → files land as
`NNN_cameralabel_display-name.ext` in effective clip order (names slugified).
Resumable via ranged `GetObject`. A copy of `project.json` is written alongside
so the folder is self-documenting.

## Deletion

Clip delete removes file + sidecar. Project/client delete lists the prefix and
deletes everything under it. Confirmations state exactly what's removed
("Delete 14 clips, 38.2 GB"). No app-level trash — bucket versioning is the
safety net if desired.

## Error handling

- Upload jobs retry with backoff; per-job error state with manual retry; the
  queue never silently drops a job.
- Stale multipart uploads aborted on launch.
- Listing failures show cached data plus an offline banner.

## Testing

Swift Testing unit tests: SigV4 signing against AWS published test vectors,
slug/key generation, ordering logic (timestamp + override), manifest
encode/decode. Integration target runs the full client against a local MinIO
when available.
