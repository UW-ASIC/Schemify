# schemify_display

GUI frontend built on [egui](https://github.com/emilk/egui). Renders the schematic canvas, menus, dialogs, panels, and handles all user interaction. Runs natively via eframe and in the browser via WASM.

## Files

### `lib.rs` — App entry point

`SchemifyApp` wraps the handler `App` and theme tokens. Entry points:
- `run_gui()` — native desktop (eframe).
- `wasm_start()` — web/WASM with project bundle loading.

`KeyCommand` enum adds GUI-only actions (`EnterCommandMode`, `SetViewSchematic`, `SetViewSymbol`, `SetViewDoc`) on top of the core `Command` pipeline.

### `canvas.rs` — Schematic canvas

Rendering and interaction for the main drawing area.

**Rendering layers** (called in order):
- `render_grid()` — dot grid + origin crosshair.
- `render_wires()` — wire segments, junctions, endpoint dots, net names.
- `render_instances()` — component symbols from built-in primitives.
- `render_geometry()` — lines, rects, circles, arcs, polygons, text.
- `render_symbol_pins()` — pin crosshairs with direction indicators (symbol view).
- `render_auto_symbol_box()` — auto-generated symbol bounding box.
- `render_selection()` — highlight overlays for selected items.
- `render_overlays()` — wire preview, placement ghost, drawing tool preview, rubber band.

**Interaction handlers:**
- `handle_mouse_press()` — tool activation, selection, wire start.
- `handle_mouse_drag()` — move, pan, rubber band, wire routing.
- `handle_mouse_release()` — finalize operations.
- `handle_scroll_zoom()` — scroll wheel zoom centered on cursor.
- `handle_space_key()` — pan toggle.

**How to add a new rendering layer:**
1. Create a `render_xyz()` function.
2. Call it from `show()` in the appropriate z-order position.

**How to add a new drawing tool:**
1. Add a `Tool` variant in `core/src/commands.rs`.
2. Handle click logic in `handle_draw_click()`.
3. Handle preview rendering in `draw_drawing_preview()`.

### `chrome.rs` — Menus, tabs, status bar, vim commands

**Menus:** File, Edit, View, Place, Hierarchy, Simulate, Plugins, Help — each dispatches `Command` variants.

**Vim command mode:** Type `:` to enter, then commands like `w`, `q`, `wire`, `sim`, `rotatecw`, `find`, `schematic`, `symbol`, etc.

**How to add a new menu item:**
1. Add the item in the appropriate menu function (`file_menu()`, `edit_menu()`, etc.).
2. It should call `app.dispatch(Command::YourCommand)`.

**How to add a new vim command:**
1. Add a match arm in `parse_vim_command()`.

### `dialogs.rs` — Modal dialogs

| Dialog | What it does |
|--------|-------------|
| `properties()` | Edit instance name, position, rotation, flip, custom properties. |
| `find()` | Search instances by name with arrow navigation. |
| `settings()` | Tabbed: Theme (token editor with presets) and Keybinds (reference table). |
| `import()` | Format selector (Spice, Xschem, Virtuoso) with path input. |
| `spice_code()` | SPICE analysis code editor with optional side-by-side netlist. |
| `new_primitive()` | Create a .chn_prim file from name, prefix, and pin list. |

**How to add a new dialog:**
1. Create a function that takes `&mut App`, `&egui::Context`, and dialog state.
2. Call it from `show_all()`.
3. Add a `Command` variant to open it (e.g., `OpenMyDialog`).

**How to add a new import format:**
1. Add a variant to the `ImportFormat` enum in dialogs.
2. Implement the import logic in `handler`.

### `highlight.rs` — Syntax highlighting

SPICE and LaTeX highlighters producing `egui::text::LayoutJob` with colored spans.

**SPICE tokens:** comments, directives, component prefixes, numbers with SI suffixes, strings, keywords.

**LaTeX tokens:** commands, math delimiters, groups, environments, Greek letters, operators.

**How to add a new SPICE keyword:**
Add it to the appropriate constant array (`DIRECTIVES`, `KEYWORDS`, etc.).

### `keybinds.rs` — Keyboard shortcuts

65 keybinds defined in the `KEYBINDS` array. Each maps a key combo to a `KeyCommand`.

**How to add a new keybind:**
1. Append to `KEYBINDS` using the `kb()` helper.
2. If the action is GUI-only (not a core `Command`), add a `KeyCommand` variant.

### `math_render.rs` — LaTeX math rendering

Parses a subset of LaTeX into a `MathNode` AST and renders to egui. Supports Greek letters, operators, `\frac`, `\sqrt`, superscripts, subscripts, and common symbols via Unicode conversion.

**How to add a new LaTeX command:**
Add a match arm in `latex_symbol()` mapping `\yourcommand` to a Unicode character.

### `panels.rs` — Sidebars, file explorer, library, doc view

- **File explorer** — browse project directory (native) or document list (WASM), plus example files.
- **Library browser** — list all 36 built-in primitives; click to select, double-click to place.
- **Welcome screen** — shown when no file is open.
- **Doc view** — edit/preview tab with LaTeX+Markdown rendering.
- **Plugin panels** — render `WidgetNode` trees from plugins into their registered slots.
- **Context menu** — right-click options (cut, copy, paste, delete, rotate, flip, wire color).

**How to add a new panel:**
1. Create a rendering function.
2. Call it from the appropriate sidebar layout.

### `theme.rs` — Theme resolution

Resolves `ThemeTokens` from core into egui `Color32` values. Provides `CanvasPalette` (15 canvas colors) and `WidgetPalette` (7 widget colors) with `dark()`/`light()` presets and `from_tokens()` fallback resolution.

**How to add a new palette color:**
1. Add a field to `CanvasPalette` or `WidgetPalette`.
2. Add a corresponding theme token in `core/src/theme.rs`.
3. Resolve it in `from_tokens()`.
