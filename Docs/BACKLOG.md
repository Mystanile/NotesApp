# BACKLOG

Anything noticed mid-milestone that isn't in the current task lands here instead of in the code. Review at each milestone boundary.

## Format: `[M?] item — why it matters`

---

## Found during the code read (Sept 12, 2026)

- [M1, from M0] `MystNotesDetailView` is 1365 lines. Not urgent, but it will fight you during M2/M3. Split it as its own commit when it starts hurting, not as a side effect.
- [M1] `copyFiles` is best-effort and silently skips a file that hasn't synced yet. Surface that as a visible "N files still downloading" state rather than a silent partial pull.
- [M1] Export currently covers page and notebook. Add whole-library export as the trust feature.
- [M2] `Link` has an anchor rect already — reuse it for graph edge anchors rather than inventing a second anchoring model
- [M3] `Page.ocrUpdatedAt` vs drawing file mtime is the existing staleness check. The stroke timeline gives a better signal; revisit then.
- [?] `LoginView` exists but there's no backend. Decide whether it stays, becomes a local profile, or gets removed before ship.

## Found while building the sync harness (Sept 12, 2026)

- [M1, from M0] A notebook whose `notebooks/<id>.json` never arrives (deleted by hand, lost by the provider) stays pending forever on the puller: its settings show, its pages don't, and the puller never publishes its own copy of it. Needs a designed state ("waiting for 1 notebook") and eventually a way out. Fits task 8/13.
- [M1] `buildSnapshot` fetches and encodes every page on every sync (twice: post-merge check and push). 0.37 s at 2,000 pages, linear in page count. Fine until it isn't; the per-notebook content signature makes an incremental snapshot possible when it's needed.
- ~~[M0]~~ **Done in task 11:** pruning keeps anything any notebook file references, plus `orphanGracePeriod`. Superseded payload versions accumulate in `files/` by design (content addressing never overwrites). Task 11's pruning must keep anything referenced by *any* notebook file present in the folder, plus a grace period, so a notebook file that hasn't arrived yet can't lose its ink.
- ~~[M0] **Decision needed: trash retention.**~~ **Decided and done Sept 18, 2026: 30 days.** `TrashRetention` sweeps the sync folder's `files/trash/` and `notebooks/trash/` inside a sync run while the folder is held, and the local `trash/` directories at launch off the main thread. The age comes from the millisecond stamp in the filename, not the file's modification date, which a sync provider rewrites on download. The sweep refuses any directory not named `trash`. Settings gains a Trash section: item count, size, age of the oldest, and an explicit Empty Trash Now. 14 tests (`TrashRetentionTests`, plus two end-to-end through a sync run). **Not done: Restore.** Getting a specific page back out of the trash is a real feature with a real UI and it is M1 — today the recovery path is Finder/Files, which is what the folder-is-the-source-of-truth invariant buys.
- [M1, from M0] Local `Documents/` orphans (a payload no `Page` references, e.g. from before task 11) aren't pruned; only the folder is. Add a local pass with the same grace rule once task 19's rebuild path exists, since that's when "what does the index reference" becomes authoritative. **Still open after the Sept 18 retention work** — that added the sweep that empties `trash/`, not the pass that puts local orphans *into* it. The dangerous half is this one: it needs "what does the index reference", and an index that is empty or mid-rebuild would make every payload look unreferenced. Guard on a non-empty fetch plus the same grace period, and it is recoverable for 30 days either way.
- ~~[M0]~~ **Done in task 6:** snapshots carry `formatVersion`. A build from before task 5 can't decode a snapshot containing a `kind: "page"` tombstone (enum decode fails, whole `library.json` rejected). Only matters while a pre-task-5 build is still installed anywhere; the format split in task 6 should carry a real version gate.
- [M1, from M0] `pushPayloads` replaces the folder's copy of a drawing file in place when the local page won. Folder-side history of superseded versions is task 7/11 territory; the loser device keeps its own copy in its local `trash/`.
- [M1, from M0, check whether task 16b closed it] `LibrarySnapshot.referencedFileNames` derives from `drawingFileRef`, so a page whose file was written but whose `context.save()` never ran (kill between the two) has ink on disk that never syncs. Derive the drawing file name from `page.id` instead; the ref is redundant with the id. Fold into task 6/10.

