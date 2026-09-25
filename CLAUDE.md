# CLAUDE.md — MystNotes

Standing context for Claude Code. Read this before touching anything.

---

## What this is

MystNotes is a handwriting-first note app for iPad and Mac (Mac Catalyst), built in SwiftUI + PencilKit, with SwiftData for metadata and files on disk for payloads. It started as a personal GoodNotes/Notability alternative and is being converted into a free, publicly shipped product.

Long-term thesis: notes are a **connected graph you can draw on**, with **stroke-level time travel** and **recall built in**. Not a filing cabinet.

Full context: `Docs/PROJECT_PLAN.md`. Regression floors: `Docs/PERFORMANCE_BASELINE.md`. Format contract: `Docs/SPEC_DOCUMENT_FORMAT.md`. Shape and fill tool diagnosis: `Docs/TOOL_FIXES.md`. Out-of-scope ideas: `Docs/BACKLOG.md`. Spike: `Docs/SPIKE_ICLOUD_CONFLICTS.md` (task 8 decided: outcome B, done). **Current milestone: M1** — task order under Milestones below.

---

## Current state (read this before proposing anything)

**~14,200 lines of Swift in 56 app files, plus ~4,400 lines of tests in 14 files (171 tests, all green). All earlier branches merged into `main` on Sept 25, 2026; M1 work branches off `main`. Far more is built than a phase list suggests.**

Already working, don't rebuild: custom PencilKit toolbar with 5 ink types and per-tool color/width memory, highlighter, vector and bitmap erasers, our own lasso (move, pinch-resize, rotate, cut/copy/paste/duplicate — `InkSelection`, Sept 19, 2026; the whiteboard still has PencilKit's), shape recognition (hold-to-snap, solid/dashed/dotted), fill/bucket tool, per-page canvas with real zoom, PDF and image import from Photos / Files / ⌘V / drag with crop/rotate/resize (any number per page, stacked — Sept 19, 2026), nested folders, notebook covers, thumbnail strip, four templates (drawn under imported artwork, and in thumbnails and exports), whiteboard page type, multi-window, presentation mode, Vision OCR handwriting search with tap-through results, page and notebook export, onboarding, login, settings, tutorial notebook, and folder-based sync.

**~~One shipped tool is broken (M1).~~ Both are fixed.** ~~The shape tool~~ — rebuilt Sept 15, 2026 and given a second pass Sept 18 after field use: the hold timer was scheduled in the default run-loop mode, which never fires while a pencil is down (`.common` now, plus an elapsed-time check in `touchesMoved`); a line with a hook on the end came back as an arrow; snapped shapes were drawn at the tool's heaviest possible mark instead of the weight of the stroke they replace; lines didn't snap to the axes; there were no dashed or dotted shapes. All fixed, 29 tests. Still owed on the iPad: that the host's recognizer receives the Pencil touch during a PencilKit stroke. ~~The fill tool~~ fixed Sept 25, 2026 after logging on the iPad showed the coordinates were right all along: its strokes were too thin for PencilKit to draw (`TOOL_FIXES.md` Part 2). Full diagnosis and acceptance criteria in `Docs/TOOL_FIXES.md` — part 4 is the lasso rebuild (Sept 19), part 3 covers the imported-image bugs fixed Sept 18 (a photo import wiped the page template; artwork vanished on page turns; no Files/paste/drag import on a Mac).

**Three things blocked shipping. All three are closed (M0, done Sept 25, 2026).**

1. ~~**`SyncEngine` can silently destroy a page.**~~ **Fixed (M0 tasks 4–5, Sept 12, 2026).** Merge is now per page on `Page.modifiedAt`; `rebuild()` is gone; pages update in place; a same-page conflict keeps the loser's ink in `trash/`; page deletions travel as `.page` tombstones and an edit newer than the deletion wins. `SyncTests` pins all of it, including the §1.2 scenario in both orders.
2. ~~**`library.json` holds the entire library in one file**~~ **Closed (M0 tasks 6–15, Sept 12, 2026).** Split into `index.json` + `notebooks/<uuid>.json` with partial push/pull, index history, `tombstones.json`, content-addressed payloads, trash-not-delete, debounced push, folder watching, non-blocking downloads, one storage root — and iCloud conflict versions read and merged (task 8; the spike found outcome B on real hardware).
3. ~~**There are no tests.**~~ **Fixed (M0 tasks 1–3).** `MystNotesTests/` — sync harness, durability, codec, fidelity, watcher, debouncer, diagnostics, shape, artwork and performance suites, 125 tests green. Run on the iPad simulator: boot it first (see gotchas), then `xcodebuild test -scheme MystNotes -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)'`.

