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

- [M0] `PageDTO` has no `aspectRatio`, so `rebuild()` resets every page's shape to default on a remote-wins merge, and an imported PDF page's aspect never syncs at all. Fold into task 5/6 when `PageDTO` gains `modifiedAt`.
- [M0] `library.json` dates are ISO-8601 whole seconds, but `lastPulledExportDate` is stored at full precision after a push. Two devices acting inside the same wall-clock second compare truncated against untruncated values. Harmless in practice today; fix as part of task 6 rather than separately.
- [M0] Reversed §1.2 ordering (iPad syncs before the Mac) happens to pass today because payload files travel independently of the metadata merge. Add it as a second `SyncTests` case once per-page merge lands so both orders are pinned.

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
