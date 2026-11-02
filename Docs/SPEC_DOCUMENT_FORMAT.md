# SPEC: The `.mystnote` Document Format

**Format version:** 1
**Status:** Draft — the Step 2 target. §5 (stroke format) is implemented and measured. Step 1 (splitting `library.json`) lands first; see §0.
**Owner:** Myst

This is a contract. Once frozen, changes require a version bump and a migration path. Read `PROJECT_PLAN.md` §3 for why this exists.

---

## 0. Where this sits relative to what exists today

The app currently syncs through `SyncEngine`, which writes one `library.json` holding the **entire** library plus a flat `files/` directory of payloads, into a user-chosen folder. That design has three problems (`PROJECT_PLAN.md` §1.2): merge granularity is the whole notebook so a page can be silently destroyed, a single file holds everything with no backup, and iCloud conflict versions are ignored.

**Step 1 (M0) fixes those without adopting this spec.** It splits the snapshot per notebook, adds `Page.modifiedAt` for per-page merge, content-addresses payloads, and moves tombstones into the folder:

```
<sync folder>/Mystnotes/
  index.json                      notebook ids, titles, folder tree, modifiedAt
  index-history/<ts>.json         last N snapshots
  notebooks/<notebook-uuid>.json  one file per notebook
  files/<sha256>.<ext>            content-addressed payloads
  tombstones.json
  trash/
```

*Landed Sept 12, 2026 (M0 task 6):* `index.json` (format 2) and `notebooks/<uuid>.json`. Each index entry carries the notebook's settings, `settingsModifiedAt`, and a `contentSignature` — SHA-256 over `(pageID, modifiedAt)` — so a puller opens only the notebook files whose page set differs from its own, and a push rewrites only those. A notebook file the index promises but that hasn't arrived leaves the pull incomplete (retried next time) and is excluded from the next push. `formatVersion` newer than the build is refused. A format-1 `library.json` is read once if no index exists and never touched again. `index-history/` keeps the last 50 copies of the index (task 7). `tombstones.json` is the record of deletions, merged by union; the index no longer carries them (task 9). `files/<sha256>.<ext>` is content-addressed and immutable (task 10); notebook files carry each payload's hash, a payload that doesn't rehash to its name is "still downloading" and defers its page. Trash lives beside what it holds — `files/trash/`, `notebooks/trash/`, and locally `Documents/trash/` — rather than one top-level `trash/`; one mechanism (`DrawingStore.moveToTrash`) serves the app, the engine and the folder (task 11). Orphaned payloads are moved there after a 7-day grace period, never while a notebook file is known to be missing. Nothing in this design deletes; a retention policy for trash is an open decision (see BACKLOG).

The same layout, metadata only, is also kept on every device at `Documents/Library/` (the local mirror), so the SwiftData index can be rebuilt with no sync folder chosen.

**Step 2 is this spec.** Each notebook becomes a package of immutable blobs plus one small mutable manifest. Do it after Step 1 has shipped and been lived with, not instead of it. §12 describes the migration.

---

## 1. Why a package format

Two constraints drive this design:

1. **A folder-synced directory arrives file by file, not atomically.** The other device can see a manifest before the ink it references. Partial arrival is the normal case. The current `library.json` design papers over this by keeping everything in one file, which trades a partial-arrival problem for a total-loss problem.
2. **`PKDrawing` is an opaque Apple blob.** If ink only exists in that form, there is no web or Android renderer without reverse engineering, and the user-visible folder of open files contains one file type nobody but Apple can read. The neutral stroke format is the whole cross-platform bet.

The package is where evolution happens, on your schedule, with your migrations.

### The core trick: immutable blobs, one mutable pointer

**Never mutate a content file in place. Every save writes a new file under a new name, and only one small pointer file changes.** That single rule buys three things at once:

- **Partial arrival becomes detectable and safe.** A manifest pointing at a blob that hasn't landed means "still syncing" — keep showing the last complete state. If the manifest hasn't arrived, the old one still points at blobs that are all present. There is no window where the document is half-broken.
- **Conflicts collapse onto one small file.** Two devices editing different pages produce manifests differing in different entries: union the pages, take the newer blob per page. Real conflicts shrink to "both edited the same page," which is rare and can be kept as two versions rather than resolved by deletion.
- **Version history is free.** Old blobs are still there until GC runs.

