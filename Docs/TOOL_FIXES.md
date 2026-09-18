# Fix brief: shape tool, fill tool, imported images

**Date:** September 12, 2026 (parts 1–2), September 18, 2026 (part 3)
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
