# M2 remaining work: judgement and final plan

## Scores (1–5)

| | Data safety | Correctness | Simplicity | User value | Total |
|---|---|---|---|---|---|
| **A: safety first** | 5 | 4 | 3 | 4 | **16** |
| **B: user first** | 4 | 4 | 2 | 5 | 15 |
| **C: simplest code** | 3 | 3 | 5 | 4 | 15 |

**A wins.** It is the only design that does all of these:
- It fixes both live link-sync bugs first.
- It keeps the selection key apart from the stroke-ID key.
- It calls `markModified` after the anchor-follow write. C says "the save already marked the page", but that is a sync race: if a push runs between the save and the anchor write, the anchor change never syncs.
- It hands the thumbnail links down from the parent instead of fetching them per cell.
- It has one helper file that all link writes go through.

What was checked in the code for this verdict:
- `removeUnfinishedLinks` (MystNotesDetailView+PageElements.swift:182) deletes any self-link with `kind != "mention" && destinationID == nil`. A node is exactly that, so the filter must change and the format must go to 5 before any node is written.
- A mention's `destinationID` holds its source text block (:24), so B is right that the field is already overloaded.
- `Page.type` exists ("paged" | "whiteboard").
- Thumbnails pass `links: []` on purpose (PageThumbnailView.swift:223-225).
- `HandwritingRecognizer.text` already renders on `InkRenderQueue`.

What the other two get wrong:
- **C:** it changes `Fingerprint` itself to date+seed, and `InkSelectionController` uses `Fingerprint`. After a split, lassoing one piece would select its sibling pieces too, and Delete would remove ink the user did not lasso. That is a data-loss bug. C also fetches links per thumbnail cell, against a known gotcha.
- **A:** a pure date+seed key would merge two live legacy strokes under one UUID. CLAUDE.md says shape strokes made in the same instant "differ by their points", so that collision is real in existing records. A's drawable map as `Page.type="map"` touches 57 `.pages` sites. A's mention pruning by token count is a fragile heuristic.
- **B:** its drawable map adds a new DTO field and payload type before anyone has designed it. It changes `graphLayout` to v2 with no format gate. `MapCanvasView` (a UIScrollView-backed PKCanvasView) is more code than the job needs.

**Taken from the others:**
- From B: the hybrid stroke-ID key (exact 5-field match first, then date+seed only for a stroke whose original is gone), with a `departed` memory inside `StrokeIDMap`. The B flow: name alert, Insert ▸ Node…, filters that dim cards instead of hiding them.
- From C: storing the mention label in `Link.title`, so pruning is exact. Reusing `LinkDestinationPickerView` with a Nodes section for both link-to-node and transclusion. A `regionInk` helper. The drawable map as a decision gate only.

---

## Design

### Data model (no new @Model; one new field)

- **`Link.title: String?`** is the only new field, in `MystNotesModels.swift` and as `LinkDTO.title: String? = nil`. It holds a node's name or a mention's inserted label.
- **Region node.** `Link(source P, destination P)`
  - `kind = "node"`, `destinationKind = "region"`
  - `strokeIDs` = UUID strings of the lassoed strokes
  - `title` = the name, never empty
  - anchor = the region's bounds when last seen
- **Link to a node.** An explicit link: `kind = nil`, `destinationKind = "region"`, `destinationID` = the node Link's id, and `destinationPageID` = the node's page, so page-level readers still navigate.
- **Lasso "Link This To…".** `kind = nil` and now also `strokeIDs`. Here they are the source anchor's strokes.
- **Transclusion.** `Link(source host H, destination owner P)`
  - `kind = "transclusion"`, `destinationKind = "region"`
  - `destinationID` = the node id
  - anchor = where it sits on H
  - It has no `strokeIDs` of its own. The node is the only owner of the stroke list; transclusions only read it.