---

## 2. On-disk layout

A `.mystnote` is a file package (a directory presented as a single file, `LSTypeIsPackage`).

```
Notebook-<uuid>.mystnote/
  manifest.json                        THE ONLY MUTABLE FILE. Points at exact blobs.
  pages/<page-uuid>/<hash>.json        Immutable. New file per save.
  ink/<page-uuid>/<hash>.strokes       Immutable. Neutral stroke stream, source of truth.
  ink/<page-uuid>/<hash>.pkd           Cached PKDrawing. Regenerable, never authoritative.
  timeline/<page-uuid>.events          Append-only stroke event log (M3)
  assets/<sha256>.<ext>                Content-addressed: images, PDFs, audio
  index/<page-uuid>.txt                Cached recognized text
  index/embeddings.bin                 Cached semantic vectors (M4)
  graph/links.json                     Outbound links from this document
  journal/<txn-id>.wal                 Write-ahead entries, deleted on commit
  trash/                               Anything deleted. Never removeItem.
```

### Rules

- **Content files are immutable and named by hash.** Nothing is ever rewritten in place except `manifest.json`. Same image imported twice stores once; deduplication and diffing are free.
- **Deletion means moving to `trash/`, never `removeItem`.** A stale tombstone or a bad merge must not be able to destroy ink. GC empties `trash/` on a retention policy.
- **Anything under `ink/*.pkd`, `index/`, and cached embeddings is regenerable.** Losing it costs CPU, never data. Never treat it as authoritative. Excluding these from sync is a valid optimization.
- **`timeline/` is append-only.** Never rewrite it in place.
- **No file in the package may reference anything outside it** except by asset hash. A package must be copyable, mailable, and openable in isolation.

---

## 3. `manifest.json`

```jsonc
{
  "formatVersion": 1,
  "documentID": "uuid",
  "documentType": "notebook | whiteboard | imported",
  "title": "string",
  "createdAt": "ISO8601",
  "modifiedAt": "ISO8601",
  "pageOrder": ["page-uuid", "..."],
  "pageBlobs": { "page-uuid": { "page": "<hash>.json", "ink": "<hash>.strokes", "modifiedAt": "ISO8601" } },
  "canvasSize": { "width": 0, "height": 0, "unit": "pt" },
  "defaultTemplate": "template-id",
  "tags": ["string"],
  "appVersion": "string",
  "checksum": "sha256 of pages/ + ink/*.strokes"
}
```

`checksum` covers only authoritative content, never caches.

---

## 4. `pages/<uuid>.json`

```jsonc
{
  "pageID": "uuid",
  "index": 0,
  "size": { "width": 0, "height": 0, "unit": "pt" },
  "template": "template-id | null",
  "background": {
    "kind": "template | pdf | image | none",
    "assetHash": "sha256 | null",
    "pdfPageIndex": 0
  },
  "inkRef": "ink/<page-uuid>.strokes",
  "elements": [
    {
      "elementID": "uuid",
      "kind": "textBlock | sticker | link | transclusion | clozeRegion",
      "frame": { "x": 0, "y": 0, "w": 0, "h": 0 },
      "rotation": 0,
      "zIndex": 0,
      "payload": { }
    }
  ],
  "nodeIDs": ["uuid"],
  "modifiedAt": "ISO8601"
}
```

`payload` is kind-specific and **must tolerate unknown keys**. A reader that meets an element kind it doesn't recognize preserves it verbatim on write and skips rendering it. That rule is what lets old clients round-trip documents from newer ones without destroying data.

---

## 5. Neutral stroke format (`ink/<uuid>.strokes`)

The most important file in the system. Binary, little-endian. **Rewritten Sept 12, 2026 against the iOS 26.5 SDK and the fidelity harness; the earlier draft cited API that does not exist.** The implementation is `StrokeCodec`; this section describes what it writes.

### Header

