# gui

All rendering, input handling, and visual state. Immediate-mode UI built every frame from application state.

## Responsibility

- Frame orchestrator: toolbar -> tabbar -> canvas/sidebars -> overlays -> dialogs
- Canvas: schematic rendering, symbol drawing, wire rendering, interaction
- Panels: file explorer, library browser, marketplace, context menu, plugin panels
- Input: keyboard/mouse handling, vim-first keybinds
- Bars: toolbar, tab bar, command bar, status bar
- Dialogs: all modal dialogs
- State: AppState, Document, Selection, Viewport, Clipboard
- Theme: palette definitions, live theme application
- Welcome screen for empty state

## Boundaries

- `state.zig` is a **separate build module** ("state") to break the gui <-> commands cycle
- Does NOT mutate schematic directly — enqueues Commands
- Owns all per-frame visual state; persistent state owned by AppState

## Dependencies

- `schematic` — types for rendering (Instance, Wire, Pin, geometry)
- `commands` — Command types for enqueue
- `plugins` — PluginHost for panel rendering
- `settings` — user config (theme, keybinds)
- `simulation` — results for display
- `import` — for import dialogs
- `dvui` — GUI framework
- `utility` — platform helpers

## Key Files

| File | Purpose |
|------|---------|
| `lib.zig` | Frame orchestrator |
| `state.zig` | AppState, Document, Selection (separate build module) |
| `theme.zig` | Palette, theme overrides (separate build module) |
| `bars.zig` | Toolbar, tab bar, command bar |
| `welcome.zig` | Empty-state welcome screen |
| `actions.zig` | Command enqueue helpers |
| `Canvas/` | Schematic canvas (render, symbols, wires, overlays, interaction) |
| `Panels/` | File explorer, library, marketplace, context menu |
| `Dialogs/` | Modal dialogs |
| `Input/` | Keyboard/mouse handlers |
