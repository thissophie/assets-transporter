# Video Transfer App Implementation Plan

> **For the implementer:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Design doc: `docs/plans/2026-09-19-video-transfer-app-design.md` — read it first.

**Goal:** Multiplatform SwiftUI app (macOS + iOS) that uploads event video to S3-compatible storage (Client → Project → Clips with JSON sidecars), browses the bucket, and downloads/deletes — with resumable multipart uploads.

**Architecture:** Self-describing bucket (discovery by prefix listing, one sidecar JSON per clip, no central index). Hand-rolled SigV4 S3 client on URLSession (no AWS SDK). Persistent upload queue with multipart resume. Shared core + platform-adapted SwiftUI.

**Tech Stack:** Swift, SwiftUI, Swift Testing, CryptoKit (SigV4 HMAC), AVFoundation (probing), Keychain Services, URLSession (background sessions on iOS).

---

## Project facts the implementer must know

- **This is an Xcode project driven via the xcode-tools MCP server.** Create/edit source files with `XcodeWrite`/`XcodeRead`, check quickly with `XcodeRefreshCodeIssuesInFile`, build with `BuildProject`, run tests with `RunAllTests`/`RunSomeTests`. Do NOT edit `project.pbxproj` by hand.
- Workspace paths look like `Untitled Project/MyApp/ContentView.swift`. On disk the project root is `/Users/patrick/Library/Developer/Xcode/UntitledProjects/Untitled Project/` (git commands run there via Bash).
- **One app target `MyApp`**, SUPPORTED_PLATFORMS already includes `iphoneos iphonesimulator macosx`. Deployment targets are 27.0.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** (approachable concurrency). Every non-UI type that must run off the main actor (models, S3 client, queue) MUST be declared `nonisolated` (e.g. `nonisolated struct ClipSidecar`, `nonisolated enum Slug`). Forgetting this is the #1 expected compile-error source.
- **No test target exists yet** (Task 0.2 creates it). Use Swift Testing (`import Testing`, `@Test`, `#expect`), NOT XCTest.
- App Sandbox is ON with `ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO` and `ENABLE_USER_SELECTED_FILES = readonly`. Task 0.3 fixes both; nothing network-related will work until it does.
- New source files go under new workspace folders: `Untitled Project/MyApp/Core/...` (models, S3, queue) and `Untitled Project/MyApp/UI/...` (views). Test files go in the test target folder.
- File layout convention in the bucket (from the design doc):
  `<client-slug-id>/client.json`, `<client>/<project-slug-id>/project.json`, `<client>/<project>/clips/<date>_<time>_<camera>_<id>.<ext>` + same key with `.json` appended for the sidecar.

**Verification rhythm for every task:** write failing test → run it, see it fail → implement minimally → run it, see it pass → `BuildProject` if new files were added → commit.

---

## Phase 0 — Setup

### Task 0.1: git init + commit baseline

**Steps:**
1. `cd "/Users/patrick/Library/Developer/Xcode/UntitledProjects/Untitled Project" && git init`
2. Create `.gitignore` at the project root containing:
   ```
   DerivedData/
   xcuserdata/
   *.xcuserstate
   .DS_Store
   ```
3. `git add -A && git commit -m "chore: baseline Xcode template + design doc + plan"`

### Task 0.2: Create the unit-test target

**Steps:**
1. Use `XcodeListTemplates` to find the unit-testing-bundle template, then `XcodeNewTarget` to create target **`MyAppTests`** (unit test bundle, hosted in `MyApp`).
2. Add a smoke test file `Untitled Project/MyAppTests/SmokeTests.swift`:
   ```swift
   import Testing

   struct SmokeTests {
       @Test func testingWorks() {
           #expect(1 + 1 == 2)
       }
   }
   ```
3. Run: `RunAllTests`. Expected: 1 test passes.
4. Commit: `git add -A && git commit -m "test: add MyAppTests target with smoke test"`

### Task 0.3: Sandbox/build settings the app needs

