# Clip streaming playback

2026-09-21. Status: designed, not yet implemented.

## Goal

Clicking a clip in the project's clip list plays it immediately, streaming from
the bucket — no download step. Works identically on macOS and iOS.

## Decisions

- **In-app playback**, not the browser: an AVKit `VideoPlayer` presented as a
  sheet, fed by a short-lived SigV4 *presigned URL*. This keeps the signed URL
  out of browser history, behaves the same on both platforms, and is the only
  way to feed AVPlayer (it cannot attach `Authorization` headers to its media
  requests — the whole grant must live in the URL).
- **Tap plays; ⓘ edits.** The row's tap gesture moves from "open Edit sheet"
  to "play". Each row gains a trailing borderless `info.circle` button that
  opens the Edit sheet; the context-menu Edit item remains as a second path.
  Delete (context menu + swipe) is unchanged.

## Core: presigned GET URLs

**`SigV4.presignedURL(...)`** — new static function beside `sign(...)`,
implementing SigV4 query-string signing:

- Inputs: method (`"GET"`), a URL already built by `S3Config.url(forKey:)`,
  access/secret key, region, service (`"s3"`), `expires` seconds, and an
  injectable `date` (same testability pattern as the rest of the app).
- Appends `X-Amz-Algorithm=AWS4-HMAC-SHA256`, `X-Amz-Credential`
  (`accessKey/date/region/s3/aws4_request`), `X-Amz-Date`, `X-Amz-Expires`,
  and `X-Amz-SignedHeaders=host`; canonicalizes with **host as the only signed
  header** and payload hash `UNSIGNED-PAYLOAD`; signs with the existing
  `signingKey`; appends `X-Amz-Signature`. Reuses the existing canonical-query
  and encoding helpers where possible. `X-Amz-Credential`'s slashes must end
  up percent-encoded (`S3Config`'s query encoder already does this).

**`S3Client.presignedGetURL(key:expiresIn:)`** — synchronous (no network)
wrapper: builds the object URL via `config.url(forKey:)`, delegates to
`SigV4.presignedURL` with the config's credentials/region. Default expiry
**1 hour** — long enough to watch any clip, short enough to bound the grant.

**Tests.** Known-answer test against AWS's published presigned-GET vector
(`examplebucket`/`test.txt`, demo keypair) pinning the exact signature; tests
that path- and virtual-host-style URLs presign correctly and that credential
slashes are encoded.

## UI: `ProjectDetailView`

- New `@State private var playingClip: Clip?`; row tap sets it.
- `.sheet(item: $playingClip)` presents a small `ClipPlayerSheet`:
  `import AVKit`, `VideoPlayer(player:)` over an `AVPlayer(url:)` held in
  `@State`, created from `session.client.presignedGetURL(key: clip.key)` —
  no loading state needed since presigning is pure. Auto-play on appear,
  pause on disappear. Title shows the clip's `displayName`. macOS: resizable
  frame (min ~640×400); iOS: large detent.
- AVPlayer streams via ranged GETs against the presigned URL, so scrubbing
  works without a full download.

## Failure modes

- Expired URL mid-playback: effectively impossible (fresh 1-hour URL per
  open).
- Formats AVFoundation can't stream (`.avi`, `.mxf`): AVPlayer's built-in
  error state, no custom handling in v1.
- Network errors: the player's own failure UI.

## Out of scope (v1)

- Copy/share streaming link, open-in-browser.
- Remote thumbnails.
- Per-clip download.
