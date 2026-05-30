---
id: gui/01
title: Wire Text tool to canvas handlers
status: ready-for-agent
priority: high
labels: [gui-linking, display]
---

# Wire Text tool to canvas handlers

## Problem

`Tool::Text` has a menu button and keyboard shortcut (T) but no interaction handler in `canvas.rs`. Clicking with Text tool active does nothing. `AddText` Command exists and is handled in `dispatch.rs:407` but never dispatched from UI.

## Acceptance criteria

- [ ] Text tool click on canvas opens inline text input or text dialog
- [ ] Submitting text dispatches `AddText { x, y, content }` at click position
- [ ] Text renders on canvas at placed position
- [ ] Undo/redo works for text placement

## Files

- `crates/display/src/canvas.rs` — add match arm for `Tool::Text` in click handlers
- `crates/handler/src/dispatch.rs:407` — handler already exists
