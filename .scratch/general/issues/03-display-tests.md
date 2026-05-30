---
id: gen/03
title: Add unit tests to display crate
status: ready-for-agent
priority: high
labels: [testing, display]
---

# Display crate unit tests

## Problem

Zero unit tests across 8 modules (~280 LOC). Canvas rendering, geometry projection, keybindings, dialogs, panels, chrome, highlighting, theme — all untested.

## Acceptance criteria

- [ ] Keybind mapping tests (shortcut → Command)
- [ ] Viewport math tests (grid↔screen coordinate transforms)
- [ ] Theme color resolution tests
- [ ] Dialog state machine tests (open/close/submit)
- [ ] Panel layout tests where feasible (state, not rendering)

## Notes

egui rendering hard to unit-test. Focus on logic/state, not pixel output.
