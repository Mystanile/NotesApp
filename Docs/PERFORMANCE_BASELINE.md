# Performance baseline

**M0 task 20.** Numbers recorded so a regression is a test failure, not a feeling. `MystNotesTests/PerformanceTests.swift` prints each as `BASELINE …` and fails past a threshold set at roughly 3–5× the observed value — enough to catch a real regression, loose enough to ignore simulator noise. Update this file and the thresholds together.

**Recorded:** Sept 12, 2026 · iPad Air 11-inch (M4) simulator, iOS 26.5 · MacBook host · Debug build · commit after `f9e5a5e`. Bitmap section added Sept 18, 2026.

## Sync engine — 200 notebooks, 2,000 pages, every page with ink

| Operation | Observed | Threshold |
|---|---|---|
| First push of the whole library | 1.52 s | 30 s |
| First pull on a second device | 1.87 s | 30 s |
| Incremental push, one page edited | 0.94 s | 5 s |
| Incremental pull of that edit | 0.75 s | 5 s |
| Sync with nothing to do | 0.45 s | 5 s |
| Full index rebuild from the folder | 1.11 s | 30 s |

**What to watch.** The incremental and no-op numbers should not depend on library size. Two terms did: hashing every local payload on every push (linear in total payload *bytes*), and fetching and encoding every page twice per sync (linear in page *count*). The first is gone — `PayloadHashCache` now persists as `.payload-hashes.json` beside the payloads, each entry validated by the file's size and modification date — but this fixture's payloads are tens of bytes, so the no-op number only moved from 0.45 s to 0.37 s; the remaining cost is the second term. At 2,000 pages that's fine. If it isn't at 10,000, the fix is an incremental snapshot: build DTOs only for notebooks whose pages changed since the last push, which the per-notebook content signature already makes possible.

## Library list — 200 notebooks

| Operation | Observed | Threshold |
|---|---|---|
| Fetch all notebooks + sort by `modifiedAt` + touch page counts (what `LibraryView` does on appear) | 0.006 s | 2 s |

A proxy for cold launch. A real `XCTApplicationLaunchMetric` needs a UI-test target; add one when task 21's crash reporting lands, since both want the app launched under test.

## Imported PDF — 500 pages

| Operation | Observed | Threshold |
|---|---|---|
| Rasterize every page at 780×1040 through `ImportedArtwork.rasterized` (the current import path) | 0.375 s total | 120 s |
| Peak physical memory during the above (`XCTMemoryMetric`) | 57.4 MB | — |

The test PDF is text and rules; a scanned lecture deck will be heavier per page. This is the number M1's live `PDFKit` layer has to beat on memory while giving up rasterization entirely.

## Ink files — one page, 500 strokes × 32 control points

| Operation | Observed | Threshold |
|---|---|---|
| `DrawingStore.save` (encode record + write cache + key) | 0.023 s | 2 s |
| Second save, all stroke ids known | 0.015 s | — |
| `DrawingStore.load` (cache hit) | 0.024 s | 1 s |
| `StrokeCodec.decode` alone | 0.021 s | — |
| Record size (`.strokes`), 500-stroke fixture | 15 KB compressed (1,440 KB uncompressed) | — |
| Record size, 3 varied fountain-pen strokes | 2.8 KB compressed (8.9 KB uncompressed) | — |

**Compression landed the same day** (LZFSE body, header flag bit 0). The fixture's 96:1 is flattered by repetition; the 3.2:1 on varied strokes is the honest figure, which puts the record at roughly 2× PencilKit's own `dataRepresentation()` rather than 6×. Decompression is under a millisecond for a dense page (load stayed at 22 ms). Measured against zlib (11.4%, 6 ms) and LZMA (0.6%, 75 ms compress): LZFSE's speed wins for something written on every autosave.


## On-demand bitmaps — page artwork and strip thumbnails (Sept 18, 2026)

Not timed against a threshold yet; these are the structural fixes and what they removed. `MystNotesTests/PageArtworkTests.swift` pins the behaviour, not the numbers.

