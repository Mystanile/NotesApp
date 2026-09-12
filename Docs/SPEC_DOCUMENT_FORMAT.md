# SPEC: The `.mystnote` Document Format

**Format version:** 1
**Status:** Draft — the Step 2 target. Step 1 (splitting `library.json`) lands first; see §0.
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

*Landed Sept 12, 2026 (M0 task 6):* `index.json` (format 2) and `notebooks/<uuid>.json`. Each index entry carries the notebook's settings, `settingsModifiedAt`, and a `contentSignature` — SHA-256 over `(pageID, modifiedAt)` — so a puller opens only the notebook files whose page set differs from its own, and a push rewrites only those. A notebook file the index promises but that hasn't arrived leaves the pull incomplete (retried next time) and is excluded from the next push. `formatVersion` newer than the build is refused. A format-1 `library.json` is read once if no index exists and never touched again. Still to come from this list: `index-history/`, content-addressed `files/`, `tombstones.json`, folder-side `trash/`.

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

The most important file in the system. Binary, little-endian, length-prefixed.

### Header

| Field | Type | Notes |
|---|---|---|
| magic | 4 bytes | `MYSK` |
| version | uint16 | 1 |
| strokeCount | uint32 | |
| flags | uint32 | bit 0: has timeline; bit 1: dual-write PKDrawing authoritative |

### Per stroke

| Field | Type | Notes |
|---|---|---|
| strokeID | 16 bytes | UUID, stable across edits |
| inkType | uint8 | enum, see below |
| color | 4 bytes | RGBA8 |
| baseWidth | float32 | |
| transform | 6 × float32 | affine |
| maskPathLen | uint32 | 0 if unmasked |
| maskPath | bytes | serialized path, for lasso-erased strokes |
| creationDate | float64 | seconds since reference date |
| pointCount | uint32 | |
| points | pointCount × 48 bytes | see below |

### Per point (12 × float32 = 48 bytes)

**These are cubic B-spline control points, not raw touch samples.** `PKStrokePath` is a collection of control points; iterating it gives you exactly what you need to reconstruct the path. Do not resample.

| Offset | Field | Source |
|---|---|---|
| 0 | x | `PKStrokePoint.location.x` |
| 4 | y | `.location.y` |
| 8 | timeOffset | `.timeOffset` |
| 12 | size.w | `.size.width` |
| 16 | size.h | `.size.height` |
| 20 | opacity | `.opacity` |
| 24 | force | `.force` |
| 28 | azimuth | `.azimuth` |
| 32 | altitude | `.altitude` |
| 36 | secondaryScale | `.secondaryScale` |
| 40 | threshold | `.threshold` |
| 44 | lateralJitter | `.lateralJitter` |

The last three matter. `secondaryScale`, `threshold`, and `lateralJitter` drive the newer ink renderers (watercolor, crayon, and friends). Dropping them is the most likely cause of a failed fidelity test, so capture them from the start even though the older initializer doesn't take them.

Construct points with the widest initializer available:
`PKStrokePoint(location:timeOffset:size:opacity:force:azimuth:altitude:secondaryScale:threshold:lateralJitter:)`, falling back to narrower overloads on older OS versions and recording which one was used.

### Ink type enum

Stable integers, append-only. Never renumber.

```
0 pen        1 pencil     2 marker      3 monoline
4 fountain   5 watercolor 6 crayon      7 highlighter
8 eraserBitmap  9 eraserVector
255 unknown  (preserve raw attributes in a sidecar)
```

### Round trip

```
PKDrawing → [PKStroke] → [PKStrokePath control points] → neutral stream    (write)
neutral stream → PKStrokePath(controlPoints:creationDate:id:)
              → PKStroke(ink:path:transform:mask:) → PKDrawing              (read)
```

Use the `id:` variant of the path initializer. Preserving `PKStrokePath.id` across a round trip is what lets the timeline, ink transclusion, and cloze regions keep pointing at the same stroke after a save/load cycle. Without it, every reload orphans every stroke reference.

All of the above is iOS 14+ / macOS 11+, so there is no availability problem.

**This round trip is unproven and must be validated before anything is built on it.** M0 task 3 renders the original and the reconstruction to bitmaps and compares them per ink type. If an ink type fails tolerance, set flag bit 1 for that stroke's document and dual-write the `PKDrawing` as authoritative for it. Document which types fall back and why.

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
