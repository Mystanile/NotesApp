# CLAUDE.md — MystNotes

Standing context for Claude Code. Read this before touching anything.

---

## What this is

MystNotes is a handwriting-first note app for iPad and Mac (Mac Catalyst), built in SwiftUI + PencilKit, with SwiftData for metadata and files on disk for payloads. It started as a personal GoodNotes/Notability alternative and is being converted into a free, publicly shipped product.

Long-term thesis: notes are a **connected graph you can draw on**, with **stroke-level time travel** and **recall built in**. Not a filing cabinet.

Full context: `Docs/PROJECT_PLAN.md`. Regression floors: `Docs/PERFORMANCE_BASELINE.md`. Format contract: `Docs/SPEC_DOCUMENT_FORMAT.md`. Shape and fill tool diagnosis: `Docs/TOOL_FIXES.md`. Out-of-scope ideas: `Docs/BACKLOG.md`. Open spike: `Docs/SPIKE_ICLOUD_CONFLICTS.md` (decides task 8).

---

## Current state (read this before proposing anything)

**~10,200 lines of Swift in 50 app files, plus ~2,300 lines of tests in 10 files (73 tests, all green). 50 commits; M0 lives on `m0-correctness`, 24 commits past `main`. Far more is built than a phase list suggests.**

Already working, don't rebuild: custom PencilKit toolbar with 5 ink types and per-tool color/width memory, highlighter, vector and bitmap erasers, lasso, shape recognition, fill/bucket tool, per-page canvas with real zoom, PDF and photo import with crop/rotate/resize, nested folders, notebook covers, thumbnail strip, four templates, whiteboard page type, multi-window, presentation mode, Vision OCR handwriting search with tap-through results, page and notebook export, onboarding, login, settings, tutorial notebook, and folder-based sync.

