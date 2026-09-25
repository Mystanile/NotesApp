# Fix brief: shape tool, fill tool, imported images

**Date:** September 12, 2026 (parts 1–2), September 18, 2026 (part 3), September 19, 2026 (part 4)
**Milestone:** M1
**Files:** `ShapeRecognizer.swift`, `ShapeHoldRecognizer.swift`, `FillTool.swift`, `MystNotesDetailView.swift`, `DrawingToolbarView.swift`, `PageBackgroundView.swift`, `ImportedPageBackgroundView.swift`, `BitmapStore.swift`, `ImportedArtwork.swift`, `CanvasGestures.swift`

Shipped tools that don't work well enough to keep as-is. Each part is the diagnosis, not the fix, so the fix can be argued with before it's written.

---

## Part 1 — Shape tool

**Done Sept 15, 2026; second pass Sept 18, 2026 after field use.** `ShapeRecognizer` rewritten on the pipeline below (resample → closed-loop cut → corners by turning angle → classify; ellipse fit first because a long ellipse's ends read as corners). Line, arrow, circle, ellipse, triangle, square, rectangle (rotated kept; snapped to the axes within 10°), quad, pentagon and hexagon; low confidence returns `nil`. Polygon vertices carry multiplicity 3 in the control points and `testRectangleStroke_hasSharpCorners_andFollowsTheEdges` samples the built `PKStrokePath` to prove the corners are sharp. Width, pressure and ink come from the stroke being replaced (see the second pass below). `ShapeDrawingOverlay` and the armed mode are deleted; `ShapeHoldRecognizer` (custom `UIGestureRecognizer` on the host, 0.5 s still, haptic + `ShapePreviewView` through `PageViewportLayer`) and `ShapeSnapController` (swap in `canvasViewDrawingDidChange`, undoable) implement hold-to-snap on both canvases. 29 tests in `ShapeRecognizerTests`. **Owed on hardware:** that the recognizer on the host receives the Pencil's touch while PencilKit draws with it - verified for fingers by the shortcut recognizers, not yet for the Pencil.


### Second pass — Sept 18, 2026

The rebuild classified well on synthetic input and still felt broken in the hand. Six complaints from real use, all reproduced in the code, all fixed on `m1-images-and-shapes`:

**The hold often wasn't noticed.** `Timer.scheduledTimer` schedules in the **default** run-loop mode only. A pencil down on the canvas puts the main run loop in **tracking** mode, where such a timer does not fire at all — so whether the hold registered depended on what else was driving the run loop. It is now created with `Timer(timeInterval:target:selector:…)` and added to `RunLoop.main` in `.common`. Second path, belt and braces: `touchesMoved` checks the elapsed time itself, so a resting Pencil's own jitter samples can trigger the hold even if the timer is starved. The wait went 0.8 s → 0.5 s, and the stillness tolerance 4 pt → 9 pt, because a hand holding a pencil drifts further than 4 pt and every drift past the tolerance restarted the clock.

**A hold that recognized nothing was spent.** `onHold` now returns a Bool; `false` leaves the hold unclaimed and the recognizer offers again as the stroke grows.

**Lines came out as arrows.** `recognizeOpen` sent the stroke to the arrow recognizer whenever *any* corner was found, and `recognizeArrow` then took `max(measuredBarb, shaftLength * 0.12)` — a floor, so a stroke with no arrowhead at all got a 12%-of-shaft one drawn on it. An open path is now fitted as a **line first**, whatever corners were found; an arrowhead must be measurably present (≥10% of the shaft, <60%) *and* double back along it (≥6% of the shaft). `testWobblyLine_isALine_notAnArrow` pins it.

**Shapes were always thick and the width slider didn't seem to touch them.** The stroke was built with `size: tool.width, force: 1` — the tool's heaviest possible mark, next to a freehand stroke drawn at whatever pressure the hand used. `ShapeRecognizer.spec(matching:tool:style:)` now takes the ink, the median point size and the median force **from the stroke being replaced**, so the snapped shape is the same mark by construction, whatever the tool and wherever the slider is. The tool is only the fallback for a shape with no source stroke (the preview, and the tests).

**No axis snapping for lines.** Rectangles snapped (7°, now 10°); lines did not. `axisSnapped(from:to:)` straightens a segment onto horizontal/vertical within 10° and onto the 45° diagonals within 6°, keeping the midpoint and the length so neither end jumps. Arrow shafts go through the same call.

**No dotted or dashed lines.** PencilKit has no dashed ink and never will have for freehand — the dashes would have to be recomputed on every sample as the stroke grew. A *snapped* shape is a finished outline, so `ShapeLineStyle` (solid/dashed/dotted) builds it as many short strokes along that outline, dash and gap scaled off the brush. It sits in the pen options popover, the live preview draws it, and `applyIfPending` swaps the one freehand stroke for the N dash strokes in a single undoable change.

One more, found while reading: `applyIfPending` required the pencil-lift to have been seen before the commit. PencilKit commits the stroke on touch-up and the order against our own `touchesEnded` is not guaranteed, so a commit that won the race dropped the snap. The window is now "unless the lift was more than 1.5 s ago", and a new stroke clears any pending shape, which is the real protection.

**Still owed on hardware:** that the recognizer on the host receives the Pencil's touch while PencilKit draws with it — verified for fingers by the shortcut recognizers, not yet for the Pencil. If the hold still misses on the iPad after this pass, that is where to look next.

### Symptom (as of Sept 12)

Only produces ovals and straight lines. Never triangles, arrows, or usable rectangles. Line thickness is always the same regardless of the selected pen. Requires arming a separate toolbar button.

### Four independent bugs, all in `ShapeRecognizer.swift`

**Bug 1 — squares are classified as circles.**

```swift
return (stdDev / avgRadius) < 0.28   // "fairly consistent radius = roughly round"
```

The coefficient of variation of a point's distance from the centre, sampled evenly around a **square**, is about **0.10**. That is comfortably under 0.28, so squares pass the "roughly circular" test and get turned into ellipses. Only strongly elongated rectangles have enough radial variance to survive as rectangles.

This single threshold explains the entire "only makes ovals" complaint.

**Bug 2 — even when it picks rectangle, the result has rounded corners.**

```swift
let path = PKStrokePath(controlPoints: strokePoints, creationDate: creationDate)
```

`PKStrokePath` takes **cubic B-spline control points**, not on-curve points. Feeding it five rectangle corners does not draw a rectangle; the spline smooths through them, rounding the corners and pulling the shape inward toward the control polygon. The ellipse happens to survive this because it is sampled at 72 points, dense enough that smoothing is invisible.

To get a genuine corner from a cubic B-spline you must repeat the control point (multiplicity 3). Every polygon vertex needs that treatment.

**Bug 3 — hardcoded thickness.**

```swift
size: CGSize(width: 4, height: 4)
```

This is the same bug class as the tool-colour one already fixed once ("Shape tool color was hardcoded — corrected to read from the active PKInkingTool"). The width was missed because `PKInk` doesn't carry width — it lives on `PKInkingTool.width`. `recognizeStroke(from:ink:)` takes a `PKInk`, so the width information never reaches it. The signature needs the tool, or an explicit width.

Note also the default argument `ink: PKInk = PKInk(.pen, color: .black)`. A default that silently produces black pen is a trap; make the parameter required.

**Bug 4 — the closed-shape test is too strict, so near-misses become lines.**

```swift
let isClosedShape = closingDistance < max(diagonal * 0.18, 20)
```

Anything that fails this falls into `idealPoints = [start, end]` and becomes a straight line between the first and last point. A hand-drawn box that overshoots its corner, or stops short, silently turns into a diagonal line. That is the "and lines" half of the complaint.

**Also, but lower priority:** `rectanglePoints(in: bounds)` is axis-aligned only, so a rectangle drawn at an angle snaps square to the screen. Use a minimum-area rotated bounding box instead.

### Recommended recognizer

Drop the radius-variance heuristic. Standard pipeline:

1. **Resample** the path to N equidistant points (N ≈ 64). Everything downstream gets easier.
2. **Closed test:** endpoint gap relative to total path length, more tolerant than now, and also treat a path that crosses itself near the start as closed (handles overshoot).
3. **Corner detection** by curvature over the resampled path. Corner count drives classification: 0 corners closed → ellipse/circle; 3 → triangle; 4 → quad; 5+ → polygon or freeform.
4. **Line:** open path with low least-squares residual.
5. **Circle vs ellipse:** fit and check radial residual with a much tighter threshold than 0.28.
6. **Rectangle vs arbitrary quad:** four corners with interior angles near 90°. Snap to axis-aligned only when within a few degrees of it, otherwise keep the rotation.
7. **Arrow:** open path with a V near one end.
8. **Bail out.** If confidence is low, leave the stroke alone. A shape tool that guesses wrong is worse than one that does nothing.

The $1 Unistroke Recognizer is a well-documented template-matching alternative that covers all of this in roughly 200 lines, if the geometric approach gets fiddly.

### Interaction change: hold to snap

Delete `ShapeDrawingOverlay` and `isShapeModeArmed` entirely. Draw normally; keep the pencil down and still at the end of the stroke, and it snaps. This is how GoodNotes and Apple Notes do it, it removes a mode, and it means the freehand phase uses real ink with real pressure instead of a 2px accent-coloured `DragGesture` preview.

**`UILongPressGestureRecognizer` will not work here.** Its `allowableMovement` measures displacement from the *initial* touch point, and the user has been drawing — moving a long way — before they hold. The recognizer will already have failed by the time they stop moving.

What's needed is a small custom `UIGestureRecognizer` subclass:

- On `touchesMoved`, if movement since the last sample exceeds a few points, restart a timer (~400–500 ms).
- If the timer fires while the touch is still down, signal the snap.
- Add it to the canvas with a delegate returning `true` from `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` so PencilKit keeps drawing underneath.

**PencilKit only commits a stroke to `canvasView.drawing` on touch-up**, so the in-progress stroke cannot be swapped mid-gesture. The sequence is:

1. Timer fires → set `pendingSnap`, fire a haptic, and draw a preview of the recognized shape in an overlay above the canvas (the existing `PageViewportLayer` is the right place).
2. User lifts → `canvasViewDrawingDidChange` fires.
3. If `pendingSnap`, replace `drawing.strokes.last` with the recognized stroke.

The haptic matters. It's what tells the user the hold registered, before they lift.

**Recognition input** should be the committed `PKStroke.path` via `interpolatedPoints(in:by:)` — on-curve points, properly sampled, with real timing. Not the raw B-spline control points, and not `DragGesture` locations.

### Acceptance

- Square, rectangle (including rotated), circle, ellipse, triangle, straight line, and arrow all recognized
- Corners are sharp, not rounded
- Stroke width and colour come from the active `PKInkingTool`
- No toolbar mode; hold-to-snap only
- Low-confidence strokes are left untouched
- Works on both paged and whiteboard page types

---

## Part 2 — Fill tool

### Fixed, Sept 25, 2026: the strokes were too thin to draw

Logging on the iPad settled it in one tap. The coordinates were right: the page point landed inside the shape, the flood covered 54,967 px (the ellipse's area), and 264 strokes were added to the canvas. They were almost all invisible. PencilKit draws nothing for a stroke under ~2pt (measured: sizes 0.5–1.5 render zero pixels), and the fill sized each band from its own height as `height / 2`, assuming a stroke renders about twice its size. A curved region has a different width on every row, so nearly every band was one row high and drawn at 0.75pt. Only the few middle rows of equal width merged into bands thick enough to see, which is exactly the "a few yellow lines across the middle" in the field report. The invisible strokes were also invisible to the next fill, so every tap stacked another few hundred of them on the page.

The fix is in the stroke synthesis only. Bands are a fixed 3 rows drawn at 4pt as monoline, so they overlap and every one renders. The runs within a band are merged. The fill goes under the existing ink, so the edges a pixel or two past the region sit beneath the outline. Result: an ellipse is >99% covered, with 82 strokes instead of 264. `FillToolTests` now checks rendered pixels, not just stroke positions. That is why the two earlier fixes and the first version of this test missed it.

The zoom hypothesis below was the right thing to rule out, and `viewport.pagePoint` (`32de133`) had already fixed it.


### Symptom

Doesn't work. Has been fixed twice already (`24eac63` "pixel buffer was never actually written", `f1d8411` "the fill tool's tap capture") and still doesn't.

### The design is sound — don't throw it away

`FillTool` rasterizes the ink, scanline flood-fills the region containing the tap, then synthesizes the result as horizontal `PKStroke`s so the fill is real, erasable ink rather than an image layer bolted on beside the drawing. That is a defensible choice and the scanline implementation looks correct, including the run-start-only seeding that keeps the stack small.

The previous two fixes were both real bugs in that machinery. The pattern of fixing it twice and still failing suggests the current failure is somewhere else.

### Leading hypothesis: page zoom broke the coordinate space

`FillTool.fill(_:in:at:color:)` documents its contract explicitly:

> `point` and `canvasSize` must be in the same coordinate space as `drawing` itself (i.e. the PKCanvasView's own local coordinates) — for the app's "paged" pages that's identical to the SwiftUI overlay that captures the tap, so callers there can pass the tap location straight through with no conversion.

**That assumption stopped being true at HEAD.** Commit `72a0eba` added "real page zoom" and per-page canvases. Once the canvas is scaled and offset, the SwiftUI tap overlay's coordinate space is no longer identical to the canvas's local space, so the tap is converted to the wrong pixel.

The two failure modes that follow both look like "nothing happens":

- The wrong pixel lands on ink → `alpha[...] <= alphaThreshold` fails → returns `nil` silently.
- The wrong pixel lands outside the intended region → floods somewhere unexpected, or spills across the whole page.

### Instrument before rewriting

This tool has been rewritten twice on hypothesis. The third attempt should start by measuring. Log, on one tap:

- the raw tap location in the overlay's space
- the location after any conversion, and the canvas's current zoom and content offset
- `canvasSize` as passed, versus the canvas's actual bounds
- the alpha value at the resolved pixel
- the returned span count

That distinguishes a coordinate-space failure from a threshold failure from a flood-escape in one run. Fix what the log actually shows.

### Other issues to address once it works

- **Silent failure.** Tapping on ink returns `nil` with no feedback at all. The user gets nothing and learns nothing. Needs at least a subtle indication that the tap was received and rejected.
- **Antialiasing leaks.** `alphaThreshold = 20` against a thin antialiased stroke edge: a hairline's outer pixels can fall below 20, so the fill escapes through a line that looks solid. Consider dilating the alpha map by a pixel before filling.
- **Backgrounds don't bound the fill.** Lined and grid templates are drawn by a SwiftUI `Canvas` behind the ink, not as strokes, so they are invisible to the flood fill. A fill inside a "box" drawn against ruled lines will spill. Expected given the architecture, surprising to a user. Worth either documenting or compositing the template into the alpha map.
- **Stroke count.** `maxBandHeight = 8` means a large region becomes hundreds of synthesized strokes, which inflates the drawing and makes erasing leave banded gaps. Once it works, measure the stroke count on a full-page fill and decide whether it's acceptable.

### The honest option

If the coordinate fix doesn't land it quickly: **hide the tool rather than ship it broken.** A visible button that does nothing is worse than an absent feature, and it's the first thing a new user will try because no competitor has it. Bringing it back when it works is a better story than having it half-work at launch.

---

## Sequencing

Shape tool first. Its bugs are fully understood, the fix is bounded, and it's the more visible of the two. The fill tool needs an instrumentation pass before anyone can say how big the fix is.

---

## Part 3 — Imported images (Sept 18, 2026)

Three symptoms, reported from use. All three are fixed on `m1-images-and-shapes`; the second one has a caveat.

### 3.1 Importing an image wiped the page's template — **fixed**

The page drew *either* its paper template *or* its imported artwork:

```swift
if page.backgroundRef != nil {
    ImportedPageBackgroundView(page: page, …)   // and this painted its own Color.white
} else {
    PageBackgroundView(template: page.template)
}
```

An import sets `backgroundRef`, so from that moment the lined/grid/dotted ruling stopped being drawn at all, and the artwork layer's own white fill covered where it had been. The model is reasonable for a full-bleed PDF, which *is* the page; it is wrong for a photo, which is something placed *on* a page.

Two things fell out of looking at it. The thumbnails and the exporter never drew a template **at any time** — so a lined page has been exporting and thumbnailing as blank paper since templates shipped, import or no import. And the ruling was a SwiftUI `Canvas` that only the editor had.

The fix is one routine, `PageTemplate.draw(_:in:context:)`, drawing into a `CGContext` in page points, called by all three; the page is now a stack — paper, template, artwork, ink, text. The artwork layer is transparent except where the artwork is. A full-bleed PDF still covers the sheet, so nothing about a PDF import looks different.

### 3.2 Images vanished on page turns until you moved the page — **fixed, with a caveat**

`ImportedPageBackgroundView.loadImage` ended:

```swift
let rendered = await Self.render(inputs).value
guard key == imageKey else { return }              // ← drops the bitmap AND skips the cache
if let rendered { PageArtworkCache.store(rendered, for: cacheKey) }
image = rendered
```

If the key drifted while the render was in flight — it is built from `@Query allImportedDocuments.first { … }`, an unordered fetch re-run on every model change — the finished bitmap was discarded without being cached *or* shown. The view's `@State` stayed nil, and its `.task(id: imageKey)` could not re-fire because the *body's* key had not changed. The page stayed white until something re-evaluated the body, which is exactly what panning around it does (`PageViewportLayer` reads the observable viewport). A contributing factor: photos were decoded at full resolution, so one 12-megapixel photo cost ~48 MB against a 96 MB `NSCache` and the cache thrashed, putting far more renders through that race than there should have been.

`BitmapStore` replaces it. A completed render is always kept — a correct bitmap for a key is valid no matter who asked. Concurrent asks for one key collapse into one render. The store is `@Observable`, so a render landing re-evaluates every view reading that key, and a `generation` counter changes on a purge, which re-fires the views' `.task(id:)`. There is no path left that leaves a view showing nothing while a bitmap exists or could be made.

**Caveat.** I could not reproduce this on hardware, and there is a second candidate with an identical symptom: `PageViewportLayer` sets `.opacity(viewport.hasSynced ? 1 : 0)`, hiding the whole layer — paper, artwork, text blocks — until the canvas publishes a fitted viewport for the *incoming* page. Any page turn where that publish doesn't land for the expected page leaves the page invisible until a gesture, and a scroll callback is exactly what would fix it. Every path I traced does end in `setNeedsLayout`, which is why 3.2 is the likely culprit and this is not. If images still vanish on the iPad, this is the next place to look.

### 3.3 No way to get an image in on a Mac — **fixed**

Image import was a single `.photosPicker(…, matching: .images)`. On Mac Catalyst that shows the Photos library and nothing else — no Files, no Finder drag, no pasteboard. There was no paste handler anywhere in the project.

Four routes now funnel into one entry point:

| Route | How |
|---|---|
| Photos | the existing picker |
| Files / Finder | a second `.fileImporter`, `[.image, .pdf]` |
| ⌘V | `CanvasHostView.paste(_:)` + `canPerformAction`. `PKCanvasView` is the first responder and implements neither, so the action walks up the chain to the host — which keeps the system Edit ▸ Paste item enabled and routed to the page. A menu item does the same thing for discoverability. |
| Drag | `UIDropInteraction` on the host, images and PDFs, loaded as data so a PNG stays a PNG |

The type is decided by the file's own header (`ImportedFileType`), never by what the source claims: a pasteboard item declared `public.png` can be a JPEG, and a PDF picked from the image importer still imports as a PDF. Bytes are stored as they arrived — the old path decoded to a `UIImage` and re-encoded JPEG at 0.9 **on the main actor**, which is both lossy for a screenshot and a full-resolution decode on the thread that has to stay clear for ink.

`hasImage` (a silent check) gates the menu item and the Edit menu; only a real paste reads the pasteboard, so iOS's "pasted from" banner appears when someone actually pasted.

### 3.4 The second `.fileImporter` killed PDF import on the iPad — **fixed, Sept 19, 2026**

The Files route in 3.3 was added as a *second* `.fileImporter` chained after the PDF one. SwiftUI gives a view one document-picker presentation; with two chained, only the last is wired up, and the first's `isPresented` flips to `true` with nothing appearing. That was the PDF importer, so "PDF onto This Page" and "PDF as New Pages" silently did nothing on the iPad from the Sept 18 build. Catalyst presents the picker differently, which is why it wasn't caught there.

There is exactly one `.fileImporter` on `NotebookDetailView` now (`showingFileImporter` + `fileImporterTypes`); the menu item picks the types, the file's header picks the path. The state var's doc comment says why there must never be two.

### 3.5 A page can hold more than one piece of artwork — **Sept 19, 2026**

Reported the same day: put a photo on a page, import a PDF onto it, the photo is gone. Not a regression — `applyBackground` deleted every `ImportedDocument` on the page before inserting the new one, because every renderer took exactly one. Same the other way round (a photo onto a PDF page replaced the PDF).

The page's artwork is a **stack** now, bottom first:

- `ImportedDocument.stackOrder: Int?` (nil = 0, so old records draw first; ties fall back to the id so both devices agree). `ImportedDocument.stack(on:in:)` is the one sort. It syncs as `ImportedDocumentDTO.stackOrder`, optional, so old snapshots decode.
- A full-bleed PDF is the page's paper and goes **under** whatever is there (`stackOrder(under:)`); a photo goes **on top** (`stackOrder(over:)`). `Page.backgroundRef` is the bottom of the stack — still "this page has artwork", still what old pages have when they have no document at all.
- `ArtworkLayer` is the value type the renderers take. `ImportedPageBackgroundView`, `PageThumbnailRenderer`, `PageRenderer` and `SearchIndex` all draw or read the whole stack. One bitmap per layer in `PageBitmaps.artwork`; placement isn't part of the key, so moving a picture re-renders nothing.
- Long-press picks the topmost picture under the finger (the canvas now passes the press location up); rotate, crop, remove and the handles act on that one (`adjustingLayerID`). Remove takes only that layer, and trashes its file if nothing else uses it.

Tests: `PageArtworkTests` (stack order, thumbnails draw every layer bottom first, bitmap key ignores placement, legacy `backgroundRef`-only pages are one layer) and `SyncTests` (a three-layer stack round-trips with its order and every file; ties are stable across devices).

### 3.6 The page strip cycled, one thumbnail visible at a time — **fixed, Sept 19, 2026**

Screen recording from the iPad: five thumbnails on screen, only ever one of them showing its page, and which one kept changing. `BitmapStore` evicted oldest-inserted when over budget and bumped `generation`, which every thumbnail's `.task(id:)` includes — so landing B evicted A and re-fired A's view, which evicted B, and so on forever. The strip at that height needs ~2.8 MB per thumbnail (rendered at the screen's scale on top of an `output` that is already 2x, deliberately: the ruling fades out at less) against an 8 MB budget, so it never settled.

Eviction is now least-recently-*read*, never touches the entry that just landed or anything read in the last second (that is what is on screen), and tolerates being over budget by what is on screen rather than dropping something that will only be asked for again. A body read of a missing bitmap also asks for it, so a view whose entry was evicted heals on its next draw. The thumbnail budget is 24 MB. `testStore_neverEvictsWhatWasJustRead_soAStripCannotCycle` replays the recording.

Second recording, same afternoon: the strip stuttered while its grabber was dragged. Every 80 px of drag was a new cache key, so every visible thumbnail re-rendered (ink decode, PDF rasterize) mid-drag, and each cell went blank until its new bitmap landed. `PageThumbnailView.renderHeight` now holds the request at the height the drag started from - the bitmap is scaled during the drag and rendered once on release - and a cell keeps showing the bitmap it had until the replacement arrives (`lastShown`), which also covers the re-render after an ink edit.

### 3.7 Exports and thumbnails lost the black ink in dark mode — **fixed, Sept 19, 2026**

An exported notebook had every page's PDF and the green ink, and none of the black handwriting; the editor showed all of it, and reopening the notebook showed all of it. The iPad was in dark mode. `PKDrawing.image(from:scale:)` renders through the *current* trait collection and PencilKit inverts ink for a dark appearance - which is why the canvas is pinned to `.light` (the dark-mode ink history in git) - but `PageRenderer` and `PageThumbnailRenderer` render with no view to take traits from, so black became white on white paper. Green isn't a colour PencilKit inverts, which is why it survived and made the failure look like missing strokes rather than invisible ones.

Both renders are wrapped in `UITraitCollection(userInterfaceStyle: .light).performAsCurrent`, as `FillTool` and `HandwritingRecognizer` already were. `testExport_keepsInkDarkInDarkMode` renders under dark traits and checks the ink is dark; `testExport_drawsTheCroppedArtworkAndTheInk` and `testNotebookExport_hasEveryPage` came out of the same investigation and pin the rest of the export.

---

## Part 4 — Lasso: resize with a pinch (Sept 19, 2026)

### Why PencilKit's lasso couldn't do it

The lasso was `PKLassoTool`. It selects and moves, and offers Cut/Copy/Delete/Duplicate, but PencilKit never exposes *which* strokes it holds — there is no `selectedStrokes` — so nothing could be attached to the selection. Resize meant owning the lasso end to end.

### What was built

`InkSelection` (pure functions on `PKDrawing`), `InkSelectionController` (gestures → edits, `@Observable`, owned by the detail view like `CanvasViewport`), `InkSelectionOverlay` + `InkSelectionToolbar` (SwiftUI, hit-testing off; the gestures live on the host).

- **Selecting.** With the lasso tool active the canvas's `drawingGestureRecognizer` is disabled and `InkLassoRecognizer` — a pure touch observer on the host, like `ShapeHoldRecognizer` — reads the Pencil's loop. A stroke is taken when more than half its sampled points are inside the loop (`CGPath.contains`, even-odd); one merely clipped stays put. Fingers still pan and zoom the page while nothing is selected.
- **Manipulating.** With a selection, `isZoomEnabled` goes false (the image handles' trick), so the host's own pan / pinch / rotation recognizers get the fingers: one-finger drag inside the box moves, **pinch resizes**, twist rotates — all about the selection's centre. Pencil-down inside the box also drags; Pencil or finger outside lets go.
- **Storage.** A move, resize or rotate is folded into each stroke's `transform`, never into its points. Stroke identity is `creationDate + randomSeed` (`StrokeIDMap.Fingerprint` ignores the transform on purpose), so IDs survive (invariant 6) and the record stores the full affine. **Measured, not assumed:** PencilKit scales the ink *width* with a scale transform (`testScaleTransform_scalesInkWidthToo`, inked area ~4× for 2×), so a doubled word reads as the same handwriting drawn bigger.
- **Never lose ink.** Each gesture step rewrites `canvas.drawing` with every stroke present and only the selected transforms changed. The canvas always holds the complete drawing, so an autosave landing mid-gesture saves complete ink (invariant 1). The step is committed once, as one `setDrawingUndoably`, when the last finger lifts — one undo per drag, pinch or twist, however many fingers took part.
- **Staleness.** The selection is remembered as fingerprints, not indices. An undo, an erase or a page change that removes a selected stroke makes the selection let go instead of acting on whatever is at those indices now; an undo that moves the ink without removing it re-syncs the box on the next gesture.
- **Copies.** Duplicate and Paste go through `reidentified`: each copy gets its own `creationDate` (a millisecond apart), so no copy ever shares a fingerprint with its original or with another copy. Ink travels on the pasteboard as PencilKit's archive under `com.mozynas.mystnotes.ink`, so it is never mistaken for a picture; ⌘C / ⌘X / ⌘V reach it through `CanvasHostView`.
- **The page holds still.** A resize used to zoom the whole page with it: `isScrollEnabled = false` stands down a `UIScrollView`'s pan only, and the canvas's pinch kept going under the selection. The controller now disables the canvas's pan *and* pinch the moment a selection exists, synchronously (`gateCanvasGestures`), and the image handles' path got the same pinch line in `PencilCanvasView.configure`. `testController_selectionHoldsThePageStill`.
- **Scope.** Paged pages only; the whiteboard keeps `PKLassoTool` (backlog).

### Owed on the iPad

Two framework behaviours the simulator can't answer, both in `BACKLOG.md`: whether the host's observer receives the Pencil with the drawing gesture disabled (the shape tool's open question), and whether the Pencil then pans the scroll view under `.pencilOnly`.

### Tests

`InkSelectionTests`, 17: what a loop takes; moves and scales keep every identity and only touch the selection; scale is about the centre; steps compose; a rotated box hit-tests as rotated; copies are new strokes; pasteboard round-trip; the width-scaling probe; and on a real `PKCanvasView` — a drag is one undo and the selection survives it, a pinch resizes about the centre, pinch+twist is one gesture, a vanished stroke lets go, duplicate/paste select the copies and are one undo, the tool stands inking down and hands it back, a new canvas drops the selection.
