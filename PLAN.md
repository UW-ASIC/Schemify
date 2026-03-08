# Schemify — Development Plan (Zig 0.15.1, Data-Oriented)

---

## Guiding Principles

- **Data before code.** Types are plain structs. Functions operate on data; data does not own functions beyond `init`/`deinit`.
- **No hidden control flow.** No virtual dispatch except the Plugin VTable ABI (which must stay for ABI stability). Use `comptime` interfaces everywhere else.
- **Flat and explicit.** Prefer flat arrays (`ArrayListUnmanaged`, fixed arrays) over deep trees of heap objects.
- **One concern per file.** A file either owns data definitions OR logic that transforms data — not both.
- **GUI renders Schemify formats only.** The `gui/` layer, `state.zig`, and `command.zig` are aware of exactly three file types: `.chn` (schematic), `.chn_tb` (testbench), and `.chn_sym` (symbol). XSchem's `.sch` / `.sym` formats are **not** known to the GUI layer. `core/xschem.zig` exists solely as a conversion engine used by the future XSchem-import plugin. No `FileType::xschem_sch`, no `Origin::xschem_files`, no `initFromXSchem` calls anywhere outside `core/`.

### gui/ file standard (enforced from Phase 9 onward)

Every file in `src/gui/` must follow this exact layout:

```zig
//! One-line module description.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
// ...other imports...

// ── Layout constants (if any) ─────────────────────────────────────────────── //
const SOME_HEIGHT: f32 = 30;

// ── Local state ──────────────────────────────────────────────────────────── //
// All module-level mutable state lives here. Global state (view_mode,
// selection, etc.) belongs in AppState; only panel-local concerns go here.

pub const State = struct {
    // e.g. for renderer: drag tracking, cursor pos, symbol cache
    // e.g. for dialogs: open flag, window rect, per-dialog buffers
    field: Type = default_value,
};

pub var state: State = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

/// Draw this panel/dialog. Called once per frame from gui.zig.
pub fn draw(app: *AppState) void { ... }
```

Rules:
- Bare module-level `var` declarations are **forbidden** — all mutable module state goes in `State`.
- `pub fn draw(app: *AppState) void` is the single entry point called by `gui.zig`.
- If the panel needs init/deinit (e.g. to free a cache allocator), expose `pub fn init() void` / `pub fn deinit() void`.
- Dialog-state that was previously in `GuiState` (props buffers, lib browser entries, find query, etc.) moves into the owning file's `State` struct.

---

## Phase 0 — Remove XSchem from GUI/state layer

**Goal:** Enforce the Schemify-only rendering invariant. The GUI currently knows about XSchem `.sch` files; that must be removed so the constraint is upheld in code, not just docs.

### Tasks

1. `src/state.zig` — Remove `FileType.xschem_sch` and the `.sch` arm in `fromPath`. Add `FileType.sym` for `.sym` (Schemify symbol files).
2. `src/state.zig` — Remove `FileIO.Origin.xschem_files` union variant and `initFromXSchem`. Remove the `xschem_files` deinit branch.
3. `src/state.zig` — `openPath`: remove the `xschem_sch` dispatch arm; return `error.InvalidFormat` for any non-Schemify extension.
4. `src/command.zig` — `reload_from_disk`: remove the `xschem_files` match arm.
5. `src/toml.zig` — `legacy_paths.schematics` field may reference `.sch` paths; add a comment that these must be converted via the XSchem-import plugin before opening.

### Future: XSchem-import plugin

A separate plugin (`plugins/xschem_import/`) will:
- Accept a `.sch` / `.sym` path via its `on_command("import_xschem", …)` handler.
- Call `core.XSchem.readFile` + `.toSchemify()` internally.
- Write out a `.chn` / `.sym` (Schemify format) next to the original.
- The GUI then opens the resulting `.chn` file normally.

`core/xschem.zig` is **not** modified as part of this phase — it stays as the conversion engine.

**Status: ✅ DONE (applied 2026-03-08)**

---

## Phase 1 — slang-server static dependency

**Goal:** Add `https://github.com/hudson-trading/slang-server` as a Zig static dependency under `deps/slang/` so Schemify can parse SystemVerilog/Verilog netlists and provide LSP-based hover/diagnostics.

### Tasks

1. `deps/slang/` — clone as git submodule (like existing Xyce/ngspice pattern).
2. `deps/slang.zig` — write a `build.zig`-compatible wrapper (mirror `deps/xyce.zig`).
3. `deps/lib.zig` — add `pub const slang = @import("slang.zig");` export.
4. `build.zig` — add `addSpiceMods()`-style helper `addSlangDep(b, exe)` that links the static lib and exposes a `slang` module.
5. `src/core/FileIO.zig` — add a `SlangBackend` struct with the required `readFile`/`writeFile` surface so `FileIO(SlangBackend)` works for `.sv`/`.v` files.
6. `src/state.zig` — add `.sv` / `.v` to `FileType` and `openPath` dispatch.

**Agent A — research:** Read slang-server's `build.zig` / CMake to determine linking strategy.
**Agent B — impl:** Write `deps/slang.zig` and wire `build.zig` once Agent A reports back.

---

## Phase 2 — Rewrite State.zig (clean, data-oriented)

**Problem:** `src/state.zig` is 691 lines mixing CT types, a second `FileIO` struct (duplicates `core/FileIO.zig` behaviour), tool state, GUI state, plugin panels, marketplace state, viewport, selection, undo history, and `AppState` methods.

