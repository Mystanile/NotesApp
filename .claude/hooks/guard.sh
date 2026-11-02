#!/bin/bash
# PreToolUse guard: invariant 3 (no removeItem outside TrashRetention) and no commit without a green test log.
IN=$(cat)
TOOL=$(jq -r '.tool_name' <<<"$IN")
if [[ "$TOOL" == "Edit" || "$TOOL" == "Write" ]]; then
  FILE=$(jq -r '.tool_input.file_path' <<<"$IN")
  NEW=$(jq -r '.tool_input.new_string // .tool_input.content // ""' <<<"$IN")
  if [[ "$FILE" == *.swift && "$FILE" != *TrashRetention.swift && "$FILE" != */MystNotesTests/* ]] && grep -q "removeItem" <<<"$NEW"; then
    echo "Blocked: invariant 3. Use DrawingStore.moveToTrash, not removeItem, on a payload. If this is not a payload, ask the user." >&2; exit 2
  fi
elif [[ "$TOOL" == "Bash" ]]; then
  CMD=$(jq -r '.tool_input.command' <<<"$IN")
  if grep -q "git commit" <<<"$CMD"; then
    # Cloud exemption (decided by the user, Nov 2, 2026): a machine without Xcode cannot run the
    # suite at all. There, and only there, a commit may go in if its message says "[not built]",
    # so nobody mistakes it for tested work. The removeItem guard above is unaffected.
    if ! command -v xcodebuild >/dev/null 2>&1 && grep -q "\[not built\]" <<<"$CMD"; then
      exit 0
    fi
    ROOT="${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd' <<<"$IN")}"
    LOG="$ROOT/.claude/last-test.log"
    if ! grep -q "TEST SUCCEEDED" "$LOG" 2>/dev/null; then
      echo "Blocked: the last test run in .claude/last-test.log did not succeed. Run .claude/hooks/run-tests.sh first." >&2; exit 2
    fi
    # Changed Swift needs a full run made after the last edit.
    SWIFT=$(cd "$ROOT" && git diff HEAD --name-only -- '*.swift')
    if [[ -n "$SWIFT" ]]; then
      if grep -q "^ARGS: .*only-testing" "$LOG"; then
        echo "Blocked: the last test run was narrowed with -only-testing. Run the full suite before committing Swift changes." >&2; exit 2
      fi
      if [[ -n $(cd "$ROOT" && find $SWIFT -newer "$LOG" 2>/dev/null) ]]; then
        echo "Blocked: Swift files changed after the last test run. Run .claude/hooks/run-tests.sh again." >&2; exit 2
      fi
    fi
  fi
fi
exit 0
