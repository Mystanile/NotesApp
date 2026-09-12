# SPIKE: What iCloud Drive does with concurrent writes to a user-picked folder

**For:** M0 task 8 — "Read and resolve `NSFileVersion` conflict versions instead of ignoring them."
**Time box:** about 45 minutes with both devices in hand.
**Branch/build:** `m0-correctness` at `9e4c25d` or later, Debug configuration, on **both** the iPad and the Mac (Catalyst). Debug matters: the *Write Sync Diagnostics* button in Settings only exists in Debug builds.
**Result goes in:** §5 of this file. Task 8's design is decided by what you write there, not by what anyone assumes.

---

## 1. What we don't know

Everything the engine reads from the folder — `index.json`, `tombstones.json`, `notebooks/<id>.json` — can be written by two devices while both are offline. When they come back online, iCloud Drive has two versions of the same path and has to do *something*. Apple documents `NSFileVersion` conflict handling for documents in an app's **own** ubiquity container. Our folder is a **user-picked** folder reached through a security-scoped bookmark, and that's the case the documentation doesn't cover. Four outcomes are plausible:

| # | Outcome | What task 8 would then be |
|---|---|---|
| A | One file survives silently; the other write is gone | Nothing to detect — the engine's per-page merge and union-merged tombstones already make the next push repair it. Task 8 becomes "prove that repair with a test" and close. |
| B | One file at the path, and `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` lists the other(s) | Read every conflict version, merge them all (union tombstones, per-page merge each notebook file, latest index wins per entry), then `removeAndResolve`. What the plan assumes. |
| C | A renamed sibling appears — `index 2.json`, `index (Mohammad's iPad).json`, `.icloud`-style names | Scan for siblings by name pattern and merge them like B, then move the sibling to `trash/`. |
| D | Behaviour differs between iPad and Mac Catalyst (sandbox bookmark vs. `~/Library/Mobile Documents`) | Whichever of A–C applies per platform, with a test per platform in task 18. |

Secondary questions worth answering on the same run because they gate tasks 13 and 14:

- Does `.ubiquitousItemHasUnresolvedConflicts` on a URL ever go `true`? (Cheap detection if it does.)
- Does `startDownloadingUbiquitousItem` through the bookmark actually pull an evicted file, and does `ubiquitousItemDownloadingStatus` report `notDownloaded` for it beforehand? (Task 14.)
- Roughly how long does a file take to land on the other device? (Task 13's polling interval, and task 18's timing.)

---

## 1.5 Already checked from the Mac (Sept 12, 2026, unsandboxed Swift process)

Run before the two-device experiment, against `iCloud Drive/MystSpike/probe/` (since removed). It narrows the question but does not answer it:

- A file written into a user folder under iCloud Drive **is** a ubiquitous item (`isUbiquitousItem=true`, status `current`), and `NSFileVersion.currentVersionOfItem(at:)` answers for it. `otherVersionsOfItem` and `unresolvedConflictVersionsOfItem` return empty arrays, not nil — so the API is live for user-folder files, at least outside the sandbox. Outcome B is *possible*; whether iCloud actually produces conflict versions here is still the open question.
- A second write from the same Mac records **no** local "other version": iCloud Drive keeps no per-write history for plain files. Any version that shows up during the experiment is a genuine cross-device conflict.
- `isUploaded` went `true` between 16 and 30 s after the write, with `brctl status` showing the daemon `caught-up`. Expect roughly that latency per hop.
- Not checked, because it needs the folder picker: whether all of the above holds **inside the Mac Catalyst sandbox through the security-scoped bookmark**, and anything on the iPad. §2's baseline diagnostics table is where that gets answered.

## 2. Setup (once, ~10 min)

- [ ] Both devices signed into the **same** iCloud account, iCloud Drive on, Wi-Fi on.
- [ ] `iCloud Drive/MystSpike` already exists and is empty (left from §1.5). Use it. Do not use your real notes folder.
- [ ] Build and run the app on the **iPad** from Xcode (Debug). Settings → Sync → *Choose Sync Folder…* → `MystSpike`. Status should read "synced" (or similar) within a few seconds.
- [ ] Create one notebook, title `Spike`, with **4 pages**. Draw a distinct mark on each page (write the page number). Settings → *Sync Now*.
- [ ] On the **Mac** (Finder → iCloud Drive → MystSpike → Mystnotes), confirm you see `index.json`, `tombstones.json`, `notebooks/`, `files/`, `index-history/`. Note how long they took to appear: ______ s.
- [ ] Build and run on the **Mac** (Catalyst, Debug). Settings → Sync → choose `MystSpike`. Confirm the `Spike` notebook appears with 4 pages and the right marks.
- [ ] On **both** devices: Settings → *Write Sync Diagnostics*. Two files appear in `MystSpike/Mystnotes/diagnostics/`. Open one and confirm it lists every file with `isUbiquitousItem=true`. If it says `false` or `nil` on either device, **stop and record that in §5** — it means that device isn't seeing the folder as an iCloud item at all, which changes everything.

