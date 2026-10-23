# MystNotes: build plan

A fresh session continues from this file. Read the Handoff section first, then Status. The milestone detail and exit criteria are in `Docs/PROJECT_PLAN.md`. Work that is not in the current task goes in `Docs/BACKLOG.md`.

Every item ends with how it was checked:

- [iPad]: someone used or measured it on the physical iPad.
- [Mac]: it was checked in the Mac app (the `.agenttest` copy).
- [tests only]: automated tests pass, but nobody used it on a device.
- [not tested]: no test and no device check.

## Handoff: start here (2026-10-22, evening)

Branch and build:

- Work on `m2-graph`. It has every change from `m1-batch-2026-09-25` plus the M2 work. The last M1 commit `9f9b4b2` came in as the cherry-pick `1978a07`, so git still lists `m1-batch-2026-09-25` as not merged. Neither branch is merged into `main` (last commit `3ab3810`, Sept 25).
- The last full test run passed: 276 tests, 1 skipped, 0 failures, on Oct 22 (`.claude/last-test.log`), with the save-order fix.
- M2 raises the sync format to 3, and smart folders (Oct 22) to 4. A device on an older build refuses the folder. Install the same build on the iPad and the Mac before you sync.
- A full copy of the iPad's data is in `~/Desktop/MystNotes-iPad-backup-2026-10-10/` (289 MB).
- The iPad runs an M1 build (sync format 2) from `m1-batch-2026-09-25` at `d6c7a0e`. It was built at 12:46 on Oct 10 (reflog and `.claude/real-build.log`) and launched at 12:47 (16:47 UTC in the iPad log). No M2 feature was used on the iPad.
- After a device on the M2 build syncs, the iPad refuses the folder until it also gets the M2 build.

Next, for the user to choose:

1. The iPad pass: the "Owed on the iPad before M1 exits" list under Status, the M2 features with the Pencil, and the notebook covers in dark mode.
2. Merge `m2-graph` into `main` after that pass.
3. The rest of M2: a lasso action that turns ink into a node. It needs a design first: what a node is beyond a page in the Page Map. Ink transclusion waits for the conditions in `Docs/BACKLOG.md` ("Transclusion waits for").
4. Shape tool on the Pencil: one undo after a snap should leave the page as before the stroke (decided Oct 22). If PencilKit's own stroke undo lands in a separate group, there is one extra undo step with no visible change. The object eraser removes a dashed shape one dash at a time, as decided.

Still open from the Oct 22 bug hunt (small, not fixed):
- Convert to Text: if you move the selection while it is recognising, the text box lands where the ink was before the move.
- If PencilKit's stroke undo lands in its own undo group, one extra undo after a snap changes nothing.

Open bugs:

- Launch hang of 6 to 8 s on the iPad, last reported around Sept 25. It waited on the first sync run. None of the 7 launches logged from Oct 7 to Oct 10 hung. If it comes back, read its `[hang] main thread stack:` line. [iPad]
- Two stalls of about 1 s under `saveCurrentPage` (Sept 19). The cause is not known. The Oct 7 ones were the share sheet. [iPad]
- Trash loop: it stopped on the newer build, but the cause is not proven. 278 MB sits in the sync folder's trash. [iPad]
- A notebook whose `notebooks/<id>.json` never arrives stays pending forever. It has no way out yet. [tests only]
- `PageViewportLayer` hides the page until the viewport syncs, with no timeout. It is a candidate cause if images still vanish on a page turn. [not tested]

## Status

### M1, Parity Floor: done except the iPad checks

- [x] Fill tool. [iPad]
- [x] Real PDF annotation: PDF pages are sharp at every zoom. [tests only]
- [x] The rest of the Sept 25 batch: lasso actions, templates, favourites and outline, stickers, pen on Mac, exports, note lock, backup, scanning. [tests only]. Pen on Mac: [Mac]
- [x] Blank pages and thumbnails fixed: off-screen ink renders on one serial queue (`70c97e6`). [iPad]
- [x] Squeeze, page swipe and the freeze (`d7c7a3a`). [tests only]
- [x] A failed move to the trash is logged and reported (`44371ad`). [tests only]. No move failed on the iPad, so this path never ran there.
- [x] The Oct 7 "save" hangs were the share sheet. No code change was needed (`2817d90`). [iPad]
- [x] Fixed a lost save: two first saves of a new page at once made the second fail (`34cfc2c`). [tests only]
- [x] Sync says what is still downloading (`eef81a3`). [tests only]
- [x] Whiteboards use our lasso (`b91461b`). [tests only]
- [x] `MystNotesDetailView.swift` split into 7 files, with no change in behavior. [tests only]
- [x] An older background save of a page can no longer overwrite newer ink. Each save takes a ticket when it is asked for, and a load cannot put an older record's stroke ids over a newer save's (Oct 22). [tests only]