**Steps:**
1. With `UpdateTargetBuildSetting` on target `MyApp`, set:
   - `ENABLE_OUTGOING_NETWORK_CONNECTIONS` = `YES` (S3 access; app is dead in the water without it)
   - `ENABLE_USER_SELECTED_FILES` = `readwrite` (Mac intake + choosing download folders)
2. `BuildProject`. Expected: build succeeds.
3. Commit: `git commit -am "chore: enable outgoing network + read-write user-selected files"`

---

## Phase 1 — Pure core logic (models, slugs, keys, ordering)

Everything in this phase is a `nonisolated` value type with no I/O — fully unit-testable.

### Task 1.1: Slugs and short IDs

**Files:**
- Create: `Untitled Project/MyApp/Core/Slug.swift`
- Test: `Untitled Project/MyAppTests/SlugTests.swift`

**Step 1: failing test**
```swift
import Testing
@testable import MyApp

struct SlugTests {
    @Test func basicSlugging() {
        #expect(Slug.make(from: "Acme Corp") == "acme-corp")
        #expect(Slug.make(from: "  Spring Gala 2026! ") == "spring-gala-2026")
        #expect(Slug.make(from: "Café Añejo") == "cafe-anejo")
        #expect(Slug.make(from: "***") == "untitled")
    }

    @Test func shortIDIsFourSafeChars() {
        var rng = SystemRandomNumberGenerator()
        let id = Slug.shortID(using: &rng)
        #expect(id.count == 4)
        #expect(id.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
    }
}
```

**Step 2:** `RunSomeTests` for `SlugTests`. Expected: FAIL — `Slug` not found.

**Step 3: implementation**
```swift
import Foundation

nonisolated enum Slug {
    /// Lowercased ASCII letters/digits separated by single dashes. Never empty.
    static func make(from name: String) -> String {
        let lowered = (name.applyingTransform(.stripDiacritics, reverse: false) ?? name).lowercased()
        var out = ""
        var pendingDash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "untitled" : out
    }

    /// 4 chars from an ambiguity-free alphabet (no 0/o/1/l/i).
    static func shortID(using rng: inout some RandomNumberGenerator) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<4).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// "acme-corp" + id -> "acme-corp-x7f2"
    static func slugWithID(_ name: String, id: String) -> String {
        "\(make(from: name))-\(id)"
    }
}
```

**Step 4:** rerun — PASS. **Step 5:** `git add -A && git commit -m "feat: slug + short id generation"`

### Task 1.2: Metadata models with stable JSON coding

**Files:**
- Create: `Untitled Project/MyApp/Core/Manifests.swift`
- Test: `Untitled Project/MyAppTests/ManifestTests.swift`

**Step 1: failing test** — round-trip each model and pin the date format:
```swift
import Foundation
import Testing
@testable import MyApp

struct ManifestTests {
    @Test func clipSidecarRoundTrip() throws {
        let clip = ClipSidecar(
            displayName: "Intro", cameraLabel: "cam-a", notes: "keeper",
            capturedAt: Date(timeIntervalSince1970: 1_789_000_000),
            orderOverride: nil, duration: 12.5, width: 3840, height: 2160,
            codec: "hvc1", fileSize: 123_456_789,
            originalFilename: "IMG_0042.MOV", sourceDevice: "Patrick's iPhone")
        let data = try ManifestCoding.encode(clip)
        let back = try ManifestCoding.decode(ClipSidecar.self, from: data)
        #expect(back == clip)
        // dates must be ISO8601 so other tools can read the bucket
        #expect(String(data: data, encoding: .utf8)!.contains("2026-09-"))
    }

    @Test func projectManifestDefaults() throws {
        let json = #"{"displayName":"Gala","createdAt":"2026-09-19T18:30:00Z"}"#
        let m = try ManifestCoding.decode(ProjectManifest.self, from: Data(json.utf8))
        #expect(m.sortIndex == nil)  // optional fields tolerate absence
    }
}
```

