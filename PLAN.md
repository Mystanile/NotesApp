# MystNotes: build plan

A fresh session continues from this file. Read the Handoff section first, then Status. The milestone detail and exit criteria are in `Docs/PROJECT_PLAN.md`. Work that is not in the current task goes in `Docs/BACKLOG.md`.

Every item ends with how it was checked:

- [iPad]: someone used or measured it on the physical iPad.
- [Mac]: it was checked in the Mac app (the `.agenttest` copy).
- [tests only]: automated tests pass, but nobody used it on a device.
- [not tested]: no test and no device check.

## Autonomous run: Nov 2, 2026 (cloud session, branch `linework-2026-11-02`)

The user listed 16 items and left Claude to work alone for the day. Decisions:

- **Nothing in this run was built.** The session ran in a Linux container with no Xcode. Every item from today is tagged **[not built]**: it was only syntax-checked with the Linux `swiftc -parse`, which does not type-check UIKit, SwiftUI or PencilKit. Tests were written but not run. First job on the Mac: build, fix the compile errors, run `.claude/hooks/run-tests.sh`.
- **Branch:** `linework-2026-11-02`, started from `m2-graph` at `4a1b45f`. Pushed to GitHub. `m2-graph` is untouched.
- **Commit gate:** `guard.sh` lets a commit through without a test log only when `xcodebuild` is missing and the message says `[not built]`. The user approved this exemption.
- **Name:** the app is now **Linework** (user's pick). Only user-facing names change. The bundle id `com.mozynas.Mystnotes`, the sync folder name `Mystnotes`, the Xcode target and the Swift file names stay, so the existing library and sync folder keep working. The GitHub repo rename is for the user (Settings, rename to `linework`); GitHub redirects the old URL.
- **AI (reverses the locked "no network AI in v1" and the §5 non-goal, at the user's request):** opt-in, off by default, bring-your-own keys for Featherless (text) and ElevenLabs (voice), kept in the Keychain. Nothing is sent unless the user asks for it. The AI can write on a page in the user's own handwriting, built from an alphabet sheet they write once.
- **`/design-taste-frontend-v1` was not installed** in this session. UI work followed Apple's HIG instead.

## Handoff: start here (2026-11-02)

**Read this first.** Everything from Nov 2 is on `linework-2026-11-02` (pushed). None of it has been compiled. Before anything else:

1. On the Mac: `git fetch && git checkout linework-2026-11-02`, open the project, build. Expect compile errors; the list below says where.
2. Fix them, then run `.claude/hooks/run-tests.sh`. Fix what fails. Then remove the `[not built]` exemption from `.claude/hooks/guard.sh` if you don't want it any more.
3. Try it on the iPad with the `.agenttest` copy (`MYST_ID_SUFFIX=.agenttest`), not the real app.
4. **Sync format is now 5.** A device on an older build refuses the folder. Install the same build everywhere before syncing.
5. Rename the GitHub repo yourself: Settings > General > Repository name > `linework`. GitHub redirects the old URL. Add a license if you want one; none was added.

**Likely compile-fix spots** (flagged by the builders and reviewers, roughly most likely first):
- `SearchIndexer.swift`: the `@ModelActor actor SearchOCRStore` under default MainActor isolation.
- `StudyPanelView.swift`: `nonisolated(unsafe)` statics, the `@Sendable` optional closure in `HandwritingWriter.Request`, `StudyContext` main-actor reads.
- `SpeechClient.swift`: `ReadAloudPlayer`'s nonisolated AVAudioPlayer delegate callbacks and the continuation code.
- `PageSidebarReorder.swift`: `ScrollPosition(edge:)`, `onScrollGeometryChange`, `onGeometryChange(for: CGRect.self)`, `@GestureState` cancel detection.
- `ConnectionsPanel.swift`: a `nonisolated enum NodeInk` with a `@MainActor static`.
- `LibraryGraphView.swift` / `NotebookGraphView.swift`: tuple key paths in `ForEach(id:)`, optional values as `.task(id:)`.
- `DrawingToolbarView.swift`: `ViewThatFits` builds the options view twice; the rainbow `ColorPicker` overlay.
- `OnboardingView.swift`: `Color.mix`. `LibraryCells.swift`: `.contentShape(.hoverEffect, …)`.
- `SyncEngine.swift`: `beginBackgroundTask`'s expiration handler isolation; `import SwiftUI` for `ScenePhase`.
- `Diagnostics.swift`: the `NSCondition` static.
- `HandwritingCapture.swift`: `@Bindable` on the capture model, `interpolatedPoints(by: .distance(4))`.

**Owed on the iPad (new today):**
- The touch lock-out: swipe the page sidebar fast with a finger, then check a finger works without touching the Pencil first. Look for `[touch]` lines in `app.log`.
- A straight line drawn at 3 to 5 degrees stays at that angle, ends where the pen was.
- Sidebar: hold a thumbnail 0.3 s and drag; a swipe still scrolls; a tap opens; hold and release opens nothing; the ... menu; Reorder mode grips; auto-scroll; the + between pages with a pointer.
- Ruler: toggles, survives page turns.
- Search: the lens on a handwriting match; the indexer pausing while a notebook is open; results with a 300-page PDF.
- Draw with Finger on and off, while a page is open.
- Pen picker: the rainbow + swatch takes a tap; popover sizing.
- Make Node with the Pencil, rename, erase its ink (greys), undo (comes back).
- Page Map and Library Map: pinch versus card drag, smoothness with a few hundred edges, crisp zoom.
- AI: a real Featherless key and ElevenLabs key; Write on Page placement at several zooms; the handwriting sheet with the Pencil.
- Custom templates: import a PDF as templates, add a page from one.
- Battery: the app should not wake in the background (watchdog parked, folder presenter removed).

### Done on Nov 2, 2026 (all [not built]: written and syntax-checked, never compiled)

- [x] Shape tool: lines and arrows keep the pen's start and end, no angle snapping (`560678d`).
- [x] Touch recovery across page changes, for the sidebar lock-out report (`d86c9fc`). Cause not proven.
- [x] Battery: watchdog 4 Hz and parked in the background, folder presenter removed in the background, no pull after Control Center, background push protected (`6599523`).
- [x] Renamed to Linework (user-facing only), new icon in light, dark, tinted and Mac, accent colour, brand mark (`cc2c969`, `ccbd42b`).
- [x] `DesignSystem.swift` tokens and components (`2828cc6`); toolbar and pen picker redesign (`a5a23c9`); library, onboarding, settings, login polish (`84b30e3`).
- [x] Page sidebar: press and hold a thumbnail to drag it (Canva-style), springs apart, auto-scroll, + between pages; the page menu moved to a ... button on the current page and on hover; a Reorder mode with grips remains (`2225e0b` and the next commit).
- [x] Ruler on the paged canvas (PencilKit's `isRulerActive`), from a toolbar button. Not on whiteboards.
- [x] Sync format 5: `Link.title`, `Notebook.role` (`7cd8229`). M2 task 5, and task 1's helpers.
- [x] Stroke ids survive erase and undo; resolver; `regionInk` (`ae26e02`). M2 tasks 3 and 4. Task 2 (device spike) skipped; questions in BACKLOG.
- [x] Page Map rebuilt (M2 tasks 10, 11) (`412a0f5`); Library Map (task 12) (`18689db`); Make Node, badges, links to nodes, Connections panel (tasks 7, 8, 13) (`75bb99f`).
- [x] Instant search, background OCR, Quick Look lens on the match; Draw with Finger (`44018f0`).
- [x] Custom page templates from a PDF or image (`de10801`).
- [x] AI study helper: Featherless and ElevenLabs on your own keys, study panel, quizzes, read aloud, write the answer on the page in your own handwriting (`c6e3a83`, `42ddbdb`, `3dbf55d`, `81917ca`).
- [x] `Docs/COMPETITIVE_GAPS.md`: about 85 gaps against GoodNotes and OneNote, with a top-8 of quick wins. Done from it today: finger drawing. Still open from the top 8: laser pointer in Present, duplicate page and go-to-page, paper colour and line spacing, page grid view, zoom window, library sort and list view.
- [x] README rewritten as a portfolio piece (`13e74dd`).

Not done from the M2 plan: task 6 (mention integrity, `[[` across notebooks), task 9 (transclusion), task 14 (drawable map decision), task 15 (docs catch-up, partly done in SPEC 7.1 and 7.2), task 16 (device check). The Page Map has no ghost cards for cross-notebook links yet, and the Library Map can't open a notebook straight into its Page Map.

## Autonomous run: decided by the user on 2026-10-25

The user asked Claude to finish the plan alone. These decisions hold for the whole run:

- Scope: finish M2, then M3, M4 and M5, then the code parts of M6 (accessibility, strings, privacy manifest, onboarding) and a local-only M7 web viewer. This overrides the rule that a milestone waits for the one before it. The M1 iPad pass is still owed by the user.
- Devices: Claude can install the `.agenttest` copy on the paired iPad. Claude can drive the Mac `.agenttest` copy with synthetic mouse events. Never use the real app.
- Git: one local branch per milestone, each started from the one before (`m3-time`, `m4-recall`, `m5-reach`, `m6-ship`, `m7-web`). One commit per working feature. No push. Nothing merges into `main`.
- Packages: if a small, well-known Swift package replaces a lot of code, Claude can add it. This file lists each one with the reason.
- Defaults chosen by Claude: transclusion is built under the conditions in `BACKLOG.md`. The iPhone uses the same app target (its device family is already 1, 2, 7). `LoginView` stays as it is until M6.
- Left for the user: the M1 iPad checks with a Pencil and the paid developer membership. Also App Store Connect, TestFlight, a public privacy policy URL, and public hosting for share links.

### Oct 24 handoff (superseded by Nov 2 above)

Branch and build:

- Work on `m2-graph`. It has every change from `m1-batch-2026-09-25` plus the M2 work. The last M1 commit `9f9b4b2` came in as the cherry-pick `1978a07`, so git still lists `m1-batch-2026-09-25` as not merged. Neither branch is merged into `main` (last commit `3ab3810`, Sept 25).
- The last full test run passed: 327 tests, 2 skipped, 0 failures, on Oct 24 (`.claude/last-test.log`).
- Oct 24: simulator probes (`MystNotesTests/SimProbe*Tests.swift`) checked the iPad list as far as the simulator allows; what each showed is under "Owed on the iPad". Their pictures go to `/tmp/mystnotes-probes/`.
- M2 raises the sync format to 3, and smart folders (Oct 22) to 4. A device on an older build refuses the folder. Install the same build on the iPad and the Mac before you sync.
- A full copy of the iPad's data is in `~/Desktop/MystNotes-iPad-backup-2026-10-10/` (289 MB).
- The iPad runs an M1 build (sync format 2) from `m1-batch-2026-09-25` at `d6c7a0e`. It was built at 12:46 on Oct 10 (reflog and `.claude/real-build.log`) and launched at 12:47 (16:47 UTC in the iPad log). No M2 feature was used on the iPad.
- After a device on the M2 build syncs, the iPad refuses the folder until it also gets the M2 build.

Next, for the user to choose:

1. The iPad pass: the "Owed on the iPad before M1 exits" list. The simulator cannot show a real Pencil touch, the sticker gesture, the scanner camera or a real Dropbox or Drive backup.
2. Merge `m2-graph` into `main` after that pass.
3. Ink to node: the design is on the UI review canvas (https://claude.ai/artifact/ND8TGfW4v9eC2nB8QWG3bR), with four decisions for the user. Do not build it before they answer.
4. UI changes proposed on the same canvas: an Insert menu for text box, photo, sticker and link; "Save" renamed to a Share and Export button; a page sidebar instead of the bottom strip; the pen colour shown on the toolbar. None is decided.
5. Shape tool on the Pencil: one undo after a snap should leave the page as before the stroke. The probe shows it does when the snap and PencilKit's stroke land in one undo group; whether PencilKit uses one group is still only checkable on the iPad.

Still open from the Oct 22 bug hunt (small, not fixed):
- If PencilKit's stroke undo lands in its own undo group, one extra undo after a snap changes nothing.

Open bugs:

- Launch hang of 6 to 8 s on the iPad, last reported around Sept 25. It waited on the first sync run. None of the 7 launches logged from Oct 7 to Oct 10 hung. If it comes back, read its `[hang] main thread stack:` line. [iPad]
- Two stalls of about 1 s under `saveCurrentPage` (Sept 19). The cause is not known. The Oct 7 ones were the share sheet. [iPad]
- Trash loop: it stopped on the newer build, but the cause is not proven. 278 MB sits in the sync folder's trash. [iPad]

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

- [x] Zoom fixes (Oct 22): text boxes, stickers, PDF and lasso layers no longer stay off the ink after a layout pass during a pinch (the queued viewport update read old values). Imported PDFs stay sharp at full zoom on a 13" iPad. A zoomed whiteboard keeps its whole board reachable after a tool or colour change (the update reset its scrollable size to 3000 at any zoom), and zoomed out it fills the view. The whiteboard fix has a hosted test, and `SimProbePagesTests` plays a pinch with layout passes in the notebook screen (Oct 24). [tests only]

- [x] Empty library shows New Notebook and Import PDF or Image buttons (Oct 22). [tests only] (`SimProbeElementsTests`, Oct 24)

- [x] Bug-hunt fixes (Oct 22): exports and Copy Pages wait for the open page's save, so they never take the previous ink; copied pages keep their tags; whole-library export keeps notebooks whose titles differ only in case; import, reorder and new pages first finish a pending Delete Page, so no two pages share an index; "Linked from" hides a page being deleted. [tests only] for the export name clash.

- [x] Text box fixes (Oct 22): deleting a text box is undoable and undo brings back its formatting and `[[` mentions; its mentions go with it, so "Linked from" and the Page Map stop showing them; new text boxes and stickers land in the middle of the screen and never exactly on another one; cancelling a link's destination picker removes the unfinished link. [tests only] for placement and the snapshot. Not tried: undo and Cancel on a device.

- [x] Lasso fixes (Oct 22): a rotated selection keeps its rotation on the next drag; undoing a paste or duplicate clears the empty selection box, and undoing a move puts the box back on the ink; Paste lights up straight after Copy; repeated pastes step apart, and a paste that would land off screen comes to the middle of it. [tests only] for rotation, undo and paste placement.

- [x] Search and Markdown (Oct 22): the handwriting indexing pass stops when the search screen closes and skips pages deleted mid-pass; results refresh when pages come or go; Markdown export (one notebook or the library) reads handwriting on pages search never indexed. [not tested] by a test of its own; the suite passes.

- [x] Notebook toolbar from the UI review (Oct 24): one Insert menu holds text box, photo, sticker, link, paste image, PDF or image file, and the new-page imports and scan (the nav-bar Import menu is gone); Save is now a Share menu; Outline, Present and New Page are in a More menu; the page-strip toggle is a sidebar icon; the pen and highlighter show their colour; every toolbar icon has a VoiceOver label. [tests only] (`NotebookToolbarTests`). Not tried: choosing a menu row with a real touch, the Mac.

- [x] Page sidebar (Oct 25): the bottom page strip is now a left sidebar. Drag its edge to make it 96 to 220 pt wide, and the thumbnails grow with it. It scrolls to the open page. [tests only] (`PageSidebarTests`). Not tried: the drag with a real touch.

- [x] Library covers (Oct 24): "Edited today / yesterday / Tuesday / Oct 3" under each notebook, and a small preview of its last inked page on the cover (none when locked). [tests only] (`NotebookCoverTests`)

- [x] Lasso toolbar (Oct 24): the floating drawing toolbar hides while ink is selected, so it no longer covers the lasso toolbar in compact width. Under about 461 pt the lasso toolbar becomes Cut, Copy, Delete, More and Done. It moves to the bottom when the selection's top would be under it. [tests only] (`SimProbeElementsTests`). Not tried: the More menu on a device, the Mac.

- [x] Page layers after a page change (Oct 24): if the canvas never reports the page's fit, the viewport asks again after 1 s and shows the paper, images and text after 2 s, with a `viewport` log line. Before, they stayed hidden with no timeout. [tests only] (`ViewportRevealTests`)

- [x] A lost notebook file is no longer pending forever (Oct 24). If `notebooks/<id>.json` is absent (no file, no iCloud placeholder) for an hour and this device has pages of that notebook, the next push publishes this device's copy. A file that is still downloading stays pending, as before. The push that republishes skips the orphan pass, so pages only the other device had keep their ink files and come back on its next push. [tests only] (five tests in `SyncTests`). Not tried: a real provider losing a file.

- [x] Convert to Text: if the selection moves while it is read, the text box goes where the ink is now, not where it was (Oct 24). [tests only]

- [x] Editing a text box: a drag in the text selects it instead of moving the box; a move handle at the top right moves it (Oct 22). [tests only] for the handle showing while editing (`SimProbeElementsTests`, Oct 24); the drag itself is not tested.

### Owed on the iPad before M1 exits

All of these are still owed on the iPad. On Oct 24 the simulator probes (`MystNotesTests/SimProbe*Tests.swift`) checked what a hosted test can check without a Pencil, a camera or a real touch. After each item: what the simulator showed.

- [x] The `[adjust]` log from one image resize. Void: the log is gone (`da33c62`). Simulator: the handles and the picture land on the same corners after a resize at zoom 1.5.
- [ ] Sticker pinch and rotate. Simulator: a pinched and turned sticker draws at its scale and angle about its centre, at every zoom, and keeps them after a reload. Not shown: the two-finger gesture.
- [ ] Lasso corner handles and the lasso toolbar, on the iPad and the Mac. Simulator: the handles sit on the corners at zoom 1, zoom 2 and after a resize. The three toolbar bugs it found are fixed (Oct 24).
- [ ] Convert to Text on real handwriting. Simulator: generated slanted, joined cursive read as "lunch time / until then", 4 of 4 words. The flow removes exactly the read ink, and undo brings it back.
- [ ] Rotate Page, and Delete Page undo. Simulator: both ran from the page strip's real menu. Rotate turned the ink, text box, sticker and PDF together, saved, and undo turned them back. Delete then Undo brought back the page, its ink file, its place and its links.
- [ ] Note lock with Face ID. Simulator: the real `LAContext` path with simulated Face ID. A match opens the notebook, a non-match does not, and with no enrollment it refuses calmly.
- [ ] Scanning with the real camera. Simulator: Scan Document is offered. Choosing it could not be driven.
- [ ] A backup to a real Dropbox or Drive folder. Simulator: a local folder chosen through the same bookmark path gets the zip, and it restores.
- [ ] Imported PDF pages zoomed to 5x stay sharp. Simulator: at 8.5x (13-inch fit times 5) the PDF tiles draw at the 32x level, and vector edges stay sharp where a bitmap control blurs.
- [ ] The Pencil lasso on a zoomed whiteboard. Simulator: at 2.5x, scrolled far out, a loop in screen points selects only the ink under it, and a drag moves it by the right distance. The board's pan takes direct touches only. Not shown: a real Pencil touch.
- [ ] The Pencil lasso on a normal page: the host recognizer gets the Pencil, and the Pencil does not pan the canvas. Simulator: the lasso recognizer takes the Pencil and nothing blocks it; the page's pan takes direct touches only. Not shown: a real Pencil touch.
- [ ] The shape hold-to-snap recognizer gets the Pencil touch during a PencilKit stroke. Simulator: it is on both canvases, takes the Pencil and shares the touch with PencilKit. A snap in the same event as its stroke undoes in one step. Not shown: a real stroke, or how PencilKit groups its own undo.
- [ ] Notebook covers in dark mode. Simulator: all six covers, title contrast 12.1:1 in light and in dark.

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
- [x] A photo button on the drawing toolbar (`8e5c0bc`). [tests only]: it opens the Photos picker, and is off on a whiteboard (`SimProbeSystemTests`, Oct 24)
- [x] Smart folders: + menu, New Smart Folder. A folder with a saved search shows every matching page (typed text, handwriting, PDF text, now tags). The search syncs. Edit Search in the folder's menu (Oct 22). [tests only] for sync.
- The plan for the rest of M2 is `Docs/M2_REMAINING_PLAN.md` (Oct 25). Its 16 numbered tasks run in order.
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

