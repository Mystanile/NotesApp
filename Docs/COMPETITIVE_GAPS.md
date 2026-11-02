# Competitive gaps: GoodNotes 6 and OneNote vs Linework

Written Nov 2, 2026. Linework is the new name for MystNotes.

This lists every concrete reason a user would say GoodNotes 6 or OneNote for iPad is better than this app today. Each gap was checked against the code with grep before it went in. Features we already have are not listed. That includes presets, favourites, bookmarks, outline, scribble to erase, two and three finger tap undo and redo, lasso resize and rotate, convert to text, shape snapping, fill, stickers, note lock, scanning, trash restore, Markdown export, smart folders, page links and the Page Map.

## How to read it

Each row has what the competitor does, what we lack, an effort and a status.

Effort:

- `S`: a day or less.
- `M`: a few days.
- `L`: a week or more, or needs a new subsystem.

Status:

- `today`: in scope for today's work. Today's list is: line tool angle freedom, sidebar drag reorder, instant search with highlight, pen picker polish, custom templates from a file, an AI study helper (summaries, quizzes, read aloud), AI writing in handwriting, the graph and Page Map, UI polish, and battery.
- `planned`: already in a milestone. M3 is audio and the stroke timeline. M4 is recall. M5 is importers, iPhone and Mac polish. M7 is the web viewer and share links.
- `non-goal`: excluded by `PROJECT_PLAN.md` §5. That covers real-time collaboration, AI chat, a paywall, native Android and Windows, and a template marketplace.
- `open`: a real gap that no milestone and nothing in today's list covers.

On AI: `CLAUDE.md` used to lock "no network AI calls in v1", and §5 ruled out AI chat. The user lifted both on Nov 2, 2026. AI is now opt-in, off by default, and runs on the user's own Featherless and ElevenLabs keys, so it costs the app nothing per query.

## Ink and tools

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Line angle freedom | GoodNotes straightens a line at any angle you drew it. | Our recognizer snaps lines near an axis (10 degree tolerance) and users fight it. | S | today |
| Pen picker | GoodNotes 6 shows chevrons on toolbar buttons for quick access to favourite pen and highlighter settings. | Our presets row works, but the picker is plain and has no recent colours. | S | today |
| Recent colours and eyedropper | Both keep recently used colours. OneNote has an eyedropper. | We have 8 fixed colours plus the system picker. No history, no eyedropper. | S | today (pen picker polish) |
| Ruler | GoodNotes has a ruler tool. OneNote has a ruler for straight lines at any angle. | No ruler at all. `PKCanvasView.isRulerActive` is unused. | S | done Nov 2 |
| Zoom window | GoodNotes has a zoom window: write large in a box at the bottom, ink lands small on the page, and it advances along the line. | Nothing like it. You zoom the whole page instead. | M | done Nov 2 |
| Tape | GoodNotes tape covers keywords. Tap to reveal. Used for self-testing. | No tape tool. | S | planned (M4 cloze on ink covers the same need) |
| Laser pointer | GoodNotes presentation mode has a laser pointer that fades. | Our Present mode only hides chrome. No laser, no pointer. | S | done Nov 2 |
| Selective eraser | GoodNotes 6 erases only one content type, such as highlights. | Our eraser removes any ink it touches. | M | open |
| Stroke stabilization | GoodNotes smooths handwriting with separate settings for writing and drawing. | No smoothing. We use raw PencilKit strokes. | M | open |
| Reduce latency | GoodNotes has a predicted-touches setting to cut ink latency. | We rely on PencilKit's default. No setting. | S | open (PencilKit already predicts; check before building) |
| Line straightening | GoodNotes straightens a handwritten line of text or bullets with one tap. | Not present. | M | open |
| Restyle | GoodNotes 6 rewrites messy handwriting into a neater version that keeps words, layout and colour. | Not present. | L | today (AI writing in handwriting) |
| Spellcheck and Word Complete | GoodNotes underlines misspelled handwriting and predicts the next word in your hand. | Not present. | L | today (AI writing in handwriting) |
| Object snapping | GoodNotes 6 snaps objects to each other and the grid with guide lines. | Text boxes, stickers and images move freely with no guides. | M | open |
| Diagram connectors | GoodNotes 6 adds connected shapes from a dot on a shape's edge, with curved or elbow connectors. | Shapes are ink. No connectors that stay attached. | L | open |
| Layers | GoodNotes 6 (early access) has layers you can hide and export separately. | No layers. Imported art always sits under the ink. | L | open |
| Object lock | GoodNotes locks an object so it cannot move by accident. | No lock on images, text boxes or stickers. | S | open |
| Finger drawing | Both let you draw with a finger. | On iPad the finger never draws (`.pencilOnly` is hard coded). No setting to change it. | S | done Nov 2 |
| Insert space | OneNote inserts space in ink and pushes content down. GoodNotes Smart Ink adds space between lines on other platforms. | Not present. | M | planned (M5) |
| Ink replay | OneNote on Windows and GoodNotes with audio replay strokes in order. | No replay. | L | planned (M3) |
| Math | GoodNotes Math Assist checks handwritten math, solves matrices and draws 2D graphs. OneNote has a math assistant on Windows. | No math recognition. | L | planned (M4) |