- **Tags** are never stored as links. The graph derives `#tag` nodes from `Page.tags`.
- **One filter rule.** Only `kind == nil` draws a plain anchor; this changes PageElements.swift:139 and PageElementsOverlayView.swift:43. `kind == "transclusion"` draws ink. Mention and node draw nothing on the page itself (a node gets a badge in task 7). `removeUnfinishedLinks` becomes `kind == nil && destinationKind == nil && destinationID == nil && source == dest`.
- **`MystNotes/Links.swift`** (new) is the only place that changes a Link. Every helper calls `markModified` on each source page it changes, because `contentSignature` hashes only page `modifiedAt`. Helpers:
  - `setDestination(_:toPage:)` and `setDestination(_:toNode:)`
  - `removeAll(touching:)`, moved out of `PageDeletion.delete`
  - `makeNode`, `setTitle`
  - `addTransclusion`
  - `nodeTitle(recognized:pageNumber:)`
  - `isPlainLink`

### Sync format

- One bump: `librarySnapshotFormatVersion = 5`, in the same task that adds `title`.
- Without the bump, a format-4 build would strip titles, show transclusions as plain anchors, and delete nodes through its `removeUnfinishedLinks`.
- Every task after the bump ships in the same build.
- The `.strokes` record does not change: UUIDs are already stored per stroke, and the matching keys exist only in memory.
- Graph positions keep their JSON meaning: fractions, now of a fixed 2000×2000 world instead of the sheet. Nothing migrates.

### Stroke IDs

- `StrokeIDMap` keeps the 5-field `Fingerprint` as the exact key, and `InkSelectionController` does not change.
- **Fallback in `encode`:** when a stroke's fingerprint is unknown, take the id of an entry with the same `(creationDate, randomSeed)` whose stroke is not in this drawing. All pieces of a split therefore share the original UUID.
- **`departed: [Fingerprint: UUID]`:** in memory only, never encoded, kept for the session (`ponytail:` no cap until it shows up in memory). `encode` moves the ids of gone strokes into it and checks it before making a new id. This fixes erase → autosave → undo.
- **New synthesized strokes** (shape snap, fill, tutorial) get creation dates 1 ms apart, as `InkSelection.reidentified` already does.
- **Resolver:** `StrokeIDMap.indices(of: Set<UUID>, in: PKDrawing) -> [Int]` (it can return several split pieces) and `static bounds(of:in:map:) -> CGRect?`. `nil` means the ink is gone.
- **`DrawingStore.regionInk(pageID:ids:) -> (strokes: [PKStroke], bounds: CGRect)?`:** nonisolated, decodes the record only. It never touches `StrokeIDCache`, never writes the `.drawing` cache, never migrates and never trashes. A damaged or legacy record returns nil. Graph greying, transclusion and export all use it.
- **Save before reading IDs:** `func flushInkAndReadIDs(_ strokes: [PKStroke], on page: Page) async -> [String]?` in +PageElements.
  - If `canvasIsDirty && canvasPageID == page.id`, it clears dirty and awaits the existing `save(canvas.drawing, to: page)` (detached, ticketed).
  - It never saves a clean canvas.
  - It then reads `StrokeIDCache.shared.map(for:).existingID`. If any id is nil, it returns nil.

### UI flow

1. **Make Node.** Lasso → **Make Node** (full toolbar and the compact More menu; paged pages only).
   - Flush and read the IDs while OCR runs (`HandwritingRecognizer.text`, already on `InkRenderQueue`).
   - Check `canvasView === canvas` again.
   - An alert opens, prefilled with `Links.nodeTitle`: first line, trimmed, at most 60 characters, otherwise "Node, p. N".
   - Make inserts the node; Cancel makes nothing. A blank field falls back to the suggestion. Undo removes the node.
2. **Badge.** A node badge sits at its anchor, with Rename, Show in Page Map and Delete Node (undoable).
3. **Insert ▸ Node…** opens `LinkDestinationPickerView` in nodes-only mode across the library. A tap places a transclusion at the visible centre, sized to the node's aspect. It can be dragged and resized. Tap gives Open Source or Remove. The whiteboard hides this item.
4. **Link This To…** gets the picker's Nodes section, which sets a link to a node.
5. **Page Map.**
   - Typed edges: explicit solid, mention dashed, transclusion double, tag dotted grey.
   - Node chips orbit their page card. Derived `#tag` nodes. Pan and zoom.
   - Filter menu (tag, folder, recency). Filtered-out cards are dimmed, not hidden, so the layout does not jump.
