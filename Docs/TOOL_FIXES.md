# Fix brief: Shape tool and Fill tool

**Date:** September 12, 2026
**Milestone:** M1
**Files:** `ShapeRecognizer.swift`, `ShapeDrawingOverlay.swift`, `FillTool.swift`, `MystNotesDetailView.swift`, `DrawingToolbarView.swift`

Both tools are shipped and visible in the toolbar. Neither works well enough to keep as-is. This brief is the diagnosis, not the fix, so the fix can be argued with before it's written.

---

## Part 1 — Shape tool

### Symptom

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
