# Mystnotes

A handwriting-first notebook app for iPad and Mac. Built because GoodNotes is very good and also closed — my notes live in a format I can't read without it, on a sync system I don't control.

## Why it exists

The obvious way to build a notes app is to put everything in the database. That doesn't survive contact with handwriting.

A page of ink is a `PKDrawing` — a binary blob that can run to megabytes once someone has actually written on it. Putting that in a synced database means every autosave ships the whole blob, and CloudKit record size limits are not generous. So drawings live on disk as files, and the database holds a filename.

That single decision creates the problem the rest of the app is organised around: **the database and the files sync through two different systems**, and a notebook is only whole when both have arrived. SwiftData's CloudKit mirroring carries the models. iCloud Drive's ubiquity container carries the ink. Neither knows about the other.

Most of the interesting code here is about keeping those two halves in step.

## What it does

- Nested folders, notebooks with cover styles, and pages in either paged or infinite-whiteboard mode
- Pen, highlighter and eraser through PencilKit, with the system tool picker and Apple Pencil pressure and tilt
- Page templates — blank, lined, grid, dotted — drawn behind the ink rather than baked into it
- Typed text blocks and stickers placed anywhere on a page, alongside the handwriting
- Import a PDF or image as page backgrounds, then annotate on top
- Internal links: tap an anchor on one page to jump to another
- Shape cleanup — draw a rough line, box or circle and have it snapped to a clean one
- Search across typed text, imported PDF text layers, **and your own handwriting**, recognised on device
- Sign in with Apple, or continue without an account entirely
- Sync through your own iCloud, or turn it off and keep everything local

## The parts worth looking at

If you're reading this as a code sample, these are the decisions that took the most thought.

**Ink is not in the database.** `Page` holds a `drawingFileRef` — a filename like `<uuid>.drawing`. `FileStore` resolves that to a URL inside the iCloud ubiquity container's Documents folder, which iCloud Drive syncs across devices on the same Apple ID. When iCloud isn't available, or the container hasn't mounted yet, it falls back to the local sandbox and catches up later. Models sync one way, payload files sync another, and a page renders only when both have landed.

**The sync switch has two different timings, and that asymmetry is deliberate.** SwiftData reads `cloudKitDatabase` once, when the `ModelContainer` is built, and can't swap it on a running container — so turning sync off only affects the database at the *next* launch. `FileStore` checks the same preference on every call, so it stops writing to iCloud immediately. Turning sync off therefore stops new ink reaching iCloud right away, while the model store waits for a relaunch. Two mechanisms, two honest behaviours, rather than one lie.

**CloudKit's rules wrote most of the model layer.** A CloudKit-backed store won't accept unique constraints, requires every attribute to have a default value or be optional, and requires every relationship to be optional. So every property in `MystNotesModels.swift` carries a default, every `@Relationship` is an optional array, `CGRect` is flattened into four `Double`s, and `Color` is stored as a hex string. None of that is stylistic — it's the shape CloudKit permits.

**Handwriting search is only affordable if you don't redo it.** `HandwritingRecognizer` renders a `PKDrawing` back to an image at 2× (1× blurs fine strokes into noise for the recogniser) and runs Vision's `VNRecognizeTextRequest` over it. OCR is by far the slowest thing the app does, so it compares the drawing file's modification date against `Page.ocrUpdatedAt` and skips any page whose ink hasn't changed. The work happens off the main actor so a search never hangs the UI. Recognised text is cached on the model, which means it syncs — OCR runs once per edit, not once per device.

**Resolving the iCloud container is slow, so it's cached.** `url(forUbiquityContainerIdentifier:)` can touch disk and do container setup, and it was being called on every autosave tick, page load and thumbnail render. That was a steady source of main-thread stutter. It's cached now, and invalidated on `NSUbiquityIdentityDidChange` — the only event that can change the answer.

**The login screen is about identity, not data isolation.** CloudKit's private database is already scoped per Apple ID, so two people on two devices cannot see each other's notebooks with zero code written for it. Sign in with Apple exists so the app knows who's using it, and so "continue without an account" can be an explicit, honest choice that pairs with sync off.

**The tutorial notebook is a real notebook.** Rather than a static walkthrough image, `TutorialNotebookFactory` builds an actual notebook whose strokes, text boxes, sticker and link are the real elements the app supports, demonstrated in place. It seeds once ever, so deleting it deliberately doesn't bring it back.

**Shape recognition is heuristics, not a classifier.** Close the path within roughly 18% of the bounding box diagonal and it's treated as closed; from there, roughly circular becomes an ellipse and everything else becomes a rectangle. An open path straightens to a line. It covers what the tool is actually used for and nothing more.

## Running it

Open `MystNotes.xcodeproj` in Xcode and run. iOS 17+ / iPadOS 17+ for SwiftData; Mac via Catalyst.

Sync needs the iCloud capability with CloudKit and the iCloud Documents container enabled, and a device signed into iCloud. Without it the app still runs — everything stays local.

An Apple Pencil is worth having. Finger and trackpad input work (`drawingPolicy = .anyInput`), they're just not what the app is for.

## Layout

```
MystNotes/
  MystNotesApp.swift          app entry, ModelContainer, second window scene
  MystNotesModels.swift       SwiftData models — shaped by CloudKit's constraints
  FileStore.swift             on-disk payload files and the iCloud container
  AppSettings.swift           UserDefaults preferences, read by views and non-view code alike
  PencilCanvasView.swift      PKCanvasView wrapped for SwiftUI
  WhiteboardCanvasView.swift  the infinite-canvas page type
  HandwritingRecognizer.swift Vision OCR over PKDrawing, with mtime-based caching
  SearchIndex.swift           combines typed text, OCR'd handwriting and PDF text layers
  ShapeRecognizer.swift       freehand line/rect/ellipse cleanup
  LibraryView.swift           folders and notebooks
  MystNotesDetailView.swift   the page editor
  TutorialNotebookFactory.swift  the welcome notebook, built as a real notebook
```

## Built with

Swift, SwiftUI, SwiftData, CloudKit, PencilKit, Vision, PDFKit. No third-party dependencies.

## What it deliberately doesn't do

**No native macOS build.** PencilKit isn't available outside UIKit, so the Mac version runs through Catalyst. There's an AppKit placeholder in `PencilCanvasView` that draws nothing — a native Mac app would need a different canvas entirely, and that's a rewrite rather than a port.

**No collaboration.** Everything is scoped to one Apple ID's private CloudKit database. Shared notebooks would mean the shared database, invitation handling, and conflict resolution on ink — which is its own project.

**Shape recognition stops at three shapes.** No triangles, arrows or polygons.

**The Apple ID identifier lives in UserDefaults, not the Keychain.** Fine for personal use; it would move to the Keychain before this went anywhere near other people.

**Handwriting recognition is English only**, and it's for search — there's no convert-to-text feature.

## Status

Working and in daily use. Roughly through phase four of six: the library, canvas, page elements, import, search and sync are all in. Still to come are the export path, and polish on the whiteboard canvas.