| Was | Now |
|---|---|
| Photos decoded at full resolution whatever size they were drawn at — a 12-megapixel photo is ~48 MB as a bitmap, and the page strip decoded one **per 60×80 thumbnail** | `ImportedArtwork.rasterized` honours `targetSize` through ImageIO (`kCGImageSourceThumbnailMaxPixelSize`), so a thumbnail decodes to ≤160 px and a page to ≤2.5× its own size |
| Image dimensions came from decoding the whole file (`UIImage(contentsOfFile:)?.size`) | `CGImageSourceCopyPropertiesAtIndex`, metadata only, with the EXIF quarter-turns applied |
| The page strip was a plain `HStack`, so opening a notebook built **every** page's thumbnail at once, each decoding that page's ink record and rasterizing its background | `LazyHStack` |
| Nothing cached a thumbnail; leaving and re-entering a notebook re-rendered all of them | `PageBitmaps.thumbnails`, 8 MB, keyed by an ink stamp so only the page that was drawn on re-renders |
| Each thumbnail ran its own `@Query` for every `ImportedDocument` in the library, re-run on every model change — one full fetch per visible page | the parent builds one `[UUID: ImportedDocument]` per update and hands each cell its own |
| A full-page artwork render could be completed and then thrown away (see `TOOL_FIXES.md` §3.2), so the same bitmap was rendered repeatedly | `BitmapStore` keeps every completed render and collapses concurrent requests for one key |

**What to watch.** Both stores drop their contents on a memory warning and bump a generation the views' `.task(id:)` reads, so a purge costs re-renders, not blank pages. If the artwork store's 64 MB starts evicting during ordinary page turns, the oversampling factor (2.5×) is the thing to look at before the budget.

**Still worth measuring on device:** opening a 200-page notebook, before and after the lazy strip. The simulator's disk makes the ink decode too cheap for the number to mean anything.

## Per-second work while drawing (Sept 18, 2026)

Reported as "the app freezes sometimes when switching between colours and stuff". Two things ran on the main thread on a one-second cycle for as long as anyone kept writing:

| Was | Now |
|---|---|
| The autosave's `Task { }` inherited the main actor, so encoding a page's strokes, LZFSE-compressing them and writing three files ran on the main thread a second after every stroke — 23 ms for a 500-stroke page *in the simulator* (see the ink-files table), plus `modelContext.save()` | `DrawingStore.saveDetached`, off the main actor. `Page.modifiedAt` is stamped only once the bytes land, so nothing reads the ink back early. Backgrounding still saves synchronously on purpose — the app may be suspended before an async write lands |
| Page turns saved the same way, synchronously | The same detached save; only backgrounding blocks |
| Handwriting OCR was awaited inside that autosave: render the page at 2×, composite, full `VNRecognizeTextRequest` — a Vision pass per second, each thrown away by the next stroke | `HandwritingIndexer`, one 12-second timer per page, flushed when you leave the page or the app |
| `PencilCanvasView.configure` re-set a dozen `PKCanvasView` properties on every SwiftUI update of the detail view, including `drawingPolicy` and `overrideUserInterfaceStyle` | each written only when it differs |

**The instrument, for what's left.** `MainThreadWatchdog` reported only hangs past 3 s and polled every 500 ms, so a 400 ms stutter was invisible. It now polls every 50 ms and logs stalls past 400 ms with the last checkpoint (no stack capture — that stays at 3 s). `applyToolState` is a checkpoint, so a stall while switching tools or colours names itself in Settings → Export Diagnostics. **Read that log before changing anything else here.** The untested hypothesis still on the table is that rebuilding the toolbar — every `toolState` change re-evaluates the whole 1,500-line detail view — churns the popover it is presented from.

## Not measured here — needs the iPad

| Measurement | How |
|---|---|
| **Ink latency on ProMotion** | Instruments → Core Animation / Hitches with the app on the iPad Pro, draw continuously for 30 s at 120 Hz. Record: hitch rate, worst frame, and whether autosave (1 s after a stroke), OCR or a debounced push (30 s) ever coincides with a hitch. The invariant is "nothing synchronous on the main thread during drawing"; the test is that none of those three show up in the trace while the pencil is down. |
| Cold launch, 200 notebooks, on device | `XCTApplicationLaunchMetric` once a UI-test target exists; until then, Xcode's Organizer launch-time report after a week of use. |