| Field | Type | Notes |
|---|---|---|
| magic | 4 bytes | `MYSK` |
| version | uint16 | 1 |
| flags | uint32 | bit 0: the body (everything after the header) is LZFSE-compressed. Set by default; a file without it reads the same. |
| strokeCount | uint32 | |

### Per stroke

| Field | Type | Notes |
|---|---|---|
| strokeID | 16 bytes | UUID. **Assigned by this format**, not by PencilKit — there is no `PKStrokePath.id`. See "Stroke identity". |
| inkType | uint16 length + UTF-8 | `PKInk.InkType.rawValue`. Currently `com.apple.ink.{pen,pencil,marker,monoline,fountainpen,watercolor,crayon}`. A reader without PencilKit maps these itself; an unknown string decodes as pen. |
| color | 4 × float64 | red, green, blue, alpha as `UIColor` reports them. Not RGBA8: quantizing colour is a guaranteed fidelity failure. |
| randomSeed | uint32 | `PKStroke.randomSeed`. Seeds pencil, watercolor and crayon texture; without it no round trip is pixel-identical. |
| transform | 6 × float64 | a b c d tx ty |
| creationDate | float64 | seconds since 2001-01-01 (`PKStrokePath.creationDate`) |
| mask | uint32 element count, then elements | `PKStroke.mask`, the lasso-erase clip, as `CGPath` elements: uint8 kind (0 move, 1 line, 2 quad, 3 cubic, 4 close) followed by 0/1/2/3 float64 point pairs. Count 0 = no mask. |
| pointCount | uint32 | |
| points | pointCount × 11 × float64 | see below |

There is no per-stroke width: `PKStroke` has none, width is per point.

### Per point (11 × float64 = 88 bytes)

**These are the B-spline control points `PKStrokePath` exposes, not raw touch samples. Never resample.** Stored at full `CGFloat` precision; halving it is a way to lose ink.

| # | Field | Source |
|---|---|---|
| 0 | x | `location.x` |
| 1 | y | `location.y` |
| 2 | timeOffset | |
| 3 | size.width | |
| 4 | size.height | |
| 5 | opacity | |
| 6 | force | |
| 7 | azimuth | |
| 8 | altitude | |
| 9 | secondaryScale | |
| 10 | threshold | |

`lateralJitter` from the earlier draft does not exist in the SDK. Reconstruct with `PKStrokePoint(location:timeOffset:size:opacity:force:azimuth:altitude:secondaryScale:threshold:)` — the widest initializer there is. **`threshold` is not optional:** rebuilding crayon strokes without it (the 7- and 8-argument initializers) changes 28,011 pixels of a 260k-pixel render.

### Stroke identity

PencilKit has no stroke id. `StrokeIDMap` recognises a stroke by what survives every operation the canvas performs on it — `(creationDate, randomSeed, pointCount, first point, last point)` — and deliberately not by its transform (lasso move) or mask (partial erase). On save, a stroke matching a known fingerprint keeps its UUID; a new one is assigned. The file carries the ids, so a load restores the map and the next save keeps them. Strokes a shape tool creates in the same instant differ by their points. Tested across add, vector erase, move, partial erase, same-instant bursts, and save/load/save.

### Fidelity (M0 task 17, measured)

`PKDrawing.image(from:scale:)` at 2×, original vs round trip, 3 strokes of 32 points, ~250k pixels:

| Ink | Differing pixels | Max channel Δ |
|---|---|---|
| pen, pencil, monoline, fountainPen, watercolor | **0** | 0 |
| marker | 52 | 3 |
| crayon | 182 | 28 |
| mixed page (all types, masks, transforms) | 20 | 3 |

The marker and crayon differences are not information the format drops. `PKStrokePoint` quantizes azimuth, altitude and threshold on construction (0.2 reads back as 0.19998474 — a 16-bit grid; azimuth 0 reads back as −4.8e−5), and constructing a point from read-back values re-quantizes with rounding: one quantum of drift, once. **A second trip is pixel-identical to the first.** Apple's `dataRepresentation()` is exact only because it stores the internal representation the public API cannot reach. Recorded tolerances (with headroom): marker 150, crayon 400, mixed 100.

