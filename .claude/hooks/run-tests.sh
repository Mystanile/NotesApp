#!/bin/bash
# Boots the iPad simulator, clears a leftover test host, runs a clean test, logs to .claude/last-test.log.
# Usage: run-tests.sh [-only-testing:MystnotesTests/SomeTests]   (the target has a lowercase n; the folder is MystNotesTests/)
UDID=67C1BFB0-4C9B-4960-96CE-24FDCD32DC7F
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$ROOT/.claude/last-test.log"
xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl terminate $UDID com.mozynas.Mystnotes 2>/dev/null
cd "$ROOT" && xcodebuild clean test -scheme MystNotes -destination "id=$UDID" "$@" > "$LOG" 2>&1
grep -E "error:|failed \(|TEST SUCCEEDED|TEST FAILED|Executed [0-9]+ tests" "$LOG" | tail -30