**Two shipped tools are broken (M1).** The shape tool only makes ovals and lines at a fixed thickness — four separate bugs in `ShapeRecognizer.swift`, including a `stdDev/avgRadius < 0.28` threshold that classifies squares as circles (a square's coefficient of variation is ~0.10), and passing polygon corners to `PKStrokePath(controlPoints:)`, which treats them as cubic B-spline controls and rounds every corner. It should also trigger by holding the stroke, not by arming a toolbar button. The fill tool doesn't work and has been fixed twice; the leading hypothesis is that HEAD's page-zoom commit broke the coordinate-space assumption its own doc comment spells out. Full diagnosis and acceptance criteria in `Docs/TOOL_FIXES.md`.

**Three things blocked shipping. As of Sept 12, 2026 (M0, `m0-correctness`) all three are closed in code; what remains is on hardware — see the M0 task list below.**

1. ~~**`SyncEngine` can silently destroy a page.**~~ **Fixed (M0 tasks 4–5, Sept 12, 2026).** Merge is now per page on `Page.modifiedAt`; `rebuild()` is gone; pages update in place; a same-page conflict keeps the loser's ink in `trash/`; page deletions travel as `.page` tombstones and an edit newer than the deletion wins. `SyncTests` pins all of it, including the §1.2 scenario in both orders.
2. **`library.json` holds the entire library in one file** — *split done (M0 task 6, Sept 12, 2026): `index.json` + `notebooks/<uuid>.json`, partial push and pull by content signature, format gate, legacy read.* Index history (task 7), `tombstones.json` (task 9), content-addressed payloads (task 10), trash-not-delete with orphan pruning (task 11), the 30 s debounced push (task 12), `NSFilePresenter` folder watching (task 13), non-blocking downloads (task 14) and the single storage root (task 15) done. Still open: iCloud conflict versions (task 8, blocked on `Docs/SPIKE_ICLOUD_CONFLICTS.md`).
3. ~~**There are no tests.**~~ **Fixed (M0 tasks 1–3).** `MystNotesTests/` — sync harness, durability, codec, fidelity, watcher, debouncer, diagnostics and performance suites, 73 tests green. Run on the iPad simulator: boot it first (see gotchas), then `xcodebuild test -scheme MystNotes -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)'`.

---

## Non-negotiable invariants

Violating any of these is a bug, even if it compiles and the tests pass.

1. **Never lose ink.** Every write is atomic and recoverable. If the app is killed mid-stroke, the last committed state must load cleanly.
2. **Merge at page granularity or finer. Never rebuild a page tree wholesale.** This is invariant #1's most likely failure mode. Was violated until M0 task 5; `testPull_updatesPagesInPlace_neverRebuildsTheTree` guards it now.
3. **Deletion is never `removeItem` on a payload.** Move to `trash/`. Tombstones and stale snapshots must not be able to destroy ink. As of M0 task 11 there is no `removeItem` on a payload anywhere; `DrawingStore.moveToTrash` is the one mechanism, and trash retention is an open decision in `BACKLOG.md`.
4. **The folder is the source of truth; SwiftData is a rebuildable index.** If the index is wrong, delete and reconstruct from the folder. The tested path is `LibraryRebuild` (Settings → Rebuild Index, M0 task 19): wipe, then pull. With no sync folder chosen it rebuilds from the local mirror, `Documents/Library/` — the same layout, metadata only, written by every debounced push (`SyncEnvironment.mirror`). Holds in both states now.
5. **Ink is stored in the neutral stroke format, never as a raw `PKDrawing` blob as the source of truth.** `PKDrawing` may be cached, always regenerable. In force since M0 task 16b: `<id>.strokes` is the record and the only ink file that syncs; `<id>.drawing` is a local render cache keyed by the record's hash; `DrawingStore` is the only code that reads or writes either.
6. **Stroke IDs are stable forever.** Links, transclusions, timeline events and cloze regions all point at stroke IDs. Regenerating them on load is a data-loss bug in disguise. **PencilKit's stroke ID API exists but is iOS 27+** — `PKStrokePath.id` and `init(controlPoints:creationDate:id:)` are both marked iOS/iPadOS/macOS 27.0+, so they are genuinely unavailable on the iOS 26.5 SDK. Verified against Apple's docs Sept 12, 2026. Adopt them when the deployment target can move; until then the neutral format (M0 task 16) owns the IDs.

Two notes on the interim mapping. First, **you mostly don't need one**: when the neutral format is the source of truth, you build the `PKDrawing` yourself in a known order, so index position *is* the mapping. The problem only arises after PencilKit itself mutates the drawing, and then it's a diff. Second, for that diff key on **`path.creationDate` + `randomSeed` only**. Drop point count and order: the vector eraser modifies a stroke's `mask` rather than its path, so creationDate and randomSeed survive erasing while point count and array position do not.
7. **One storage root.** Payloads live in the app's Documents directory and nowhere else. `FileStore`'s iCloud ubiquity path, the dual-location fallback and the `syncEnabled` preference are gone (M0 task 15); only a one-time, background adoption of anything an old build left in the container remains.
8. **Local-first.** Fully functional with no sync folder chosen, an unreachable folder, or an evicted file. These are designed states with calm UI, not error dialogs.
9. **The user can export everything, always.** Any feature that creates data is covered by export before it ships.
10. **Ink latency is sacred.** Nothing synchronous on the main thread during drawing. Recognition, indexing, thumbnails, embeddings and sync all stay off the drawing path.
11. **SwiftData properties stay optional or defaulted, no unique constraints.** Not currently required (no CloudKit), but it costs nothing and preserves the option.

---

## Repo layout

Currently flat — all Swift files sit in `MystNotes/`. Don't reorganize as a side effect of other work; if it's worth doing, do it as its own commit.

**Canvas and drawing:** `PencilCanvasView` (393), `CanvasGestures` (751), `DrawingToolbarView` (273), `FillTool` (190), `ShapeRecognizer` (123), `ShapeDrawingOverlay`, `WhiteboardCanvasView` (158), `PageViewportLayer`, `PageGeometry` (100)

**Pages and content:** `MystNotesDetailView` (1365 — the big one), `PageElementsOverlayView` (237), `PageBackgroundView`, `PageThumbnailView` (146), `PageRenderer` (121), `ImportedArtwork` (235), `ImportedPageBackgroundView` (120), `ImageCropOverlay`, `ImageAdjustOverlay`, `ImageAdjustToolbar`, `StickerPickerView`, `LinkDestinationPickerView`

**Library:** `LibraryView` (516), `LibraryCells`, `FolderPickerView`, `TutorialNotebookFactory` (303)

**Data:** `MystNotesModels`, `FileStore`, `DrawingStore`, `StrokeCodec` (neutral ink format + `StrokeIDMap`), `AppSettings`

**Sync:** `SyncEngine`, `SyncEnvironment`, `SyncFolder`, `SyncModels`, `SyncDebouncer`, `SyncFolderWatcher`, `SyncDiagnostics` (debug) — folder layout is documented at the top of `SyncModels.swift`

**Search:** `HandwritingRecognizer` (133), `SearchIndex`, `SearchResultsView` (132)

**App shell:** `MystnotesApp`, `ContentView`, `MystnotesWindowView`, `SettingsView`, `OnboardingView`, `LoginView`, `ShareSheet`, `Color+Hex`, `Diagnostics` (crash reports, log, export)

**Tests:** `MystNotesTests/` — `SyncTestHarness` + `SyncTests` (two-library sync harness), `DurabilityTests` (+ `Fixtures/` schema fixture). Seams the tests drive: `SyncEnvironment` (sync), `DrawingStore` (ink file I/O). Run on the iPad simulator.

### Data model (`MystNotesModels.swift`)

`Folder` → `Notebook` → `Page` → (`TypedTextBlock`, `Sticker`, `ImportedDocument`), plus `Link` (`sourcePageID`, `destinationPageID`, anchor rect). All relationships cascade-delete; all properties optional or defaulted.

`Page` carries `drawingFileRef`, `backgroundRef`, `aspectRatio`, `recognizedTextCache`, `ocrUpdatedAt`, and `modifiedAt: Date?` (M0 task 4, done). Set `modifiedAt` only through `Page.markModified(at:)` — it also lifts the notebook's date, never lowers it. `nil` means the page predates the field and loses to any dated page. OCR fields never call it.

`Notebook.settingsModifiedAt: Date?` (M0 task 6) is the merge clock for title/cover/folder; set it only through `Notebook.markSettingsModified(at:)`. `Notebook.modifiedAt` is the library sort key, lifted by page edits, never a merge key.

`Link` is the seed of the graph in M2. Generalize it; don't start a parallel model.

---

## Locked decisions — do not relitigate without an explicit ask

- Native SwiftUI/UIKit + PencilKit. **Not** custom Core Graphics ink.
- Custom toolbar driving `PKCanvasView.tool` directly, not `PKToolPicker`. Pencil input keeps PencilKit's low-latency path; only tool selection is custom.
- **Folder-based sync is the permanent architecture**, not a stopgap for the missing CloudKit entitlement. See `PROJECT_PLAN.md` §3.1 for why it's actually better here.
- Entitlements carry only self-declarable sandbox keys so free-account signing works. CloudKit/Sign-in-with-Apple/push stay parked in `Mystnotes.entitlements.paid-account-backup`.
- Document files live on disk; SwiftData holds metadata and references.
- Mac Catalyst as the second target, full editing, not view-only.
- AI features stay behind a stub. No network AI calls in v1.
- `AnyView` is an accepted escape hatch for recursive `some View` compiler errors (see `FolderPickerView`).
- **`Page.recognizedTextCache` / `ocrUpdatedAt` never bump `Page.modifiedAt`.** They are derived data and merge on their own (newest `ocrUpdatedAt` wins). A background OCR pass on one device must never out-rank a real stroke on another. (Decided Sept 12, 2026.)
- **Same-page concurrent edits keep both versions.** Per-page last-writer-wins picks what the page shows, but the losing ink goes to `trash/` and is recoverable, never discarded. Tasks 5 and 11 are designed together for this. (Decided Sept 12, 2026.)

---

## Working agreement

**Code delivery.** Complete file replacements, not diffs or snippets. If a change touches five files, give me five whole files.

**Errors.** Explain the root cause before the fix. I want to understand why it broke.

**Planning.** Plan thoroughly up front, lock the approach, then execute fast. Don't start coding until the approach is stated and agreed.

**Scope.** One milestone task at a time. Anything else worth doing goes in `Docs/BACKLOG.md`, not into the current change.

**Uncertainty.** If a framework behavior is unverified — PencilKit internals, `NSFileCoordinator` semantics, iCloud Drive conflict handling, PDFKit annotation layers — say so and propose a spike. Don't guess and present the guess as fact.

**Tests.** Anything touching sync or persistence ships with tests in the same change. Durability tests are never skipped, never marked flaky, never disabled to get a build green.

---

## Environment

- Development: MacBook, Xcode. Testing: physical iPad plus Mac Catalyst.
- Repo: `~/Desktop/Mystnotes`. Xcode project: `MystNotes`. GitHub: `Mystanile`.
- **Free Apple Developer account.** No CloudKit, no push, no Sign in with Apple, and builds expire after 7 days. Needed before M6 and before M0's week-long soak test.

### Known gotchas — already paid for, don't rediscover

- Vision returns nothing on transparent ink. `HandwritingRecognizer` composites onto opaque white first. Keep that.
- `url(forUbiquityContainerIdentifier:)` blocks. It is now called at most once per install, off the main thread, by `FileStore.adoptLegacyCloudFilesOnce`. Don't reintroduce it on a hot path.
- Flipping the old sync toggle used to swing `baseDirectory()` and make every drawing invisible. Deleted in task 15 along with the fallback that papered over it; there is one directory now.
- Ink colors invert with system light/dark mode; fixed across three commits, don't regress it.
- SwiftData's template-generated `Item.swift` causes duplicate schema conflicts. Delete it.
- A missing iPad Air simulator destination makes UIKit / `UIViewRepresentable` types unavailable when building for Mac.
- Simulator launch failures: quit and relaunch Xcode. Stalled iPad pairing needs manual intervention.
- `NSFilePresenter` on a user-picked folder inside iCloud Drive **does** fire for other processes' writes — coordinated or not, any depth — about a second after the write, several times per write. Verified Sept 12, 2026 with a two-process script on the Mac. It is *not* verified for a folder outside iCloud Drive with an uncoordinated writer (Dropbox etc.); the foreground pull and Sync Now still cover that.
- `xcodebuild test` against a simulator that isn't booted fails with `Simulator device failed to launch … Busy ("Application failed preflight checks")` — SpringBoard is still coming up. Boot first: `xcrun simctl boot <udid> && xcrun simctl bootstatus <udid> -b`, then run. A leftover test host from a previous run does the same; `xcrun simctl terminate <udid> com.mozynas.Mystnotes` clears it.
- Xcode full-screen hides the toolbar and Play/Stop buttons.
- Watch for `CGFloat`/`Double` mismatches in drag gesture handling.
- Tool color must be read from the active `PKInkingTool`, never hardcoded.
- `PKDrawing`'s `==` compares an internal drawing identity, not content: `PKDrawing() == PKDrawing()` is **false**. Compare strokes structurally (`assertStrokesEqual` in the tests). `PKDrawing(data:)` preserves the identity, which is why a data round trip *looks* equal.
- `PKStrokePoint` quantizes `azimuth`, `altitude` and `threshold` on construction (16-bit grid; 0.2 → 0.19998474). Rebuilding a point from read-back values drifts by one quantum, once; marker and crayon texture can see it (≤0.07% of pixels), the other inks can't. Measured in `InkFidelityTests`; don't chase it, it isn't the codec.
- `PKDrawing(data:)` is not a corruption check. It throws on truncation and most garbage (`NSCocoaErrorDomain 3`), but short arbitrary byte strings can parse as a zero-stroke drawing. `DrawingStore.load` also checks the archive header (`wrd\xf0`, read from `PKDrawing().dataRepresentation()` at runtime) before trusting an empty result.

---

## Milestones — build in this order

Detail and exit criteria in `Docs/PROJECT_PLAN.md`.

| # | Milestone | Purpose |
|---|---|---|
| **M0** | Correctness | Tests, sync rewrite, storage cleanup, ink format. **Blocking. No new features.** |
| **M1** | Parity Floor | Real PDF annotation, shape tool rebuild, fill tool, lasso-to-text, per-page templates, favorites, note lock |
| **M2** | The Graph | Nodes, links, backlinks, graph canvas, ink transclusion |
| **M3** | Time & Voice | Stroke timeline, replay, audio, transcription, stroke-bound playback |
| **M4** | Recall | Semantic search, cloze on ink, spaced repetition, math |
| **M5** | Switch Costs & Reach | Importers, iPhone, Mac polish, App Intents, Pencil Pro |
| **M6** | Ship | Membership, accessibility, privacy manifest, TestFlight, App Store |
| **M7** | Cross-Platform | Web renderer, share links, sync service spike |

### M0 task order (current milestone)

In order. Each gates the next.

**Tests first, so the rest is verifiable**
1. Add a test target.
2. `DurabilityTests`: kill the process mid-stroke, mid-save, mid-migration. Assert clean load.
3. `SyncTests`: a two-library harness driving `SyncEngine` against a temp folder. **First test: edit page 3 in library A, page 7 in library B, sync, assert both survive.** It should fail today. Do not fix anything until it fails for the right reason.

**Sync rewrite**
4. Add `Page.modifiedAt`, maintained on every mutation.
5. Merge per page. Remove `rebuild()`'s delete-all-pages behavior.
6. Split `library.json` into `index.json` + `notebooks/<uuid>.json`.
7. Keep the last N index snapshots in `index-history/`.
8. Read and resolve `NSFileVersion` conflict versions instead of ignoring them.
9. Move tombstones from `UserDefaults` into `tombstones.json` in the folder.
10. Content-address payloads by SHA-256; drop mtime comparison in `copyFiles`.
11. Prune orphaned payloads; route deletions to `trash/`, never `removeItem`.
12. Periodic debounced push (~30s after last edit), not only on background.
13. `NSFilePresenter` so folder changes land while the app is open.
14. Make `ensureDownloaded` async; stop blocking a loop on `Thread.sleep`.

**Storage cleanup**
15. Delete the iCloud ubiquity path from `FileStore`. One storage root. Remove the dual-location fallback in `url(for:)`.

**Ink format**
16. ~~Neutral stroke codec~~ done — `StrokeCodec` + `StrokeIDMap`, spec §5 rewritten against the SDK.
17. ~~Pixel-diff fidelity harness per ink type~~ done — 5 of 7 inks exact, marker/crayon within a one-time quantization drift; numbers in spec §5.
16b. ~~Storage flip~~ done — `.strokes` is the record, `.drawing` a hash-keyed cache, legacy `.drawing`-only pages migrate on first load.

**Proof**
18. Two-device test on real hardware against the real folder: offline edits both sides, simultaneous same-page edit, evicted file, open mid-sync.
19. ~~SwiftData index rebuild~~ done — `LibraryRebuild`, two tests (shape equality after rebuild; a rebuild never pushes and trashes unpushed ink).
20. ~~Performance baseline~~ done except ink latency (needs the iPad) — numbers and thresholds in `Docs/PERFORMANCE_BASELINE.md`, tests in `PerformanceTests`. Findings: the record was ~6× PencilKit's size — now LZFSE-compressed (~2×); no-op sync cost is linear in payload bytes (persist hashes, backlog).
21. ~~Crash reporting~~ done — MetricKit subscriber + `AppLog` + Settings → Export Diagnostics (`Diagnostics.swift`). **Device verification still owed:** MetricKit payloads never arrive on the simulator or under the debugger; crash the app once on the iPad, relaunch, confirm a `diagnostic-*.json` in the export.

**M0 exit:** the task-3 scenario passes ✅, no known path to data loss ✅, index proven rebuildable ✅ (folder and local mirror), durability suite green ✅. **Still owed before calling M0 done:** task 8 (decided by `Docs/SPIKE_ICLOUD_CONFLICTS.md` §5), task 18 on real hardware, the ink-latency baseline, crash-report verification on device, and the trash-retention decision in `BACKLOG.md`. Then merge `m0-correctness` → `main`.

---

## Key APIs in play

| Area | API |
|---|---|
| Ink | `PencilKit` — `PKCanvasView`, `PKDrawing`, `PKStroke`, `PKStrokePath`, `PKStrokePoint`, `PKInkingTool` |
| Stroke reconstruction | `PKStrokePath(controlPoints:creationDate:)` — the `id:` variant is iOS 27+; until then IDs live in the neutral format (see invariant 6) |
| Persistence | `SwiftData` (local index only) |
| Sync | `NSFileCoordinator`, `NSFilePresenter`, `NSFileVersion`, security-scoped bookmarks, `startDownloadingUbiquitousItem` |
| PDF | `PDFKit` — real annotation layer, **not** rasterization (M1) |
| Handwriting OCR | `Vision` — `VNRecognizeTextRequest`, composited onto opaque white |
| Transcription | `Speech` — `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26), not `SFSpeechRecognizer` |
| Audio | `AVAudioEngine` |
| Semantic search | `NaturalLanguage` sentence embeddings, or a small Core ML model |
| Pencil Pro | `UIPencilInteraction` — squeeze, barrel roll, double tap, hover |
| System integration | `AppIntents`, `CoreSpotlight`, `QuickLook` |

---

## Things I will push back on

- Rebuilding a page tree wholesale on merge
- `removeItem` on a payload file for any reason
- Touching sync without a test that fails first
- Any feature that runs on the main thread during drawing
- Hardcoding stroke width, colour, or anything else that belongs to the active `PKInkingTool`
- Rewriting the fill tool again without instrumenting it first
- Reorganizing the file layout as a side effect of unrelated work
- Starting a new milestone before the current one's exit criteria are met
- Network AI calls in v1
- Anything from the §5 non-goals list in `PROJECT_PLAN.md`