**Goal:** Split into cohesive, small files. `AppState` becomes a flat bag-of-data; logic moves to free functions or the existing module files.

### Proposed file layout after refactor

```
src/
  types.zig          ← CT (Point, Wire, Instance, Schematic, Symbol, Shape…)
                        Tool, CommandFlags, FileType, Sim
  document.zig       ← Document struct (replaces state.FileIO; wraps core/FileIO.zig)
                        Origin union, dirty flag, viewport-local state
  gui_state.zig      ← GuiState, PluginPanel, MarketplaceState, PluginKeybind
                        ToolState, GuiViewMode, PluginPanelLayout
  state.zig          ← AppState (data only: gpa, schematics, active_idx, history,
                        queue, view, selection, tool, cmd_flags, gui, log…)
                        init / deinit / allocator helper ONLY
  state_ops.zig      ← Free functions: openPath, newFile, saveActiveTo,
                        selectAll, registerPluginPanel*, togglePlugin*…
```

### Rules for the new `state.zig`

- `AppState` fields are all `pub` — no accessor methods.
- Only `init`, `deinit`, and `allocator()` live as methods (lifecycle only).
- All mutation logic moves to `state_ops.zig` and takes `*AppState` as first arg.
- `gui/` imports `state_ops` for all mutations; it never reaches into AppState internals directly.

### Tasks

1. Extract `CT` types → `src/types.zig`.
2. Extract `GuiState` and friends → `src/gui_state.zig`.
3. Replace `state.FileIO` with a thin `Document` wrapper in `src/document.zig` that delegates to `core.FileIO(Backend)`.
4. Slim down `src/state.zig` to data + lifecycle only.
5. Move all public methods (openPath, newFile, registerPluginPanel, etc.) → `src/state_ops.zig`.
6. Update all call-sites: `gui/`, `src/cli.zig`, `src/main.zig`, `src/command.zig`.
7. Update `build.zig` module graph (currently just `core` + `PluginIF`).

**Agent C:** Extract CT types + GuiState (no logic changes, pure moves).
**Agent D:** Write `state_ops.zig` by lifting methods out of AppState; update call-sites in `gui/`.

---

## Phase 3 — gui/ ↔ State clean connection

**Goal:** Every `gui/*.zig` file takes `*AppState` and calls `state_ops.*` — no direct field mutation outside `state_ops.zig`.

### Tasks

1. Audit each `gui/` file for direct `app.X = Y` mutations; route through `state_ops`.
2. `gui/renderer.zig` — reads `app.schematics[app.active_idx]` via `state_ops.active(app)` only.
3. `gui/actions.zig` — `enqueue` and `runGuiCommand` become thin wrappers over `state_ops`.
4. Add a `state_ops.tick(app)` that drains `app.queue` each frame (extracted from wherever this currently happens).

---

## Phase 4 — Modular Plugin Interface improvements

The existing `PluginIF.zig` VTable (ABI v4) is solid. Extend without breaking ABI:

1. **`on_command` dispatch table** — currently a single `on_command` fn per plugin. Add a helper `PluginIF.CommandDispatch` comptime struct so plugins declare `[N]CommandHandler` at comptime instead of a big switch.
2. **`UiCtx` extensions** — add `plot` (2D line chart, needed by GmID Visualizer and Circuit Visionary), `image` (for waveform bitmaps), and `collapsible_section` widgets to `UiCtx` in `PluginIF.zig`. Bump `ABI_VERSION` to 5.
3. **Plugin config** — add `get_config`/`set_config` to VTable for TOML-backed per-plugin settings (reuse `src/toml.zig`).

**Agent E:** Implement `UiCtx` extensions + ABI bump + update all existing plugins.

---

## Phase 5 — Renderer: every missing visual feature

All work is in `src/gui/renderer.zig` unless noted.

### 5A — Snap-to-grid in `p2w`

`p2w` currently rounds to nearest integer. It must snap to the grid when any
draw/wire tool is active.

```
// current (no snap)
fn p2w(pt, vp) CT.Point { round(…) }

// needed
fn p2w(pt, vp, snap: f32) CT.Point {
    const raw_x = (pt.x - vp.cx) / vp.scale + vp.pan[0];
    const raw_y = (pt.y - vp.cy) / vp.scale + vp.pan[1];
    return .{
        .x = @intFromFloat(@round(raw_x / snap) * snap),
        .y = @intFromFloat(@round(raw_y / snap) * snap),
    };
}
```

Pass `app.tool.snap_size` when the active tool is `.wire`, `.line`, `.rect`,
`.polygon`, `.arc`, `.circle`, `.text`, `.move`; pass `1.0` for `.select`
and `.pan`.

**Agent F-snap**

---

### 5B — Zoom fit (real bounding box)

`AppState.Viewport.zoomFit` currently just calls `zoomReset`. It must:

1. Walk all instances and wires in the active schematic.
2. Compute `(min_x, min_y, max_x, max_y)` in world space.
3. Set `zoom = min(canvas_w / world_w, canvas_h / world_h) * 0.9`.
4. Set `pan` so the centre of the bounding box maps to the canvas centre.

`zoom_fit_selected` does the same but only over the selected subset
(`app.selection.instances` / `app.selection.wires` bitsets).

**Agent F-zoom**

---

