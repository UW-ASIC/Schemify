# A5: Panels + Dialogs

**Wave**: 2
**Depends on**: A3 (canvas scaffold must exist)

## Goal
All UI chrome around the canvas: tab bar, toolbar, command bar, side panels, dialogs. Each panel/dialog dispatches commands through `AppWrite`. Plugin slots integrated where panels mount.

## Branch
`feat/panels-dialogs`

## Zig Reference Files
- `../Schemify/src/gui/bars.zig` — toolbar, tab bar, command bar
- `../Schemify/src/gui/dialogs.zig` — modal dialogs
- `../Schemify/src/gui/settings.zig` — settings panel + keybind/theme persistence
- `../Schemify/src/gui/welcome.zig` — welcome/splash screen
- `../Schemify/src/gui/doc_view.zig` — documentation view
- `../Schemify/src/gui/Panels/file_explorer.zig` — file browser
- `../Schemify/src/gui/Panels/library.zig` — symbol library
- `../Schemify/src/gui/Panels/marketplace.zig` — plugin marketplace
- `../Schemify/src/gui/Panels/context_menu.zig` — right-click menu

## Crate/File Map

### display (`crates/display/src/`)
- NEW `tab_bar.rs` — multi-document tabs (name, dirty indicator, close button)
- NEW `toolbar.rs` — tool buttons (select, wire, move, draw tools), zoom controls
- NEW `command_bar.rs` — text command entry, command parsing
- NEW `file_explorer.rs` — project tree panel (left sidebar slot)
- NEW `library_browser.rs` — primitive catalog panel (left sidebar slot)
- NEW `dialogs/mod.rs` — dialog module root
- NEW `dialogs/properties.rs` — instance property editor
- NEW `dialogs/find.rs` — search instances/nets
- NEW `dialogs/settings.rs` — theme JSON editor, keybind editor
- NEW `dialogs/import.rs` — import format selection + path
- NEW `dialogs/spice_code.rs` — SPICE code editor
- NEW `dialogs/new_primitive.rs` — primitive creation wizard
- NEW `status_bar.rs` — bottom status line (status_msg, cursor coords, tool name)
- NEW `slot_renderer.rs` — renders plugin panels into their assigned slots

## Layout Structure

```
+------------------------------------------+
| Tab Bar (doc tabs)                        |
+------+---------------------------+-------+
| Tool |                           | Right |
| bar  |       Canvas (A3)         | Side  |
|      |                           | bar   |
| Left |                           | slot  |
| Side |                           |       |
| bar  |                           |       |
| slot |                           |       |
+------+---------------------------+-------+
| Status Bar (slot)                         |
+------------------------------------------+
```

Slots (`SlotId` from A2):
- `LeftSidebar` — file explorer, library browser, plugin panels
- `RightSidebar` — plugin panels (empty by default)
- `BottomBar` — plugin panels (empty by default)
- `Toolbar` — tool buttons + plugin-injected buttons
- `MenuBar` — future (not in wave 2)
- `StatusBar` — status msg + cursor + tool

## Checklist

### Bars
- [ ] Tab bar: render doc tabs, click to switch, close button, dirty indicator
- [ ] Toolbar: tool buttons with active state, zoom +/- /fit/reset buttons
- [ ] Command bar: text input, parse → Command, dispatch
- [ ] Status bar: status_msg, cursor world coords, active tool name
- [ ] Commit

### Panels
- [ ] File explorer: directory tree, click to open .chn file
- [ ] Library browser: list PrimEntry names, click to start placement
- [ ] Slot renderer: iterate `SlotId`, render registered plugin panels in order
- [ ] Panel show/hide toggle (keybind or menu)
- [ ] Commit

### Dialogs
- [ ] Properties dialog: show instance props, edit values, apply → SetInstanceProp command
- [ ] Multi-select properties: common props across selected instances
- [ ] Find dialog: text search across instance names/net names, click to select + zoom
- [ ] Settings dialog: theme token editor, keybind editor, preset selector
- [ ] Import dialog: format dropdown, path picker, trigger ImportSpice command
- [ ] SPICE code editor: textarea for schematic.spice_body, apply → SetSpiceCode
- [ ] New primitive dialog: type selector, name, pin list, create stub .chn_prim
- [ ] Commit

### Integration
- [ ] All dialogs read state from handler (GuiState, DialogStates)
- [ ] All mutations go through `AppWrite::dispatch()`
- [ ] File dialog (native OS) for open/save via `rfd` crate
- [ ] Commit after each meaningful change

## Do NOT Touch
- `canvas.rs` / `render.rs` / `interaction.rs` — A3's territory
- `handler/src/dispatch.rs` — commands already handled
- `sim/` — not your crate
- `plugins/` — not your crate