- [x] Imported PDF and image pages go in after the page you are on, not at the end (Oct 22). [tests only]
- [x] Import from the library: "Import PDF or Image" in the + menu makes a notebook named after the file, several files at once. Dropping a PDF or image on the library does the same. "Open in Mystnotes" from Files or another app's share sheet. Notebook Import > From Files takes several files (Oct 22). [tests only] for the notebook from a file. Not tried: the picker, the drop and Open In on a device.

- [x] Shape tool fixes (Oct 22): the eraser and lasso no longer snap; a snap only replaces the held stroke, never one added by an undo or paste; size limits follow the zoom; snapped pencil strokes keep their tilt and opacity; whiteboards show the snap preview; tilted ellipses snap as themselves. [tests only] for the recognizer. Not tried with the Pencil.

- [x] Zoom fixes (Oct 22): text boxes, stickers, PDF and lasso layers no longer stay off the ink after a layout pass during a pinch (the queued viewport update read old values). Imported PDFs stay sharp at full zoom on a 13" iPad. A zoomed whiteboard keeps its whole board reachable after a tool or colour change (the update reset its scrollable size to 3000 at any zoom), and zoomed out it fills the view. The whiteboard fix has a hosted test. [not tested] on a device, no test covers either.

- [x] Empty library shows New Notebook and Import PDF or Image buttons (Oct 22). [not tested]

- [x] Bug-hunt fixes (Oct 22): exports and Copy Pages wait for the open page's save, so they never take the previous ink; copied pages keep their tags; whole-library export keeps notebooks whose titles differ only in case; import, reorder and new pages first finish a pending Delete Page, so no two pages share an index; "Linked from" hides a page being deleted. [tests only] for the export name clash.

- [x] Text box fixes (Oct 22): deleting a text box is undoable and undo brings back its formatting and `[[` mentions; its mentions go with it, so "Linked from" and the Page Map stop showing them; new text boxes and stickers land in the middle of the screen and never exactly on another one; cancelling a link's destination picker removes the unfinished link. [tests only] for placement and the snapshot. Not tried: undo and Cancel on a device.

- [x] Lasso fixes (Oct 22): a rotated selection keeps its rotation on the next drag; undoing a paste or duplicate clears the empty selection box, and undoing a move puts the box back on the ink; Paste lights up straight after Copy; repeated pastes step apart, and a paste that would land off screen comes to the middle of it. [tests only] for rotation, undo and paste placement.

- [x] Search and Markdown (Oct 22): the handwriting indexing pass stops when the search screen closes and skips pages deleted mid-pass; results refresh when pages come or go; Markdown export (one notebook or the library) reads handwriting on pages search never indexed. [not tested] by a test of its own; the suite passes.

- [x] Editing a text box: a drag in the text selects it instead of moving the box; a move handle at the top right moves it (Oct 22). [not tested] on a device.

### Owed on the iPad before M1 exits

All of these are [not tested]. None of them can be checked in the simulator.

- [ ] The `[adjust]` log from one image resize.
- [ ] Sticker pinch and rotate.
- [ ] Lasso corner handles and the lasso toolbar, on the iPad and the Mac.
- [ ] Convert to Text on real handwriting.
- [ ] Rotate Page, and Delete Page undo.
- [ ] Note lock with Face ID.
- [ ] Scanning with the real camera.
- [ ] A backup to a real Dropbox or Drive folder.
- [ ] Imported PDF pages zoomed to 5x stay sharp.
- [ ] The Pencil lasso on a zoomed whiteboard.
- [ ] The Pencil lasso on a normal page: the host recognizer gets the Pencil, and the Pencil does not pan the canvas.
- [ ] The shape hold-to-snap recognizer gets the Pencil touch during a PencilKit stroke.
- [ ] Notebook covers in dark mode.

### M2, The Graph: started on `m2-graph`