### 5C — Instance label rendering

Each `CT.Instance` has `.name` (refdes like `R1`) and `.symbol` (path).
Draw both next to the instance bounding box:

- Refdes label: above the box, `dvui.labelNoFmt` or `dvui.Path`-based text.
- Symbol basename (e.g. `resistor`) below the box, smaller, only when
  `app.cmd_flags.text_in_symbols` is true.
- Both are hidden when zoom is below a threshold (< 0.3) to avoid clutter.

**Agent F-labels**

---

### 5D — Net label rendering on wires

`CT.Wire` has an optional `net_name`. When set:

- Draw the label at the wire midpoint.
- Render as coloured text (use `pal.wire` colour family).
- Only show when `app.cmd_flags.show_netlist` is true OR always for named nets.

**Agent F-labels** (same agent as 5C)

---

### 5E — Real symbol geometry from `.sym` files

Currently `drawInstance` draws a placeholder box. Real rendering:

1. Add a `SymbolCache` (file-path → `CT.Symbol`) as a module-level
   `std.StringHashMapUnmanaged(CT.Symbol)` in `renderer.zig`.
2. In `drawInstance`, look up `inst.symbol` in the cache.
   - Cache miss: call `core.Schemify.readFile(data, alloc, logger)` to parse the
     `.sym` (Schemify symbol format) file → convert to `CT.Symbol` shapes/pins → cache it.
     (Only Schemify `.sym` files are supported; XSchem `.sym` files must be converted first.)
   - Cache hit: use cached symbol directly.
3. Draw the symbol shapes using `drawSymbol` (already implemented for the
   symbol-view path — reuse it here).
4. Draw pin stubs at the symbol's pin positions (offset by `inst.pos`,
   transformed by `inst.xform.rot` and `inst.xform.flip`).
5. Apply rotation/flip transforms in `w2p` or as a pre-pass on the shape
   points (use a 2×2 integer rotation matrix: `rot=0` identity, `rot=1` 90°CW,
   etc.).

**Agent G-symbols**

---

### 5F — Rubber-band drag selection

In `handleCanvasInput`, add drag-select for the `.select` tool:

1. On `mouse.press(.left)` when not over any object: record `drag_start: ?dvui.Point.Physical`.
2. On `mouse.motion` with `drag_start` set: draw a dashed rectangle from start
   to current position using `dvui.Path.stroke` with a dashed pattern.
3. On `mouse.release(.left)`: convert the rectangle corners to world space,
   find all instances/wires whose bounding box intersects the drag rect, set
   them in `app.selection`.

Add two new module-level statistics: `drag_start: ?dvui.Point.Physical = null`
and `drag_current: dvui.Point.Physical`.

**Agent H-input**

---

### 5G — Interactive move tool on canvas

When `app.tool.active == .move` and something is selected:

1. On `mouse.press(.left)`: record `move_anchor: CT.Point` (world space snap).
2. On `mouse.motion`: compute `delta = current_world - move_anchor` and draw
   the selected objects at their offset positions as a "ghost" (translucent
   version of the normal draw).
3. On `mouse.release(.left)`: push a `nudge` or batch of `move_device` +
   wire-endpoint moves onto the command queue; clear move_anchor.

**Agent H-input** (same agent as 5F)

---

### 5H — Draw-tool canvas interactions

For each graphic primitive tool, implement the click-place loop:

| Tool       | Behaviour                                                                                                          |
| ---------- | ------------------------------------------------------------------------------------------------------------------ |
| `.line`    | Click → anchor; move → rubber-band preview line; click → commit `CT.Shape{.line}` to active symbol or a draw layer |
| `.rect`    | Click → first corner; move → preview rect; click → commit `CT.Shape{.rect}`                                        |
| `.polygon` | Click to add vertices; double-click or Escape → close polygon                                                      |
| `.arc`     | Click centre, click radius point, click sweep end → commit `CT.Shape{.arc}` (add `ArcData` to `CT.Shape`)          |
| `.circle`  | Click centre, click edge → commit `CT.Shape{.circle}`                                                              |
| `.text`    | Click → open a small inline input box; Enter commits a `CT.TextLabel` at that position                             |

State needed in `ToolState` (add to `state.zig`):

```
draw_points: [16]CT.Point = undefined,  // reusable point accumulator
draw_point_count: u8 = 0,
```

**Agent H-input** (same agent)

---

### 5I — Right-click context menu

On `mouse.press(.right)` in `handleCanvasInput`:

1. Hit-test for instance or wire under cursor.
2. Push `.show_context_menu` to queue with the hit index and type as payload.
3. In `command.dispatch`, open a dvui floating menu with items appropriate
   to the object type:
   - Instance: "Properties [Q]", "Delete [Del]", "Rotate CW [R]",
     "Flip H [X]", "Move [M]", "Descend [E]"
   - Wire: "Delete [Del]", "Set Net Name", "Select Connected"
   - Empty canvas: "Paste [Ctrl+V]", "New File", "Insert from Library [Insert]"

**Agent H-input**

---

### 5J — Crosshair cursor

`app.cmd_flags.crosshair` is already a flag; it is never drawn.
When true, draw two lines spanning the full canvas through the current mouse
position each frame. Store mouse position in a module-level
`cursor_pos: dvui.Point.Physical` updated in `handleCanvasInput`.

**Agent F-labels** (trivial addition alongside label work)

---