---

## Non-negotiable invariants

Violating any of these is a bug, even if it compiles and the tests pass.

1. **Never lose ink.** Every write is atomic and recoverable. If the app is killed mid-stroke, the last committed state must load cleanly.
2. **Merge at page granularity or finer. Never rebuild a page tree wholesale.** This is invariant #1's most likely failure mode. Was violated until M0 task 5; `testPull_updatesPagesInPlace_neverRebuildsTheTree` guards it now.
3. **Deletion is never `removeItem` on a payload — with exactly one exception.** Move to `trash/`. Tombstones and stale snapshots must not be able to destroy ink. `DrawingStore.moveToTrash` is the one way in (M0 task 11). The one way out is `TrashRetention.sweep`, which removes a file that has been in a `trash/` for **30 days** (decided Sept 18, 2026) and refuses any directory not named `trash`. It runs in the sync folder while the folder is held, and locally at launch. Nothing else in the app may call `removeItem` on a payload; if you think you need to, you want `moveToTrash`.
4. **The folder is the source of truth; SwiftData is a rebuildable index.** If the index is wrong, delete and reconstruct from the folder. The tested path is `LibraryRebuild` (Settings → Rebuild Index, M0 task 19): wipe, then pull. With no sync folder chosen it rebuilds from the local mirror, `Documents/Library/` — the same layout, metadata only, written by every debounced push (`SyncEnvironment.mirror`). Holds in both states now.
5. **Ink is stored in the neutral stroke format, never as a raw `PKDrawing` blob as the source of truth.** `PKDrawing` may be cached, always regenerable. In force since M0 task 16b: `<id>.strokes` is the record and the only ink file that syncs; `<id>.drawing` is a local render cache keyed by the record's hash; `DrawingStore` is the only code that reads or writes either.
6. **Stroke IDs are stable forever.** Links, transclusions, timeline events and cloze regions all point at stroke IDs. Regenerating them on load is a data-loss bug in disguise. **PencilKit's stroke ID API exists but is iOS 27+** — `PKStrokePath.id` and `init(controlPoints:creationDate:id:)` are both marked iOS/iPadOS/macOS 27.0+, so they are genuinely unavailable on the iOS 26.5 SDK. Verified against Apple's docs Sept 12, 2026. Adopt them when the deployment target can move; until then the neutral format (M0 task 16) owns the IDs.

Two notes on the interim mapping. First, **you mostly don't need one**: when the neutral format is the source of truth, you build the `PKDrawing` yourself in a known order, so index position *is* the mapping. The problem only arises after PencilKit itself mutates the drawing, and then it's a diff. Second, for that diff key on **`path.creationDate` + `randomSeed` only**. Drop point count and order: the vector eraser modifies a stroke's `mask` rather than its path, so creationDate and randomSeed survive erasing while point count and array position do not.
7. **One storage root.** Payloads live in the app's Documents directory and nowhere else. `FileStore`'s iCloud ubiquity path, the dual-location fallback and the `syncEnabled` preference are gone (M0 task 15); only a one-time, background adoption of anything an old build left in the container remains.
8. **Local-first.** Fully functional with no sync folder chosen, an unreachable folder, or an evicted file. These are designed states with calm UI, not error dialogs.
9. **The user can export everything, always.** Any feature that creates data is covered by export before it ships.
10. **Ink latency is sacred.** Nothing synchronous on the main thread during drawing. Recognition, indexing, thumbnails, embeddings and sync all stay off the drawing path. **Violated twice more, found Sept 18, 2026:** the autosave encoded, compressed and wrote a page's ink on the main thread a second after every stroke (`DrawingStore.saveDetached` now), and handwriting OCR ran a full Vision pass on every one of those autosaves (`HandwritingIndexer` debounces it to 12 s). Both were `Task { }` formed inside a main-actor view — see the isolation gotcha. **Was violated by the entire sync engine until Sept 12, 2026** — see the gotcha on `SWIFT_DEFAULT_ACTOR_ISOLATION`; `testRunner_executesOffTheMainThread_whenDetached` guards it now.
11. **SwiftData properties stay optional or defaulted, no unique constraints.** Not currently required (no CloudKit), but it costs nothing and preserves the option.

---

## Repo layout