**Step 2:** run — FAIL. **Step 3: implementation**
```swift
import Foundation

nonisolated struct ClientManifest: Codable, Equatable, Sendable {
    var displayName: String
}

nonisolated struct ProjectManifest: Codable, Equatable, Sendable {
    var displayName: String
    var sortIndex: Int?
    var createdAt: Date
}

nonisolated struct ClipSidecar: Codable, Equatable, Sendable {
    var displayName: String
    var cameraLabel: String?
    var notes: String?
    var capturedAt: Date?
    var orderOverride: Date?   // manual "effective time" correction
    var duration: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var fileSize: Int64
    var originalFilename: String
    var sourceDevice: String
}

nonisolated enum ManifestCoding {
    static func encode(_ value: some Encodable) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: data)
    }
}
```
**Steps 4–5:** tests pass; `git commit -am "feat: manifest models + ISO8601 JSON coding"`

### Task 1.3: Bucket key builder/parser

**Files:**
- Create: `Untitled Project/MyApp/Core/BucketKeys.swift`
- Test: `Untitled Project/MyAppTests/BucketKeyTests.swift`

**Step 1: failing test**
```swift
import Foundation
import Testing
@testable import MyApp

struct BucketKeyTests {
    @Test func clipKeyFormat() {
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 19
        comps.hour = 18; comps.minute = 30; comps.second = 42
        comps.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let key = BucketKeys.clipKey(client: "acme-corp-x7f2", project: "spring-gala-k9q1",
                                     capturedAt: date, cameraLabel: "Cam A", id: "e51f", ext: "mov")
        #expect(key == "acme-corp-x7f2/spring-gala-k9q1/clips/2026-09-19_183042_cam-a_e51f.mov")
        #expect(BucketKeys.sidecarKey(forClipKey: key) ==
                "acme-corp-x7f2/spring-gala-k9q1/clips/2026-09-19_183042_cam-a_e51f.mov.json")
    }

    @Test func manifestKeys() {
        #expect(BucketKeys.clientManifestKey(client: "acme-corp-x7f2") == "acme-corp-x7f2/client.json")
        #expect(BucketKeys.projectManifestKey(client: "acme-corp-x7f2", project: "spring-gala-k9q1")
                == "acme-corp-x7f2/spring-gala-k9q1/project.json")
    }

    @Test func isClipKeyDistinguishesSidecars() {
        #expect(BucketKeys.isClipFile("a/b/clips/x.mov"))
        #expect(!BucketKeys.isClipFile("a/b/clips/x.mov.json"))
    }
}
```

**Step 3: implementation** — key points:
- Sidecar key = clip key + `".json"` (so a clip and its sidecar always sort adjacently and the mapping is trivial).
- Timestamp in keys is **UTC** `yyyy-MM-dd_HHmmss` from a fixed-locale `DateFormatter` (`en_US_POSIX`).
- Camera label is slugged (`Slug.make`), defaulting to `"cam"` when nil/empty.
- `isClipFile(_:)` = under a `/clips/` prefix and NOT ending in `.json`.
- Also provide `parseClipTimestamp(fromKey:)` returning the `Date?` encoded in the key (used as last-resort ordering fallback).

**Steps 4–5:** pass; commit `"feat: bucket key builder/parser"`.

### Task 1.4: Clip ordering

**Files:**
- Create: `Untitled Project/MyApp/Core/ClipOrdering.swift`
- Test: `Untitled Project/MyAppTests/ClipOrderingTests.swift`

**Step 1: failing test**
```swift
import Foundation
import Testing
@testable import MyApp

struct ClipOrderingTests {
    private func clip(_ key: String, captured: TimeInterval?, override: TimeInterval? = nil) -> Clip {
        Clip(key: key,
             sidecar: ClipSidecar(displayName: key, cameraLabel: nil, notes: nil,
                                  capturedAt: captured.map { Date(timeIntervalSince1970: $0) },
                                  orderOverride: override.map { Date(timeIntervalSince1970: $0) },
                                  duration: nil, width: nil, height: nil, codec: nil,
                                  fileSize: 0, originalFilename: key, sourceDevice: "test"))
    }

    @Test func overrideBeatsCaptureTime() {
        let a = clip("a", captured: 100, override: 300)
        let b = clip("b", captured: 200)
        #expect(ClipOrdering.sorted([a, b]).map(\.key) == ["b", "a"])
    }

    @Test func stableTiebreakOnKey() {
        let a = clip("a", captured: 100), b = clip("b", captured: 100)
        #expect(ClipOrdering.sorted([b, a]).map(\.key) == ["a", "b"])
    }

    @Test func missingTimesSortFirstByKey() {
        let a = clip("z-unknown", captured: nil), b = clip("b", captured: 100)
        #expect(ClipOrdering.sorted([a, b]).map(\.key) == ["z-unknown", "b"])
    }
}
```

