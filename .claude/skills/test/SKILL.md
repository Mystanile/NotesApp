---
name: test
description: Run the MystNotes test suite on the iPad simulator (boot, clear stale host, clean build) and report the result.
disable-model-invocation: true
---
Run `.claude/hooks/run-tests.sh $ARGUMENTS` with a 600000 ms timeout (pass `-only-testing:MystNotesTests/<Suite>` to narrow it).
The full log is `.claude/last-test.log`; the commit guard reads it.
Report pass/fail and the names of failing tests. If only `testLibraryOf200Notebooks` failed on time, rerun it alone before calling it a regression.