- [x] Links are graph edges: kind, destination and stroke IDs. Sync format 3 (`5d6011b`). [tests only]
- [x] "Linked from" box on each page. It fetches only the linking pages (`8093c65`, `440e207`). [tests only]
- [x] Lasso, then "Link This To…" (`6f55691`). [tests only]
- [x] Page Map with cards you can drag. Positions sync as a notebook setting (`a873c6d`, `6ce299c`). [tests only]
- [x] Deleting a page removes links to it on every device (`5dfa0c2`). [tests only]
- [x] Page tags, a Tags row in the library, and tags in the Markdown export (`32976e7`, `3deaa09`, `f05eb7e`). [tests only]
- [x] Type `[[` in a text box to mention another page (`d422f65`). [tests only]
- [x] Links between notebooks (`855237e`). [tests only]
- [x] Notebook covers with a spine, a title label and page edges (`c60306c`). [tests only], light mode only
- [x] A photo button on the drawing toolbar (`8e5c0bc`). [not tested], no test of its own
- [x] Smart folders: + menu, New Smart Folder. A folder with a saved search shows every matching page (typed text, handwriting, PDF text, now tags). The search syncs. Edit Search in the folder's menu (Oct 22). [tests only] for sync.
- [ ] A lasso action that turns ink into a node.
- [ ] Ink transclusion. It is not started on purpose.

## Earlier state, moved from CLAUDE.md on 2026-10-22

The sections below are copied word for word from `CLAUDE.md`. Only the headings are marked as archived. They describe the app as of Oct 10, 2026. The Handoff and Status above replace them, including the shorter "Owed on the iPad" paragraph at the end.

### Current state as of Oct 10, 2026 (archived)

**~16,900 lines of Swift in 66 app files, plus ~6,300 lines of tests in 30 files (231 tests, all green). All earlier branches merged into `main` on Sept 25, 2026. The M1 batch of Sept 25 sits unmerged on `m1-batch-2026-09-25` (on top of `m1-artwork-editing`), waiting for a pass on the iPad. Far more is built than a phase list suggests.**

Already working, don't rebuild: custom PencilKit toolbar with 5 ink types and per-tool color/width memory, highlighter, vector and bitmap erasers, our own lasso (move, pinch-resize, rotate, cut/copy/paste/duplicate — `InkSelection`, Sept 19, 2026; the whiteboard still has PencilKit's), shape recognition (hold-to-snap, solid/dashed/dotted), fill/bucket tool, per-page canvas with real zoom, PDF and image import from Photos / Files / ⌘V / drag with crop/rotate/resize (any number per page, stacked — Sept 19, 2026), nested folders, notebook covers, thumbnail strip, four templates (drawn under imported artwork, and in thumbnails and exports), whiteboard page type, multi-window, presentation mode, Vision OCR handwriting search with tap-through results, page and notebook export, onboarding, login, settings, tutorial notebook, and folder-based sync. Added Sept 25, 2026 (`m1-batch-2026-09-25`): the mouse draws on a Mac, stickers resize/rotate, stickers/links/text in exports and thumbnails with working PDF links, lasso recolour/copy-as-image/convert-to-text, Engineering and Cornell paper, page sizes, favourites/bookmarks/page names/outline, Markdown and whole-library export, note lock, document scanning, pen presets, text-box lists, lasso corner handles, toolbar choices, daily backup, trash restore, New Page Like This.

**Oct 10, 2026 (autonomous day, `Docs/CHANGES_2026-10-10.md`):** M1 is done except for the checks on the iPad. M2 has started on `m2-graph` with your approval: links are graph edges (sync format 3), there is a "Linked from" box, lasso "Link This To…", a Page Map with draggable cards (`Notebook.graphLayout`), page tags (`Page.tags`, `PageTags`), `[[` mentions in text boxes (`Link.kind == "mention"`, no tap anchor), and link cleanup when a page is deleted. `MystNotesDetailView.swift` is split into `MystNotesDetailView+*.swift`.

**~~One shipped tool is broken (M1).~~ Both are fixed.** ~~The shape tool~~ — rebuilt Sept 15, 2026 and given a second pass Sept 18 after field use: the hold timer was scheduled in the default run-loop mode, which never fires while a pencil is down (`.common` now, plus an elapsed-time check in `touchesMoved`); a line with a hook on the end came back as an arrow; snapped shapes were drawn at the tool's heaviest possible mark instead of the weight of the stroke they replace; lines didn't snap to the axes; there were no dashed or dotted shapes. All fixed, 29 tests. Still owed on the iPad: that the host's recognizer receives the Pencil touch during a PencilKit stroke. ~~The fill tool~~ fixed Sept 25, 2026 after logging on the iPad showed the coordinates were right all along: its strokes were too thin for PencilKit to draw (`TOOL_FIXES.md` Part 2). Full diagnosis and acceptance criteria in `Docs/TOOL_FIXES.md` — part 4 is the lasso rebuild (Sept 19), part 3 covers the imported-image bugs fixed Sept 18 (a photo import wiped the page template; artwork vanished on page turns; no Files/paste/drag import on a Mac).