### 5K — Info overlay (bottom-right corner of canvas)

`drawInfoOverlay` has a `// Future:` comment and does nothing.
Implement:

- Tool name badge (colour-coded, already computed).
- Cursor world coordinates: `(x, y)` derived from `cursor_pos` via `p2w`.
- Zoom percentage: `@round(app.view.zoom * 100)`.
- Snap size: `app.tool.snap_size`.

Draw using `dvui.labelNoFmt` anchored to the bottom-right corner via
a positioned box.

**Agent F-labels**

---

## Phase 6 — Command dispatcher: implement every stub

All work is in `src/command.zig` `dispatch()` unless noted.
A "(stub)" comment means the current body is `state.setStatus("… (stub)")`.

### 6A — Selection operations (Agent I-select)

| Command                     | Implementation                                                                                                                                                                                                                                 |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `select_connected`          | Walk wire adjacency: from each selected wire endpoint, DFS along wires that share an endpoint. Add connected wires + instances to selection.                                                                                                   |
| `select_attached_nets`      | For each selected instance, find all wires that touch any of the instance's pin positions (via CT pin offsets + instance transform). Add to selection.                                                                                         |
| `highlight_selected_nets`   | Resolve nets with `schemify.resolveNets` on the active schematic; collect net IDs of selected wires; store highlighted net IDs in a new `AppState.highlighted_nets: std.DynamicBitSetUnmanaged`. Renderer uses this to tint highlighted wires. |
| `unhighlight_selected_nets` | Remove selected wire net IDs from `highlighted_nets`.                                                                                                                                                                                          |
| `unhighlight_all`           | `highlighted_nets.unsetAll()`.                                                                                                                                                                                                                 |
| `highlight_dup_refdes`      | Build a `StringHashMap(u32)` of refdes → count; add instances with count > 1 to selection.                                                                                                                                                     |
| `rename_dup_refdes`         | Same scan; for duplicates, append `_1`, `_2`, etc. using `fio.setProp(idx, "name", …)`.                                                                                                                                                        |
| `find_select_dialog`        | Open a dvui floating window (module-level `find_dialog_open: bool`) with a text input. Match against instance names and symbol paths. On Enter, select all matches.                                                                            |

---

### 6B — Clipboard (Agent J-clipboard)

Clipboard payload: a new `Clipboard` struct in `state.zig`:

```zig
pub const Clipboard = struct {
    instances: std.ArrayListUnmanaged(CT.Instance) = .{},
    wires: std.ArrayListUnmanaged(CT.Wire) = .{},
    alloc: std.mem.Allocator,
};
```

Add `clipboard: Clipboard` to `AppState`.

| Command           | Implementation                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------- |
| `clipboard_copy`  | Deep-copy all selected instances + wires into `app.clipboard`.                                                |
| `clipboard_cut`   | Same as copy, then `delete_selected`.                                                                         |
| `clipboard_paste` | Append clipboard items to active schematic, offset by `(snap_size * 2, snap_size * 2)`. Select the new items. |
| `copy_selected`   | Same as `clipboard_copy` (it enters "copy-on-place" mode — paste on next click).                              |

---

### 6C — Move with stretch (Agent J-clipboard, same agent)

`move_interactive_stretch`: same as the canvas move (Phase 5G) but wires
whose endpoints are inside the selection box are stretched to follow, rather
than moved wholesale.

`align_to_grid`: for each selected instance, round `.pos.x` and `.pos.y` to
the nearest `app.tool.snap_size` multiple. For each selected wire, round both
endpoints.

---

### 6D — Wire geometry operations (Agent K-wires)

| Command                      | Implementation                                                                                                                                                                                 |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `break_wires_at_connections` | For each wire, check if any other wire's endpoint lies strictly between the wire's start and end. If so, split the wire into two at that point. Insert the two new wires, delete the original. |
| `join_collapse_wires`        | Find collinear wire pairs that share an endpoint (same direction, same line equation). Merge into a single wire spanning both.                                                                 |

---

### 6E — Hierarchy navigation (Agent L-hierarchy)

These require a hierarchy stack in `AppState`:

```zig
hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
pub const HierEntry = struct { doc_idx: usize, instance_idx: usize };
```

| Command                      | Implementation                                                                                                                                                                                                      |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `descend_schematic`          | Get the selected instance's `.symbol` path. Call `app.openPath(schematic_for_symbol)` (replace `.sym` → `.sch`). Push `HierEntry{.doc_idx = active_idx, .instance_idx = selected_instance}` onto `hierarchy_stack`. |
| `descend_symbol`             | Same but open the `.sym` file directly; switch `gui.view_mode` to `.symbol`.                                                                                                                                        |
| `ascend`                     | Pop `HierEntry` from `hierarchy_stack`. Switch `active_idx` back; restore selection to the instance we came from.                                                                                                   |
| `edit_in_new_tab`            | `app.openPath(symbol_path)` — creates a new tab without pushing hierarchy stack.                                                                                                                                    |
| `make_symbol_from_schematic` | Create a new `CT.Symbol` from the selected shapes/pins in the active schematic view. Open it in a new tab in symbol view.                                                                                           |
| `make_schematic_from_symbol` | Inverse: open a new tab referencing the currently-viewed symbol.                                                                                                                                                    |
| `insert_from_library`        | Open a library browser dialog (see Phase 8A).                                                                                                                                                                       |
| `reopen_last_closed`         | Add `closed_tabs: std.ArrayListUnmanaged([]const u8)` to `AppState`. On `close_tab`, push the path. `reopen_last_closed` pops and calls `openPath`.                                                                 |

