# Performance baseline

**M0 task 20.** Numbers recorded so a regression is a test failure, not a feeling. `MystNotesTests/PerformanceTests.swift` prints each as `BASELINE …` and fails past a threshold set at roughly 3–5× the observed value — enough to catch a real regression, loose enough to ignore simulator noise. Update this file and the thresholds together.

**Recorded:** Sept 12, 2026 · iPad Air 11-inch (M4) simulator, iOS 26.5 · MacBook host · Debug build · commit after `f9e5a5e`.

## Sync engine — 200 notebooks, 2,000 pages, every page with ink

| Operation | Observed | Threshold |
|---|---|---|
| First push of the whole library | 1.52 s | 30 s |
| First pull on a second device | 1.87 s | 30 s |
| Incremental push, one page edited | 0.94 s | 5 s |
| Incremental pull of that edit | 0.75 s | 5 s |
| Sync with nothing to do | 0.45 s | 5 s |
| Full index rebuild from the folder | 1.11 s | 30 s |

**What to watch.** The incremental and no-op numbers should not depend on library size, and today they do, linearly in total payload bytes: every push hashes every local payload (`PayloadHashCache` only spans one run). At 2,000 tiny test payloads that's the 0.45 s. At 2,000 real pages averaging 100 KB it would be a few seconds per sync, all disk reads. The fix is on the backlog — persist the hash beside the model when `DrawingStore` writes the record — and this table is the trigger for it.

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
| **Record size (`.strokes`)** | **1,440 KB** | — |

**What to watch.** 1.4 MB for a dense page is ~6× PencilKit's own `dataRepresentation()` for the same strokes: eleven float64s per control point, uncompressed, by design (spec §5 — precision is ink). It is what syncs, per page, per edit. A 200-page notebook of dense ink is ~300 MB in the folder and in iCloud. Compression is the obvious step — the header's `flags` field exists for it, and control-point streams compress well — and it should land **before any library is synced in anger**, because a format flag is cheap to add now and expensive to retrofit. On the backlog as a pre-M1 item.

## Not measured here — needs the iPad

| Measurement | How |
|---|---|
| **Ink latency on ProMotion** | Instruments → Core Animation / Hitches with the app on the iPad Pro, draw continuously for 30 s at 120 Hz. Record: hitch rate, worst frame, and whether autosave (1 s after a stroke), OCR or a debounced push (30 s) ever coincides with a hitch. The invariant is "nothing synchronous on the main thread during drawing"; the test is that none of those three show up in the trace while the pencil is down. |
| Cold launch, 200 notebooks, on device | `XCTApplicationLaunchMetric` once a UI-test target exists; until then, Xcode's Organizer launch-time report after a week of use. |
