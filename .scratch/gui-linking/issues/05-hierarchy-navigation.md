---
id: gui/05
title: Hierarchy navigation (descend/ascend schematic)
status: needs-info
priority: medium
labels: [gui-linking, display, handler]
---

# Hierarchy navigation

## Problem

Menu buttons for hierarchy navigation exist in `chrome.rs` but permanently disabled. No handler support for subcircuit entry/exit, breadcrumb tracking, or symbol/schematic switching.

## Blocked by

- S2S issue 02 (hierarchical subcircuit import) — need multi-sheet model first
- Handler needs concept of "current sheet" within a hierarchy

## Acceptance criteria

- [ ] Double-click subcircuit instance → descend into child schematic
- [ ] Breadcrumb bar shows hierarchy path
- [ ] "Ascend" action returns to parent
- [ ] Menu items enabled when hierarchy available

## Files

- `crates/display/src/chrome.rs:444-454` — currently disabled stubs
- `crates/handler/src/` — needs new Commands (DescendHierarchy, AscendHierarchy)
- `crates/core/src/commands.rs` — add hierarchy Commands