**Three things blocked shipping. All three are closed (M0, done Sept 25, 2026).**

1. ~~**`SyncEngine` can silently destroy a page.**~~ **Fixed (M0 tasks 4–5, Sept 12, 2026).** Merge is now per page on `Page.modifiedAt`; `rebuild()` is gone; pages update in place; a same-page conflict keeps the loser's ink in `trash/`; page deletions travel as `.page` tombstones and an edit newer than the deletion wins. `SyncTests` pins all of it, including the §1.2 scenario in both orders.
2. ~~**`library.json` holds the entire library in one file**~~ **Closed (M0 tasks 6–15, Sept 12, 2026).** Split into `index.json` + `notebooks/<uuid>.json` with partial push/pull, index history, `tombstones.json`, content-addressed payloads, trash-not-delete, debounced push, folder watching, non-blocking downloads, one storage root — and iCloud conflict versions read and merged (task 8; the spike found outcome B on real hardware).
3. ~~**There are no tests.**~~ **Fixed (M0 tasks 1–3).** `MystNotesTests/` — sync harness, durability, codec, fidelity, watcher, debouncer, diagnostics, shape, artwork and performance suites, 125 tests green. Run on the iPad simulator: boot it first (see gotchas), then `xcodebuild test -scheme MystNotes -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)'`.


### M0 — done (Sept 25, 2026)

All 22 tasks done, exit criteria met, and the user confirmed it on the iPad on Sept 25, 2026. The full task list and its findings are in `Docs/PROJECT_PLAN.md` §4 and in git history. Branches merged `custom-drawing-toolbar` → `m0-correctness` → `m1-images-and-shapes` → `main` the same day. M0 items still open in `BACKLOG.md` moved to M1.

### M1 task order (archived)

Already done early: shape tool rebuild (Sept 15/18), images on a page with stacking and Mac import (Sept 18/19), text block typography (Sept 15), our own lasso with move/resize/rotate/cut/copy/paste (Sept 19), copy pages to another notebook (Sept 19).

1. ~~**Fill tool**~~ — done Sept 25, 2026, confirmed on the iPad (`TOOL_FIXES.md` Part 2): one erasable stroke per fill, the pen's colour, pan/zoom while selected, no gap at the outline.
2. ~~**Real PDF annotation**~~ — done Sept 25, 2026 on `m1-pdf-vectors`: PDF pages sharp at every zoom (vector tiles over the bitmap), export keeps the PDF's real text. Owed: a look on the iPad zoomed to 5x. Text selection is in the backlog.
3. ~~Lasso~~ — recolour, copy as image, convert to text done Sept 25 (`LassoActionsTests`); cross-page move is cut, turn the page, paste. Corner handles for a Mac.
4. ~~Templates~~ — Engineering and Cornell paper, page sizes for new pages, change a page's paper, New Page Like This for an imported template.
5. ~~Favourites, bookmarks, page outline~~ — plus page names (searchable). Syncs.
6. ~~Stickers~~ — resize/rotate (syncs); stickers and link anchors in exports, real PDF links.
7. ~~Pen on Mac~~ — `.pencilOnly` meant nothing drew on a Mac; verified with a test-bundle copy on this Mac.
8. ~~Export additions~~ — Markdown, whole-library zip. "Layered PDF" is still undefined; the export is vector PDF under a raster ink layer.
9. ~~Note lock; off-device backup~~ — Face ID/passcode gate; daily backup in the sync layout to a chosen folder, restorable.
10. Also done: document scanning (searchable), pen presets, bullets/checklists in text boxes, toolbar choices, trash restore.

**Owed on the iPad before M1 exits** — none of it can be checked in the simulator: the `[adjust]` log from one image resize (the resize-preview bug didn't reproduce; `BACKLOG.md`), sticker pinch/rotate, lasso corner handles and toolbar, Convert to Text on real handwriting, Rotate Page, Delete Page undo, note lock with Face ID, scanning, and a backup to a real Dropbox/Drive folder.

**M1 exit:** a GoodNotes user can do a full day of classes without hitting a wall.

