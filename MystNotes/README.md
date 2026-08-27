# Personal Notetaking App Project

This is a native note-taking app for iPad and Mac, which is a personal GoodNotes/Notability alternative built entirely with SwiftUI, SwiftData, and PencilKit. Create multi-page notebooks, sketch with Apple Pencil or your mouse, organize everything into nested folders, import and annotate PDFs and images, and search your handwriting. It runs on iPadOS and on the Mac via Mac Catalyst, so the same editable canvas works on both.

## Feature list (bulleted, drop into a Features section)

### Drawing & writing
- Full PencilKit canvas — works with Apple Pencil, finger, and (on Mac) mouse/trackpad
- Custom floating drawing toolbar (GoodNotes/Notability-style — not Apple's system tool picker): pen, highlighter, eraser, lasso select, and the shape tool, each remembering its own color/width independently
- Five pen ink types: pen, pencil, marker, fountain pen, monoline, with a continuous width slider (not fixed presets)
- Dedicated highlighter tool (translucent ink), with its own color/width
- Eraser with precise (vector) or area (bitmap) modes
- Shape tool with automatic stroke smoothing (recognized shapes)
- Undo / redo, autosave after every stroke, and a manual Save action that shows a brief confirmation
- Large-canvas whiteboard page type for freeform sketching

### Notebooks & pages
- Multi-page notebooks with a thumbnail strip for navigation
- Add, delete, and reorder pages
- Four page templates: blank, lined, grid, dotted

### Organization
- Nested folders  
- Notebook covers with 6 color styles (indigo, sunset, ocean, forest, mono, berry)
- Rename notebooks and folders

### Page elements
- Draggable typed text boxes
- Sticker library (reusable SF Symbol graphics)
- Internal hyperlinks that jump between pages
- Import PDFs or photos as full page backgrounds

### Documents & annotation
- PDF import — each PDF page becomes its own page
- Image import via the photo picker
- Annotate/highlight directly on top of imported documents with the pen tools

### Productivity
- Global search across every notebook, matching typed text, imported PDF text, and handwriting (on-device Vision OCR)
- Tap a search result to open the notebook at the exact matching page
- Presentation / mirroring mode (clean, interface-hidden view)
- Open any notebook in its own separate window (great for iPad Split View)
- Settings screen: default pen, default paper template, light/dark/system theme, and sync status

### Platforms

- iPadOS — full Apple Pencil support
- macOS (Mac Catalyst) — the same editable canvas, using mouse/trackpad (no rework between platforms)
- One codebase shared across both

## Tech stack

- SwiftUI + SwiftData for the UI and data model
- PencilKit for the drawing engine (palm rejection, pressure/tilt, undo/redo)
- Vision framework for on-device handwriting recognition (private — no data leaves the device)
- PDFKit for document import
- CloudKit for syncing notebook records between your devices (requires a paid Apple Developer Program account — Apple doesn't allow free/personal-team accounts to register the iCloud/CloudKit capability at all. Currently disabled in `Mystnotes.entitlements` for that reason; the original entitlements are kept in `Mystnotes.entitlements.paid-account-backup` to restore once enrolled)
- Mac Catalyst so the iPad app runs on the Mac

## Architecture notes

- Drawings and imported files are stored as files on disk (a lightweight store with iCloud Documents + local fallback), while SwiftData models hold metadata and file references — keeps the database light and sync predictable.
- All text (typed + recognized handwriting + PDF) is indexed for fast search. Handwriting OCR renders each page's ink onto an opaque background before running Vision's text recognizer — it reliably returns nothing on a transparent one.
- The drawing toolbar (`DrawingToolbarView`) drives `PKCanvasView.tool` directly instead of showing Apple's `PKToolPicker`, so Pencil input still goes straight through PencilKit's own low-latency path — only the tool-selection UI is custom.