**Step 3: implementation**
```swift
import Foundation

nonisolated struct Clip: Equatable, Sendable, Identifiable {
    var key: String            // full object key of the video file
    var sidecar: ClipSidecar
    var id: String { key }

    /// override > capturedAt > timestamp parsed from the key > distantPast
    var effectiveTime: Date {
        sidecar.orderOverride ?? sidecar.capturedAt
            ?? BucketKeys.parseClipTimestamp(fromKey: key) ?? .distantPast
    }
}

nonisolated enum ClipOrdering {
    static func sorted(_ clips: [Clip]) -> [Clip] {
        clips.sorted {
            ($0.effectiveTime, $0.key) < ($1.effectiveTime, $1.key)
        }
    }
}
```
**Steps 4–5:** pass; commit `"feat: clip model + time-based ordering with override"`.

### Task 1.5: Download filename generator

**Files:**
- Create: `Untitled Project/MyApp/Core/DownloadNaming.swift`
- Test: `Untitled Project/MyAppTests/DownloadNamingTests.swift`

**Step 1: failing test**
```swift
import Testing
@testable import MyApp

struct DownloadNamingTests {
    @Test func orderPrefixedNames() {
        // build 2 clips (reuse helper style from ClipOrderingTests), cam label "Cam A"/nil,
        // display names "Intro!" / "Main Talk", extensions .mov/.mp4
        let names = DownloadNaming.filenames(forOrdered: clips)
        #expect(names == ["001_cam-a_intro.mov", "002_main-talk.mp4"])
    }

    @Test func padsToCollectionSize() {
        // 150 clips -> "001"... "150" (3 digits covers it); 1200 clips -> 4 digits
        #expect(DownloadNaming.indexWidth(count: 9) == 3)      // minimum 3
        #expect(DownloadNaming.indexWidth(count: 1200) == 4)
    }
}
```

**Step 3: implementation** — `filenames(forOrdered:)` takes already-ordered clips; per clip: zero-padded 1-based index (width = `max(3, digits(count))`), then slugged camera label if present, then slugged display name, joined with `_`, plus the original file extension (from the clip key). Dedupe collisions by appending `-2`, `-3`….

**Steps 4–5:** pass; commit `"feat: order-prefixed download filenames"`.

---

## Phase 2 — S3 client

### Task 2.1: SigV4 signer

**Files:**
- Create: `Untitled Project/MyApp/Core/S3/SigV4.swift`
- Test: `Untitled Project/MyAppTests/SigV4Tests.swift`

**Step 1: failing tests**
```swift
import Foundation
import Testing
@testable import MyApp

struct SigV4Tests {
    // Vector from AWS docs "Deriving the signing key" (verify against
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
    // if it fails — trust the docs, not this file).
    @Test func signingKeyDerivation() {
        let key = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                   date: "20120215", region: "us-east-1", service: "iam")
        #expect(key.map { String(format: "%02x", $0) }.joined()
                == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    @Test func canonicalRequestShape() {
        var req = URLRequest(url: URL(string: "https://s3.example.com/bucket/a%20b.mov")!)
        req.httpMethod = "PUT"
        req.setValue("s3.example.com", forHTTPHeaderField: "Host")
        req.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue("20260919T183042Z", forHTTPHeaderField: "x-amz-date")
        let canonical = SigV4.canonicalRequest(for: req, payloadHash: "UNSIGNED-PAYLOAD")
        let lines = canonical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "PUT")
        #expect(lines[1] == "/bucket/a%20b.mov")      // path stays encoded
        #expect(lines[2] == "")                        // empty query
        #expect(lines.contains("host:s3.example.com")) // lowercase header names, sorted
        #expect(lines.last == "UNSIGNED-PAYLOAD")
    }

    @Test func authorizationHeaderFormat() {
        // sign a fixed request with fixed credentials + date, assert the header matches
        // "AWS4-HMAC-SHA256 Credential=AKID/20260919/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=<64 hex>"
        // (regex-match the shape; the exact signature is covered by integration tests against ministack)
    }
}
```