---

### 6F — Properties dialogs (Agent M-dialogs)

| Command                   | Implementation                                                                                                                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `edit_properties`         | Open a floating dvui window. For the selected instance, render an editable key/value table: for each `CT.InstanceProp`, a text input per value. On close, call `fio.setProp` for changed values. |
| `view_properties`         | Same but read-only (labels, not inputs).                                                                                                                                                         |
| `edit_schematic_metadata` | Floating window editing `fio.comp.name`, `fio.origin` path display.                                                                                                                              |

---

### 6G — Netlist generation (Agent N-netlist)

The core machinery already exists in `src/core/netlist.zig`
(`UniversalNetlistForm.generateSpice`) and `src/core/schemify.zig`
(`Schemify.resolveNets`). The stubs just need to be wired up.

| Command                | Implementation                                                                                                                                                                                                                                             |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `netlist_hierarchical` | Load active doc via `core.SchemifyIO`, call `UniversalNetlistForm.fromSchemify`, call `generateSpice(alloc, core.pdk_registry)`. Write result to `<project_dir>/<name>.sp`. Open a read-only text overlay (or write to a temp path and open in a new tab). |
| `netlist_flat`         | Same but call `resolveNets` with `flatten=true` flag (add this flag to `schemify.resolveNets`).                                                                                                                                                            |
| `netlist_top_only`     | Same as hierarchical but do not recurse into sub-schematics.                                                                                                                                                                                               |
| `toggle_show_netlist`  | Toggle `cmd_flags.show_netlist`; when true, `renderer.zig` draws net names inline (Phase 5D) and shows the last-generated netlist in a bottom panel.                                                                                                       |

---

### 6H — File I/O stubs in `state.zig` (Agent N-netlist, same agent)

The `FileIO` struct in `state.zig` (which is the Document layer, distinct from
`core/FileIO.zig`) has placeholder bodies:

| Method          | What it currently does     | What it must do                                                                                                                  |
| --------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `saveAsChn`     | Writes a one-line comment  | Serialize `self.sch` to the real `.chn` text format via `core.SchemifyIO` / `schemify.Schemify.writeFile`                        |
| `createNetlist` | Writes a placeholder `.sp` | Delegate to `UniversalNetlistForm.generateSpice`                                                                                 |
| `runSpiceSim`   | Logs a stub message        | Spawn a child process: `ngspice -b <netlist_path>` or `Xyce <path>`; capture stdout to `Logger`. Wire up to `std.process.Child`. |

`AppState.openPath` creates a `FileIO` struct but **never actually reads file
content into `self.sch`**. It must call `core.SchemifyIO.readFile()` and populate
`CT.Schematic` from the parsed result. Only `.chn`, `.chn_tb`, and `.sym` paths
are valid; XSchem `.sch` files are not opened here (use the XSchem-import plugin first).

---

### 6I — View operations (Agent O-view)

| Command                 | Implementation                                                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `toggle_fullscreen`     | Call `dvui.windowSetFullscreen(true/false)` (look up the correct dvui API — use `context7` MCP).                                                 |
| `toggle_colorscheme`    | Call `dvui.themeSet(dvui.themeByName("Adwaita Dark"/"Adwaita"))` or cycle through `dvui.themes`.                                                 |
| `show_keybinds`         | Open a read-only floating window listing all keybindings from the `static_keybinds` table in `gui.zig` and the active `app.gui.plugin_keybinds`. |
| `show_context_menu`     | Handled in Phase 5I above.                                                                                                                       |
| `merge_file_dialog`     | Native file open dialog; parse the selected file; append its instances and wires to the active schematic.                                        |
| `save_as_symbol_dialog` | Native save dialog with `.sym` filter; serialize active `CT.Symbol` via `core.Schemify.writeFile` (Schemify `.sym` format — not XSchem).                                                      |

---

### 6J — Export (Agent P-export)

| Command           | Implementation                                                                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `export_pdf`      | Render the canvas to an off-screen dvui surface; encode as PDF using a pure-Zig PDF writer (or shell out to `inkscape --export-pdf` if available). |
| `export_png`      | Use `dvui.captureScreenshot` or render to a pixel buffer; write with `std.zig-png` (add as dep) or shell out to ImageMagick.                       |
| `export_svg`      | Walk `CT.Schematic` and emit SVG `<line>` / `<rect>` elements directly — no external tool needed.                                                  |
| `screenshot_area` | Same as PNG but prompt user for a rectangle on the canvas (rubber-band; Phase 5F can be reused).                                                   |

---

### 6K — Undo/redo proper (Agent Q-undo)

The current `History` records commands but `undo` just pops without reversing
effects. Two viable DOD approaches:

**Option A — Inverse commands (preferred for small state):**
For each reversible command, define an inverse:

```zig
pub const CommandInverse = union(enum) {
    place_device: DeleteDevice,   // inverse of place_device is delete_device
    delete_device: PlaceDevice,   // inverse of delete is re-place
    move_device: MoveDevice,      // inverse dx/dy = -original dx/dy
    set_prop: SetProp,            // previous key/val
    add_wire: DeleteWire,
    delete_wire: AddWire,
    delete_selected: RestoreSelected,  // stores list of (inst/wire) snapshots
    …
};
```