## Open on the morning of Sept 13, 2026 (M0 closed Sept 25, 2026; leftovers carried to M1)

- ~~[M0]~~ **Closed Sept 25, 2026:** the user confirmed on the iPad that M0 works. **One launch-time main-thread hang remains on the iPad**, 6–8 s, consistent, not reproducible in the simulator (200 ms launch against the same library). Timing: main stops answering ~1 s after launch and resumes within 20 ms of the first background sync run finishing — it is waiting on something the run holds for its whole duration: security-scoped access to the iCloud folder, or the runner's second SwiftData context on the shared store. The build on the iPad (`a4d585b`) captures the main thread's real stack on the next hang (`[hang] main thread stack:` in `Documents/diagnostics/app.log`, readable from the Mac via `devicectl device copy from`). Read it, then either release folder access per phase or keep the runner's SwiftData work to short windows.
- [M1, from M0] **Two ~1 s main-thread stalls under `DetailView.saveCurrentPage` on the iPad** (Sept 19, 20:52 and 21:10 UTC), neither explained: the checkpoint is where the stall *started*, and everything after it that runs on main is `page.markModified()`, `modelContext.save()` and the SwiftUI re-render they trigger. Since Sept 21, 2026 a stall past 400 ms logs the main thread's stack, not just the checkpoint. Read the next `[stall] main thread stack:` before touching the save path. (The four Sept 21 crash payloads were the orphaned-artwork trap, fixed the same day; a colour change has never stalled past 400 ms in either device's log.)
- [M1, from M0] `Write Sync Diagnostics` names the device by `UIDevice.name` ("iPad"), unlike sync's install-id naming. Cosmetic; align.
- ~~[M0]~~ **Closed Sept 25, 2026:** the user confirmed on the iPad that M0 works. The spike checklist §3 (clean offline round: `X` on page 3 from the iPad, `O` on page 2 from the Mac) has still not been run on a build free of both the old-build saves and the launch hangs. `a4d585b` is that build. Wait 20 s after launch before going offline.

## Reported during the first two-device run (Sept 12, 2026)

- [M1] Pen on Mac: reported as not usable. Strokes *were* drawn on the Mac in the same session, so this is a specific tool or input path. Reproduce first. See PROJECT_PLAN M5 note.
- ~~[M1] Typed text blocks: no font, size, bold/italic, colour controls - only typing and moving.~~ **Done Sept 15, 2026**: font design (system/serif/rounded/mono), size, bold, italic, colour, and a corner resize handle; typography syncs (`TextBlockDTO` optionals, `testTextBlockTypography_reachesTheOtherDevice_andOldSnapshotsStillDecode`) and exports (`PageRenderer.drawTextBlocks`).
- [M1] Page thumbnails don't composite typed text blocks (export does, since Sept 15). At 60×80 it hardly shows. **Thumbnails got their real cache Sept 18 (`PageBitmaps.thumbnails`), so the reason to wait is gone** — add it to `PageThumbnailRenderer.render` next to the artwork draw.
- [M1] Stickers and link anchors aren't drawn in exports either (invariant 9). Same shape as `PageRenderer.drawTextBlocks`.
- [M1] Stickers: no resize or rotate - only move.
- ~~[M0, open] iPad freezes on entering Airplane Mode~~ **Closed Sept 13, 2026, verified on device** ("didn't freeze"; log shows every sync run and the watcher setup on the background thread). It was never Airplane Mode: four successive launch-time main-thread hangs, 6–8 s each, in sync setup — the runner, `startWatchingFolder`, the `start` closure capturing `self`, the watcher closure capturing a `@MainActor` callback — each hit while the test was starting. Root cause for all four: default MainActor isolation making `Task.detached` closures main-actor whenever they capture anything main-actor-typed. Rule and test in CLAUDE.md. One launch hang remains with checkpoint "(none)" — before sync starts; launch-path checkpoints added and thumbnails moved off main to find/fix it.
- ~~[M1] `FillTool` computes its flood fill in a `Task.detached` formed inside a main-actor view, so under default MainActor isolation it runs on the main thread. A hitch on large fills, same species as the sync engine bug; move the computation into a `nonisolated` static.~~ **Not so, measured Sept 25, 2026:** `FillToolTests` logs the flood on a background thread, not on main.
- [M1] PencilKit crash in undo on the whiteboard canvas (`-[PKTiledView updateTilesForVisibleRect…]` under `WhiteboardCanvasView` undo, Sept 10 crash log). Reproduce: draw on a whiteboard, undo via the shortcut. Likely undoing across a canvas swap.


