---
id: gui/06
title: Verify bus mode flag propagates to AddWire
status: done
priority: medium
labels: [gui-linking, display]
---

# Verify bus mode wiring

## Problem

Menu checkbox toggles `app.state.tool.bus_mode` but unclear if `AddWire` command receives `bus=true` in all code paths. Some paths may hardcode `bus=false`.

## Acceptance criteria

- [x] Audit all `AddWire` dispatch sites in canvas.rs — only 1 site (line 2044)
- [x] Confirm bus_mode flag propagates from tool state → AddWire { bus } — correct (line 2043)
- [x] Fix any hardcoded `bus: false` paths — none found
- [x] Add test: enable bus mode → draw wire → verify AddWire has bus=true — handler/src/lib.rs