Two further facts the harness surfaced: `PKDrawing`'s `==` compares an internal drawing identity, not content (`PKDrawing() == PKDrawing()` is false), so content equality is checked stroke by stroke; and `PKDrawing(data:)` parses some short byte strings as an empty drawing rather than throwing, so `DrawingStore` checks the `wrd\xf0` archive header before trusting an empty result.

### Storage (16b, landed)

`<id>.strokes` is the source of truth for every ink type and the only ink file that syncs. `<id>.drawing` stays as a local render cache, used only when `<id>.drawing.key` holds the SHA-256 of the current `.strokes` bytes — so the user's own device never sees the one-quantum drift, while every other reader gets the neutral file. No per-type dual-write flags. A page from before the flip has only a `.drawing`; it loads and its record is written on first load. A damaged record with a readable cache is quarantined and regenerated from the cache. All of it lives in `DrawingStore`.

---

## 6. Timeline (`timeline/<uuid>.events`) — M3

Append-only event log. Each record:

```
eventID       16 bytes (uuid)
timestamp     float64
kind          uint8   (strokeAdded | strokeErased | elementAdded | elementMoved | elementDeleted | pageCleared)
targetID      16 bytes
payloadLen    uint32
payload       bytes
```

Replaying from empty must reproduce the current page exactly. That property is what makes the scrubber, version history, and audio binding all the same feature.

Periodic snapshots (every N events) keep replay fast. Snapshots go in `timeline/<uuid>.snapshot.<n>`.

---

## 7. Graph links (`graph/links.json`)

```jsonc
{
  "nodes": [
    {
      "nodeID": "uuid",
      "kind": "page | inkRegion | textBlock | document",
      "pageID": "uuid | null",
      "label": "string",
      "graphPosition": { "x": 0, "y": 0 },
      "bounds": { "x": 0, "y": 0, "w": 0, "h": 0 }
    }
  ],
  "links": [
    {
      "linkID": "uuid",
      "from": "node-uuid",
      "to": "node-uuid",
      "kind": "explicit | tag | transclusion",
      "createdAt": "ISO8601"
    }
  ]
}
```

`graphPosition` is persisted deliberately. Spatial memory is a feature; layout must not jump between launches.

Cross-document links use a fully qualified `documentID:nodeID`. Dangling links are kept, not deleted, and rendered as broken — so a link survives a document being temporarily unavailable during sync.

### 7.1 Sync snapshot, format 5 (Nov 2, 2026)

The folder's `librarySnapshotFormatVersion` is 5. A build that reads a newer folder refuses it rather than guessing; a format-4 build would strip the fields below on its next write. History: 3 added the M2 link fields, 4 `FolderDTO.smartQuery`, 5 the following.

**Link kinds** (`LinkDTO.kind`; all optional, nil is a plain page link):

| `kind` | Meaning | Draws on the page | Key fields |
|---|---|---|---|
| nil | Explicit link / anchor | A tappable anchor | `destinationPageID`; with `destinationKind = "region"`, `destinationID` is the node's id; optional `strokeIDs` of the anchor |
| `node` | A named region of strokes (self-link on its page) | Nothing (badge in the graph UI) | `destinationKind = "region"`, `strokeIDs`, `title` (never empty), anchor = region bounds when last seen |
| `mention` | `[[ ]]` reference from a text block | Nothing | `destinationID` = text block key, `title` = inserted label (nil until M2 task 6 writes it) |
| `transclusion` | A node's ink shown on another page | The node's ink | `destinationKind = "region"`, `destinationID` = node id; no `strokeIDs` of its own |
| `tape` | A strip covering a region of ink, for recall (M4 seed) | A peelable opaque strip over the anchor, on screen only: never exported, never in a thumbnail (the ink is the data) | Self-link, `destinationKind = "region"`, `strokeIDs` of the covered ink, no `title`, anchor = the region's bounds when made, `reviewState` |

Tags are never stored as links; the graph derives them from `Page.tags`.

**`LinkDTO.title`** (new, optional, absent in format 4): a node's name or a mention's label.