Baseline diagnostics, read from the Mac in Finder:

| Device | `isUbiquitousItem` on `index.json` | `currentVersion` non-nil? | `otherVersions` count |
|---|---|---|---|
| iPad | | | |
| Mac | | | |

---

## 3. The experiment: same file, two writers, both offline

The engine writes `index.json` and `tombstones.json` on every push, so this exercises exactly the conflict task 8 cares about. A page edit on each side guarantees `notebooks/<id>.json` conflicts too.

- [ ] **Go offline on both.** iPad: Control Center → Airplane Mode (and confirm Wi-Fi is off too). Mac: turn Wi-Fi off. Wait 10 s.
- [ ] **iPad:** open `Spike`, page 1, draw a big **"I"**. Go to Settings → *Sync Now*. Status should still say it succeeded — the write goes to the local copy of the folder. If it fails, write the message in §5 and continue anyway.
- [ ] **Mac:** open `Spike`, page 2, draw a big **"M"**. Settings → *Sync Now*. Same expectation.
- [ ] **Still offline, both:** Settings → *Write Sync Diagnostics*. (These reports show the offline state — `isUploaded=false` is expected.)
- [ ] **Go online on both** within a few seconds of each other. Start a timer.
- [ ] **Wait 2 minutes without touching the app on either device.** Watch `MystSpike/Mystnotes/` in Finder on the Mac. Record every file that appears, disappears, or is renamed in the table below. Sort Finder by *Date Modified*.
- [ ] After 2 min: **both** devices → *Write Sync Diagnostics*. (Do this *before* Sync Now — we want the OS's view before the engine touches anything.)
- [ ] Then **both** devices → *Sync Now*, iPad first, Mac 30 s later, then iPad again.
- [ ] Open `Spike` on both. Page 1 should show "I", page 2 should show "M". Record what you actually see.

### What appeared in the folder after coming online

Fill in from Finder. Names exactly as shown.

| Path | Present? | Duplicate/renamed sibling? (exact name) | Modified by (from Get Info or diagnostics) |
|---|---|---|---|
| `index.json` | | | |
| `tombstones.json` | | | |
| `notebooks/<Spike id>.json` | | | |
| `files/<page1 id>.drawing` | | | |
| `files/<page2 id>.drawing` | | | |
| anything else | | | |

### What the diagnostics said (post-online, pre-Sync Now)

From the two `diagnostics/*.txt` files written after the 2-minute wait. For `index.json` and the Spike notebook file:

| | iPad report | Mac report |
|---|---|---|
| `hasUnresolvedConflicts` | | |
| `otherVersions` count | | |
| `unresolvedConflictVersions` count | | |
| conflict version `by=` (which computer) | | |
| `head:` — whose `deviceName` is in the surviving file | | |

### What the app showed after Sync Now

| | iPad | Mac |
|---|---|---|
| Page 1 shows "I"? | | |
| Page 2 shows "M"? | | |
| Page count still 4? | | |
| `files/trash/` contains anything? | | |
| Sync status text | | |

---

## 4. Two short extras (skip if over time)

**Eviction (task 14).** On the Mac, in Finder, right-click `files/<page3 id>.drawing` → *Remove Download*. On the iPad, open `Spike` and go to page 3, then Settings → *Sync Now*, then *Write Sync Diagnostics*. Record: did page 3's mark still show? Diagnostics `downloadingStatus` for that file before and after: ______ / ______. Did the file come back in Finder?

**Tombstone conflict (task 9's union claim).** Both offline again. iPad: delete page 4 of `Spike`. Mac: create a second notebook `Other`, then delete it. Both *Sync Now* offline, both online, wait 2 min, *Write Sync Diagnostics*, *Sync Now* on both. Open `tombstones.json` on the Mac: does it contain **both** deletions (a `page` and a `notebook` kind)? ______. Did `Spike` end up with 3 pages on both devices? ______.

---

## 5. Result — fill this in

**Date run:** ________  **iOS / macOS versions:** ________ / ________

**Outcome (circle):** A — silent last-writer · B — `NSFileVersion` conflicts · C — renamed siblings · D — differs per platform

**Evidence (paste the relevant lines from the diagnostics files):**

```
```

**Anything that surprised you:**

**Decision for task 8:**

- [ ] A → write the "two offline pushes converge on the next round" test, close task 8.
- [ ] B → implement conflict-version reading in `readRemote`; merge every version; `removeAndResolve` after a successful merge.
- [ ] C → implement sibling scanning by pattern ______; merge; move sibling to `trash/`.
- [ ] D → both of the above, guarded per platform, with a task-18 test each.

**Timing observed:** file from iPad visible on Mac in ______ s; from Mac on iPad in ______ s. (Feeds task 13's `NSFilePresenter` decision and task 18.)

---

## 6. Cleanup

- [ ] On both devices: Settings → *Turn Off Folder Sync*, then re-pick your real folder if you had one.
- [ ] Leave `MystSpike` in iCloud Drive until task 8 is merged — the diagnostics files in it are the evidence.