Currently flat — all Swift files sit in `MystNotes/`. Don't reorganize as a side effect of other work; if it's worth doing, do it as its own commit.

**Canvas and drawing:** `PencilCanvasView`, `CanvasGestures` (host view, scribble-erase, shortcuts, paste/drop, `CanvasPasteboard`), `DrawingToolbarView`, `FillTool` (190), `ShapeRecognizer` (+ `ShapeLineStyle`), `ShapeHoldRecognizer` (hold-to-snap + `ShapeSnapController` + `ShapePreviewView`), `WhiteboardCanvasView`, `PageViewportLayer`, `PageGeometry` (100)

**Pages and content:** `MystNotesDetailView` (~1500 — the big one), `PageElementsOverlayView` (237), `PageBackgroundView` (+ `PageTemplate`, the one ruling renderer), `PageThumbnailView` (+ `PageThumbnailRenderer`), `PageRenderer`, `ImportedArtwork`, `ImportedPageBackgroundView` (+ `ArtworkRenderer`), `ImportedFileType` (header sniffing), `BitmapStore` (+ `PageBitmaps`), `ImageCropOverlay`, `ImageAdjustOverlay`, `ImageAdjustToolbar`, `StickerPickerView`, `LinkDestinationPickerView`

**Library:** `LibraryView` (516), `LibraryCells`, `FolderPickerView`, `TutorialNotebookFactory` (303)

**Data:** `MystNotesModels`, `FileStore`, `DrawingStore`, `StrokeCodec` (neutral ink format + `StrokeIDMap`), `TrashRetention` (the 30-day sweep — the only `removeItem` on a payload), `AppSettings`

**Sync:** `SyncEngine`, `SyncEnvironment`, `SyncFolder`, `SyncModels`, `SyncDebouncer`, `SyncFolderWatcher`, `SyncDiagnostics` (debug) — folder layout is documented at the top of `SyncModels.swift`

**Search:** `HandwritingRecognizer` (133), `SearchIndex`, `SearchResultsView` (132)

**App shell:** `MystnotesApp`, `ContentView`, `MystnotesWindowView`, `SettingsView`, `OnboardingView`, `LoginView`, `ShareSheet`, `Color+Hex`, `Diagnostics` (crash reports, `AppLog`, the main-thread watchdog — hangs past 3 s with a stack, stalls past 400 ms with the last checkpoint — and Export Diagnostics)