**Step 3: implementation** — `nonisolated enum SigV4` using CryptoKit:
- `sha256Hex(_ data: Data) -> String`
- `hmac(key: Data, data: Data) -> Data` (`HMAC<SHA256>`)
- `signingKey(secret:date:region:service:) -> Data` — chained HMAC over `"AWS4" + secret` → date → region → service → `"aws4_request"`.
- `canonicalRequest(for:payloadHash:)` — method, encoded path (default `/`), canonical query (URL-encoded, sorted by key), lowercase-sorted headers (`host` + all `x-amz-*`), signed-headers list, payload hash. Use `URLComponents.percentEncodedPath/percentEncodedQueryItems` so already-encoded values aren't double-encoded.
- `sign(request:credentials:region:date:payloadHash:) -> URLRequest` — sets `x-amz-date`, `x-amz-content-sha256`, and `Authorization`. All S3 payloads are signed as `UNSIGNED-PAYLOAD` over HTTPS (standard practice; avoids buffering multi-GB files to hash them). Region defaults to `us-east-1` — S3-compatible providers accept any consistent region string; expose it as an optional setting later only if a provider demands it.

**Steps 4–5:** pass; commit `"feat: SigV4 request signing"`.

### Task 2.2: Endpoint config + request building

**Files:**
- Create: `Untitled Project/MyApp/Core/S3/S3Config.swift`
- Test: `Untitled Project/MyAppTests/S3ConfigTests.swift`

**Step 1: tests** — path-style URL building:
```swift
let config = S3Config(endpoint: URL(string: "https://minio.example.com:9000")!,
                      bucket: "video", accessKey: "AK", secretKey: "SK",
                      style: .path, region: "us-east-1")
#expect(config.url(forKey: "acme/a b.mov").absoluteString
        == "https://minio.example.com:9000/video/acme/a%20b.mov")
#expect(config.url(forKey: "x", query: [URLQueryItem(name: "uploads", value: nil)]).absoluteString
        == "https://minio.example.com:9000/video/x?uploads")
// virtualHost style: https://video.minio.example.com:9000/x
```

**Step 3:** `nonisolated struct S3Config` (`style: .path | .virtualHost`, default `.path`). Encode each key segment with a strict allowed set (alphanumerics + `-._~/`) per S3 rules. **Steps 4–5:** commit `"feat: S3 endpoint config + URL building"`.

### Task 2.3: ListObjectsV2 XML parsing

**Files:**
- Create: `Untitled Project/MyApp/Core/S3/S3ListParser.swift`
- Test: `Untitled Project/MyAppTests/S3ListParserTests.swift`

**Step 1: test** — feed a literal `ListBucketResult` XML string (2 `Contents` with Key/Size/LastModified, 1 `CommonPrefixes`, `IsTruncated=true`, `NextContinuationToken`) and assert the parsed `S3ListResult { objects: [S3Object(key:size:lastModified:)], commonPrefixes: [String], nextContinuationToken: String? }` matches. Include a key containing `&amp;` to prove XML entities decode.

**Step 3:** implement with Foundation `XMLParser` and a small delegate class (`nonisolated final class`), collecting text per element. **Steps 4–5:** commit `"feat: ListObjectsV2 XML parsing"`.

### Task 2.4: S3Client over a mockable transport

**Files:**
- Create: `Untitled Project/MyApp/Core/S3/S3Client.swift`
- Test: `Untitled Project/MyAppTests/S3ClientTests.swift`