## Pages and navigation

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Sidebar drag reorder | GoodNotes reorders pages in the sidebar by drag, with a grey drop highlight. | A hold-and-drag exists in the sidebar but needs polish and a clear drop target. | S | today |
| Page grid view | GoodNotes shows every page as a grid of thumbnails to scan, reorder and pick. | Only the narrow sidebar list. No full-screen grid. | M | done Nov 2 |
| Multi-page select | GoodNotes selects many pages to move, copy, rotate, export or delete at once. | Every page action works on one page. | M | open |
| Duplicate page | GoodNotes duplicates a page with its ink. | "New Page Like This" copies the paper only. Copy to Notebook works across notebooks. | S | done Nov 2 |
| Go to page | GoodNotes shows "3 of 20" and lets you jump to a page number. | No page indicator and no jump to a number. | S | done Nov 2 |
| Continuous scroll | GoodNotes scrolls pages vertically or horizontally as one long strip. | One page at a time with a swipe. | L | open |
| Document tabs | GoodNotes keeps several documents open in tabs. | No tabs. Multi-window covers part of it. | M | open |
| Two documents side by side | GoodNotes split view shows two notebooks at once in one window. | Only through two system windows. | M | open |
| Page undo | GoodNotes undoes add, delete, rotate, reorder and template change. | Undo lives on the page canvas, so it is lost on a page turn. Delete has its own undo banner. | M | open (in `BACKLOG.md`) |
| Subpages | OneNote nests pages under a parent page. | Pages are flat in a notebook. | M | open |
| Section tabs | OneNote has sections and section groups inside a notebook. | Notebooks have no sections. Folders sit above notebooks only. | L | open |
| Read-only mode | GoodNotes has a reading mode that stops accidental marks. | No view mode. | S | open |

## PDF and study

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| PDF text select | GoodNotes selects, copies and highlights a PDF's real text. | PDFs are sharp and searchable, but you cannot select their text. | M | open (in `BACKLOG.md`) |
| PDF links and outline | GoodNotes follows a PDF's internal links and shows its outline. | An imported PDF's own links and bookmarks are ignored. | M | open |
| Custom templates from a file | GoodNotes imports any PDF or image as a reusable template. | Six built-in papers. "New Page Like This" reuses an imported page, but there is no saved template list. | M | today |
| Paper colour and spacing | GoodNotes offers white, yellow and dark paper and several line spacings. | Paper is always white. Line spacing is fixed at 32 pt. | S | done Nov 2 |
| Flashcards | GoodNotes has study sets with spaced repetition. | Not present. | L | planned (M4) |
| Quiz Me | GoodNotes generates quizzes from your notes. | Not present. | M | today (AI study helper) |
| Summaries | GoodNotes AI summarises notes and recordings. | Not present. | M | today (AI study helper) |
| Read aloud | OneNote's Immersive Reader reads a page aloud with highlighting. | No read aloud. | S | today (AI study helper) |
| Larger imports | GoodNotes imports PDFs up to 1 GB and Word and PowerPoint files. | PDF and images only. No Office files. | M | open |

## Organization

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Library sort | GoodNotes sorts by name, date created or date modified, ascending or descending. | The library has fixed sorts. No picker. | S | done Nov 2 (plus a custom order) |
| List view | GoodNotes switches the library between grid and list. | Grid only. | S | done Nov 2 |
| Folder colours | GoodNotes 6 picks any folder colour by wheel, hex or RGB. | Folders have no colour. | S | open |
| Multi-select in library | GoodNotes selects many notebooks to move, duplicate or delete. | One notebook at a time. | M | open |
| Tag summary | OneNote tags lines (To Do, Important) and builds a summary of every tagged item. | Tags are per page. No line-level tags, no summary. | M | open |
| Calendar and tasks | OneNote links to Outlook tasks. GoodNotes shows calendar events in planners. | No calendar or task integration. | L | open |
| Quick note | GoodNotes opens a QuickNote from the Home Screen icon or a widget. | No widget, no Home Screen quick action. | S | planned (M5, App Intents) |

