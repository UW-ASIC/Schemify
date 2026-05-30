# 03 — Audit every GUI control → Command wiring

Status: done
Labels: audit
Crate: schemify-display
Complexity: M
Depends on: ~~gui-linking/01~~ ✅

## Audit Results (2026-05-30)

190 Command dispatch sites across display crate. gui/01 landed — display compiles.

### Tools — all wired ✅

- ✅ SetTool(Select) — keybinds.rs, chrome.rs, canvas.rs
- ✅ SetTool(Wire) — keybinds.rs, chrome.rs
- ✅ SetTool(Move) — keybinds.rs, chrome.rs (vim only, not in Place menu)
- ✅ SetTool(Pan) — keybinds.rs only (not in menu)
- ✅ SetTool(Text) — keybinds.rs, chrome.rs, canvas.rs click handler (gui/01)
- ✅ SetTool(Line/Rect/Circle/Arc/Polygon) — chrome.rs

### File operations — all wired ✅

- ✅ FileNew, FileOpen, FileSave, FileSaveAs — chrome.rs + keybinds.rs
- ✅ NewTab, CloseTab, SwitchTab — chrome.rs tab bar
- ✅ ReloadFromDisk — chrome.rs
- ✅ ImportSpice — dialogs.rs:664

### Edit operations — all wired ✅

- ✅ Undo/Redo — chrome.rs, keybinds.rs
- ✅ Cut/Copy/Paste — chrome.rs, keybinds.rs, panels.rs
- ✅ DeleteSelected — chrome.rs, keybinds.rs, panels.rs
- ✅ DuplicateSelected — chrome.rs, panels.rs
- ✅ RotateCw/RotateCcw — chrome.rs, keybinds.rs, panels.rs
- ✅ FlipHorizontal/FlipVertical — chrome.rs, keybinds.rs, panels.rs
- ✅ AlignToGrid — chrome.rs
- ✅ SelectAll/SelectNone/InvertSelection — chrome.rs

### View — all wired ✅

- ✅ ZoomIn/ZoomOut/ZoomFit/ZoomReset — chrome.rs, keybinds.rs
- ✅ ToggleGrid — chrome.rs, keybinds.rs
- ✅ ToggleFullscreen/ToggleColorScheme — vim commands

### Simulation — wired ✅

- ✅ RunSim — chrome.rs
- ✅ SetSimBackend — chrome.rs
- ✅ SetStimulusLang — chrome.rs (gui/04)
- ✅ ExportNetlist — dialogs.rs
- ✅ SetSpiceCode — dialogs.rs

### Commands NEVER dispatched from display

| Command | Status | Notes |
|---------|--------|-------|
| AddPolygon | ⚠️ by design | Uses `commit_polygon()` which dispatches internally |
| DeleteInstance(idx) | ⚠️ by design | Uses SelectNone + DeleteSelected pattern |
| MoveInstance/MoveWire | ⚠️ by design | Uses MoveSelected pattern |
| PluginMutation | ❌ dead | Core exists, never sent from UI — gui/08 |
| RenameNet | ❌ unwired | No UI for net renaming |

### Disabled menu stubs (11 items)

- ❌ Export SVG — chrome.rs:216 (enabled=false)
- ❌ Descend Schematic/Symbol — chrome.rs:470,473 (hierarchy, needs s2s/02)
- ❌ Ascend — chrome.rs:476
- ❌ Edit in New Tab — chrome.rs:480
- ❌ Highlight Selected Nets — chrome.rs:523 (gui/07)
- ❌ Unhighlight All — chrome.rs:526 (gui/07)
- ❌ Clear Sim Cache — chrome.rs:533
- ❌ Reload Config — chrome.rs:594

### Selection bypasses Command pattern

Canvas uses direct `app.select_instance()`, `app.select_wire()` etc. instead of
dispatching Commands. These ARE undoable via handler methods but don't flow
through `dispatch()`. Architectural note — not a bug, but worth tracking.

## Acceptance criteria

- [x] `display` compiles and GUI launches
- [x] Checklist marks every control as ✅ wired or ❌ + follow-up
- [x] No `Command` variant constructed in display that core does not define