**Design:**
```swift
nonisolated protocol S3Transport: Sendable {
    func perform(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: S3Transport { /* URLSession.shared or injected session */ }

nonisolated struct S3Client: Sendable {
    let config: S3Config
    let transport: S3Transport

    func putObject(key: String, data: Data, contentType: String) async throws
    func putObject(key: String, fileURL: URL, contentType: String) async throws
    func getObject(key: String, range: ClosedRange<Int64>?) async throws -> Data
    func deleteObject(key: String) async throws
    func listObjects(prefix: String, delimiter: String?) async throws -> S3ListResult  // auto-follows continuation tokens
    func createMultipartUpload(key: String, contentType: String) async throws -> String        // uploadId
    func uploadPart(key: String, uploadId: String, partNumber: Int, fileURL: URL) async throws -> String  // ETag
    func completeMultipartUpload(key: String, uploadId: String, parts: [(Int, String)]) async throws
    func abortMultipartUpload(key: String, uploadId: String) async throws
    func listParts(key: String, uploadId: String) async throws -> [(partNumber: Int, etag: String, size: Int64)]
    func listMultipartUploads(prefix: String) async throws -> [(key: String, uploadId: String)]
}
```
Errors: `nonisolated enum S3Error: Error { case http(status: Int, body: String), case badResponse }`.

**Step 1: tests with a recording mock transport** — a mock that captures requests and returns canned responses. Assert for each operation: HTTP method, path, query (`?uploads`, `?uploadId=...&partNumber=...`), presence of `Authorization` header starting `AWS4-HMAC-SHA256`, and correct parsing of canned XML responses (CompleteMultipartUpload body contains sorted `<Part><PartNumber>` entries; `listObjects` follows a truncated page). Assert non-2xx throws `S3Error.http` with the body text.

**Step 3:** implement; every request goes through one private `signedRequest(method:key:query:headers:)` helper that stamps SigV4. **Steps 4–5:** commit `"feat: S3 client (put/get/delete/list/multipart)"`.

### Task 2.5: Keychain credential store + settings model