## Search

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Instant search with highlight | Both highlight the match on the page when you open a result. | Results open the page but do not mark where the match is. Search runs on each keystroke without a ranked list. | M | today |
| Search inside a notebook | GoodNotes finds text in the open document with next and previous. | Search is library-wide only. | S | today (part of instant search) |
| Text in photos | OneNote finds text inside pictures. | Imported photos are not OCR'd. Only scans and PDF text layers are. | S | done Nov 2 |
| Languages | GoodNotes reads handwriting in many languages. | OCR is English only (`en-US`). | S | open |
| Semantic search | GoodNotes AI finds notes by meaning. | Keyword only. | L | planned (M4) |

## Sync and sharing

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Share a link | Both share a page or notebook as a link anyone can open. | Export only. | L | planned (M7) |
| Real-time collaboration | Both edit together live. GoodNotes claims under 0.3 s latency. | Not present. | L | non-goal |
| Comments | GoodNotes attaches comments to objects. | Not present. Comments only mean something with sharing. | M | non-goal (follows collaboration) |
| Cloud services | GoodNotes opens and saves back to Box and Dropbox. OneNote is on OneDrive. | Folder sync covers any provider the Files app sees. No open-and-save-back. | M | open |
| Tool settings sync | GoodNotes syncs pen colours and toolbar settings across devices. | Presets and toolbar choices stay on one device. | S | open |
| Print | Both print. | No print action. `UIPrintInteractionController` is unused. | S | done Nov 2 |

## AI

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Study helper | Ask GoodNotes summarises, explains and quizzes with citations to the page. | Not present. Must be on device. | M | today |
| Chat with notes | Ask GoodNotes and OneNote Copilot answer free questions over all notes. | Not present. | L | non-goal (§5, AI chat) |
| Handwriting writing help | GoodNotes Restyle, spellcheck and Word Complete. | Not present. | L | today |
| Diagram generation | Ask GoodNotes turns notes into flowcharts and timelines. | Not present. | L | open |
| Image generation | GoodNotes inserts Image Playground pictures. | Not present. Image Playground is a system sheet, so this is cheap. | S | open |

## Audio

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Recording | Both record audio inside a note. GoodNotes has one-tap record on the toolbar. | No audio at all. | L | planned (M3) |
| Synced playback | GoodNotes replays strokes with the audio and links timestamps. | Not present. | L | planned (M3) |
| Transcripts | GoodNotes transcribes in 99 languages and summarises recordings. | Not present. | L | planned (M3) |

## Polish and UX

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| Liquid Glass | GoodNotes 7.1 adopts the iOS 26 design. | Our chrome is mostly stock SwiftUI and uneven. | M | today (UI polish) |
| Animated toolbar | GoodNotes' floating toolbar slides in and out and can be moved and hidden. | Toolbar choices exist, but no animation and no free placement. | M | today (UI polish) |
| Customisable toolbar | GoodNotes picks which tools sit on the toolbar. | Partly done ("toolbar choices" in Settings). | S | today (UI polish) |
| Battery | GoodNotes backs up less often to save battery. Reviewers notice drain. | No battery work. Sync, OCR and backup cadence are not tuned for it. | M | today |
| Clickable links | GoodNotes makes pasted URLs clickable. | Text boxes do not detect web links. | S | done Nov 2 |
| Highlight typed text | GoodNotes highlights text in text boxes. | Text boxes have colour but no highlight. | S | open |
| Polished first run | Both ship large template and sticker libraries. | A tutorial notebook and a few stickers. | L | non-goal (marketplace) |

## Platform

| Gap | What they do | What we lack | Effort | Status |
|---|---|---|---|---|
| iPhone | Both run on iPhone. | The target allows it but nothing is designed for it. | L | planned (M5) |
| Windows, Android, web | Both run everywhere. | Apple only. | L | non-goal (native), planned (M7 web viewer) |
| Mac shortcuts and menus | GoodNotes has a full menu bar and shortcuts for rename, print, find and the sidebar. | Only zoom shortcuts and Space to pan. | M | planned (M5) |
| Pencil Pro | GoodNotes uses squeeze and hover. | Squeeze and double tap work. Barrel roll and hover preview do not. | M | planned (M5) |
| Shortcuts and Spotlight | Both appear in Spotlight and Shortcuts. | No App Intents, Spotlight or Quick Look. | M | planned (M5) |
| Importers | Users expect to bring their GoodNotes and OneNote notes. | No importer. | L | planned (M5 spike) |
| External display | GoodNotes shows a clean page on a second screen while you write. | Present mode is the same screen only. | M | open |
| Price | OneNote is free. GoodNotes is paid for most features. | Not a gap. Linework is free with no limits. | | |

