# MystNotes — Project Plan: Personal App to Shippable Product

**Version:** 1.1 — revised after reading the actual repo at `~/Desktop/Mystnotes`
**Date:** September 12, 2026
**Owner:** Myst
**Codebase at time of writing:** 8,179 lines of Swift across 42 files, 26 commits, HEAD `72a0eba` (Sept 11, 2026)
**Objective:** Convert MystNotes from a personal iPad/Mac note app into a free, publicly shippable product with a credible path to cross-platform.

---

## 0. The one-paragraph version

MystNotes is much further along than a phase list suggests. The drawing layer is genuinely competitive: a custom GoodNotes-style toolbar driving PencilKit directly, five ink types, a fill tool GoodNotes doesn't have, image crop/rotate/resize, working handwriting search, export, onboarding, a tutorial notebook, and a folder-based sync engine that sidesteps the paid-developer-account problem entirely. What stands between it and other people's coursework is narrower than expected and sharper: **the sync engine can silently destroy a page, PDFs are rasterized on import, and there is not a single test in the repo.** This plan fixes those three things first, then spends the remaining effort on the thing nobody else has: notes as a connected graph you can draw on, with time travel built in.

---

## 1. What's actually built

Read from the repo, not from memory. This section exists because the old plan under-counted the work by a lot.

### 1.1 Done and genuinely good — do not rebuild

**Drawing**
- Custom floating toolbar (`DrawingToolbarView`, 273 lines) driving `PKCanvasView.tool` directly rather than showing `PKToolPicker`. Pencil input still goes through PencilKit's low-latency path; only the tool UI is custom. This was the right call.
- Five ink types (pen, pencil, marker, fountain, monoline), continuous width slider, per-tool independent color/width memory
- Dedicated highlighter, eraser with vector and bitmap modes, lasso, shape tool with recognition (`ShapeRecognizer`)
- **Fill/bucket tool** (`FillTool`, 190 lines) — GoodNotes doesn't have this
- Undo/redo, autosave per stroke, manual save with confirmation
- Per-page canvas with real page zoom (HEAD commit), `CanvasGestures` at 751 lines
- Dark-mode ink handling, fixed across three separate commits

**Documents and media**
- PDF and photo import, `ImportedArtwork` + `ImportedPageBackgroundView`
- Image placement with live preview, resize matching Google Docs/Freeform behavior, rotate, crop (`ImageCropOverlay`, `ImageAdjustOverlay`, `ImageAdjustToolbar`)
- Per-page `aspectRatio` set from the PDF's media box, so an imported page *is* the page rather than a picture floating on a differently-shaped canvas. Nice detail.

**Organization and navigation**
- Nested folders, 6 notebook cover styles, thumbnail strip, page add/delete/reorder
- Four page templates, whiteboard page type
- Multi-window, presentation mode, `FolderPickerView`

**Search**
- Vision OCR pipeline (`HandwritingRecognizer`, `SearchIndex`, `SearchResultsView`), composites ink onto opaque white before recognition because Vision returns nothing on transparent. Indexed across typed text, PDF text, and handwriting. Tap-through to the matching page.

**Product surface already shipped**
- Onboarding (`OnboardingView`), login (`LoginView`), settings (`SettingsView`), tutorial notebook (`TutorialNotebookFactory`, 303 lines), export (`PageRenderer` + `ShareSheet`)

These last four were on the old plan's M6 "Ship" milestone. They're done. M6 shrinks accordingly.

**Sync**
- `SyncEngine` / `SyncFolder` / `SyncModels` (814 lines) — a folder-based library sync using a user-picked folder and a security-scoped bookmark, with `NSFileCoordinator`, tombstones, and iCloud placeholder download handling. The entitlements file is deliberately stripped of CloudKit so free-account signing works, with the paid version parked in a backup file.

That last one deserves saying plainly: working around the absence of a paid developer account by using a user-chosen synced folder instead of CloudKit is the right architectural instinct, and §3 argues it should become the permanent design rather than a stopgap.

