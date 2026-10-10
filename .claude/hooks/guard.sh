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
    LOG="$(jq -r '.cwd' <<<"$IN")/.claude/last-test.log"
    if ! grep -q "TEST SUCCEEDED" "$LOG" 2>/dev/null; then
      echo "Blocked: the last test run in .claude/last-test.log did not succeed. Run .claude/hooks/run-tests.sh first." >&2; exit 2
    fi
  fi
fi
exit 0
