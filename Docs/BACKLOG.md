# BACKLOG

Anything noticed mid-milestone that isn't in the current task lands here instead of in the code. Review at each milestone boundary.

## Format: `[M?] item — why it matters`

---

## Found during the code read (Sept 12, 2026)

- [M0] `MystNotesDetailView` is 1365 lines. Not urgent, but it will fight you during M2/M3. Split it as its own commit when it starts hurting, not as a side effect.
- [M1] `AppSettings.syncEnabled` becomes partly meaningless once `FileStore`'s ubiquity path is deleted — audit what the toggle should actually mean afterwards
- [M1] `copyFiles` is best-effort and silently skips a file that hasn't synced yet. Surface that as a visible "N files still downloading" state rather than a silent partial pull.
- [M1] Export currently covers page and notebook. Add whole-library export as the trust feature.
- [M2] `Link` has an anchor rect already — reuse it for graph edge anchors rather than inventing a second anchoring model
- [M3] `Page.ocrUpdatedAt` vs drawing file mtime is the existing staleness check. The stroke timeline gives a better signal; revisit then.
- [?] `LoginView` exists but there's no backend. Decide whether it stays, becomes a local profile, or gets removed before ship.

## Found while building the sync harness (Sept 12, 2026)

- [M0] A notebook whose `notebooks/<id>.json` never arrives (deleted by hand, lost by the provider) stays pending forever on the puller: its settings show, its pages don't, and the puller never publishes its own copy of it. Needs a designed state ("waiting for 1 notebook") and eventually a way out. Fits task 8/13.
- [M0] Every push hashes every local payload (cached within one run, not across runs). Fine at today's library size; at 200 notebooks with imported PDFs it's seconds of reading per push. Persist the hash next to the model (`Page.drawingHash` set by `DrawingStore.save`, likewise for imports) when it starts to show in task 20's baseline.
- [M0] Superseded payload versions accumulate in `files/` by design (content addressing never overwrites). Task 11's pruning must keep anything referenced by *any* notebook file present in the folder, plus a grace period, so a notebook file that hasn't arrived yet can't lose its ink.
- [M0] **Decision needed: trash retention.** Nothing is ever deleted now — deleted pages, conflict losers, unreadable files, superseded payloads and tombstoned notebook files all go to a `trash/` beside where they lived, locally and in the folder. That grows without bound. Proposed: keep 30 days locally and in the folder, then remove; surface "N items in trash, oldest X days" in Settings with a Restore. The removal itself is the one place `removeItem` on ink would be allowed, and only after that period.
- [M0] Local `Documents/` orphans (a payload no `Page` references, e.g. from before task 11) aren't pruned; only the folder is. Add a local pass with the same grace rule once task 19's rebuild path exists, since that's when "what does the index reference" becomes authoritative.
- [M0] A build from before task 5 can't decode a snapshot containing a `kind: "page"` tombstone (enum decode fails, whole `library.json` rejected). Only matters while a pre-task-5 build is still installed anywhere; the format split in task 6 should carry a real version gate.
- [M0] `pushPayloads` replaces the folder's copy of a drawing file in place when the local page won. Folder-side history of superseded versions is task 7/11 territory; the loser device keeps its own copy in its local `trash/`.
- [M0] `LibrarySnapshot.referencedFileNames` derives from `drawingFileRef`, so a page whose file was written but whose `context.save()` never ran (kill between the two) has ink on disk that never syncs. Derive the drawing file name from `page.id` instead; the ref is redundant with the id. Fold into task 6/10.

## Parked from planning (Sept 12, 2026)

- [M1] Scanned document capture with `VisionKit` + Live Text — Apple Notes parity, cheap
- [M1] Collapsible sections, tables, checklists in typed content
- [M2] Graph clustering / level-of-detail rendering — only needed above ~1000 nodes, benchmark first
- [M2] Auto-suggested links from semantic similarity — depends on M4 embeddings, so sequence after
- [M3] Multi-track audio (mic + system audio for recorded calls)
- [M4] 3D graphing of equations — Apple Notes shipped this in iOS 26
- [M5] Quick Note-style system-wide capture
- [M5] Drag and drop between MystNotes and other apps on Mac
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