`History.push` stores `(Command, CommandInverse)` pairs.
`History.undo` pops the inverse and dispatches it.

**Option B — Snapshot (simpler, higher memory):**
Before each mutable command, deep-copy `CT.Schematic` into a snapshot arena.
`History.undo` swaps the current schematic for the snapshot.

Start with Option A for the simple single-object commands; fall back to
snapshot only for `delete_selected` / `duplicate_selected` / `clear_schematic`.

---

### 6L — Simulation (Agent P-export, same agent)

`open_waveform_viewer`:

1. Look for a `.raw` or `.tr0` output file next to the last-run netlist.
2. Parse the raw file (ngspice `.raw` format: ASCII or binary — add
   `src/core/spice_raw.zig` parser).
3. Open a new tab in a "waveform" view mode (add `.waveform` to `GuiViewMode`).
4. The waveform renderer draws time-series traces using `dvui.Path.stroke`.

For now, Phase 6H's `runSpiceSim` should at least block-wait (or detach) the
child process and write stdout to a `Logger` ring buffer.

---

## Phase 7 — GUI dialogs (modal windows)

All dialogs are module-level state booleans in their respective files.
Use `dvui.floatingWindow` or `dvui.dialog` to render them.

### 7A — Library browser (Agent M-dialogs)

Triggered by `insert_from_library`.

```
LibraryBrowser {
    open: bool,
    search_buf: [128]u8,
    search_len: usize,
    root_dir: []const u8,     // = app.project_dir/symbols/
    entries: [256]DirEntry,   // scanned once on open
    entry_count: usize,
    selected: i32,
    preview_sym: ?CT.Symbol,  // parsed from selected .sym file
}
```

Layout: left panel = filtered list of `.sym` files; right panel = symbol
preview (calls `drawSymbol`). "Place" button pushes `.place_device` command
with cursor position or (0,0) if not interactive.

### 7B — Properties editor (Agent M-dialogs)

Triggered by `edit_properties`. Module-level:

```
PropsDialog {
    open: bool,
    inst_idx: usize,
    // per-field edit buffers:
    bufs: [16][128]u8,
    lens: [16]usize,
    dirty: [16]bool,
}
```

On close: for each `dirty[i]`, call `fio.setProp(inst_idx, key, buf[0..len])`.

### 7C — Find/select dialog (Agent I-select)

Already planned in Phase 6A. Fixed-size state:

```
FindDialog {
    open: bool,
    query_buf: [128]u8,
    query_len: usize,
    results: [64]usize,  // instance indices
    result_count: usize,
}
```

### 7D — Keybinds help (Agent O-view)

Read-only floating window. Iterate `static_keybinds` at comptime and render
a two-column table: key combo | action name.

### 7E — Netlist preview panel (Agent N-netlist)

When `cmd_flags.show_netlist` is true, the bottom-bar plugin panel slot shows
the last generated netlist text (stored in a `AppState.last_netlist: [8192]u8`
fixed buffer). Uses a scrollable text view.

---

## Phase 8 — Plugin panel widget stubs (Agent E, continuation)

In `src/gui/plugin_panels.zig`, four host-side UiCtx functions are stubs:

| Function        | Current body   | Needed                                                   |
| --------------- | -------------- | -------------------------------------------------------- |
| `hostTextInput` | `return false` | Wrap `dvui.textInput` with the plugin's buf/len pointers |
| `hostSlider`    | `return false` | Wrap `dvui.slider`                                       |
| `hostCheckbox`  | `return false` | Wrap `dvui.checkbox`                                     |
| `hostProgress`  | `_ = fraction` | Wrap `dvui.progress` (or draw a filled rect)             |

---

## Agent execution map

```
Round 1 — COMPLETE (applied 2026-03-08):
  ✅ Phase 5A   snap-to-grid in p2w                           renderer.zig
  ✅ Phase 5B   zoom fit with real bounding box               command.zig + state.zig (canvas_w/h)
  ✅ Phase 5C   instance label rendering (dvui.labelNoFmt)    renderer.zig
  ✅ Phase 5D   net label at wire midpoint (dvui.labelNoFmt)  renderer.zig
  ✅ Phase 5E   symbol cache + real .chn_sym geometry         renderer.zig
  ✅ Phase 5F   rubber-band drag-select                       renderer.zig
  ✅ Phase 5G   interactive move tool                         renderer.zig
  ✅ Phase 5H   draw tool canvas interactions (line/rect/poly/text) renderer.zig
  ✅ Phase 5I   right-click context menu                      gui.zig + renderer.zig
  ✅ Phase 5J   crosshair cursor                              renderer.zig
  ✅ Phase 5K   info overlay (tool badge + coords + zoom)     renderer.zig
  ✅ Phase 6A   selection ops (connected, nets, dup refdes)   command.zig
  ✅ Phase 6B   clipboard copy/cut/paste                      state.zig + command.zig
  ✅ Phase 6C   align-to-grid                                 command.zig
  ✅ Phase 6D   break/join wires                              command.zig
  ✅ Phase 6I   toggle_fullscreen/colorscheme (dvui.themeSet), show_keybinds command.zig
  ✅ Phase 7C   find/select dialog                            gui.zig
  ✅ Phase 7D   keybinds help window                          gui.zig

Round 2 — COMPLETE (applied 2026-03-08):
  ✅ Agent L-hierarchy → Phase 6E  (descend/ascend, insert from library, reopen)
  ✅ Agent M-dialogs   → Phase 6F + 7A + 7B  (props dialog, library browser)
  ✅ Agent N-netlist   → Phase 6G + 6H + 7E  (netlist gen, real file I/O, preview panel)
  ✅ Agent P-export    → Phase 6J + 6L  (export, simulation child process)
  ✅ Agent Q-undo      → Phase 6K  (inverse command undo/redo)

Round 3 — COMPLETE (applied 2026-03-08):
  ✅ Phase 8  plugin panel widget stubs (hostTextInput/Slider/Checkbox/Progress)  plugin_panels.zig

Round 4 (current):
  Agent R-gui-std  → Phase 9A  gui/ renderer.zig State struct
  Agent S-dialogs  → Phase 9B  gui/ dialog files extracted from gui.zig
  Agent T-state    → Phase 10  state.zig slim-down (remove dialog fields from GuiState)
  Agent U-cmd      → Phase 11  command.zig cleanup (split dispatch into groups)
```

