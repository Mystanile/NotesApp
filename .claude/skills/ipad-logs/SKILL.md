---
name: ipad-logs
description: Pull Documents/diagnostics/app.log from the connected iPad and extract [hang] and [stall] main-thread stacks.
disable-model-invocation: true
---
1. `xcrun devicectl list devices` and pick the physical iPad (not "simulated").
2. `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.mozynas.Mystnotes --source Documents/diagnostics/app.log --destination <scratchpad>/app.log`
3. `grep -n -A40 "\[hang\]\|\[stall\]" <scratchpad>/app.log` and summarize each stack: when, the checkpoint, and the top app frames.
4. Match each to the open BACKLOG items (launch hang, saveCurrentPage stalls) and say what the stack shows. Do not change code from this skill.