6. **Library map.** A Library toolbar **Map** button opens notebooks as nodes, with edges weighted by the number of cross-notebook links. Tap a notebook to open its Page Map, where cross-notebook neighbours show as ghost cards. Tapping a ghost goes through the existing `jumpToPage`.

### Transclusion rendering

- **Live overlay.** `PageBitmaps.transclusions` is a third `BitmapStore`.
  - Key: `TransclusionRequest {ownerPageID, ownerModifiedAt, ownerDrawingFileRef, strokeIDs, size}`.
  - Renderer: exactly one `InkRenderQueue.run { regionInk → PKDrawing(strokes).image(from: bounds, scale: 2.5) under the light trait }`. It renders at 2.5× to stay sharp under `scaleEffect`.
- **Thumbnails and export.** `PageElements.transclusions: [Transclusion {frame, ownerPageID, strokeIDs, ownerStamp, title}]` is drawn synchronously inside `draw(in:)`.
  - Thumbnails already run inside `InkRenderQueue.run`; export runs on main, which the gotcha allows.
  - `draw` must never call `InkRenderQueue.run` (nested on a serial queue = deadlock). Say so in a comment.
- **Invalidation.**
  - The owner stamp is in `PageElements`, so the host's `PageThumbnailRequest` hash changes when the owner changes.
  - Thumbnails get the transclusion links from the parent, which already has them. No fetch per cell.
  - The open host page re-keys only the overlay bitmap. It never reloads the canvas, so the `InkStamp` rule holds.

### Erase and placeholder behaviour

- A region is **gone** when `bounds` is nil. That state is derived and never stored, and nothing is deleted automatically (decision 3).
- Node badge and map chip go grey. A transclusion draws a dashed box with "‹title› · ink removed". A lasso link keeps its last anchor, hidden while its strokes are gone.
- Undo brings the strokes back with the same IDs (the `departed` map), and everything resolves again.
- **Anchor-follow.** After each successful `save(_:to:)` of a page that has links with `strokeIDs`, a `nonisolated static` detached function computes the bounds from the saved drawing value and the map. Back on main, it writes anchors that moved by more than 1 pt and calls `markModified` once. A nil result leaves the anchor where it is. It never runs in `canvasViewDrawingDidChange`.

### Cycle guard

- By construction: a transclusion draws only its owner's **strokes**, never the owner's elements. So no transclusion can contain another one, and mutual transclusion is finite.
- A test covers it.

### Export coverage (invariant 9)

- PDF and image export go through `PageElements.draw` (transclusion ink or the placeholder).
- Markdown gains `Nodes: a, b` and `Transcluded: title (Notebook · p. N)` per page.
- Backup and the mirror carry every `LinkDTO` field, including `title`.
- Tags are already exported. Graph positions are layout, not content.

---

## Tasks

**Run order and parallelism.**
- Tasks 1 → 9 run in order. Task 10 (layout) can run in parallel with tasks 3–6, because it touches only `NotebookGraphView`/`NotebookGraphLayout`.
- Tasks 7, 8, 13 and 14 all touch `MystNotesDetailView+PageElements.swift` and the overlay, so never run them in parallel.
- Prove fail-first runs with `xcodebuild clean test`.