---

## Phase 9 — gui/ module standardization

**Goal:** Every `src/gui/*.zig` file follows the State-struct standard defined in Guiding Principles.
No bare module-level `var` declarations; all local state lives in a `pub const State` struct with
a `pub var state: State = .{};` singleton.

### 9A — renderer.zig (Agent R-gui-std)

Current bare module-level vars to collect into `RendererState`:

| Current var | Type | Purpose |
|---|---|---|
| `pan_dragging` | `bool` | middle-mouse pan in progress |
| `pan_last` | `dvui.Point.Physical` | previous pan position |
| `drag_start` | `?dvui.Point.Physical` | drag-select start |
| `drag_current` | `dvui.Point.Physical` | drag-select current pos |
| `move_anchor` | `?CT.Point` | move-tool anchor in world space |
| `cursor_pos` | `dvui.Point.Physical` | current mouse position |
| `symbol_cache` | `std.StringHashMapUnmanaged(CT.Symbol)` | loaded symbol geometry |
| `symbol_cache_arena` | `?std.heap.ArenaAllocator` | backing allocator for cache |

New shape:

```zig
pub const State = struct {
    pan_dragging:       bool                                     = false,
    pan_last:           dvui.Point.Physical                      = .{ .x = 0, .y = 0 },
    drag_start:         ?dvui.Point.Physical                     = null,
    drag_current:       dvui.Point.Physical                      = .{ .x = 0, .y = 0 },
    move_anchor:        ?CT.Point                                = null,
    cursor_pos:         dvui.Point.Physical                      = .{ .x = 0, .y = 0 },
    symbol_cache:       std.StringHashMapUnmanaged(CT.Symbol)    = .{},
    symbol_cache_arena: ?std.heap.ArenaAllocator                 = null,
};

pub var state: State = .{};
```

All internal functions that read/write these vars use `state.field` instead of the bare name.
`getSymbolCacheAllocator` becomes a method or inline helper operating on `state.symbol_cache_arena`.

### 9B — gui.zig dialogs → separate files (Agent S-dialogs)

`gui.zig` currently contains 5 inline dialogs plus 2 bare window-rect vars. Each dialog moves to its own file with a `State` struct.

#### Files to create

| New file | Extracted from gui.zig | State fields |
|---|---|---|
| `gui/find_dialog.zig` | `drawFindDialog` + `runFindQuery` | `open: bool`, `query: [128]u8`, `query_len: usize`, `results: [64]usize`, `result_count: usize` |
| `gui/context_menu.zig` | `drawContextMenu` | `open: bool`, `inst_idx: i32 = -1`, `wire_idx: i32 = -1` |
| `gui/keybinds_dialog.zig` | `drawKeybindsWindow` | `open: bool` |
| `gui/props_dialog.zig` | `drawPropertiesDialog` | `open: bool`, `view_only: bool`, `inst_idx: usize`, `bufs: [16][128]u8`, `lens: [16]usize`, `dirty: [16]bool`, `win_rect: dvui.Rect` |
| `gui/library_browser.zig` | `drawLibraryBrowser` | `open: bool`, `search_buf: [128]u8`, `search_len: usize`, `entries: [256][256]u8`, `entry_count: usize`, `selected: i32`, `win_rect: dvui.Rect` |

Each new file has `pub var state: State = .{};` and `pub fn draw(app: *AppState) void`.

`gui.zig`'s `frame()` calls each as:
```zig
find_dialog.draw(app);
context_menu.draw(app);
keybinds_dialog.draw(app);
if (props_dialog.state.open) props_dialog.draw(app);
if (library_browser.state.open) library_browser.draw(app);
```

Also move `keyToChar`, `KeybindAction`, `Keybind`, `static_keybinds`, `dispatchStaticKeybind`,
`dispatchPluginKeybind`, `encodeMods` → `gui/keybinds.zig` (pure data + lookup, no drawing).
`gui.zig` calls `keybinds.dispatchStatic(app, …)` and `keybinds.dispatchPlugin(app, …)`.

#### gui.zig after 9B

`gui.zig` retains only:
- `frame()` — layout shell
- `handleInput()` / `handleNormalMode()` / `handleCommandMode()` — keyboard routing (uses `keybinds.*`)
- `drawCenterColumn()` + `drawNetlistPreview()`

---

## Phase 10 — state.zig slim-down

