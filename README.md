# Mystnotes

A handwriting-first notebook app for iPad and Mac. I built it because GoodNotes is very good and also closed. My notes live in a format I can't read without it, on a sync system I don't control, and I wanted out.

## Why it exists

The obvious way to build a notes app is to put everything in the database. That falls apart the moment you add real handwriting.

A page of ink is a `PKDrawing`, which is a binary blob that can run to megabytes once someone has actually written on the page. If that goes in a synced database, every autosave ships the whole blob, and CloudKit's record size limits are tight. So drawings live on disk as files, and the database just holds a filename.

That one decision shapes the rest of the app. Ink is stored in my own stroke format, not as a `PKDrawing` blob, so it can be read without PencilKit and every stroke keeps a stable id. Sync is a folder you pick (iCloud Drive, Dropbox, anything the Files app can see), and that folder is the source of truth. The SwiftData database is only an index that can be thrown away and rebuilt from it.

## What it does

- Nested folders, notebooks with cover styles, and pages in either paged or infinite-whiteboard mode
- Pen, pencil, marker, fountain and monoline inks, a highlighter, erasers, a fill tool and a lasso, through a custom toolbar that drives PencilKit directly, with Apple Pencil pressure and tilt
- Page templates (blank, lined, grid, dotted, engineering, Cornell) drawn behind the ink rather than baked into it
- Typed text blocks and stickers placed anywhere on a page, alongside the handwriting
- Import a PDF or image as a page background, then annotate on top
- Links between pages and notebooks, a "Linked from" box, a Page Map of a notebook's links, page tags, and `[[` mentions in text boxes
- Shape cleanup: hold at the end of a rough line, arrow, circle or polygon and a clean one snaps in its place, solid, dashed or dotted
- Search across typed text, imported PDF text layers, and your own handwriting, recognised on device, plus lasso Convert to Text
- Export a page, a notebook, Markdown, or the whole library, and a daily backup to a folder you choose
- Sync through a folder you choose, or none at all and keep everything local
- A note lock with Face ID or the passcode, and a trash you can restore from for 30 days

## The parts worth looking at

If you're reading this as a code sample, these are the decisions that took the most thought.

**Ink is not in the database.** `Page` holds a `drawingFileRef`, a file name like `<uuid>.strokes`. That file is the record, in a neutral stroke format (`StrokeCodec`) that gives every stroke an id that never changes, which links and the coming stroke timeline point at. The `PKDrawing` beside it is only a cache, rebuilt from the record whenever its hash does not match. `DrawingStore` is the only code that reads or writes either, and every write is atomic.

**Sync is a folder, not CloudKit.** CloudKit needs a paid developer account, and a folder turned out better anyway: you can see and back up your notes in Finder. The folder holds `index.json`, one `notebooks/<uuid>.json` per notebook and content-addressed payload files. `SyncEngine` merges per page on `Page.modifiedAt` and never rebuilds a page tree. When two devices edit the same page, the losing ink goes to `trash/` instead of being discarded, and nothing in the app deletes a payload outright. It moves to the trash, and only a 30-day sweep empties it. A two-library test harness (`SyncTests`) pins all of this.

**Nothing heavy runs on the main thread while you draw.** The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which quietly put the whole sync engine on the main thread once. Saving, sync, OCR and off-screen ink rendering now run off it, and the off-screen renders share one serial queue, because PencilKit deadlocks when the thread pool fills with them.

**The model layer still follows CloudKit's rules.** No unique constraints, every attribute optional or defaulted, every relationship optional, `CGRect` flattened into four `Double`s and `Color` stored as a hex string. Nothing needs that today, but it costs nothing and keeps CloudKit possible later.

**Handwriting search is only affordable if you don't redo it.** `HandwritingRecognizer` renders a `PKDrawing` back to an image at 2x (1x blurs fine strokes into noise for the recogniser) and runs Vision's `VNRecognizeTextRequest` over it. OCR is by far the slowest thing the app does, so it compares the drawing file's modification date against `Page.ocrUpdatedAt` and skips any page whose ink hasn't changed. The work runs off the main actor so a search never hangs the UI. Recognised text is cached on the model, so it syncs too, and OCR runs once per edit instead of once per device.

**The tutorial notebook is a real notebook.** Instead of a static walkthrough image, `TutorialNotebookFactory` builds an actual notebook whose strokes, text boxes, sticker and link are the real elements the app supports, shown in place. It seeds once, ever, so deleting it on purpose doesn't bring it back.

**Shape recognition is heuristics, not a classifier.** Hold the pencil still at the end of a stroke and `ShapeRecognizer` fits a line, arrow, circle, ellipse or polygon from three to six sides, at the weight of the stroke it replaces. The hold timer runs in the `.common` run-loop mode, because a timer in the default mode never fires while the pencil is down.

## Running it

Open `MystNotes.xcodeproj` in Xcode and run. It needs iPadOS 26.5 or later, and the Mac build goes through Catalyst. A free Apple developer account is enough to sign it.

To sync, pick a folder in Settings. Without one, the app runs and everything stays local.

An Apple Pencil is worth having. On an iPad the finger pans and the Pencil draws, and on a Mac the mouse draws.

Run the tests on the iPad simulator with `.claude/hooks/run-tests.sh`. It boots the simulator and runs a clean test.

## Layout

```
MystNotes/
  MystNotesApp.swift          app entry, ModelContainer, second window scene
  MystNotesModels.swift       SwiftData models (the index, not the source of truth)
  DrawingStore.swift          the only reader and writer of ink files
  StrokeCodec.swift           the neutral stroke format and its stroke ids
  SyncEngine.swift            folder sync, merged per page
  TrashRetention.swift        the 30-day sweep, the only delete of a payload
  PencilCanvasView.swift      PKCanvasView wrapped for SwiftUI
  DrawingToolbarView.swift    the custom toolbar
  WhiteboardCanvasView.swift  the infinite-canvas page type
  HandwritingRecognizer.swift Vision OCR over the ink
  SearchIndex.swift           typed text, OCR'd handwriting and PDF text layers
  ShapeRecognizer.swift       hold-to-snap shape cleanup
  LibraryView.swift           folders and notebooks
  MystNotesDetailView*.swift  the page editor, split by concern
MystNotesTests/               sync harness, durability, codec and performance suites
```

## Built with

Swift, SwiftUI, SwiftData, PencilKit, Vision, PDFKit. No third-party dependencies.

## What it deliberately doesn't do

**No native macOS build.** PencilKit isn't available outside UIKit, so the Mac version runs through Catalyst. There's an AppKit placeholder in `PencilCanvasView` that draws nothing. A native Mac app would need a different canvas entirely, which is a rewrite, not a port.

**No collaboration.** Sync keeps one person's devices in step. Shared notebooks would mean invitations and real conflict resolution on ink, which is its own project.

**No account yet.** Sign in with Apple is built but parked until the app has a paid developer account, so for now you continue without one.

**Handwriting recognition is English only.**

## Status

Working and in daily use. M0 (correctness) and M1 (parity with GoodNotes) are built, with a few checks still owed on the iPad. M2, notes as a graph, has started on the `m2-graph` branch. Live status is in `PLAN.md`.