**`LinkDTO.reviewState`** (new, optional, absent before; also format 5, since no device runs format 5 yet): a tape's spaced-repetition schedule, a JSON string `{"due": "<SnapshotDates string, ms>", "interval": <days, Double>, "ease": <Double>, "reps": <Int>, "lapses": <Int>}`. nil means never reviewed, which counts as due. Only `kind = "tape"` carries it. It is written only through `Links.setReviewState`, which marks the source page, so it travels and merges with the page (per-page last-writer-wins on `modifiedAt`): two devices reviewing tapes on different pages both keep their grades; the same page, the later edit wins. A format-4 build would drop it on its next write of the page, hence the same format bump. Scheduling is `ReviewScheduler` (SM-2 lite: Again due in 10 minutes, ease -0.2; Hard x1.2 and ease -0.15; Good 1 day, 3 days, then x ease; Easy Good x1.3 and ease +0.15; ease floor 1.3).

**`Notebook.role`** (new, optional, absent in format 4; in `NotebookIndexEntry` and `NotebookDTO`): marks a notebook the app itself uses. `"templates"` is the custom page-templates notebook; nil is an ordinary notebook. It is a notebook setting and merges on `settingsModifiedAt` like the title and cover.

**`Notebook.manualOrder`** (new, optional, absent before; in `NotebookIndexEntry` and `NotebookDTO`; also format 5, since no device runs format 5 yet): the notebook's position in the library's Custom sort, among the notebooks of its folder. A `Double`; smaller sorts first; nil sorts after every numbered notebook (then by `modifiedAt`, newest first). A move writes the midpoint of the new neighbours (or the end neighbour -/+ 1.0) and, when the gap falls below 1e-6, renumbers the whole level 1, 2, 3... Every write goes through `markSettingsModified(at:liftModifiedAt: false)` (so a reorder doesn't change the notebook's Edited date), so it merges on `settingsModifiedAt` with the title and cover. The index signature needs no change: a changed order moves `settingsModifiedAt`. Moving a notebook to another folder clears its `manualOrder`.

**`PageDTO.recordings`** (new, optional, absent before and when a page has none; also format 5, since no device runs format 5 yet): audio recorded while writing, an array of `RecordingDTO`:

| Field | Meaning |
|---|---|
| `id` | Stable record id |
| `startedAt` | Wall-clock start (`SnapshotDates` string, ms). Strokes carry creation dates; `startedAt` plus a stroke's date minus it is the stroke's offset in the audio, which is how playback follows the ink |
| `duration` | Seconds |
| `fileRef` / `fileHash` | Local name (`<uuid>.m4a`, AAC 44.1 kHz mono) and SHA-256. The payload is `files/<hash>.m4a`, content-addressed, immutable, copied exactly like an imported document's file |
| `title` | Optional name |
| `transcript` / `transcriptSegments` | Optional, absent before transcription. On-device speech-to-text: the plain text, and a JSON string `[{"start": <s>, "end": <s>, "text": "..."}]` (seconds into the audio, segments of at most ~12 s). Derived data, decided like the OCR fields: writing them does **not** call `Page.markModified`, so a transcript never out-ranks a real edit elsewhere. They travel in the `RecordingDTO` whenever the page is next pushed and are replaced with the page on a pull. A reader that ignores them loses nothing |

Recordings travel inside their page, so they merge with it (per-page last-writer-wins on `modifiedAt`) and are never merged on their own. Adding or deleting one calls `Page.markModified`. Deleting moves the file to `trash/` unless another recording still names it. A format-4 build would drop `recordings` on its next write of the page, hence the same format bump. Exports put the files in `<Notebook>/Recordings/` and list `Audio: <title> (<m:ss>)` under the page in the Markdown, with an indented `Transcript: ...` line beneath it when the recording has one. Backups carry them because a backup is a sync folder.

**Folder order is not in the format.** Folders have no settings clock: they merge as a flat upsert by id, so a synced `manualOrder` would last-writer-win across unrelated edits and could not be compared. Folder Custom order is therefore per device, in `AppSettings` (`libraryFolderOrder`, JSON `{"<folder id>": Double}`). Sort key, direction and grid/list choice are per device too. Revisit if folders ever get a settings clock.