**Goal:** `GuiState` becomes a lean struct. Dialog-specific state that moved to `gui/*.zig` (Phase 9B)
is deleted from `GuiState`. CT types move to `src/types.zig`. `FileIO` moves to `src/document.zig`.

### Tasks

1. **Remove from `GuiState`** (now owned by their gui/ files):
   - `find_dialog_open`, `find_query`, `find_query_len`, `find_results`, `find_result_count`
   - `keybinds_open`
   - `context_menu_open`, `context_menu_inst`, `context_menu_wire`
   - `props_dialog_open`, `props_view_only`, `props_inst_idx`, `props_bufs`, `props_lens`, `props_dirty`
   - `lib_browser_open`, `lib_search_buf`, `lib_search_len`, `lib_entries`, `lib_entry_count`, `lib_selected`

2. **Keep in `GuiState`** (truly global GUI state):
   - `view_mode`, `command_mode`, `command_buf`, `command_len`
   - `plugin_panels`, `key_to_panel`, `marketplace`, `plugin_keybinds`

3. **Extract `CT` types** → `src/types.zig`
   Exports: `CT.Point`, `CT.Wire`, `CT.Instance`, `CT.InstanceProp`, `CT.Schematic`,
   `CT.Shape`, `CT.ShapeTag`, `CT.SymbolPin`, `CT.Symbol`, `CT.Transform`.
   `state.zig` re-exports: `pub const CT = @import("types.zig");`

4. **Extract `FileIO`** → `src/document.zig`
   `state.zig` re-exports: `pub const FileIO = @import("document.zig").FileIO;`

5. **`AppState`** retains only fields; all mutation free-functions move to `src/state_ops.zig`
   (except `init`, `deinit`, `allocator`).

**Agent T-state** — implement tasks 1–2 first (no new files needed); tasks 3–5 in a follow-up.

---

## Phase 11 — command.zig cleanup

**Goal:** The 1 400-line `dispatch()` monolith is split into small, named handler groups.
The `Command` union, `History`, and `CommandQueue` types stay in `command.zig` as pure data.
Dispatch logic moves out.

### Split

```
src/
  command.zig          ← Command union, History, CommandQueue  (data only, no dispatch logic)
  cmd/
    dispatch.zig       ← pub fn dispatch(c: Command, app: *AppState) !void — routes to groups
    selection.zig      ← select_all, select_none, select_connected, highlight_*, find_select_dialog
    clipboard.zig      ← clipboard_copy/cut/paste, copy_selected, duplicate_selected
    edit.zig           ← delete_selected, rotate_cw/ccw, flip_*, nudge_*, align_to_grid
    wire.zig           ← add_wire, cancel_wire, break_wires_*, join_collapse_wires, start_wire*
    view.zig           ← zoom_*, pan_*, toggle_*, snap_*, show_keybinds, open_waveform_viewer
    file.zig           ← new_tab, close_tab, save_*, reload_from_disk, reopen_last_closed
    hierarchy.zig      ← descend_*, ascend, edit_in_new_tab, make_symbol_*, insert_from_library
    netlist.zig        ← netlist_*, toggle_show_netlist, generateNetlistAndStore
    sim.zig            ← run_sim, open_waveform_viewer
    props.zig          ← edit_properties, view_properties, edit_schematic_metadata, set_prop
    plugin.zig         ← plugin_command, plugins_refresh
    undo.zig           ← undo, redo  (full inverse-command logic)
```

### Rules

- Each `cmd/*.zig` file exposes: `pub fn handle(c: Command, app: *AppState) !void`
- `dispatch.zig` is a pure routing switch: `switch (c) { .select_all, .select_none, ... => selection.handle(c, app), ... }`
- No business logic in `dispatch.zig` itself.
- Toggle flags (e.g. `toggle_crosshair`) are expressed as data: a comptime table mapping tag → `*bool` field, handled by a single generic `toggleFlag` in `view.zig`.

**Agent U-cmd** — implement the split. Start with `command.zig` (data only) + `cmd/dispatch.zig` + one group (`view.zig`) to verify the pattern compiles, then fill the remaining groups.

---

## Running Multiple Agents in Parallel

Claude Code agents are launched via the `Agent` tool with `isolation: "worktree"` so each gets its own git worktree and cannot conflict.

### Pattern

In a single Claude message, call `Agent` multiple times:

```
Agent(subagent_type="general-purpose", isolation="worktree",
      name="phase2-types",
      prompt="Extract CT types from src/state.zig into src/types.zig …")

Agent(subagent_type="general-purpose", isolation="worktree",
      name="phase2-gui-state",
      prompt="Extract GuiState and friends from src/state.zig into src/gui_state.zig …")
```

Both agents run simultaneously on independent worktrees. When both finish, merge their branches.

### Concrete split for Phase 2

```
Agent A (worktree): types.zig extraction          — no logic, pure type moves
Agent B (worktree): gui_state.zig extraction      — no logic, pure type moves
Agent C (worktree): state_ops.zig + call-sites    — depends on A+B finishing first
```

Start A and B in parallel, then start C after both are merged.

### Tips

- Give each agent the exact files it should read and write in the prompt.
- Include the DOD rules from this PLAN as a constraint.
- Use `run_in_background: true` for long-running agents so you can keep working.
- After each agent finishes, run `pr-review-toolkit:code-reviewer` on its diff before merging.