## Found while fixing images and shapes (Sept 18, 2026)

- [M1] **`PageViewportLayer` hides everything until the viewport syncs.** `.opacity(viewport.hasSynced ? 1 : 0)` covers the paper, the artwork, the text blocks and the link anchors, and it is cleared only by the canvas publishing a fitted viewport for the *incoming* page. Every path I traced ends in `setNeedsLayout`, so it should always land — but it is the second candidate for "images disappear on a page turn until you move around" (`TOOL_FIXES.md` §3.2) and it has no fallback. If that symptom survives the `BitmapStore` fix on the iPad, this is the cause; the fix is to stop hiding a whole layer on a signal with no timeout.
- ~~[M1] Imported artwork is still **one background per page**~~ done Sept 19, 2026 — `ImportedDocument.stackOrder`, any number per page, PDF under and photos over (`TOOL_FIXES.md` §3.5). Artwork *in front of* ink is still not a thing: the stack sits under the canvas.
- ~~[M1] `removeImage(from:)` … leaves the payload on disk.~~ Trashed now if nothing else references it (Sept 19, 2026).
- [M1] Dashed and dotted only exist for *snapped* shapes, because a freehand stroke's dashes would have to be recomputed on every sample as it grows. If dashed freehand is ever wanted, it is a post-processing pass at stroke commit, not a change to the live path.
- ~~[M1] `ShapeLineStyle` is session state~~ **Done Sept 25, 2026:** remembered in `AppSettings.shapeLineStyle`. on `DrawingToolState`, not persisted in `AppSettings` like the pen's ink type, colour and width. One line each way; do it with the next `AppSettings` change rather than on its own.
- [M1] **Every `toolState` change re-evaluates the whole of `NotebookDetailView`** — 1,500 lines, including the toolbar the colour popover is presented from. The certain costs on that path are fixed (Sept 18), but if the stall log still points at `applyToolState`, the fix is to make `DrawingToolState` `@Observable` and read it from a small child view, so picking a colour invalidates the toolbar and nothing else. Don't do it on a hunch: read the `[stall]` lines first.
- [M1] `ScribbleErase.isScribble` runs on the main thread on every stroke commit, interpolating the whole stroke at 4pt spacing. Small, but it is on the drawing path and belongs off it with everything else.
- [M2] `BitmapStore` is the shape the graph canvas will want for node previews too — bounded, keyed by a value, `@Observable`, renderer injected. Don't write a third one.

## Found while building the lasso (Sept 19, 2026)

- [M1] **Needs the iPad:** the lasso's Pencil loop is read by a touch observer on the canvas host with PencilKit's drawing gesture disabled (`InkLassoRecognizer`). Same open question as the shape tool's hold: does the host's recognizer receive the Pencil on real hardware? And a second one specific to this: with the drawing gesture off, does the Pencil *pan* the canvas's scroll view under `.pencilOnly`? If it does, the fix is `canvas.panGestureRecognizer.allowedTouchTypes = [.direct]` while the lasso is active. Neither can be answered on the simulator or a Mac.
- [M1] The whiteboard keeps PencilKit's `PKLassoTool` — `WhiteboardCanvasView` has its own host and the selection controller isn't installed on it. Select-and-move works there; pinch-resize doesn't. Installing it is the same three lines `PencilCanvasView` uses, plus the overlay.
- [M1] Corner handles on the selection box, for a Mac where there's no pinch. The box is already drawn from four corners; the handles are `ImageAdjustOverlay`'s, and the controller's `scale(by:)` is the only call they need.
- ~~[M1] The image long-press (`onLongPress`) still fires~~ **Done Sept 25, 2026:** no image handles while the lasso is the tool. while a Pencil loop is being drawn, if the Pencil rests for 0.6 s mid-loop with artwork on the page. It did with `PKLassoTool` too. Gate it on `inkSelection.display.lasso.isEmpty`.
- [M1] Every gesture step sets `canvas.drawing` with all strokes, so PencilKit re-lays the whole page per frame. Fine on a notes page; a page with thousands of strokes may stutter under a pinch. If it does, the fix is to render the *unselected* strokes once to a bitmap for the gesture's duration and only re-set the selected ones — never to remove them from the canvas (invariant 1).