**Files:**
- Create: `Untitled Project/MyApp/Core/CredentialStore.swift`
- Test: manual (Keychain doesn't unit-test well in a host app; verify in Task 5.1)

`nonisolated struct CredentialStore`: `save(S3Credentials)` / `load() -> S3Credentials?` / `delete()` using `kSecClassGenericPassword`, service `"video-transfer.s3"`, storing a JSON blob `{endpoint, bucket, accessKey, secretKey, pathStyle, region}`. `BuildProject`, then commit `"feat: Keychain credential store"`.

---

## Phase 3 — BucketStore (the bucket's object model)

### Task 3.1: Listing clients / projects / clips

**Files:**
- Create: `Untitled Project/MyApp/Core/BucketStore.swift`
- Test: `Untitled Project/MyAppTests/BucketStoreTests.swift`

**Design:** `nonisolated struct BucketReader` (pure functions over `S3Client`, tested with the mock transport from 2.4):
- `listClients()` — `listObjects(prefix: "", delimiter: "/")` → for each common prefix, `getObject("<prefix>client.json")` → `[ClientRef(prefix:displayName:)]` sorted by displayName. A prefix without a readable `client.json` still appears, with the slug as its display name (never hide data).
- `listProjects(client:)` — same pattern one level down; sort by `sortIndex ?? Int.max`, then `createdAt`.
- `listClips(client:project:)` — `listObjects(prefix: ".../clips/", delimiter: nil)`; pair each clip file with its sidecar (fetch all sidecar objects; a clip missing its sidecar appears with defaults derived from the key — it may still be uploading from another device). Return `ClipOrdering.sorted`.

**Step 1: tests** — canned list XML + canned JSON bodies through the mock; assert the assembled tree, the sidecar-missing fallback, and ordering.

**Steps 3–5:** implement, pass, commit `"feat: bucket reader (clients/projects/clips)"`.

### Task 3.2: Mutations — create / rename / reorder

Same files. `nonisolated struct BucketWriter`:
- `createClient(name:)` → put `client.json` at `Slug.slugWithID(name, id: newID)/`; returns the ref. Same for `createProject` (with `createdAt: now`, `sortIndex: nil`).
- `renameClient/renameProject/updateProjectOrder` → rewrite just that manifest.
- `updateClipSidecar(_:)` → rewrite one sidecar (rename, notes, camera label, order override).

**Tests:** assert exact keys + JSON bodies written through the mock (decode the captured body and compare models). Commit `"feat: bucket writer (create/rename/reorder)"`.

### Task 3.3: Deletion

`BucketWriter.deleteClip(clip:)` (file + sidecar), `deleteProject(...)` / `deleteClient(...)` (list full prefix, delete every object, batches of ≤1000). Also `deletionPreview(prefix:) -> (count: Int, bytes: Int64)` for the confirmation dialog. **Tests:** mock returns a 3-object listing → expect 3 DELETEs; preview sums sizes. Commit `"feat: prefix deletion with preview"`.

---

## Phase 4 — Upload pipeline

### Task 4.1: Clip probing (AVFoundation)

**Files:** Create `Untitled Project/MyApp/Core/ClipProber.swift`

`nonisolated struct ProbedClip { capturedAt: Date?, duration: Double?, width: Int?, height: Int?, codec: String? }`
`ClipProber.probe(url: URL) async throws -> ProbedClip` using `AVURLAsset`: `load(.creationDate)` (fall back to file creation date via `URLResourceValues`), `load(.duration)`, first video track's `naturalSize` and format description codec fourCC.

**Verify with `RunCodeSnippet`** against any bundled/simulator video (no unit test — AVFoundation needs real media). Commit `"feat: AVFoundation clip prober"`.

### Task 4.2: Persistent upload queue state

**Files:**
- Create: `Untitled Project/MyApp/Core/Upload/UploadJob.swift`, `UploadQueueStore.swift`
- Test: `Untitled Project/MyAppTests/UploadQueueStoreTests.swift`

`nonisolated struct UploadJob: Codable, Sendable, Identifiable`: id (UUID), source file URL + security-scoped bookmark `Data?`, destination clip key + sidecar (already probed), state (`waiting / uploading(uploadId: String) / failed(message: String) / done`), completed parts `[Int: String]` (partNumber → ETag), part size, total size.

`UploadQueueStore`: load/save `[UploadJob]` as JSON in Application Support (injected directory for tests). **Tests:** round-trip, mutate-one-job-and-persist, corrupted-file → empty queue not a crash. Commit `"feat: persistent upload job store"`.

### Task 4.3: Multipart upload engine with resume

**Files:**
- Create: `Untitled Project/MyApp/Core/Upload/UploadEngine.swift`
- Test: `Untitled Project/MyAppTests/UploadEngineTests.swift`

`nonisolated actor UploadEngine` (S3Client + store injected). Per job:
1. No `uploadId` → `createMultipartUpload`, persist it.
2. Has `uploadId` and empty local part map → `listParts` to recover server-side progress.
3. Split source into 64 MB part files in a temp dir (macOS may stream directly, but using part files on both platforms keeps one code path and enables iOS background sessions); upload missing parts sequentially, persisting each ETag; report progress via `AsyncStream<Double>`.
4. All parts done → `completeMultipartUpload` → put sidecar JSON (**sidecar last** — a clip exists only when whole) → state `.done`, delete temp parts.
5. Any thrown error → state `.failed(message)`, job stays for retry.
Also `abandonStaleUploads()`: on launch, `listMultipartUploads` and abort any uploadId no live job owns.

**Tests (mock transport):** happy path issues create→N parts→complete→sidecar PUT in order; resume path skips parts returned by `listParts`; failure at part 2 persists part 1's ETag and marks `.failed`; sidecar is never PUT before complete succeeds. Commit `"feat: resumable multipart upload engine"`.

### Task 4.4: iOS background sessions + Mac watched folder

Two platform-conditional pieces (`#if os(iOS)` / `#if os(macOS)`), verified by running, not unit tests:

- **iOS:** `BackgroundTransport` wrapping `URLSession(configuration: .background(withIdentifier: "video-transfer.upload"))`; parts enqueue as `uploadTask(with:fromFile:)`; delegate callbacks persist ETags into the store and enqueue the next batch; app relaunch re-attaches to the session identifier. Sign each part request just before enqueueing.
- **macOS:** `WatchedFolder`: security-scoped bookmark to a user-chosen folder, `DispatchSource.makeFileSystemObjectSource(.write)`, debounce 2 s, only enqueue files whose size has stopped changing (recorder may still be writing), remember processed paths.

Commit `"feat: iOS background upload transport + macOS watched folder"`.

---

## Phase 5 — UI

UI tasks are verified with `BuildProject` + `RenderPreview` per view + a manual run (`RunProject`) at the end of the phase; commit after each task. All views are plain `@MainActor` (the default). One `@Observable final class AppModel` owns `S3Config?`, `BucketReader/Writer`, `UploadEngine`, and cached tree state.

### Task 5.1: Settings screen
Form: endpoint URL, bucket, access key, secret (SecureField), path-style toggle, region (default `us-east-1`). Save → `CredentialStore` + rebuild `S3Client`. "Test connection" button = `listObjects(prefix: "", delimiter: "/")` and shows success/failure. First-run: app opens straight into Settings when no credentials exist.

### Task 5.2: Client & project browsing
`NavigationSplitView` (macOS/iPad) / `NavigationStack` (iPhone): clients list → projects list. Create (sheet with name field), rename (inline/alert), project drag-reorder writes `sortIndex` to each moved project's manifest. Pull-to-refresh / toolbar refresh re-lists. Offline: show cached tree + warning banner.

### Task 5.3: Project detail + intake
Clip list ordered by `effectiveTime`: thumbnail (`AVAssetImageGenerator`, cached), display name, camera label, duration, size, state badge (uploading %, failed-retry button, done). Editing sheet per clip: name / camera / notes / date-time override → `updateClipSidecar`.
Intake into the open project: iPhone `PhotosPicker` (`.videos`) + `fileImporter`; Mac `fileImporter` + `.dropDestination(for: URL.self)` accepting files and folders (folders expand to contained videos); a per-batch default camera label prompt. Each picked file → copy/export to a staging dir → probe → enqueue `UploadJob`.

### Task 5.4: Download flow
Project toolbar "Download…" (whole project or selected clips) → folder picker (`fileImporter` with `.directory` / `NSOpenPanel`) → sequential ranged `getObject` downloads to `DownloadNaming.filenames`, resuming partial files by starting the range at existing file size; writes `project.json` copy alongside; progress sheet with cancel.

### Task 5.5: Deletion
Swipe/context "Delete" on clip, project, client → `deletionPreview` → `confirmationDialog` ("Delete 14 clips, 38.2 GB — cannot be undone") → `BucketWriter` delete → refresh.

### Task 5.6: Upload queue screen
List of jobs with progress, error messages, retry / remove; "stale uploads cleaned on launch" hook calls `abandonStaleUploads()`.

---

## Phase 6 — Integration verification

### Task 6.1: ministack integration test (optional but recommended)
Use **ministack** (per user direction — NOT MinIO) as the local S3-compatible endpoint: start it, create bucket `it-video`, run an `@Test(.enabled(if: ...))` suite in `MyAppTests` gated on an `S3_IT_ENDPOINT` env var: real `S3Client` round-trip (put/list/get/delete + a real 3-part multipart with resume-after-abort). This is where SigV4 correctness is truly proven. Commit.

### Task 6.2: End-to-end manual pass
`RunProject` on macOS: configure credentials → create client + project → drag in two videos → watch multipart progress → verify keys/JSON in the bucket (Test-connection listing or ministack's inspection tooling) → download the project to a folder → check `001_..., 002_...` naming → delete a clip. Repeat intake+upload on the iOS simulator (Photos picker). Fix anything found; final commit.

---

## Task order & dependencies

Phases are sequential; within Phase 1 and Phase 2, tasks are independent after 1.1/1.2 (2.3 needs nothing from 2.1–2.2; 2.4 needs 2.1–2.3). Phase 3 needs 2.4. Phase 4 needs 3.2 + 2.4. Phase 5 needs everything before it. Commit after every task without exception.