### 1.2 The three things that actually block shipping

Everything else in §1.3 is a feature gap. These three are correctness problems, and they're ordered by how badly they'd hurt.

---

#### Blocker 1: the sync engine can silently destroy a page

`SyncEngine.apply()` merges at **whole-notebook** granularity, last-writer-wins on `Notebook.modifiedAt`. When the remote copy wins, `rebuild()` deletes every local `Page` object and recreates the tree from the DTO.

The failure, concretely:

1. Offline on iPad, you write on page 3. `Notebook.modifiedAt` updates.
2. Offline on Mac, you write on page 7. `Notebook.modifiedAt` updates, slightly later.
3. Sync. Mac's `modifiedAt` is newer, so on the iPad `rebuild()` deletes all pages and recreates them from the Mac's snapshot. **The page-3 edit is gone from the model.**

And then it gets stranger. Page IDs are stable, so page 3's ink file is still `<page3-uuid>.drawing` on disk, and the iPad's copy is *newer* than the folder's. `copyFiles()` only overwrites when the source is newer, so the iPad keeps its own newer ink file. You end up with metadata from one device and ink from the other. Depending on which side pushes next, the result is either a silent loss or a silently mixed notebook.

**Root cause:** `PageDTO` has no `modifiedAt`. `Page` in `MystNotesModels.swift` has no `modifiedAt` either. Merge granularity can't be finer than the notebook because there's nothing to compare per page.

**Fix:** add `Page.modifiedAt`, merge per page, and stop rebuilding the whole tree. This is a small change with a very large payoff and it is the single highest-priority item in this plan.

---

#### Blocker 2: `library.json` is one file holding the entire library

Every push serializes the whole library — every folder, every notebook, every page, every text block, sticker, link and imported document — into a single `library.json` and overwrites it.

- One bad write, one truncated sync, one decode failure, and the entire library's metadata is gone. The ink files survive on disk, but nothing knows what they belong to.
- There is no backup. No previous snapshot is retained.
- iCloud Drive conflict versions are never read. `readSnapshot()` opens `library.json` and nothing else, so if two devices write it simultaneously, iCloud keeps a conflict copy and the app silently ignores one device's entire library state.
- It doesn't scale. At 200 notebooks this file is megabytes, rewritten on every backgrounding.

**Fix:** split it. One file per notebook, plus a small index. Keep the last N snapshots of the index. Read and resolve `NSFileVersion` conflict versions instead of ignoring them.

---

#### Blocker 3: there are no tests

No test target. No test files. Zero. For an app whose core promise is "I will not lose your handwriting," and whose sync engine has the bug in Blocker 1, this is the gap that makes everything else risky to change.

**Fix:** a durability suite and a sync suite, before the sync rewrite, so the rewrite is verifiable.

---

### 1.3 Feature gaps versus GoodNotes, Notability, and Apple Notes

Smaller than the old draft claimed, because so much is already built.

| Gap | Who has it | Severity |
|---|---|---|
| **PDF import rasterizes to JPEG** — `ImportedArtwork.render(_:within:)` draws each `PDFPage` into a `UIGraphicsImageRenderer` and writes `jpegData(compressionQuality: 0.9)`. No text selection, no PDF text in search, blurry at zoom, large files. | Both, properly | Critical |
| **No audio recording** | Notability's entire identity; Apple Notes too | High |
| **No handwriting → text conversion.** The Vision pipeline exists for search; exposing it as lasso-to-convert is a small delta. | Both | High |
| **No document tabs or two-note split view.** Multi-window helps on iPad but isn't the same. | GoodNotes tabs, Notability split | High |
| **No import from GoodNotes or Notability** | — | High |
| **Templates are four global options.** No per-page choice, no custom sizes, no imported templates. `Page.aspectRatio` already exists, so the model is half there. | Both | Medium |
| **No favorites, bookmarks, or page outline** | Both | Medium |
| **No off-device backup target** (Dropbox/Drive/OneDrive) | Both | Medium |
| **No note lock** | GoodNotes, Apple Notes | Medium |
| **No iPhone target** | All three | Medium |
| **No App Intents, Shortcuts, Spotlight, Quick Look** | Apple Notes deeply | Medium |
| **No accessibility pass** | All three | Medium |
| **No tags or smart folders** | Apple Notes | Medium |
| **No Math Notes equivalent** | Apple Notes (with 3D graphs in iOS 26) | Medium — high personal value for engineering coursework |
| **No collaboration or share links** | Both, incl. real-time | Deferred, see §5 |