---

## 8. Write protocol

Every mutation follows this sequence. No shortcuts.

1. Write a `journal/<txn>.wal` entry describing the intended change.
2. Write new content to temporary files inside the package.
3. `fsync`.
4. Atomically replace the target files.
5. Update `manifest.json` (`modifiedAt`, `checksum`) atomically.
6. Delete the journal entry.

On launch, any surviving `journal/` entry means the last write didn't complete: roll forward if the temp files are complete and valid, otherwise roll back. Either way, load cleanly.

`DurabilityTests` kills the process at each of steps 1–6 and asserts a clean load every time.

---

## 9. SwiftData index (rebuildable, not frozen)

The folder is the source of truth. SwiftData is a **local cache** that must be reconstructible from the folder alone. If it is ever wrong or corrupt, delete the store and re-index. There must be a tested rebuild path.

The existing models in `MystNotesModels.swift` — `Folder`, `Notebook`, `Page`, `TypedTextBlock`, `Sticker`, `ImportedDocument`, `Link` — are already the right shape: every property optional or defaulted, no unique constraints, cascade deletes wired. Keep that discipline; it costs nothing and preserves the option of adding CloudKit later.

**One field is missing and it is the highest-priority change in M0:**

| Field | Type | Why |
|---|---|---|
| `Page.modifiedAt` | `Date` | Without it, sync cannot merge below whole-notebook granularity, and `SyncEngine.rebuild()` destroys a page's edits when the other device's notebook timestamp is newer. See `PROJECT_PLAN.md` §1.2 Blocker 1. |

Fields to add alongside the graph work (M2), in the package first and mirrored into the index only for query speed: `tagsFlat`, `isFavorite`, `nodeID`.

**Nothing goes in SwiftData that cannot be regenerated from the folder.** If a feature seems to need a column that can't, the data belongs in the package.

## 10. Versioning and migration

- `formatVersion` in `manifest.json` is the gate.
- Readers handle `formatVersion <= current`. A higher version opens **read-only** with a clear banner, never silently downgrades.
- Migration is per-document and lazy, on first open, with a backup copy taken first.
- Every migration is covered by a test with a real fixture document from the previous version. Keep fixtures in the repo forever.
- Unknown JSON keys and unknown element kinds are always preserved on write.

### Migrating from the Step 1 layout

1. Read `index.json` and each `notebooks/<uuid>.json`.
2. For each notebook, create `Notebook-<uuid>.mystnote/`, write each page's JSON and ink as hashed blobs, and write the manifest pointing at them.
3. Copy payloads from the flat `files/` directory into `assets/` — they are already SHA-256 named after Step 1, so this is a move, not a rehash.
4. Leave the Step 1 files in place until the new packages verify. Do not delete the old layout in the same run.
5. Verify by rebuilding the SwiftData index from the packages alone and diffing against the index rebuilt from the Step 1 files. They must match.
6. Only then move the Step 1 files to `trash/`.

---

## 11. Export targets

Every one of these must exist before v1.0.

| Target | Notes |
|---|---|
| `.mystnote` package | Full fidelity, the open format |
| PDF (flattened) | Ink rendered into the page |
| PDF (layered) | Original PDF plus annotations as real PDF annotations where possible |
| PNG / JPEG | Per page |
| Markdown | Typed content, links as `[[wikilinks]]`, ink as embedded images |
| Plain text | Recognized handwriting + transcripts |
| Audio | Original `.m4a` files plus transcript |

"Export everything" produces a single zip of all packages plus a `README.txt` explaining the format. Ship this in M0 or M1. It is the cheapest trust a free app can buy.

### 7.2 Stroke ids after erasing (Nov 2, 2026)

A stroke id is stable, but it is not always one stroke. When the vector eraser splits a stroke, every piece keeps the original's id, matched on `creationDate` and `randomSeed` once the original is gone. So one id can name several strokes, and anything that points at ids (links, nodes, transclusions) must expect one-to-many. Two strokes that both exist with the same date and seed always keep different ids. An erased stroke's id is remembered for the session (in memory only, never in the file) so an undo brings it back with the same id.