**Tests:** `MystNotesTests/` — `SyncTestHarness` + `SyncTests` (two-library sync harness), `DurabilityTests` (+ `Fixtures/` schema fixture), `ShapeRecognizerTests`, `PageArtworkTests`, `TrashRetentionTests`, plus the codec, fidelity, watcher, debouncer, diagnostics and performance suites. Seams the tests drive: `SyncEnvironment` (sync), `DrawingStore` (ink file I/O), `BitmapStore` (injected renderer). Run on the iPad simulator.

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
- Ink colors invert with system light/dark mode; fixed across three commits, don't regress it. **Every `PKDrawing.image(from:)` outside a view is subject to it too**: exports and thumbnails rendered black ink white in dark mode until Sept 19, 2026. Wrap any off-screen ink render in `UITraitCollection(userInterfaceStyle: .light).performAsCurrent`, as `PageRenderer`, `PageThumbnailRenderer`, `FillTool` and `HandwritingRecognizer` do.
- SwiftData's template-generated `Item.swift` causes duplicate schema conflicts. Delete it.
- A missing iPad Air simulator destination makes UIKit / `UIViewRepresentable` types unavailable when building for Mac.
- Simulator launch failures: quit and relaunch Xcode. Stalled iPad pairing needs manual intervention.
- `NSFilePresenter` on a user-picked folder inside iCloud Drive **does** fire for other processes' writes — coordinated or not, any depth — about a second after the write, several times per write. Verified Sept 12, 2026 with a two-process script on the Mac. It is *not* verified for a folder outside iCloud Drive with an uncoordinated writer (Dropbox etc.); the foreground pull and Sync Now still cover that.
- `xcodebuild test` against a simulator that isn't booted fails with `Simulator device failed to launch … Busy ("Application failed preflight checks")` — SpringBoard is still coming up. Boot first: `xcrun simctl boot <udid> && xcrun simctl bootstatus <udid> -b`, then run. A leftover test host from a previous run does the same; `xcrun simctl terminate <udid> com.mozynas.Mystnotes` clears it.
- **An incremental `xcodebuild test` has run stale app code after an app-source edit** — twice on Sept 25, 2026, once each way (a new test passed that should have failed; a fix showed no effect). When a result is surprising, or when proving a test fails without a fix, run `xcodebuild clean test`.
- Xcode full-screen hides the toolbar and Play/Stop buttons.
- Watch for `CGFloat`/`Double` mismatches in drag gesture handling.
- Tool color must be read from the active `PKInkingTool`, never hardcoded.
- **A `Task { }` inside a view inherits the main actor.** Not just `Task.detached` with a captured main-actor type — a plain `Task { }` in a SwiftUI view body or method runs its whole body on the main thread. That is how the autosave's encode-compress-write and a per-second Vision pass ended up there. The pattern that works is a `nonisolated static` function that is capture-free by construction and wraps `Task.detached` (`SyncEngine.runDetached`, `DrawingStore.saveDetached`).
- **Anything a SwiftUI representable's `updateUIView` writes, it writes on every update of the enclosing view** — for `NotebookDetailView` that is every colour change, every undo-state change, every page turn. Write UIKit properties only when they differ; re-setting `PKCanvasView.drawingPolicy` or `overrideUserInterfaceStyle` is not free.
- **This project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every type not marked `nonisolated` is main-actor, and `Task.detached { someMainActorType.work() }` does NOT run in the background — the closure is inferred main-actor and hops to the main thread.** The whole sync engine ran on the main thread this way (iPad crash log: watchdog kill inside `NSFileCoordinator` under `SyncRunner.run`, thread 0). Every sync, persistence, codec and diagnostics type is now `nonisolated`; when adding one, mark it, and if it must run in the background write a test that observes the thread. `@MainActor` on `SyncEngine`, the watcher and the debouncer is deliberate.
- **Anything hashed or compared across devices must be computed from what the file says, never from in-memory values.** `Date()` has microseconds, the snapshot has milliseconds; hashing raw `timeIntervalSince1970` made every notebook "not match its index entry" after one round trip and left both real devices pending forever. `SnapshotDates.stamp` is the encoded string for that reason. The harness clock ticks in whole seconds, which is why tests never saw it — the sub-millisecond regression test exists now.
- `UIDevice.current.name` is "iPad" on Mac Catalyst too (the real name is behind an entitlement). Sync's device name is platform + install id.
- A canvas nobody drew on must never be saved: it may be blank only because its ink hasn't arrived. `MystNotesDetailView` saves only when `canvasIsDirty`, and only to `canvasPageID` — the page the canvas was loaded for, which a pull can shift out from under `currentPageIndex`.
- `PKDrawing`'s `==` compares an internal drawing identity, not content: `PKDrawing() == PKDrawing()` is **false**. Compare strokes structurally (`assertStrokesEqual` in the tests). `PKDrawing(data:)` preserves the identity, which is why a data round trip *looks* equal.
- `PKStrokePoint` quantizes `azimuth`, `altitude` and `threshold` on construction (16-bit grid; 0.2 → 0.19998474). Rebuilding a point from read-back values drifts by one quantum, once; marker and crayon texture can see it (≤0.07% of pixels), the other inks can't. Measured in `InkFidelityTests`; don't chase it, it isn't the codec.
- **`PKLassoTool` never says what it selected.** There is no `selectedStrokes`; anything that needs the selection (resize, rotate, a menu of ours) needs our own lasso, which is `InkSelectionController`. A scale in `PKStroke.transform` scales the ink width too — measured in `InkSelectionTests`, so don't bake resizes into control points.
- **A bounded cache that tells its views when it evicts will thrash the moment the visible set exceeds the budget.** `BitmapStore` did: the page strip on the iPad cycled forever, one thumbnail visible at a time. It evicts least-recently-read now and never what was read in the last second (`TOOL_FIXES.md` §3.6). Keep that property if you touch it.
- **`isScrollEnabled = false` stands down a `UIScrollView`'s pan only.** Its pinch keeps zooming. Anything that wants the page held still — the image handles, selected ink — has to disable `pinchGestureRecognizer` as well (`InkSelectionController.gateCanvasGestures`, `PencilCanvasView.configure`).
- **A view gets one `.fileImporter`.** Two chained on the same view and only the last one presents; the other's `isPresented` flips to `true` and nothing appears. That is how PDF import died on the iPad for a day (Sept 18–19, 2026). `NotebookDetailView` has exactly one, with the allowed types set before it is presented.
- **A `Timer` is scheduled in the default run-loop mode only.** A pencil down on the canvas puts the main run loop in *tracking* mode, where such a timer does not fire at all — which is why hold-to-snap kept being missed. Anything timing a gesture must be `Timer(timeInterval:target:selector:…)` added to `RunLoop.main` in `.common`, and ideally should have a second path that doesn't depend on a timer at all.
- **PencilKit draws nothing at all for a stroke under ~2pt.** Not thin: invisible, and invisible to anything that rasterizes the drawing too. A 4pt stroke is ~4–6 px tall and runs ~size/2 past each end. That is why the fill tool never worked: one-row bands were synthesized at 0.75pt (Sept 25, 2026, `FillToolTests`). Anything that synthesizes strokes must check what renders, in pixels, not where the strokes are.
- **`PKStrokePoint(size:force:)` is the mark's weight, and `force: 1` is the tool's heaviest possible one.** A reconstructed stroke built at `tool.width` with `force: 1` is visibly fatter than the freehand stroke beside it, drawn at whatever pressure the hand used. Take both from the stroke being replaced (`ShapeRecognizer.spec(matching:)`) rather than from the tool.
- **A `@Query` inside a cell view runs once per cell.** Every `PageThumbnailView` fetched every `ImportedDocument` in the library and re-fetched on every model change. The parent that already holds the list hands it down now. Same for a `ForEach` over a long list inside a plain `HStack`/`VStack`: it isn't lazy, so every row is built immediately — the page strip rendered every page's thumbnail on open.
- `PKDrawing(data:)` is not a corruption check. It throws on truncation and most garbage (`NSCocoaErrorDomain 3`), but short arbitrary byte strings can parse as a zero-stroke drawing. `DrawingStore.load` also checks the archive header (`wrd\xf0`, read from `PKDrawing().dataRepresentation()` at runtime) before trusting an empty result.