## Found while fixing the fill tool (Sept 25, 2026)

- [M1] Pages where the old fill tool was tried hold hundreds of invisible sub-2pt strokes per tap (one test page had 1,356 before its first logged tap). They are harmless to see, but they bloat the record and sync. A cleanup would be deleting ink, so it needs its own decision: detect by the old fill's exact signature (`.pen`, four points on one horizontal line, size < 2) and move them to `trash/` as a normal edit, never drop them silently.
- [M1] Filling an already filled region does nothing now, because the fill is ink. Recolouring a fill (tap with another colour) would need the fill's strokes to be recognisable as one fill, a group id in the neutral format. Not now.

## Found while making PDFs sharp (Sept 25, 2026)

- [M1] Select, copy and highlight an imported PDF's text. Left out of M1 task 2 on purpose: it needs its own gesture on a page where the Pencil inks and the lasso selects, so it's a design question first. `PDFPage.selection(from:to:)` gives the text; the page space is already shared with the ink.
- [M1] Exported ink is still a 2x bitmap on top of the vector PDF. PencilKit has no vector output; a stroke-to-path renderer from the neutral format would give one, and is the M7 web renderer's first half anyway.
- [M1] `SearchIndex.pdfTextCache` is an unbounded static dictionary read on every keystroke, with no lock. Fine at today's sizes; bound it and move extraction off the main thread when PDFs get big.

## Found while fixing the artwork handles (Sept 25, 2026)

- [M1] **Resize preview, open:** the report (drag a corner, the picture doesn't follow until a page turn) doesn't reproduce in a hosted window, through `ImportedPageBackgroundView` or `PageViewportLayer`, during the drag or after Done (`ArtworkEditingTests`). `[adjust]` lines in `app.log` from one resize on the iPad say where it goes wrong; remove them after.
- [M1] Undo lives on the page's canvas, so a page turn drops it - for ink as it always has, and now for artwork edits, Rotate Page and Delete Page too. A notebook-level undo stack would keep them; it is a bigger change to how the canvas's undo is owned.
- [M1] Text blocks, stickers and link anchors keep their size when a page rotates while the ink scales with the page (by 1/aspect). Scaling them too is one more multiply each, if it looks wrong in use.
- [M1] Two background ink saves of one page aren't ordered (`saveDetached` tasks), so an older one can land last. Pre-existing; Rotate Page saves blocking but can't stop an older detached save still in flight. A per-page serial queue in `DrawingStore` would close it.

## Parked from planning (Sept 12, 2026)

- [M1] Scanned document capture with `VisionKit` + Live Text — Apple Notes parity, cheap
- [M1] Collapsible sections, tables, checklists in typed content
- [M2] Graph clustering / level-of-detail rendering — only needed above ~1000 nodes, benchmark first
- [M2] Auto-suggested links from semantic similarity — depends on M4 embeddings, so sequence after
- [M3] Multi-track audio (mic + system audio for recorded calls)
- [M4] 3D graphing of equations — Apple Notes shipped this in iOS 26
- [M5] Quick Note-style system-wide capture
- ~~[M5] Drag and drop between MystNotes and other apps on Mac~~ **Inbound done Sept 18, 2026** (images and PDFs dragged onto a page, plus ⌘V and a Files importer). Outbound — dragging a page or a lasso selection *out* — is still open, and still M5.
- [M6] Localization beyond English
- [M7] `automerge-swift` evaluation for multi-device CRDT sync
- [M7] Read-only web share links backed by the neutral stroke renderer
- [?] Template gallery / community templates — non-goal for v1, revisit only with real user demand
- [?] Handwriting style transfer / beautification — fun, no evidence anyone wants it
- [?] Apple Watch quick capture — almost certainly not worth it

---

## Deliberately rejected

Keep these here so they don't get re-proposed.

- Real-time collaborative editing in v1 — needs a backend and CRDTs, M7 at the earliest
- Network AI chat with notes — per-query cost a free app can't absorb; on-device semantic search covers most of the value
- Native Android / Windows clients — the web viewer is the cheap reach
- Any paywall or StoreKit work — app is free