### 1.4 Shipped but broken

Two tools are in the toolbar and neither works well enough to keep as-is. Full diagnosis in `Docs/TOOL_FIXES.md`.

**Shape tool.** Produces only ovals and straight lines, at a fixed thickness, behind a separate armed mode. Four independent bugs in `ShapeRecognizer.swift`:

1. `isRoughlyCircular` uses a threshold of `stdDev / avgRadius < 0.28`. A square's coefficient of variation is about 0.10, so **squares classify as circles**. This one threshold explains the whole "only ovals" symptom.
2. `PKStrokePath(controlPoints:)` takes **cubic B-spline control points**, so five rectangle corners get smoothed into a rounded, shrunken blob. The ellipse only survives because it's sampled at 72 points. Sharp corners need control-point multiplicity 3.
3. `size: CGSize(width: 4, height: 4)` is hardcoded — the same bug class as the tool-colour one already fixed once. Width lives on `PKInkingTool`, not `PKInk`, so it never reaches the recognizer.
4. The closed-shape test is too strict; anything failing it becomes a straight line from first point to last, which is where the stray diagonals come from.

It also only handles axis-aligned rectangles, and has no triangle, arrow, or polygon support at all.

The interaction changes too: **hold the stroke to snap**, the way GoodNotes and Apple Notes do it, instead of arming a toolbar button. That deletes `ShapeDrawingOverlay` and a mode, and means the freehand phase uses real ink with real pressure instead of a 2px `DragGesture` preview.

**Fill tool.** Doesn't work, and has been fixed twice already. The design is sound — rasterize, scanline flood fill, synthesize horizontal `PKStroke`s so the fill is erasable ink rather than a bolted-on image layer — and the scanline implementation looks correct. The leading hypothesis is that HEAD's "real page zoom" commit broke the coordinate-space assumption the function documents: the tap overlay's space is no longer identical to the canvas's local space, so the tap resolves to the wrong pixel and the function returns `nil` silently.

Because it's been rewritten twice on hypothesis, the third attempt starts with instrumentation, not a rewrite. If the fix isn't quick, hide the tool rather than ship a visible button that does nothing.

---

---

## 2. Strategy: what MystNotes is actually for

A feature checklist against GoodNotes is a losing game. They have a team and a decade. Reach the trust floor, then win on a dimension they structurally can't copy quickly.

### 2.1 Notes are a graph, and the graph is a canvas

Every competitor treats notes as a filing cabinet. Obsidian and Roam proved knowledge work is a graph, but they're text-only and hostile to a pencil. Nobody has built a graph you can draw on.

A page, a lasso'd region of ink, or a text block becomes a **node**. The graph view is a real infinite canvas you can write on, and node positions persist, so spatial memory becomes retrieval. The everyday form is a **backlinks strip in the page margin** — while you write, you see what points here.

You already have `Link` with `sourcePageID`, `destinationPageID` and an anchor rect. That's the seed. The graph is a generalization of a model that's already in the codebase, not a new subsystem from nothing.

### 2.2 Handwriting that stays live (ink transclusion)

Lasso a diagram, promote it to a node, reference it on five other pages. Fix the original, all five update. This exists nowhere, and it turns a note app into a knowledge tool without a single AI call.

### 2.3 Time is a free feature nobody uses