## Top 8 quick wins not otherwise planned today

**Nov 2, 2026, evening: all eight are built** ([not built] on the branch: written, never compiled). See PLAN.md.

Ranked by value for the effort. Each is small, needs no backend and fits SwiftUI and PencilKit. Each was confirmed missing in the code.

1. **Finger drawing setting (S).** `PKCanvasViewDrawingPolicy.mystNotes` is hard coded to `.pencilOnly` on iPad. Add a Settings toggle for `.anyInput`. Anyone without a Pencil can then write at all.
2. **Ruler (S).** Set `PKCanvasView.isRulerActive` from a toolbar button. PencilKit draws and snaps to it already. Both competitors have one.
3. **Laser pointer in Present (S).** A finger or Pencil trail drawn in an overlay that fades after a second. Nothing is saved, so no format or sync work.
4. **Duplicate page and go to page (S).** Duplicate copies the `.strokes` record under new page and stroke ids through `DrawingStore`. Add a "3 of 20" indicator that opens a page-number field.
5. **Paper colour and line spacing (S).** White, cream and dark paper, and narrow, medium and wide ruling. `PageTemplate` is the one ruling renderer, so it changes in one place. Store it on the page with the template.
6. **Page grid view with multi-select (M).** A full-screen `LazyVGrid` of the existing cached thumbnails. Select many to delete, move, copy or export. Reuses `PageThumbnailRenderer` and `Copy to Notebook`.
7. **Zoom window (M).** A magnified writing strip at the bottom that maps strokes back onto a box on the page and advances along the line. It is the most praised GoodNotes tool for small handwriting.
8. **Library sort and list view (S).** A sort picker (name, created, modified, each way) and a list mode. Store the choice in `AppSettings`.

Just outside the eight: OCR on imported photos, print, object lock, and clickable links in text boxes. All four are `S`.

## Sources

- [GoodNotes: What's new, July to September 2026](https://www.goodnotes.com/blog/whats-new-in-goodnotes-july-september-2026)
- [GoodNotes: What's new, April to June 2026](https://www.goodnotes.com/blog/whats-new-in-goodnotes-april-june-2026)
- [GoodNotes: October to December 2025](https://goodnotes.com/blog/features-fixes-updates-december-2025)
- [GoodNotes: July to September 2025](https://www.goodnotes.com/blog/features-fixes-updates-september-2025)
- [GoodNotes: April to June 2025](https://goodnotes.com/blog/features-fixes-updates-june-2025)
- [GoodNotes: January to March 2025](https://www.goodnotes.com/blog/features-fixes-updates-march-2025)
- [GoodNotes: Ask Goodnotes, Math Assist and handwriting editing](https://www.vktr.com/the-wire/goodnotes-elevates-productivity-for-its-24m-users-with-new-ai-powered-enhancements/)
- [TapSmart: GoodNotes 6.5 review](https://www.tapsmart.com/apps/goodnotes-6-5-review/)
- [NotePlan: GoodNotes vs OneNote](https://noteplan.co/blog/goodnotes-vs-onenote)
- [AFFiNE: GoodNotes vs OneNote](https://affine.pro/vs/goodnotes-vs-onenote)
- [GummySearch: note-taking apps on Reddit](https://gummysearch.com/tools/best-products/note-taking-app/)
- [Microsoft: Immersive Reader in OneNote](https://support.microsoft.com/en-au/office/use-immersive-reader-to-hear-your-notes-d248423e-9d91-48f5-9be2-4b17a5fc4e1b)
- [Copilot in OneNote for iPad and Mac](https://elevenforum.com/t/copilot-functionality-has-come-to-onenote-for-ipad-and-mac.29812)
- [UC Today: OneNote revamp (ruler)](https://www.uctoday.com/unified-communications/microsoft-reveals-onenote-revamp/)

Web coverage of OneNote for iPad in 2025 and 2026 is thin. OneNote rows describe long-standing features. Some, such as ink replay and the math assistant, are Windows-first and may be limited on iPad.