**1. Link writes go through `Links.swift`. Fixes: a picked destination never syncs, and notebook or folder delete drops incoming links without syncing it**
- **Files:** `MystNotes/Links.swift` (new), `PageDeletion.swift`, `LibraryView.swift`, `MystNotesDetailView.swift`, `MystNotesTests/SyncTestHarness.swift`, `SyncTests.swift`
- **Detail:**
  - Root cause: a link change syncs only through its source page's `modifiedAt`.
  - Add `Links.setDestination(_:toPage:in:now:)`: set the field, `markModified` on the source page, save. It replaces the body of the picker callback at :445-447.
  - Add `Links.removeAll(touching: Set<UUID>, in:, now:)`, moved from PageDeletion.swift:17-31. It marks every surviving source page outside the set.
  - `PageDeletion.delete`, `LibraryView.cleanUpLinks` (:717-722) and the harness's `deleteNotebook` all call it.
- **Fails first:**
  - `testLinkDestinationPickedAfterAPush_reachesTheOtherDevice`
  - `testDeletingANotebook_removesIncomingLinksFromOtherNotebooks_onTheOtherDevice`
  - `PageDeletionTests` stays green.
- **iPad:** none (tests only).

**2. SPIKE: what erasers, Rotate Page, fittingWithinPage and synthesized strokes do to stroke identity (no app change)**
- **Files:** `MystNotesTests/StrokeIdentitySpikeTests.swift` (new), `Docs/BACKLOG.md`, `PLAN.md`
- **Detail:**
  - Simulator: does `transformed(using:)` (PageRotation.swift:79, +Persistence:99) bake the transform into the points or set `transform`?
  - Simulator: what `randomSeed` and `creationDate` do `ShapeRecognizer`, `FillTool` and `reidentified` produce, and do they collide?
  - Mac `.agenttest` with CGEvent drags (check the topmost window before every click): with Precise (.vector) and with Area (.bitmap), log per stroke: date, seed, pointCount, first and last point, mask, and the stroke count. Use a temporary `#if DEBUG` AppLog line that is not committed.
  - Also run erase → wait 2 s → undo → dump.
  - Record the findings, dated, in BACKLOG. Adjust task 3 to what the spike finds.
- **Tests:** the spike file asserts what it observed, so a future SDK change fails loudly.
- **iPad:** the Area and Precise eraser with a real Pencil goes on "Owed on the iPad". The Mac mouse result is not proof for the iPad.

**3. Stroke IDs: exact key + date/seed fallback + `departed`; synthesized strokes get unique dates**
- **Files:** `StrokeCodec.swift`, `ShapeRecognizer.swift`, `FillTool.swift`, `TutorialNotebookFactory.swift`, `StrokeCodecTests.swift`, `DurabilityTests.swift`, `SyncTests.swift`, `SimProbePagesTests.swift`
- **Detail:**
  - As in the Design section: a secondary index `(date, seed) → [UUID]`, the fallback used only for absent originals, and `departed`.
  - Update the doc comments on `encode` and on `StrokeIDMap`. The "map is exactly the drawing" contract applies to the live map only.
  - Synthesized strokes are stamped `base + i·0.001 s`.
- **Fails first (StrokeCodecTests):**
  - erase → encode → re-add → encode keeps the UUID
  - two split pieces (same date and seed, different points, original absent) both get the original UUID
  - two **live** strokes with the same date and seed keep different UUIDs
  - a mask change keeps the id (the existing test)
- **Other tests:**
  - ShapeRecognizerTests: one multi-stroke shape has distinct dates.
  - DurabilityTests `testStrokeID_survivesEraseSaveUndoSave`.
  - SyncTests `testStrokeIDs_surviveSyncInBothOrders`.
  - SimProbePagesTests:650: compare UUIDs, not only date and seed, across Rotate Page and fittingWithinPage.
  - Run the full Codec, InkFidelity, Durability and InkSelection suites.
- **iPad:** none beyond task 2.

**4. Resolver and the side-effect-free read**
- **Files:** `StrokeCodec.swift`, `DrawingStore.swift`, `StrokeCodecTests.swift`, `DurabilityTests.swift`
- **Detail:** `StrokeIDMap.indices(of:in:)`, `StrokeIDMap.bounds(of:in:map:)`, and the nonisolated `DrawingStore.regionInk(pageID:ids:)`.
- **Fails first:**
  - `testRegionInk_writesNothing_andLeavesTheCacheAlone`: the directory listing, mtimes and `StrokeIDCache` are unchanged after reading a legacy page, a damaged page and a good page.
  - indices and bounds for present, partly erased and absent ids.