`PKStrokePoint` carries a timestamp, so the stroke stream is already a timeline. Record it and you get: scrub any page back through its own writing history; bind audio to the *stroke* timeline rather than wall-clock time like Notability, so tapping a stroke plays what was being said when you wrote it; and per-page version history, which doubles as the strongest possible answer to "will I lose my work."

### 2.4 Recall without building decks

GoodNotes Study Sets and Notability Learn both require you to *make* cards. Nobody does. Lasso any handwriting, hit "quiz me," and the region becomes a cloze deletion **on the ink itself**, masked in place, scheduled by spaced repetition. The note is the deck.

### 2.5 What this adds up to

> MystNotes is the notebook that remembers how you got here. Everything you write is connected, replayable, and searchable by meaning, without you filing anything.

---

## 3. Architecture: folder sync is the design, not the workaround

### 3.1 What sync is today

There is no paid Apple Developer Program membership, so no iCloud entitlement, so no CloudKit — Apple doesn't let free/personal teams register the capability at all. `SyncFolder` works around this properly: the user points `.fileImporter` at any folder, the app keeps a security-scoped bookmark, and whatever service backs that folder (iCloud Drive, in practice) moves it between devices. The entitlements file carries only self-declarable sandbox keys, with the CloudKit version parked in `Mystnotes.entitlements.paid-account-backup`.

**Keep this. Make it the permanent architecture.** Not because CloudKit is unavailable, but because it's better for this app:

- The document is already the sync unit. CloudKit would mean shredding notebooks into records and reassembling them, for no gain.
- It deletes the append-only schema trap. CloudKit's production schema can never drop or retype a field. Folder sync has no schema to freeze.
- **Users own their files.** They can see them in Files.app, back them up, move them. For a free app with no backend and no company behind it, "your notes are files in a folder you chose" is the strongest trust story available, and neither competitor can say it.
- **The folder doesn't have to be iCloud.** Dropbox, Google Drive, Syncthing, or a plain local folder with no sync at all. The picker already allows this. It's a real feature no competitor offers and it costs nothing extra.
- It is the cross-platform path. A folder of open-format files is what a future web or Android client reads.

CloudKit becomes an optional convenience to evaluate much later, if ever.

### 3.2 What's wrong with the current implementation

Beyond Blockers 1 and 2 in §1.2:

| Issue | Where | Consequence |
|---|---|---|
| Payload freshness compared by file mtime | `SyncRunner.copyFiles` | Copies don't reliably preserve mtime and device clocks skew. Wrong file wins. Content hashing fixes this and dedupes for free. |
| Orphaned payloads never pruned | `files/` directory | `referencedFileNames` is computed but nothing deletes what's no longer referenced. The folder grows forever. |
| Tombstones live in `UserDefaults` | `SyncTombstones` | Not in the synced folder, so a reinstall resurrects deleted notebooks. |
| `deleteFiles(for:)` removes `.drawing` files on tombstone application | `SyncRunner` | Irreversible ink deletion driven by a stale tombstone. Should move to a trash folder, not `removeItem`. |
| Sync only on foreground (pull) and background (push) | `ContentView` wiring | A long session never syncs. A crash before backgrounding means the session never pushed at all. |
| No `NSFilePresenter` | — | Changes arriving in the folder while the app is open are invisible. On Mac, where the app stays open for days, this is the common case. |
| `ensureDownloaded` busy-waits with `Thread.sleep` up to 15s | `SyncFolder` | Called per file in a loop. A pull of 200 files can block for a very long time. |
| Two storage roots still exist | `FileStore` | `baseDirectory()` still tries the iCloud ubiquity container (which can't resolve without the entitlement) and `url(for:)` carries a dual-location fallback whose own comment says it exists to stop pages rendering blank. This already caused one shipped bug ("Stop content disappearing when the iCloud sync toggle is flipped"). Now that folder sync exists, delete the ubiquity path entirely. |

### 3.3 The target design: per-notebook files, content-addressed payloads

Don't jump straight to a full package format. Get there in two steps, each independently shippable.

**Step 1 — split and harden the existing snapshot (this is most of M0):**

```
<sync folder>/Mystnotes/
  index.json                      small: notebook ids, titles, folder tree, modifiedAt
  index-history/<ts>.json         last N snapshots of the index
  notebooks/<notebook-uuid>.json  one file per notebook
  files/<sha256>.<ext>            content-addressed payloads
  tombstones.json                 tombstones move here, out of UserDefaults
  trash/                          deleted payloads land here, not removeItem
```

With `Page.modifiedAt` added, merge becomes per page, and the Blocker-1 failure disappears: the iPad's page 3 and the Mac's page 7 both survive because they're compared independently.

**Step 2 — the `.mystnote` package** (see `SPEC_DOCUMENT_FORMAT.md`), where each notebook becomes a directory of immutable blobs plus one small mutable manifest. That structure makes partial arrival detectable, collapses conflicts onto a small mergeable file, and gives version history for free. It's the right end state, but it's a bigger change and it should follow Step 1, not replace it.

### 3.4 Ink must move to a neutral stroke format

Unchanged, and the folder design makes it *more* important: the user-visible folder full of open files currently contains one file type nobody but Apple can read. `PKDrawing` is opaque. If ink only exists in that form, there's no web or Android renderer, ever.

`PKStroke` exposes `PKStrokePath` as a spline over `PKStrokePoint`s, and `PKStrokePath(controlPoints:creationDate:)` rebuilds it, so a faithful round trip is reachable. (The `id:` variant that would preserve stroke identity for free is iOS 27+, so until the deployment target can move, the neutral format owns the IDs.) **Still unproven — it needs the pixel-diff harness in M0.** If an ink type fails tolerance, dual-write the `PKDrawing` for that type and document it.

### 3.5 SwiftData gets demoted

With CloudKit out of the picture, SwiftData is no longer a sync layer needing a frozen schema. It's a **local, rebuildable index** over the folder. If it's ever wrong or corrupt, delete it and rebuild from the files. Schema changes stop being scary.

The models are already CloudKit-shaped (every property optional or defaulted, no unique constraints), which was good defensive work. Keep that discipline — it costs nothing and preserves the option.

### 3.6 States that must be designed, not error-dialogged

Folder not chosen; folder unreachable (bookmark stale, drive unmounted, permission lapsed); file evicted, downloading, or download failed; document mid-sync; conflict version present; provider storage full; two devices writing at once.

`SyncFolder.SyncFolderError` covers three of these. The rest need designed UI. None may lose data or show a stack trace.

### 3.7 The developer program question

You'll need the paid membership ($99/yr) eventually, and the timing matters more than it looks:

- **TestFlight and App Store distribution are impossible without it.** Hard blocker for M6.
- **Free provisioning expires builds after 7 days.** That makes M0's durability work much weaker than it should be, because "run the real app through a week of real classes and see if anything is lost" is exactly the test that catches the bugs that matter. Budget for it before the soak test, not at M6.
- Apple grants membership fee waivers to accredited educational institutions. It goes to the institution, not to individual students, but it's worth ten minutes asking whether UofT Engineering already holds one that covers student projects.

Everything through M5 works fine unpaid.

---

## 4. Roadmap

Seven milestones. **The app is releasable at the end of each one.** Week counts assume serious part-time hours alongside first-year engineering; treat them as sequence, not schedule.

### M0 — Correctness (3–4 weeks) · *blocking, no new features*

Fix the three blockers. Nothing else matters until these are done.

**Tests first, so the rest is verifiable**
1. Add a test target. There isn't one.
2. `DurabilityTests`: kill the process mid-stroke, mid-save, mid-migration. Assert clean load every time.
3. `SyncTests`: a two-library harness driving `SyncEngine` against a temp folder, with the §1.2 scenario as the first failing test — edit page 3 in library A, page 7 in library B, sync, assert both survive. It should fail today.

**Sync rewrite**
4. Add `Page.modifiedAt`, maintained on every mutation.
5. Merge per page. Delete `rebuild()`'s delete-all-pages behavior.
6. Split `library.json` into `index.json` + `notebooks/<uuid>.json` (§3.3).
7. Keep the last N index snapshots in `index-history/`.
8. Read and resolve `NSFileVersion` conflict versions instead of ignoring them.
9. Move tombstones out of `UserDefaults` into `tombstones.json` in the folder.
10. Content-address payloads by SHA-256; drop mtime comparison.
11. Prune orphaned payloads; route deletions to `trash/` rather than `removeItem`.
12. Add periodic debounced push (~30s after last edit), not just on background.
13. Add `NSFilePresenter` so folder changes land while the app is open.
14. Make `ensureDownloaded` async; stop blocking a loop on `Thread.sleep`.

**Storage cleanup**
15. Delete the iCloud ubiquity path from `FileStore`. One storage root. Remove the dual-location fallback in `url(for:)` and the now-dead `syncEnabled` interactions.

**Ink format**
16. Neutral stroke codec: `PKDrawing` → neutral → `PKDrawing`, preserving stroke IDs.
17. Pixel-diff fidelity harness, per ink type. Dual-write any type that fails.

**Proof**
18. Two-device test on iPad and Mac against the real folder, deliberately including: offline edits on both sides, a simultaneous same-page edit, an evicted file, and an open mid-sync.
19. SwiftData index rebuild path: delete the store, reconstruct from the folder, test it.
20. Performance baseline: ink latency on ProMotion, memory with a 500-page PDF, cold launch with 200 notebooks. Record the numbers; they become regression thresholds.
21. Crash reporting.

**Exit:** the §1.2 sync scenario passes, no known path to data loss, index proven rebuildable, durability suite green.

### M1 — Parity Floor (3 weeks)

Smaller than it was, because the toolbar, export, image editing, settings and onboarding are already done.

- **Real PDF annotation.** Replace `ImportedArtwork`'s rasterize-to-JPEG with a live `PDFKit` layer: selectable text, PDF text in the search index, annotations as a separate layer over the real page. Highest-value item in the milestone.
- **Rebuild the shape tool** (`Docs/TOOL_FIXES.md` Part 1): proper classifier with corner detection, sharp corners via control-point multiplicity, width and colour from the active `PKInkingTool`, rotated rectangles, triangles and arrows, and hold-to-snap replacing the armed mode. Delete `ShapeDrawingOverlay`.
- **Fix or hide the fill tool** (`Docs/TOOL_FIXES.md` Part 2): instrument first to find where the tap coordinate goes wrong under page zoom, then fix. If it isn't quick, remove it from the toolbar until it works.
- Lasso upgrades: cross-page move, **convert to text** (the Vision pipeline already exists), resize, recolor, copy as image
- Per-page templates, custom page sizes, imported templates, a starting template library. `Page.aspectRatio` means the model is half done.
- Favorites, bookmarks, page outline / jump bar
- Text formatting in typed blocks: bold/italic, headings, bullets, checklists
- Scribble-to-erase; toolbar customization; pen presets
- Export additions: layered PDF, markdown for typed content, whole-library zip
- Note lock via Face ID
- Off-device backup target

**Exit:** a GoodNotes user can do a full day of classes without hitting a wall.

### M2 — The Graph (3–4 weeks) · *differentiator #1*

- Generalize `Link` into a node/edge model: page, ink region, text block, notebook
- Link types: explicit, tag, transclusion
- `[[` autocomplete in text blocks; lasso → "link this to…"
- **Backlinks strip** in the page margin, live while writing
- **Graph canvas:** force-directed initial layout, then manually and *persistently* positioned; pan/zoom; filter by tag, folder, recency; drawable
- **Ink transclusion:** lasso → promote to node → reference elsewhere; edits propagate
- Tags and saved searches as smart folders
- Link integrity on delete and move (extend existing orphan cleanup)

**Exit:** you can navigate a semester entirely through the graph and never open a folder.

### M3 — Time & Voice (3 weeks) · *differentiator #2*

- Persist the stroke timeline per page
- **Replay scrubber** with playback speed; per-page version history and restore on the same mechanism
- Audio recording via `AVAudioEngine`, background-safe, interruption-resilient
- On-device transcription via **`SpeechAnalyzer` / `SpeechTranscriber`** (iOS 26), not `SFSpeechRecognizer`
- **Stroke-bound audio:** tap a stroke → play that moment; tap a transcript word → scrub ink to it
- Lecture Mode: ink, waveform and live transcript on one timeline
- Transcripts feed the search index

**Exit:** a strictly better lecture recorder than Notability, on the axis Notability owns.

### M4 — Recall (3 weeks) · *differentiator #3*

- Semantic search over recognized text, transcripts and typed content using on-device embeddings (`NaturalLanguage`, or a small Core ML model). "That thing about entropy" should find a page that says "disorder."
- Unified ranked search across ink, typed text, PDF text, transcripts, titles, tags
- **Lasso → quiz me:** ink region becomes a cloze deletion masked in place
- Spaced repetition (SM-2 is fine)
- Review inbox, graph-driven so related material surfaces together
- Handwritten equation recognition → live evaluation and re-evaluation on edit

**Exit:** the app helps you pass the course, not just take notes in it.

### M5 — Switch Costs & Reach (2–3 weeks)

- **Importers.** GoodNotes and Notability formats are proprietary and undocumented; this is a **timeboxed research spike**, not a promised deliverable. Guaranteed fallback: excellent PDF-with-annotations import (which M1 enables) plus Apple Notes markdown import.
- iPhone target: quick capture into a graph inbox node, plus read and review
- Mac Catalyst polish: menu bar, keyboard shortcuts, trackpad, drag and drop
- App Intents / Shortcuts, Spotlight indexing, Quick Look thumbnails
- Handoff
- Apple Pencil Pro: squeeze, barrel roll, double-tap, hover preview
- **Insert-space-in-handwriting:** lasso a point, push everything below down, reflow ink. Top-three daily annoyance in every note app; nobody does it well.

### M6 — Ship (2 weeks)

Shorter than planned — onboarding, settings, tutorial notebook and export already exist.

- Buy the developer membership (needed earlier, per §3.7, but hard-required here)
- Refresh onboarding to teach the graph in under 60 seconds
- **Accessibility pass:** VoiceOver, Dynamic Type, contrast, reduced motion
- Localization scaffolding (strings extracted, English-only at launch)
- App Store: privacy manifest (required), privacy policy, support URL, screenshots, preview video, description, keywords
- TestFlight: internal → 20 friends → public link, with a structured feedback channel
- In-app feedback and diagnostics export
- Metrics: crash-free rate, sync failure rate, data-loss reports. Nothing creepy.

**Exit:** public App Store release, free, no paywall.

### M7 — Cross-Platform Foundation (ongoing, starts after M2)

- **Web renderer** for the neutral stroke format (Canvas or WebGL). Proves the format is portable and gives read-only share links.
- Share-a-link viewer: publish a page or notebook as a URL rendering real ink in a browser
- Sync service spike: what a non-folder backend looks like, what it costs, what it breaks
- Evaluate CRDTs (`automerge-swift`) for the eventual multi-device and multi-user path

---

## 5. Explicit non-goals for v1

- **Real-time collaborative editing.** Needs a backend and CRDTs. M7 at the earliest.
- **AI chat with your notes.** Both competitors have it; it's becoming table stakes rather than a differentiator, and it costs money per query that a free app can't absorb. M4's on-device semantic search delivers most of the value at zero marginal cost.
- **Native Android and Windows clients.** The M7 web viewer is the cheap reach.
- **Template marketplace.** Content problem, not a product problem.
- **Any paywall, subscription, or StoreKit work.** Free.

---

## 6. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| The §1.2 whole-notebook merge bug reaches real users | Silent handwriting loss; unrecoverable reputation damage | M0 items 3–5. The failing test comes before the fix. |
| `library.json` lost or corrupted | Entire library's metadata gone at once | Split per notebook, keep index history, resolve conflict versions |
| Changing sync without tests breaks something worse | Regression in the one system that must not fail | Test target and sync harness before the rewrite, not after |
| Neutral stroke format loses ink fidelity | Kills the cross-platform premise | Pixel-diff harness per ink type; dual-write fallback |
| Partial package arrival looks like corruption | Destroys trust instantly | Immutable blobs + single mutable manifest (Step 2); missing blob means "syncing", never "corrupt" |
| Security-scoped bookmark goes stale | App silently can't find the library | Refresh on launch (partly handled in `SyncFolder.withFolder`), clear re-pick flow, never fail silently |
| No paid membership until late | 7-day expiry makes week-long soak testing impossible; M6 blocked outright | Buy before M0's soak test; check the UofT institutional waiver first |
| Graph view becomes a slow hairball at 1000+ nodes | Flagship feature feels broken | Level-of-detail, clustering, filtering; benchmark at 5000 synthetic nodes |
| Competitor importers unreachable | Weakens adoption | Timeboxed spike; PDF + markdown fallback is already solid |
| Fill tool gets rewritten a third time on a guess | Weeks lost on a tool that's already failed twice | Instrument before touching it; hide it if the measured fix isn't small |
| Scope creep from the parity checklist | Never ships | §5 is binding. Anything outside the current milestone goes to `BACKLOG.md`. |
| First year of engineering eats all available time | Slips | Milestones ship independently; stopping after M1 still leaves a real app |

---

## 7. Definition of done for v1.0

A quality bar, not a feature list.

1. A week of real classes taken in the app with no data loss and no crash.
2. Two-device sync verified through the real folder, including offline edits on both sides, a simultaneous same-page edit, an evicted file, and an open mid-sync. Nothing lost in any of them.
3. A 300-page annotated PDF opens in under 2 seconds and scrolls at 120fps.
4. Ink latency indistinguishable from Apple Notes side by side.
5. Every user can export 100% of their data in an open format in one tap.
6. A first-time user creates their first link and sees their first backlink within five minutes, unprompted.
7. VoiceOver can navigate the library and read note titles and typed content.
8. Crash-free session rate above 99.5% across a 20-person TestFlight cohort for two weeks.

---

## 8. How to work this plan

- `CLAUDE.md` goes at the repo root. It's the working agreement and standing context for Claude Code.
- `SPEC_DOCUMENT_FORMAT.md` and this file go in `Docs/`. The spec is a contract; change it deliberately and bump the version.
- One milestone at a time. Start each session by pointing Claude Code at `CLAUDE.md` and naming the milestone and task.
- Everything outside the current milestone goes in `BACKLOG.md` instead of into the code.
- M0 is not optional and cannot be reordered. Every other milestone can slip; that one can't.

---

## Sources

- [GoodNotes vs. Notability app review, Paperlike (2026)](https://paperlike.com/blogs/paperlikers-insights/app-review-goodnotes-vs-notability)
- [Introducing Goodnotes 6, Goodnotes Blog](https://www.goodnotes.com/blog/introducing-goodnotes-6)
- [Notability: AI Notes & Planner, App Store listing](https://apps.apple.com/us/app/notability-ai-notes-planner/id360593530)
- [New Apple Notes iOS 26 features](https://www.geeky-gadgets.com/apple-notes-ios-26-new-features-guide/)
- [Import and export Markdown in Apple Notes, iOS 26](https://www.macrumors.com/how-to/ios-import-export-markdown-apple-notes/)
- [Bring advanced speech-to-text to your app with SpeechAnalyzer, WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Squeeze the most out of Apple Pencil, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10214/)
- [PKStrokePoint reference](https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct)
- [PKStrokePath reference](https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct)
- [automerge-swift](https://github.com/automerge/automerge-swift)
- [Apple Developer Program fee waivers](https://developer.apple.com/help/account/membership/fee-waivers/)
