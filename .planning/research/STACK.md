# Technology Stack: GUI Layer Cleanup

**Project:** Schemify v2.0 GUI Layer Cleanup
**Researched:** 2026-03-27
**Focus:** Patterns and stack refinements for GUI->state->core layer separation in a Zig/dvui immediate-mode schematic editor.

## Recommended Stack

No new dependencies. This milestone is a refactoring of existing code. The stack section documents patterns and structural decisions within the existing technology, not new library additions.

### Core Framework (unchanged)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Zig | 0.15 | Language | Constrained by project |
| dvui | latest (raylib backend native, wasm backend web) | Immediate-mode GUI | Already integrated, dvui.App manages lifecycle |
| raylib | via dvui dependency | Native rendering backend | Already integrated via dvui |

### Layer Architecture (the "stack" that matters)

| Layer | Files | Allowed Imports | Why |
|-------|-------|----------------|-----|
| **gui/** | lib.zig, Renderer.zig, Bars/, Components/, Dialogs/ | `dvui`, `state`, `commands` (types only) | GUI reads state, enqueues commands, renders via dvui. Never imports `core`. |
| **commands/** | command.zig, Dispatch.zig, View.zig, Edit.zig, ... | `state`, `core`, `utility` | Commands mutate state. Never import `dvui`. |
| **state.zig** | Single file | `core`, `commands` (types only), `utility` | Holds all mutable state. Pure data container. |
| **core/** | Schemify.zig, Reader.zig, Writer.zig, ... | `utility`, `std` | Domain logic. No knowledge of GUI or commands. |

**Confidence:** HIGH -- this layering is already partially implemented and documented in PROJECT.md.

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| GUI state location | Consolidate all in `AppState.GuiState` | Keep module-level `var` per GUI file | Module-level vars are invisible to serialization, testing, and reset logic. They survive across document switches, causing stale state bugs. dvui's `dataGet`/`dataSet` is for widget-internal cross-frame state (scroll positions, animation), not application-level dialog state. |
| Core access from GUI | Through `state` (GUI reads `app.active().sch` fields) | Direct `@import("core")` in Renderer.zig | Direct import creates hidden coupling. If core types change, GUI breaks. State already re-exports `Instance`, `Wire`, `Sim`, `Point`. Extend the pattern to `Schemify`, `DeviceKind`, `primitives`. |
| View.zig dvui import | Split into View.zig (pure state mutation) + GUI reads cmd_flags | Keep `dvui.themeSet()` call in View.zig | Commands layer should set flags, not call GUI framework APIs. `toggle_colorscheme` should set `cmd_flags.dark_mode`, and GUI should read that flag each frame to call `dvui.themeSet()`. This is the core immediate-mode pattern: state is truth, rendering is derived. |
| Renderer state location | `Renderer` struct stored in `AppState.GuiState` | Module-level `var renderer_state` in lib.zig | Same problem as other module-level vars. The renderer has zoom, pan, drag state that should be part of the app state for serialization and testing. Transient input state (dragging, drag_last, last_click_time) also moves -- it is per-session and does not need persistence, but grouping it with the rest makes state transitions cleaner. |
| Dialog state | Nested structs in `GuiState` per dialog | Separate module-level vars per dialog file | 6 dialog files each have their own module-level vars (is_open, query_buf, win_rect, etc.). Moving them into `GuiState.find_dialog`, `GuiState.props_dialog`, etc. makes all dialog state visible, resettable, and testable. Dialog files become pure rendering functions: `fn draw(app: *AppState) void`. |

## Patterns (the actual "stack" for this milestone)

### Pattern 1: Thin Renderer Pattern

**What:** GUI files are pure functions: `fn draw(app: *AppState) void`. They read state, call dvui widgets, and dispatch commands. Zero state storage, zero business logic.

**Why it works for this codebase:** dvui is immediate-mode -- widgets are created every frame from current state. The entire GUI can be a pure function of `AppState`. Module-level `var` in GUI files is an anti-pattern because it creates shadow state that diverges from `AppState`.

**Current violations (7 files with module-level state):**

| File | Module-level vars | Move to |
|------|------------------|---------|
| `lib.zig` | `renderer_state: Renderer` | `GuiState.renderer` |
| `FileExplorer.zig` | `sections`, `files`, `selected_section`, `selected_file`, `scanned`, `preview_name`, `win_rect` | `GuiState.file_explorer: FileExplorerState` |
| `LibraryBrowser.zig` | `win_rect`, `search_buf`, `selected_idx`, `scanned` | `GuiState.library_browser: LibraryBrowserState` |
| `Dialogs/FindDialog.zig` | `is_open`, `query_buf`, `query_len`, `result_count`, `win_rect` | `GuiState.find_dialog: FindDialogState` |
| `Dialogs/PropsDialog.zig` | `is_open`, `view_only`, `inst_idx`, `win_rect` | `GuiState.props_dialog: PropsDialogState` |
| `Dialogs/KeybindsDialog.zig` | `open`, `win_rect` | `GuiState.keybinds_dialog: KeybindsDialogState` |
| `Theme.zig` | `current_overrides: ThemeOverrides` | `GuiState.theme_overrides: ThemeOverrides` |

**Why NOT dvui.dataGet/dataSet:** dvui's cross-frame persistence is for widget-internal state (scroll positions, collapsed/expanded toggles, text cursor positions). Application-level state like "which dialog is open" or "which file is selected in the explorer" must live in `AppState` because: (a) it needs to be resettable on document switch, (b) it needs to be queryable by commands, (c) it may need serialization for workspace restore. dvui.dataGet is keyed by `@src()` location, which is frame-dependent and not inspectable from outside the widget.

**Confidence:** HIGH -- this pattern is the standard immediate-mode GUI architecture (Ryan Fleury, Dear ImGui best practices, dvui documentation all agree: application state is external, widget state is framework-managed).

### Pattern 2: Command-Flag Bridge

**What:** Commands set boolean/enum flags in `AppState.cmd_flags`. GUI reads those flags each frame to configure rendering.

**Why it works for this codebase:** The `toggle_colorscheme` handler in View.zig currently calls `dvui.themeSet()` directly -- this is the only dvui import in the commands layer. Instead, the command should set `cmd_flags.dark_mode = !cmd_flags.dark_mode`, and `lib.zig` should read `app.cmd_flags.dark_mode` at the start of each frame to call `dvui.themeSet()`.

**Implementation:**

```zig
// commands/View.zig -- AFTER (no dvui import)
.toggle_colorscheme => {
    state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
    state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
},

// gui/lib.zig -- frame() reads the flag
pub fn frame(app: *AppState) !void {
    // Apply theme from command flags (bridge between commands and GUI)
    dvui.themeSet(if (app.cmd_flags.dark_mode)
        dvui.Theme.builtin.adwaita_dark
    else
        dvui.Theme.builtin.adwaita_light);

    handleInput(app);
    // ... rest of frame
}
```

This eliminates the only `dvui` import from the commands layer. After the change, `"dvui"` can be removed from the `commands` module's imports in `build.zig` line 23, providing compile-time enforcement that no command handler ever calls into the GUI framework.

**Confidence:** HIGH -- this is exactly how the codebase already handles all other view flags (fullscreen, fill_rects, crosshair, etc.). The colorscheme toggle is the sole exception.

### Pattern 3: State-Mediated Core Access

**What:** GUI accesses core data types only through re-exports in `state.zig`. GUI files never `@import("core")` directly.

**Why it works for this codebase:** Currently `Renderer.zig` imports `core` directly for `Schemify`, `DeviceKind`, and `primitives`. The Renderer needs these types to iterate SoA arrays and look up device drawings. Rather than re-exporting all of core, state.zig should expose the specific types the GUI needs.

**Current violation:**

```zig
// Renderer.zig -- BEFORE
const core = @import("core");
const Schemify = core.Schemify;
const DeviceKind = core.DeviceKind;
const primitives = core.primitives;
```

**Approach -- re-export through state:**

```zig
// state.zig -- add re-exports the GUI needs
pub const Schemify = core.Schemify;
pub const DeviceKind = core.DeviceKind;
pub const primitives = core.primitives;

// Renderer.zig -- AFTER (no core import)
const st = @import("state");
const Schemify = st.Schemify;
const DeviceKind = st.DeviceKind;
const primitives = st.primitives;
```

This is not a deep abstraction -- it is a dependency boundary. The types are the same. But the import path enforces that GUI depends on state, not on core directly. When core internals change, only state.zig needs updating. The pattern is already established: state.zig already re-exports `Instance`, `Wire`, `Sim`, and `Point` from core.

**Alternative considered:** Create a `RenderView` struct in state that pre-extracts SoA slices. Rejected because the Renderer already accesses `doc.sch` fields directly and creating wrapper types would add allocation and copy overhead for a hot-path (rendering happens every frame). Re-exporting types is the right granularity.

**Confidence:** HIGH -- extends an existing pattern (4 types already re-exported through state.zig).

### Pattern 4: Comptime Table-Driven UI Definitions

**What:** Use comptime arrays of tagged unions to define menus, keybinds, and toolbar layouts declaratively. The rendering function is a generic loop over the table.

**Why it works for this codebase:** This pattern is already used successfully in three places:

1. **ToolBar.zig** -- `file_items`, `edit_items`, etc. are comptime `[]MenuItem` arrays rendered by `renderItems()`. Each entry is a tagged union `MenuItem = union(enum) { action, gui_cmd, separator }`.

2. **Keybinds.zig** -- `static_keybinds` is a comptime-sorted array with O(log n) binary search lookup.

3. **Actions.zig** -- `vim_noarg_entries` is a comptime `StaticStringMap` for O(1) vim command dispatch.

**Where to extend:** The ContextMenu.zig (71 lines) currently uses inline dvui calls for each menu item. It should use the same `MenuItem` table pattern as ToolBar.zig, making the context menu data-driven and consistent with the rest of the toolbar/menu system.

**Confidence:** HIGH -- proven in existing codebase, no research needed.

### Pattern 5: Component Extraction for Reusable Patterns

**What:** Extract repeated dvui widget compositions into `Components/` as comptime-parameterized types.

**Why it works for this codebase:** Already done for `FloatingWindow`, `HorizontalBar`, `Button`, `DropdownButton`. The pattern uses Zig's comptime generics:

```zig
pub fn FloatingWindow(comptime opts: struct {
    title: [:0]const u8,
    min_w: f32 = 300,
    min_h: f32 = 200,
    modal: bool = false,
}) type {
    return struct {
        pub fn draw(rect: *dvui.Rect, open: *bool, content_fn: anytype, app: *AppState) void {
            // standard floating window boilerplate
            content_fn(app);
        }
    };
}
```

**Where to extend:** `Marketplace.zig` and `FileExplorer.zig` both implement their own floating window with header/body/button-row patterns inline. These should use `FloatingWindow` from Components/ instead of reimplementing the boilerplate.

**Confidence:** HIGH -- pattern already exists and works.

### Pattern 6: Renderer Decomposition

**What:** Split `Renderer.zig` (844 lines) into focused sub-modules by rendering concern.

**Why it works for this codebase:** Renderer.zig contains conceptually separate concerns:

| Section | Approx Lines | Purpose | Extract to |
|---------|-------------|---------|-----------|
| `Renderer` struct + `draw()` + `handleInput()` | ~200 | Canvas widget, input handling, viewport | Keep in Renderer.zig |
| `drawSchematic()` + `drawSymbolView()` | ~250 | SoA iteration over wires/instances/text | `SchematicDraw.zig` |
| `lookupPrim()` + `kindToName()` + `drawPrimEntry()` + `drawGenericBox()` | ~160 | Device symbol lookup and drawing | `SymbolDraw.zig` |
| Stroke helpers (`strokeLine`, `strokeDot`, `strokeCircle`, `strokeArc`, `strokeRectOutline`) | ~80 | Low-level dvui path drawing | `DrawHelpers.zig` |
| Grid + origin drawing | ~50 | Background rendering | `GridDraw.zig` or `DrawHelpers.zig` |
| Coordinate transforms (`w2p`, `p2w`, `p2w_raw`) | ~30 | World-pixel conversion | `DrawHelpers.zig` |
| Constants (hit tolerance, dot sizes) | ~15 | Shared values | `DrawHelpers.zig` |

Target: Renderer.zig stays under 250 lines as the canvas widget controller. Extracted modules are pure functions that take viewport + palette + data and call dvui drawing primitives. No new state, no new dependencies -- just physical file boundaries.

**Confidence:** HIGH -- this is standard decomposition. The extracted functions have clean signatures (take data + viewport, produce drawing commands).

## Import Graph (target state)

```
gui/lib.zig ----------- dvui, state, commands (types only)
gui/Renderer.zig ------ dvui, state (including re-exported core types)
gui/Bars/*.zig -------- dvui, state, commands (types), Actions.zig
gui/Dialogs/*.zig ----- dvui, state, Components/
gui/Components/*.zig -- dvui (no state dependency -- reusable)
gui/Actions.zig ------- state, commands
gui/Keybinds.zig ------ dvui (key enum only), commands, Actions.zig

commands/*.zig -------- state, core, utility
commands/View.zig ----- state, utility (NO dvui)

state.zig ------------- core (re-exports select types), commands (types), utility
core/ ----------------- utility, std
```

**Critical changes from current state:**
- `Renderer.zig` drops `@import("core")` -- uses `@import("state")` re-exports instead
- `commands/View.zig` drops `@import("dvui")` -- sets flags, GUI reads them
- `gui/Theme.zig` module-level `var` moves into `GuiState`
- All dialog/browser module-level `var` move into `GuiState`

## Build System Impact

After the refactoring, one change to `build.zig`:

1. Remove `"dvui"` from `commands` module imports in `build.zig` line 23 (currently: `&.{ "state", "core", "utility", "dvui" }` becomes `&.{ "state", "core", "utility" }`)
2. All other module imports remain the same

This is a build-time verification that the layering is correct: if any commands/ file imports dvui after the change, compilation will fail immediately. The `dvui` dependency was only needed because of View.zig's `dvui.themeSet()` call. Removing it enforces the layer boundary at compile time.

**Confidence:** HIGH -- verified by reading build.zig module_defs.

## State Container Changes (state.zig)

### New sub-structs in GuiState

```zig
pub const GuiState = struct {
    // Existing fields (keep as-is)
    ctx_menu: CtxMenu = .{},
    view_mode: GuiViewMode = .schematic,
    command_mode: bool = false,
    command_buf: [128]u8 = [_]u8{0} ** 128,
    command_len: usize = 0,
    plugin_panels: std.ArrayListUnmanaged(PluginPanel) = .{},
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,
    marketplace: MarketplaceState = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},

    // REMOVE keybinds_open (replaced by keybinds_dialog.open)

    // NEW: consolidated from module-level vars
    renderer: RendererState = .{},
    file_explorer: FileExplorerState = .{},
    library_browser: LibraryBrowserState = .{},
    find_dialog: FindDialogState = .{},
    props_dialog: PropsDialogState = .{},
    keybinds_dialog: KeybindsDialogState = .{},
    theme_overrides: ThemeOverrides = .{},
};
```

Each `*State` struct is defined in `state.zig` (pure data, no dvui types) and contains exactly the fields currently scattered as module-level vars. Dialog draw functions become: `fn draw(app: *AppState) void` reading `app.gui.find_dialog.*` etc.

**dvui.Rect type concern:** Several dialog state structs contain `win_rect: dvui.Rect`. This would require state.zig to import dvui, breaking the layer rule. Solution: use `[4]f32` (x, y, w, h) in state and convert at the usage site, or define a plain `Rect` struct in state.zig: `pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 }`. dvui.Rect is just 4 floats so the conversion is trivial.

**Renderer state split:** The `Renderer` struct currently mixes persistent state (zoom, pan, snap_size, show_grid) with transient input state (dragging, drag_last, space_held, last_click_time). Both should move into `GuiState.renderer`. The distinction is documented but does not affect storage location -- both are per-session state that lives as long as the app runs. Wire_start is already in `AppState.tool` (ToolState), not in Renderer.

**Confidence:** HIGH -- straightforward struct composition. All types are plain data.

## Dead Code Removal

| File | Lines | Status | Action |
|------|-------|--------|--------|
| `Input/Handler.zig` | 5 | Empty stub | Delete file |
| `Input/KeyboardInputHandler.zig` | 5 | Empty stub | Delete file |
| `Input/MouseInputHandler.zig` | 42 | Unused stub (input handled in lib.zig and Renderer.zig) | Delete file |
| `Input/` directory | -- | Empty after above deletions | Delete directory |

These stubs are leftovers from a previous architecture. Input handling is fully implemented in `gui/lib.zig` (keyboard) and `Renderer.zig` (mouse/canvas). The stubs are not imported by any file.

**Confidence:** HIGH -- verified by grep: no file imports from `Input/`.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `src/gui/`, `src/commands/`, `src/state.zig`, `src/main.zig`, `build.zig` -- direct code reading of all 24 GUI files, 14 command files, and state container
- [dvui Core Architecture -- DeepWiki](https://deepwiki.com/david-vanderson/dvui/3-core-architecture) -- widget lifecycle, state management, App pattern, dataGet/dataSet scope
- [dvui GitHub](https://github.com/david-vanderson/dvui) -- immediate-mode design, backend abstraction, App-managed lifecycle pattern
- `.planning/PROJECT.md` -- milestone requirements, known violations, layer rules

### Secondary (MEDIUM confidence)
- [Ryan Fleury: UI Part 2 -- Every Single Frame](https://www.dgtlgrove.com/p/ui-part-2-build-it-every-frame-immediate) -- immediate-mode state/rendering separation: state is truth, view is derived, widget cache is transparent
- [Sam Sartor: Statefulness in GUIs](https://samsartor.com/guis-1/) -- input->state and state->rendering as separate passes
- [Ziggit: Architecture of a complex data-driven app](https://ziggit.dev/t/architecture-of-a-complex-data-driven-app/3389) -- centralized state struct, change tracking, DOD patterns in Zig GUI applications
- [Dear ImGui: About the IMGUI paradigm](https://github.com/ocornut/imgui/wiki/About-the-IMGUI-paradigm) -- canonical immediate-mode principles: reconstruct widget hierarchy from scratch every frame, maintain separation between view state and model state

### Tertiary (LOW confidence)
- [Designing an Event-Driven ImGui Architecture](https://medium.com/@EDBCBlog/designing-an-event-driven-imgui-architecture-from-zero-to-hero-no-phd-required-82290c082c6a) -- command queue + immediate-mode integration (different framework, same principles)
- [Zig Data-Oriented Design (issue #2078)](https://github.com/ziglang/zig/issues/2078) -- general DOD discussion, SoA patterns, struct layout for cache efficiency

---
*Research completed: 2026-03-27*