- **iPad:** none.

**5. Format 5: `Link.title`, kind filters, docs comments**
- **Files:** `MystNotesModels.swift`, `SyncModels.swift`, `SyncEngine.swift`, `Links.swift`, `PageElements.swift`, `PageElementsOverlayView.swift`, `MystNotesDetailView+PageElements.swift`, `SyncTests.swift`, `SyncTestHarness.swift`
- **Detail:**
  - Add the field and map it in `buildSnapshot` (~1222) and `addChildren` (~1471).
  - `librarySnapshotFormatVersion = 5` with the dated reason.
  - Fix the "format 2" header at SyncModels.swift:9 and the `Link.kind`/`destinationID`/`strokeIDs` doc comments, per kind.
  - Apply the filter rule and the new `removeUnfinishedLinks` predicate.
  - Harness `Shape.links` also compares kind, destinationKind, destinationID, strokeIDs and title.
- **Fails first:**
  - `testLinkTitle_reachesTheOtherDevice`
  - `testLinkDTO_fromFormat4_decodesWithNilTitle`
  - `testFormatVersion_isFive_forNodeTitles`
  - `removeUnfinishedLinks` keeps a node self-link
  - `PageElements` has no anchor for a node
  - The refusal test and the rebuild test (:621) stay green.
- **iPad:** none. The real iPad, at format 2, will refuse the folder until it gets this build.

