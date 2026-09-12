# CLAUDE.md — MystNotes

Standing context for Claude Code. Read this before touching anything.

---

## What this is

MystNotes is a handwriting-first note app for iPad and Mac (Mac Catalyst), built in SwiftUI + PencilKit, with SwiftData for metadata and files on disk for payloads. It started as a personal GoodNotes/Notability alternative and is being converted into a free, publicly shipped product.

Long-term thesis: notes are a **connected graph you can draw on**, with **stroke-level time travel** and **recall built in**. Not a filing cabinet.

Full context: `Docs/PROJECT_PLAN.md`. Format contract: `Docs/SPEC_DOCUMENT_FORMAT.md`. Out-of-scope ideas: `Docs/BACKLOG.md`.

---

## Current state (read this before proposing anything)

**~8,200 lines of Swift, 42 files, 26 commits. Far more is built than a phase list suggests.**

Already working, don't rebuild: custom PencilKit toolbar with 5 ink types and per-tool color/width memory, highlighter, vector and bitmap erasers, lasso, shape recognition, fill/bucket tool, per-page canvas with real zoom, PDF and photo import with crop/rotate/resize, nested folders, notebook covers, thumbnail strip, four templates, whiteboard page type, multi-window, presentation mode, Vision OCR handwriting search with tap-through results, page and notebook export, onboarding, login, settings, tutorial notebook, and folder-based sync.

**Three things block shipping. They are the current work.**

1. **`SyncEngine` can silently destroy a page.** Merge is whole-notebook last-writer-wins on `Notebook.modifiedAt`, and when the remote wins, `rebuild()` deletes every local `Page` and recreates the tree. Edit page 3 on iPad and page 7 on Mac offline, sync, and one edit is gone — while the *ink file* for the lost page may still be the newer one on disk, producing a mixed state. Root cause: `Page` has no `modifiedAt`, so merge can't be finer than the notebook.
2. **`library.json` holds the entire library in one file**, overwritten on every push, with no backup and no handling of iCloud conflict versions.
3. **There are no tests.** No test target, no test files.

---

## Non-negotiable invariants

Violating any of these is a bug, even if it compiles and the tests pass.

1. **Never lose ink.** Every write is atomic and recoverable. If the app is killed mid-stroke, the last committed state must load cleanly.
2. **Merge at page granularity or finer. Never rebuild a page tree wholesale.** This is invariant #1's most likely failure mode and it is currently violated.
3. **Deletion is never `removeItem` on a payload.** Move to `trash/`. Tombstones and stale snapshots must not be able to destroy ink.
4. **The folder is the source of truth; SwiftData is a rebuildable index.** If the index is wrong, delete and reconstruct from the folder. There must be a tested rebuild path.
5. **Ink is stored in the neutral stroke format, never as a raw `PKDrawing` blob as the source of truth.** `PKDrawing` may be cached, always regenerable.
6. **Stroke IDs are stable forever.** Links, transclusions, timeline events and cloze regions all point at stroke IDs. Regenerating them on load is a data-loss bug in disguise. **PencilKit has no stroke ID API** — verified against the iOS 26.5 SDK on Sept 12, 2026: `PKStrokePath` has only `init(controlPoints:creationDate:)`, and `PKStroke` carries `randomSeed: UInt32` and nothing else identity-like. The neutral format (M0 task 16) owns the IDs; mapping a `PKStroke` back to its ID must key on what does survive a `PKDrawing` round trip (`path.creationDate`, `randomSeed`, point count, order).
7. **One storage root.** `FileStore`'s iCloud ubiquity path is dead code in a free-account build and has already caused one shipped bug. Payloads live in one place.
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

**Data:** `MystNotesModels` (210), `FileStore` (131), `DrawingStore`, `AppSettings` (227)

**Sync:** `SyncEngine` (482), `SyncEnvironment`, `SyncFolder` (160), `SyncModels` (172)

**Search:** `HandwritingRecognizer` (133), `SearchIndex`, `SearchResultsView` (132)

