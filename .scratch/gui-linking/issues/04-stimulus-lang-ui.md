---
id: gui/04
title: Add UI for SetStimulusLang command
status: done
priority: medium
labels: [gui-linking, display, sim]
---

# Add UI for SetStimulusLang command

## Problem

`Command::SetStimulusLang` exists and is handled in `dispatch.rs:493` but no UI element dispatches it. Users cannot set simulation stimulus language from GUI.

## Acceptance criteria

- [ ] Stimulus language selector in Simulate menu or simulation settings dialog
- [ ] Selector dispatches `SetStimulusLang` with chosen variant
- [ ] Current stimulus language reflected in UI state

## Files

- `crates/display/src/chrome.rs` — add menu item or dialog entry
- `crates/display/src/dialogs.rs` — if using dialog approach
- `crates/handler/src/dispatch.rs:493` — handler already exists