**6. Mention integrity, and [[ across notebooks**
- **Files:** `PageMentions.swift`, `MystNotesDetailView+PageElements.swift`, `PageElementsOverlayView.swift`, `PageMentionsTests.swift`
- **Detail:**
  - `addMention` stores the inserted label in `title`.
  - `PageMentions.labels(in:) -> Set<String>`.
  - On a text block save, delete that block's mention links (`destinationID == block key`) whose `title` is not in the labels. A nil-title (legacy) link is deleted only when the text has no `[[ ]]` at all. Go through `Links`, which marks the page.
  - Suggestions use a `modelContext` fetch only while `pendingQuery != nil`. The ranking is a pure `static suggestions(query:current:pages:)`: same notebook first, then "Notebook · p. N", at most 6.
- **Tests:**
  - dropping one of two tokens leaves exactly one link and bumps `modifiedAt`
  - a destination rename drops nothing
  - the ranking order
- **iPad:** typing [[ with the on-screen keyboard and with Scribble.

**7. Make Node**
- **Files:** `InkSelectionOverlay.swift`, `MystNotesDetailView.swift`, `MystNotesDetailView+PageElements.swift`, `Links.swift`, `PageElementsOverlayView.swift`, `LibraryExport.swift`, `MystNotesTests/NodeTests.swift` (new), `LibraryExportTests.swift`
- **Detail:**
  - `onMakeNode: (() -> Void)? = nil` in full and compact, passed at the paged call site (~799) only.
  - The flow from the Design section, using `flushInkAndReadIDs`. On nil, show `exportMessage` and stop.
  - `Links.makeNode` inserts, `markModified`, `saveMetadata`, registers an undo, and clears the selection.
  - A badge view in the overlay with Rename (`Links.setTitle` rejects empty input) and Delete Node (undoable).
  - Markdown `Nodes:` line.
- **Tests:**
  - `nodeTitle` is never empty
  - `setTitle` rejects empty input
  - Hosted (one `ModelContainer` per class): strokes drawn with `canvasIsDirty` and no autosave yet → `makeNode` → the ids resolve through `regionInk` to exactly the selection.
  - undo removes the node
  - SyncTests `testNode_reachesTheOtherDevice_andStillResolves`, in both orders
  - the Markdown line
- **iPad:** lasso with the Pencil → Make Node → OCR name → rename.

**8. Anchors follow their ink; Link This To records ids and can target a node**
- **Files:** `MystNotesDetailView+Persistence.swift`, `MystNotesDetailView+PageElements.swift`, `Links.swift`, `LinkDestinationPickerView.swift`, `MystNotesDetailView.swift`, `NodeTests.swift`
- **Detail:**
  - `linkSelection` uses `flushInkAndReadIDs`.
  - Anchor-follow as in the Design section, with `markModified` after the write.
  - The picker gets a Nodes section (every `kind == "node"` link in the library, greyed when gone). The callback becomes `(pageID, nodeID?)` and goes through `Links.setDestination(_:toNode:)`.
  - `PageRotation`'s anchor move stays as the fallback for links without `strokeIDs`.
- **Tests:**
  - after a lasso move and save, the anchor equals the new bounds
  - after an erase, the anchor is unchanged and the bounds are nil
  - the follow helper runs off the main thread (thread-observing test)
  - a link to a node fills all three fields and marks the source page
  - SyncTests: a link to a node round-trips
- **iPad:** lasso-move linked ink with the Pencil, and check the anchor follows after an autosave.

**9. Ink transclusion (render + UI + export)**
- **Files:** `PageElements.swift`, `PageElementsOverlayView.swift`, `BitmapStore.swift`, `PageThumbnailView.swift`, `LibraryCells.swift`, `LinkDestinationPickerView.swift`, `DrawingToolbarView.swift`, `MystNotesDetailView.swift`, `MystNotesDetailView+PageElements.swift`, `Links.swift`, `LibraryExport.swift`, `PageElementsExportTests.swift`, `SyncTests.swift`, `SimProbeElementsTests.swift`
- **Detail:** everything under "Transclusion rendering" in the Design section, plus:
  - Insert ▸ Node…
  - `Links.addTransclusion`, which marks the host
  - drag and resize as a frame (divided by zoom)
  - Open Source → `jumpToPage`
  - Remove (undoable)
  - the placeholder
  - the Markdown `Transcluded:` line
- **Tests:**
  - an image export contains the owner's ink pixels inside the frame, and the placeholder after the owner's strokes are erased
  - the host `PageThumbnailRequest` hash changes when the owner's `modifiedAt` changes
  - mutual transclusion renders both thumbnails in finite time
  - SyncTests: a transclusion syncs pushed before **and** after its node, and resolves in both orders; deleting the owner page removes it on B
  - a hosted probe PNG
- **iPad:** a live update when the owner is edited on the same device and after a pull; sharpness at maximum zoom.

**10. Page Map: force layout, fixed world, pan and zoom**
- **Files:** `NotebookGraphView.swift`, `NotebookGraphLayout.swift`, `NotebookGraphTests.swift`
- **Detail:**
  - Deterministic Fruchterman-Reingold, 200 iterations, seeded from today's ellipse, applied only to cards with no saved position. Add `ponytail: O(n²), Barnes-Hut above ~500`.
  - A 2000² world; saved fractions are fractions of the world.
  - `@State scale/offset`, `MagnifyGesture` plus a background `DragGesture`, fit-to-view at start.
  - A card drag divides by `scale` and saves on `onEnded` with the final translation (fixes the one-frame lag).
- **Tests:**
  - the layout is deterministic
  - linked pairs end up closer than unlinked pairs
  - the same world point at two sheet sizes
  - the drag maths at scale 2
  - `testPageMapPositions_sync…` stays green
- **iPad:** two-finger pinch and pan versus dragging a card.

**11. Page Map: kinds, node chips, greying, tag nodes, filters**
- **Files:** `NotebookGraphView.swift`, `MystNotes/GraphFilter.swift` (new), `MystNotesDetailView.swift`, `NotebookGraphTests.swift`
- **Detail:**
  - `edges()` returns `(from, to, kind)`. A link to a node targets the node chip.
  - Greying is computed in a `.task` keyed on the owners' `modifiedAt`, through a detached `regionInk` call.
  - Tag nodes come from `PageTags`, and their positions are not saved.
  - `GraphFilter {tags, folderID, since}` is a pure `apply`. It dims to 0.15 and drops edges, and is view state only.
  - Node chip menu: Rename / Delete through `Links`.
- **Tests:**
  - the edge kind for each link shape
  - a tag node is derived and the Link count is unchanged
  - greyed when no id resolves; not greyed when one piece remains
  - `GraphFilter` for each criterion and combined; an empty filter keeps everything
- **iPad:** none beyond task 10.

**12. Library map**
- **Files:** `MystNotes/LibraryGraphView.swift` (new), `LibraryView.swift`, `NotebookGraphView.swift`, `MystNotesDetailView.swift`, `NotebookGraphTests.swift`
- **Detail:**
  - Notebooks as nodes, with edges weighted by the number of cross-notebook links.
  - It reuses the task 10 layout (not saved; `ponytail: persist if asked`) and the task 11 filter.
  - Tap a notebook → `NotebookGraphView`, which stops dropping cross-notebook links (:24-25) and shows ghost cards. A ghost tap goes to `onSelect` → `jumpToPage`.
  - A toolbar **Map** button in the library.
- **Tests:**
  - the aggregation counts, with links inside one notebook excluded
  - a ghost for a cross-notebook link
  - a hosted PNG
  - a ghost tap calls `onSelect` with the foreign page id
- **iPad:** the exit test, walking a semester's notebooks without opening a folder.

**13. Linked from: cap at 5 + "and N more"**
- **Files:** `LinkedFromStrip.swift`, `LinkedFromTests.swift`
- **Detail:** a pure `split(_:limit:)`; the overflow goes in a `Menu`.
- **Tests:** 3, 5 and 9 sources.
- **iPad:** none.

**14. Drawable map: decision gate (no code)**
- **Files:** `Docs/BACKLOG.md`
- **Detail:** record two options and ask the user. Recommend deferring until after M3.
  - Option (a): a hidden `Page` with `type = "map"`. It inherits merge, trash and export, but needs an audit of 57 `.pages` sites.
  - Option (b): a notebook-level `.strokes` record. It needs a new payload type and a DTO field.

**15. Docs catch-up**
- **Files:** `Docs/SPEC_DOCUMENT_FORMAT.md`, `Docs/BACKLOG.md`, `PLAN.md`
- **Detail:**
  - SPEC: format 5 and its history; the Link kinds and title; nodes are derived; dangling links are hidden; a gone region shows a placeholder; a newer format is refused; unknown keys are dropped; the stroke key is exact-then-date+seed; split pieces share one UUID.
  - BACKLOG: links on a page that loses a same-page conflict are lost with that page; a transclusion is briefly stale when `modifiedAt` arrives before `.strokes`; copied pages do not carry nodes; `NotebookDTO`/tombstone `formatVersion` are never checked.
  - Propose the invariant-6 wording ("exact match, then date+seed for a stroke whose original is gone") to the user. Do not edit CLAUDE.md.
- **Check:** grep that "format version 1" and "format 2" are gone.

**16. Device check (`.agenttest` only)**
- **Files:** `MystNotesTests/SimProbeM2Tests.swift`, `PLAN.md`
- **Detail:**
  - Use `MYST_ID_SUFFIX=.agenttest` on the iPad and the Mac. The probe asserts its bundle id ends in `.agenttest`.
  - Sync only through a scratch folder, never the user's.
  - Flow: Make Node → rename → map → Insert ▸ Node on another page → erase the source (placeholder and grey) → undo → library map → [[ across notebooks.
  - Tag each item [iPad], [Mac] or [tests only].
  - The Pencil checks (eraser identity, Make Node by hand) go on "Owed on the iPad".
  - Remind the user that the real iPad app is at format 2.

**Remaining risks:**
- If the spike shows that the Area eraser gives pieces new dates or seeds, those pieces lose their ids. The node then shrinks or greys early. That is not ink loss.
- Format 5 locks out every older device until it gets this build.