**App shell:** `MystnotesApp`, `ContentView`, `MystnotesWindowView`, `SettingsView` (155), `OnboardingView`, `LoginView`, `ShareSheet`, `Color+Hex`

**Tests:** `MystNotesTests/` — `SyncTestHarness` + `SyncTests` (two-library sync harness), `DurabilityTests` (+ `Fixtures/` schema fixture). Seams the tests drive: `SyncEnvironment` (sync), `DrawingStore` (ink file I/O). Run on the iPad simulator.

### Data model (`MystNotesModels.swift`)

`Folder` → `Notebook` → `Page` → (`TypedTextBlock`, `Sticker`, `ImportedDocument`), plus `Link` (`sourcePageID`, `destinationPageID`, anchor rect). All relationships cascade-delete; all properties optional or defaulted.

`Page` carries `drawingFileRef`, `backgroundRef`, `aspectRatio`, `recognizedTextCache`, `ocrUpdatedAt`. **It does not carry `modifiedAt`. Adding that is M0 task 4 and it unblocks the sync fix.**

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
- `url(forUbiquityContainerIdentifier:)` blocks and is called on essentially every autosave; `FileStore` memoizes it. That whole path is scheduled for deletion in M0 anyway.
- Flipping the sync toggle used to swing `baseDirectory()` and make every drawing invisible. `url(for:)`'s dual-location fallback exists solely to paper over that. Fix the cause, remove the patch.
- Ink colors invert with system light/dark mode; fixed across three commits, don't regress it.
- SwiftData's template-generated `Item.swift` causes duplicate schema conflicts. Delete it.
- A missing iPad Air simulator destination makes UIKit / `UIViewRepresentable` types unavailable when building for Mac.
- Simulator launch failures: quit and relaunch Xcode. Stalled iPad pairing needs manual intervention.
- `xcodebuild test` against a simulator that isn't booted fails with `Simulator device failed to launch … Busy ("Application failed preflight checks")` — SpringBoard is still coming up. Boot first: `xcrun simctl boot <udid> && xcrun simctl bootstatus <udid> -b`, then run. A leftover test host from a previous run does the same; `xcrun simctl terminate <udid> com.mozynas.Mystnotes` clears it.
- Xcode full-screen hides the toolbar and Play/Stop buttons.
- Watch for `CGFloat`/`Double` mismatches in drag gesture handling.
- Tool color must be read from the active `PKInkingTool`, never hardcoded.

---

## Milestones — build in this order

Detail and exit criteria in `Docs/PROJECT_PLAN.md`.

| # | Milestone | Purpose |
|---|---|---|
| **M0** | Correctness | Tests, sync rewrite, storage cleanup, ink format. **Blocking. No new features.** |
| **M1** | Parity Floor | Real PDF annotation, lasso-to-text, per-page templates, favorites, note lock |
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
16. Neutral stroke codec: `PKDrawing` → neutral → `PKDrawing`, preserving stroke IDs.
17. Pixel-diff fidelity harness per ink type. Dual-write any type that fails tolerance.

**Proof**
18. Two-device test on real hardware against the real folder: offline edits both sides, simultaneous same-page edit, evicted file, open mid-sync.
19. SwiftData index rebuild: delete the store, reconstruct from the folder, test it.
20. Performance baseline (ink latency on ProMotion, 500-page PDF memory, cold launch with 200 notebooks). Record as regression thresholds.
21. Crash reporting.

**M0 exit:** the task-3 scenario passes, no known path to data loss, index proven rebuildable, durability suite green.

---

## Key APIs in play

| Area | API |
|---|---|
| Ink | `PencilKit` — `PKCanvasView`, `PKDrawing`, `PKStroke`, `PKStrokePath`, `PKStrokePoint`, `PKInkingTool` |
| Stroke reconstruction | `PKStrokePath(controlPoints:creationDate:)` — there is no `id:` variant; IDs live in the neutral format (see invariant 6) |
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
- Reorganizing the file layout as a side effect of unrelated work
- Starting a new milestone before the current one's exit criteria are met
- Network AI calls in v1
- Anything from the §5 non-goals list in `PROJECT_PLAN.md`