---

## Milestones — build in this order

Detail and exit criteria in `Docs/PROJECT_PLAN.md`.

| # | Milestone | Purpose |
|---|---|---|
| **M0** | Correctness | ✅ Done Sept 25, 2026. Tests, sync rewrite, storage cleanup, ink format. |
| **M1** | Parity Floor (current) | Real PDF annotation, shape tool rebuild, fill tool, lasso-to-text, per-page templates, favorites, note lock |
| **M2** | The Graph | Nodes, links, backlinks, graph canvas, ink transclusion |
| **M3** | Time & Voice | Stroke timeline, replay, audio, transcription, stroke-bound playback |
| **M4** | Recall | Semantic search, cloze on ink, spaced repetition, math |
| **M5** | Switch Costs & Reach | Importers, iPhone, Mac polish, App Intents, Pencil Pro |
| **M6** | Ship | Membership, accessibility, privacy manifest, TestFlight, App Store |
| **M7** | Cross-Platform | Web renderer, share links, sync service spike |

### M0 — done (Sept 25, 2026)

All 22 tasks done, exit criteria met, and the user confirmed it on the iPad on Sept 25, 2026. The full task list and its findings are in `Docs/PROJECT_PLAN.md` §4 and in git history. Branches merged `custom-drawing-toolbar` → `m0-correctness` → `m1-images-and-shapes` → `main` the same day. M0 items still open in `BACKLOG.md` moved to M1.

### M1 task order (current milestone)

Already done early: shape tool rebuild (Sept 15/18), images on a page with stacking and Mac import (Sept 18/19), text block typography (Sept 15), our own lasso with move/resize/rotate/cut/copy/paste (Sept 19), copy pages to another notebook (Sept 19).

1. ~~**Fill tool**~~ — done Sept 25, 2026, confirmed on the iPad (`TOOL_FIXES.md` Part 2): one erasable stroke per fill, the pen's colour, pan/zoom while selected, no gap at the outline.
2. **Real PDF annotation** — live PDFKit layer instead of rasterize-to-JPEG. The highest-value item.
3. Lasso: convert to text, recolor, cross-page move, copy as image.
4. Per-page templates, custom page sizes, imported templates.
5. Favorites, bookmarks, page outline.
6. Sticker resize and rotate; stickers and link anchors in exports.
7. Pen on Mac (reproduce first).
8. Export additions: layered PDF, markdown, whole-library zip.
9. Note lock via Face ID; off-device backup target.

**M1 exit:** a GoodNotes user can do a full day of classes without hitting a wall.

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
