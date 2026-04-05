# Phase 1: GUI Architecture & Cleanup - Research

**Researched:** 2026-04-04
**Domain:** Zig GUI module decomposition, dvui immediate-mode architecture, state migration
**Confidence:** HIGH

## Summary

Phase 1 is a pure architectural refactoring phase -- no new user-facing features. The work decomposes Renderer.zig (1153 LOC) into a Canvas/ subfolder, builds out reusable themed components, strips the toolbar to File/Edit/View only, migrates all 25+ module-level `var` declarations into AppState.gui, replaces page_allocator with GPA in GUI hot paths, and removes stale Arch.md files. Both native and web backends must compile and render after all changes.

The codebase is well-structured for this decomposition. Renderer.zig has clear responsibility boundaries (viewport math, grid, symbol rendering, wire rendering, selection overlay, interaction handling) that map directly to the Canvas/ subfolder files specified in D-01. The module-level state migration is straightforward -- all `var` declarations are simple scalars, rects, booleans, and small array lists that can be embedded as sub-structs in GuiState. The allocator fix requires threading `std.mem.Allocator` through three callsites that currently hardcode `page_allocator`.

**Primary recommendation:** Decompose bottom-up: types.zig first (shared Canvas types), then leaf renderers (Grid, WireRenderer, SymbolRenderer), then Viewport/SelectionOverlay/Interaction, then the Canvas/lib.zig orchestrator. This avoids forward-reference issues and lets each file compile independently.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Split Renderer.zig into Canvas/ subfolder: Viewport.zig, Grid.zig, SymbolRenderer.zig, WireRenderer.zig, SelectionOverlay.zig, Interaction.zig, lib.zig, types.zig
- **D-02:** Canvas/lib.zig preserves z-order: Grid -> Wires -> Junctions -> Symbols -> Labels -> Selection -> Rubber-band -> Crosshair
- **D-03:** Keep existing FloatingWindow and HorizontalBar in Components/
- **D-04:** Extract new reusable widgets (ThemedButton, ThemedPanel, ScrollableList) only where pattern appears 3+ times
- **D-05:** Components/ follows module structure: lib.zig + types.zig + one pub struct per file
- **D-06:** Strip ToolBar to File, Edit, View menus only. Remove Draw, Sim, Plugins menus entirely.
- **D-07:** No stubs or placeholder items. Removed items re-added in their respective phases.
- **D-08:** Review remaining File/Edit/View items -- remove any that reference unimplemented functionality.
- **D-09:** Move all 25+ module-level var declarations from gui/ into sub-structs within GuiState
- **D-10:** Renderer state (subcircuit cache, arena) moves into CanvasState owned by AppState
- **D-11:** Each dialog/panel draw() receives *AppState and reads state from appropriate GuiState sub-struct
- **D-12:** Replace page_allocator with GPA in Renderer.zig line 39, FileExplorer.zig line 38, Theme.zig line 163
- **D-13:** Thread std.mem.Allocator from AppState through all GUI callsites using page_allocator
- **D-14:** Remove all Arch.md files from source tree
- **D-15:** state.zig merged into state/types.zig (old src/state.zig fully superseded)
- **D-16:** Both zig build run (native) and zig build -Dbackend=web must compile and render
- **D-17:** No platform-specific code in gui/

### Claude's Discretion
- Exact naming of Canvas/ sub-files (responsibility split is the intent; adjust file boundaries if implementation reveals a better split)
- Whether to create a RenderContext struct that threads allocator + viewport + theme through sub-renderers, or pass them individually
- Internal helper organization within each Canvas/ file

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-01 | GUI module rebuilt with components/ subfolder containing reusable themed widgets | D-03, D-04, D-05: Component library architecture documented; existing FloatingWindow/HorizontalBar patterns analyzed; 3+ repeat patterns identified (ThemedButton, ThemedPanel, ScrollableList) |
| INFRA-02 | Renderer.zig decomposed into Canvas/ subfolder with single-responsibility components | D-01, D-02: Full 1153 LOC analysis complete; 8 responsibility zones mapped to files; z-order preserved in orchestrator |
| INFRA-03 | Minimal toolbar with File, Edit, View menus only -- all stubs removed | D-06, D-07, D-08: Current ToolBar.zig analyzed; 10 menus identified (File, Edit, View, Wire/Draw, Hierarchy, Netlist, Sim, Export, Transform, Plugins); menus to remove and items to audit documented |
| INFRA-04 | Module-level var state eliminated from GUI files -- all persistent state in AppState.gui | D-09, D-10, D-11: Complete inventory of 25 module-level vars across 9 files; sub-struct design documented |
| INFRA-05 | state.zig merged into types.zig | D-15: Confirmed old src/state.zig already deleted (git status shows D src/state.zig); state/ module already has proper structure |
| INFRA-06 | All Arch.md files removed from source tree | D-14: Only src/gui/Arch.md remains on disk (others already deleted per git status) |
| INFRA-07 | page_allocator replaced with GPA in GUI hot paths | D-12, D-13: Three callsites identified with exact line numbers; allocator threading path documented |
| INFRA-08 | Both native and WASM backends functional and tested | D-16, D-17: Build system module graph analyzed; gui/ compiled as part of exe_mod, not a separate build module; no platform-specific code needed |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Module structure**: Every module MUST be a folder with lib.zig, types.zig, one pub struct per file
- **One pub struct per file** except types.zig which holds shared/simple data types
- **Data-oriented design**: Minimize padding, order fields by alignment, prefer SoA over AoS
- **Frame z-order**: Rendering order in gui/lib.zig matters -- must preserve strict layering
- **Queue commands for undoable ops** -- do not mutate state directly
- **Use Theme.zig palette** -- never hardcode colors
- **Plugin panel contract**: ParsedWidget rendering must stay stable
- **Lint rules**: No std.fs.* or std.posix.getenv outside utility/ and cli/
- **Dual backend**: All GUI code must work on both native and web
- **Naming**: PascalCase.zig for struct files, camelCase for functions, snake_case for fields

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig | 0.15.2 | Language and build system | Project language, verified installed |
| dvui | 0.4.0-dev | Immediate-mode GUI framework | Already in use, fetched from david-vanderson/dvui |
| raylib | (transitive via dvui) | Native window, OpenGL, input | Native backend, pulled by dvui |
| std.heap.GeneralPurposeAllocator | (stdlib) | Application memory management | Project standard; replaces page_allocator |

### Supporting
No new dependencies. Phase is purely internal refactoring of existing code.

### Alternatives Considered
None applicable -- all decisions are locked.

## Architecture Patterns

### Recommended Project Structure (Canvas/ subfolder)

```
src/gui/
├── lib.zig                  # Frame orchestrator (existing, updated imports)
├── Actions.zig              # Command dispatch (unchanged)
├── Keybinds.zig             # Static keybind table (unchanged)
├── Theme.zig                # Color palette (updated: accept allocator param)
├── PluginPanels.zig         # Plugin widget rendering (unchanged)
├── ContextMenu.zig          # Right-click menus (unchanged)
├── FileExplorer.zig         # File browser (updated: state -> GuiState, allocator -> GPA)
├── LibraryBrowser.zig       # Library browser (updated: state -> GuiState)
├── Marketplace.zig          # Plugin marketplace (updated: state -> GuiState)
├── Canvas/                  # NEW: Decomposed from Renderer.zig
│   ├── lib.zig              # Orchestrator: draw() calls sub-renderers in z-order
│   ├── types.zig            # CanvasEvent, RenderViewport, Vec2, Point aliases, drawing constants
│   ├── Viewport.zig         # Coordinate transforms: w2p, p2w, p2w_raw
│   ├── Grid.zig             # Grid drawing, origin crosshair
│   ├── SymbolRenderer.zig   # Instance/subcircuit/prim rendering, subcircuit cache
│   ├── WireRenderer.zig     # Wire segments, endpoints, net labels, junction dots
│   ├── SelectionOverlay.zig # Selection highlight, wire preview overlay
│   └── Interaction.zig      # Mouse/keyboard dvui events -> CanvasEvent translation
├── Bars/
│   ├── ToolBar.zig          # Menu bar (updated: File/Edit/View only)
│   ├── TabBar.zig           # Document tabs (unchanged)
│   └── CommandBar.zig       # Status + command input (unchanged)
├── Components/
│   ├── lib.zig              # NEW: replaces root.zig, re-exports all components
│   ├── types.zig            # NEW: shared component types (if needed)
│   ├── FloatingWindow.zig   # Existing (unchanged)
│   ├── HorizontalBar.zig    # Existing (unchanged)
│   ├── ThemedButton.zig     # NEW: wraps dvui.button with Theme palette
│   ├── ThemedPanel.zig      # NEW: consistent padding/background/border
│   └── ScrollableList.zig   # NEW: scrollable item list (3+ repeat pattern)
└── Dialogs/
    ├── PropsDialog.zig      # Updated: state -> GuiState sub-struct
    ├── FindDialog.zig        # Updated: state -> GuiState sub-struct
    └── KeybindsDialog.zig   # Updated: state -> GuiState sub-struct
```

### Pattern 1: RenderContext Struct (Recommended Discretion Choice)

**What:** A struct that bundles allocator + viewport + palette, threaded to all Canvas/ sub-renderers.
**When to use:** Every Canvas/ draw function needs the same three parameters.
**Why recommended:** Reduces parameter count from 3-4 to 1, makes adding new shared context (e.g., line_width) non-breaking.

```zig
// Canvas/types.zig
pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    vp: RenderViewport,
    pal: Palette,
    cmd_flags: CommandFlags,
};
```

Each sub-renderer takes `ctx: *const RenderContext` plus its domain-specific data (e.g., `sch: *const Schemify`).

### Pattern 2: GuiState Sub-Struct Migration

**What:** Each dialog/panel that currently has module-level `var` gets a corresponding state struct in `state/types.zig`.
**When to use:** For all module-level mutable state that must persist across frames.

```zig
// state/types.zig additions
pub const FileExplorerState = struct {
    sections: std.ArrayListUnmanaged(Section) = .{},
    files: std.ArrayListUnmanaged(FileEntry) = .{},
    selected_section: i32 = -1,
    selected_file: i32 = -1,
    scanned: bool = false,
    preview_name: []const u8 = "",
    win_rect: dvui.Rect = .{ .x = 60, .y = 40, .w = 720, .h = 500 },
};

pub const CanvasState = struct {
    subckt_cache: SubcktCache = .{},
    subckt_arena_state: ?std.heap.ArenaAllocator = null,
    // Interaction state (from Renderer struct fields)
    dragging: bool = false,
    drag_last: @Vector(2, f32) = .{ 0, 0 },
    space_held: bool = false,
    last_click_time: f64 = 0,
    last_click_pos: @Vector(2, f32) = .{ 0, 0 },
};
```

### Pattern 3: Canvas/lib.zig Orchestrator

**What:** Single `draw()` function that calls sub-renderers in strict z-order.
**Why:** Preserves the rendering order contract from CLAUDE.md.

```zig
// Canvas/lib.zig
pub fn draw(app: *AppState) CanvasEvent {
    const pal = Palette.fromDvui(dvui.themeGet());
    // ... setup canvas box, compute viewport ...
    const ctx = RenderContext{ .allocator = app.allocator(), .vp = vp, .pal = pal, .cmd_flags = app.cmd_flags };

    const event = interaction.handleInput(&app.gui.canvas, app, wd, vp);

    if (app.show_grid) grid.draw(&ctx, app.tool.snap_size);
    grid.drawOrigin(&ctx);

    if (app.active()) |doc| {
        switch (app.gui.view_mode) {
            .schematic => {
                wire_renderer.draw(&ctx, &doc.sch, &app.selection);
                symbol_renderer.draw(&ctx, &doc.sch, app, &app.selection);
            },
            .symbol => symbol_renderer.drawSymbol(&ctx, &doc.sch),
        }
        selection_overlay.drawWirePreview(&ctx, app);
    }

    return event;
}
```

### Anti-Patterns to Avoid
- **Module-level `var`:** Never use file-scope mutable state. All persistent state goes in AppState.gui sub-structs. The existing code has 25+ violations of this -- this phase eliminates all of them.
- **page_allocator in hot paths:** Always use the application GPA. page_allocator allocates whole OS pages (4 KiB minimum), wasting memory and syscalls.
- **Hardcoded colors:** Always use Theme.zig palette. Some existing code (FileExplorer, LibraryBrowser) hardcodes `dvui.Color{ .r = 30, .g = 30, .b = 38, .a = 255 }` -- these should use palette colors (addressed in Phase 11 THEME-01, but avoid introducing new hardcoded colors).
- **Breaking Components/root.zig rename:** The current `root.zig` must be renamed to `lib.zig` per module structure rules, but all import paths (`../Components/root.zig`) must be updated simultaneously.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Floating windows | Custom window management | `dvui.floatingWindow` + existing `FloatingWindow` component | Already works on both backends, handles drag, close button, modal |
| Scroll areas | Custom scrolling logic | `dvui.scrollArea` | Existing pattern used in FileExplorer, LibraryBrowser, Keybinds |
| Menu system | Custom dropdown menus | `dvui.menu` + `dvui.menuItemLabel` + `dvui.floatingMenu` | ToolBar.zig already uses this pattern correctly |
| Coordinate transforms | New math library | Existing `w2p`, `p2w`, `p2w_raw` functions | Proven correct, just move to Canvas/Viewport.zig |
| Path rendering | Custom line drawing | `dvui.Path.stroke` | Already used for all canvas primitives |

## Common Pitfalls

### Pitfall 1: Components/root.zig -> lib.zig Rename Breaks Imports
**What goes wrong:** Renaming root.zig to lib.zig without updating all import sites causes compilation failures.
**Why it happens:** ToolBar.zig, FindDialog.zig, KeybindsDialog.zig all import `../Components/root.zig`.
**How to avoid:** Search for all `root.zig` imports and update atomically. There are exactly 3 import sites:
- `src/gui/Bars/ToolBar.zig` line 8: `@import("../Components/root.zig")`
- `src/gui/Dialogs/FindDialog.zig` line 6: `@import("../Components/root.zig")`
- `src/gui/Dialogs/KeybindsDialog.zig` line 7: `@import("../Components/root.zig")`
**Warning signs:** `error: FileNotFound: 'root.zig'` during build.

### Pitfall 2: gui/ Is Not a Build Module -- Files Are Part of exe_mod
**What goes wrong:** Attempting to create a "gui" entry in build.zig module_defs or expecting `@import("gui")` to work.
**Why it happens:** The gui/ folder is NOT registered as a named module in build.zig. It's compiled as part of the main.zig executable module. gui/lib.zig is imported directly by main.zig via `@import("gui/lib.zig")` or similar path.
**How to avoid:** New files in gui/ (like Canvas/lib.zig) are imported via relative path from gui/lib.zig. No build.zig changes needed for the Canvas/ subfolder.
**Warning signs:** `error: module 'gui' not found`.

### Pitfall 3: theme_config Module Is gui/Theme.zig
**What goes wrong:** Moving Theme.zig or changing its public API breaks the `theme_config` build module.
**Why it happens:** build.zig line 24 defines `theme_config` with root source `src/gui/Theme.zig`. The plugins module and Renderer.zig both import `theme_config`.
**How to avoid:** When modifying Theme.zig (D-12: accept allocator param for applyJson), keep the public API backwards-compatible. The `applyJson(json_str: []const u8)` signature currently uses page_allocator internally -- change the internal implementation to accept an allocator parameter while keeping the public API signature if possible, or update all callers.
**Warning signs:** Build failure mentioning `theme_config` module.

### Pitfall 4: KeybindsDialog.open Is pub var -- Used by gui/lib.zig
**What goes wrong:** Moving `open` into GuiState but forgetting to update gui/lib.zig lines 74-75 which directly access `keybinds_dlg.open`.
**Why it happens:** gui/lib.zig has special sync logic: `keybinds_dlg.open = keybinds_dlg.open or app.gui.keybinds_open;`.
**How to avoid:** After migrating KeybindsDialog state to GuiState, update gui/lib.zig to use `app.gui.keybinds_dialog.open` directly. The sync with `keybinds_open` flag should be simplified.
**Warning signs:** Keybinds dialog won't open from keybind but opens from menu, or vice versa.

### Pitfall 5: Subcircuit Cache Uses Arena with page_allocator
**What goes wrong:** Simply replacing `page_allocator` with GPA in the arena init causes the cache to leak -- arenas require explicit `reset()` or `deinit()`.
**Why it happens:** The current code initializes `ArenaAllocator.init(std.heap.page_allocator)` lazily and never deinits it. Moving to GPA means the arena must be properly lifecycled.
**How to avoid:** The CanvasState struct must own the arena. AppState.deinit() must call `canvas_state.subckt_arena_state.?.deinit()`. The arena backing allocator should be `app.gpa.allocator()`.
**Warning signs:** Memory leak detected by GPA in debug builds.

### Pitfall 6: ToolBar Inline For Uses Comptime Indices
**What goes wrong:** Removing menus from `simple_menus` array changes the indices used in `id_extra` for dvui widgets, potentially causing widget ID collisions.
**Why it happens:** ToolBar.zig uses `inline for (simple_menus[0..2], 0..)` and `inline for (simple_menus[2..], 0..)` with index-based id_extra values. Changing the array changes all downstream IDs.
**How to avoid:** After stripping to File/Edit/View, rewrite the menu rendering to use stable id_extra values (not dependent on array position). Use comptime string hashing or fixed constants.
**Warning signs:** Menu items flickering or dvui widget assertion failures about duplicate IDs.

### Pitfall 7: FileExplorer Uses std.fs.path Functions
**What goes wrong:** `FileExplorer.zig` line 239 calls `std.fs.path.isAbsolute()` and line 340 calls `std.fs.path.basename()`. The build-time lint step bans `std.fs.*` outside utility/ and cli/.
**Why it happens:** `std.fs.path` is a path manipulation module (no I/O), but the lint regex may match it.
**How to avoid:** Check if the lint step in build.zig matches `std.fs.path` or only `std.fs.` followed by I/O operations. If it matches path functions, use Vfs equivalents or move the path helpers to utility/.
**Warning signs:** Build lint failure on FileExplorer.zig.

## Complete Module-Level Var Inventory

This is the exhaustive list of all module-level `var` declarations that must be migrated to GuiState sub-structs per D-09/D-10:

### gui/lib.zig (1 var)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `renderer_state` | `Renderer` (interaction state) | `GuiState.canvas: CanvasState` |

### gui/Renderer.zig (2 vars)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `subckt_cache` | `SubcktCache` | `CanvasState.subckt_cache` |
| `subckt_arena_state` | `?std.heap.ArenaAllocator` | `CanvasState.subckt_arena_state` |

### gui/FileExplorer.zig (7 vars)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `sections` | `ArrayListUnmanaged(Section)` | `GuiState.file_explorer.sections` |
| `files` | `ArrayListUnmanaged(FileEntry)` | `GuiState.file_explorer.files` |
| `selected_section` | `i32` | `GuiState.file_explorer.selected_section` |
| `selected_file` | `i32` | `GuiState.file_explorer.selected_file` |
| `scanned` | `bool` | `GuiState.file_explorer.scanned` |
| `preview_name` | `[]const u8` | `GuiState.file_explorer.preview_name` |
| `win_rect` | `dvui.Rect` | `GuiState.file_explorer.win_rect` |

### gui/LibraryBrowser.zig (2 vars)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `win_rect` | `dvui.Rect` | `GuiState.library_browser.win_rect` |
| `selected_prim` | `i32` | `GuiState.library_browser.selected_prim` |

### gui/Marketplace.zig (1 var)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `win_rect` | `dvui.Rect` | `GuiState.marketplace.win_rect` (MarketplaceState already exists, add win_rect) |

### gui/Dialogs/FindDialog.zig (5 vars)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `is_open` | `bool` | `GuiState.find_dialog.is_open` |
| `query_buf` | `[128]u8` | `GuiState.find_dialog.query_buf` |
| `query_len` | `usize` | `GuiState.find_dialog.query_len` |
| `result_count` | `usize` | `GuiState.find_dialog.result_count` |
| `win_rect` | `dvui.Rect` | `GuiState.find_dialog.win_rect` |

### gui/Dialogs/PropsDialog.zig (4 vars)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `is_open` | `bool` | `GuiState.props_dialog.is_open` |
| `view_only` | `bool` | `GuiState.props_dialog.view_only` |
| `inst_idx` | `usize` | `GuiState.props_dialog.inst_idx` |
| `win_rect` | `dvui.Rect` | `GuiState.props_dialog.win_rect` |

### gui/Dialogs/KeybindsDialog.zig (2 vars)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `open` | `bool` (pub) | `GuiState.keybinds_dialog.open` |
| `win_rect` | `dvui.Rect` | `GuiState.keybinds_dialog.win_rect` |

### gui/Theme.zig (1 pub var)
| Variable | Type | Target Sub-Struct |
|----------|------|-------------------|
| `current_overrides` | `ThemeOverrides` | Keep as `pub var` -- written by plugin runtime via SET_CONFIG. This is intentionally global mutable state for the plugin override protocol. It does NOT need to move to GuiState. |

**Total: 25 vars to migrate + 1 intentionally kept (Theme.current_overrides).**

## ToolBar Menu Stripping Analysis

### Current Menus (10 total)
1. **File** -- KEEP (D-06)
2. **Edit** -- KEEP (D-06)
3. **View** -- KEEP (D-06, special: dynamic grid toggle)
4. **Wire/Draw** -- REMOVE (Phase 6)
5. **Hierarchy** -- REMOVE (Phase 10)
6. **Netlist** -- REMOVE (Phase 9)
7. **Sim** -- REMOVE (Phase 9)
8. **Export** -- REMOVE (Phase 10)
9. **Transform** -- REMOVE (Phase 5)
10. **Plugins** (dynamic) -- REMOVE (Phase 11)

### Items to Audit in Remaining Menus (D-08)

**File menu -- review for unimplemented items:**
- "Start New Process [Ctrl+Shift+N]" -- spawns a new OS process. Functional on native, skip on WASM. KEEP (functional).
- "View Logs [Ctrl+L]" -- opens log viewer. Check if implemented. If stub, REMOVE.
- "Reload from Disk [Alt+S]" -- reloads file. KEEP if functional.
- "Clear Schematic [Ctrl+N]" -- clears current doc. KEEP.

**Edit menu -- review for unimplemented items:**
- "Move [M]" -- sets tool mode. KEEP (basic mode switch works).
- "Copy Selected [C]" -- copy mode. Verify if functional. If stub, REMOVE.
- "Duplicate [D]" -- duplicates selected. KEEP (partially works per CONCERNS.md).
- "Align to Grid [Alt+U]" -- verify if implemented.
- "Highlight Dup Refs [#]" -- uses stub setProp. REMOVE (non-functional).
- "Fix Dup Refs" -- uses stub setProp. REMOVE (non-functional).

**View menu -- review for unimplemented items:**
- "Toggle Fullscreen [\\]" -- platform-dependent. Verify both backends.
- "Show Netlist Overlay" -- verify if rendering code exists.
- "Toggle Text in Symbols" -- verify.
- "Toggle Symbol Details" -- verify.
- "Increase/Decrease Line Width" -- likely works (modifies cmd_flags.line_width).
- "Schematic View [S]" / "Symbol View [W]" -- functional view mode toggle. KEEP.

The planner should verify each questionable item compiles and has a handler in Dispatch.zig before deciding to keep or remove.

## Allocator Threading Path (D-12, D-13)

### Callsite 1: Renderer.zig subcircuit cache (line 39)
```
subckt_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
```
**Fix:** CanvasState owns the arena. Init with `app.gpa.allocator()`. Thread via AppState.

### Callsite 2: FileExplorer.zig (line 38)
```
const gpa = std.heap.page_allocator;
```
**Fix:** Remove the constant. All functions that currently use `gpa` should accept `app.allocator()` via the `*AppState` parameter that `draw()` already receives.

### Callsite 3: Theme.zig applyJson (line 163)
```
const alloc = std.heap.page_allocator;
```
**Fix:** Since `applyJson` is called from the plugin runtime (which has access to AppState), change the signature to `applyJson(alloc: std.mem.Allocator, json_str: []const u8)`. The plugin runtime passes `app.allocator()`. Note: Theme.zig is the root of the `theme_config` build module, so this API change affects plugins/runtime.zig which imports theme_config.

## Arch.md Files to Delete (D-14)

Git status shows these as deleted (already staged):
- `src/Arch.md`
- `src/commands/Arch.md`
- `src/core/Arch.md`
- `src/plugins/Arch.md`
- `src/utility/Arch.md`
- `src/web/Arch.md`

Still on disk (not yet staged):
- `src/gui/Arch.md` (found by glob)

**Action:** Delete `src/gui/Arch.md` and confirm all others are already gone.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in test + custom runner |
| Config file | `build.zig` test_defs array |
| Quick run command | `zig build test` |
| Full suite command | `zig build test` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INFRA-01 | Components/ has lib.zig, types.zig, ThemedButton, ThemedPanel, ScrollableList | smoke | `zig build` (compile check) | Wave 0 |
| INFRA-02 | Canvas/ subfolder compiles with correct z-order | smoke | `zig build` (compile check) | Wave 0 |
| INFRA-03 | ToolBar only shows File/Edit/View | manual | Run app, verify menus | N/A (manual) |
| INFRA-04 | Zero module-level var in gui/ | unit | `grep "^var " src/gui/ -r` (lint check) | Wave 0 |
| INFRA-05 | src/state.zig does not exist | smoke | `test ! -f src/state.zig` | Already true |
| INFRA-06 | No Arch.md in src/ | smoke | `find src/ -name Arch.md` returns empty | Wave 0 |
| INFRA-07 | No page_allocator in gui/ | unit | `grep "page_allocator" src/gui/ -r` returns empty | Wave 0 |
| INFRA-08 | Both backends compile | smoke | `zig build && zig build -Dbackend=web` | Wave 0 |

### Sampling Rate
- **Per task commit:** `zig build` (native compile check)
- **Per wave merge:** `zig build && zig build -Dbackend=web && zig build test`
- **Phase gate:** Full suite green + manual verification of both backends rendering

### Wave 0 Gaps
- [ ] Add a lint test for module-level var detection in gui/ (simple grep-based check)
- [ ] Add a lint test for page_allocator usage in gui/
- [ ] No new test files needed -- this is a structural refactoring phase. Compile success is the primary validation.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Zig | All compilation | Yes | 0.15.2 | -- |
| Python 3 | Web dev server (zig build run_local) | Yes | 3.13.12 | -- |
| raylib | Native backend (transitive via dvui) | Yes (fetched by zig build) | (via dvui) | -- |
| X11 libs | Native backend on Linux | Yes (hardcoded in build.zig) | -- | -- |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

## Code Examples

### Canvas/types.zig -- Shared Types
```zig
// Canvas/types.zig -- shared types for all canvas sub-renderers
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");
const st = @import("state");

pub const Point = [2]i32;
pub const Vec2 = @Vector(2, f32);
pub const Color = dvui.Color;
pub const Palette = theme.Palette;

pub const RenderViewport = struct {
    cx: f32,
    cy: f32,
    scale: f32,
    pan: [2]f32,
    bounds: dvui.Rect.Physical,
};

pub const CanvasEvent = union(enum) {
    none,
    click: Point,
    double_click: Point,
    right_click: struct { pixel: Vec2, world: Point },
};

// Drawing constants (moved from Renderer.zig bottom)
pub const grid_min_step_px: f32 = 3.0;
pub const grid_max_points: f32 = 16_000.0;
pub const wire_endpoint_radius: f32 = 2.5;
pub const wire_preview_dot_radius: f32 = 4.0;
pub const wire_preview_arm: f32 = 8.0;
pub const inst_hit_tolerance: f32 = 14.0;
pub const wire_hit_tolerance: f32 = 10.0;
```

### Canvas/Viewport.zig -- Coordinate Transforms
```zig
// Canvas/Viewport.zig -- world <-> pixel coordinate transforms
const types = @import("types.zig");
const Vec2 = types.Vec2;
const Point = types.Point;
const RenderViewport = types.RenderViewport;

pub inline fn w2p(pt: Point, vp: RenderViewport) Vec2 {
    const world: Vec2 = @floatFromInt(@as(@Vector(2, i32), pt));
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    const s: Vec2 = @splat(vp.scale);
    const center: Vec2 = .{ vp.cx, vp.cy };
    return center + (world - pan) * s;
}

pub inline fn p2w_raw(pt: Vec2, vp: RenderViewport) Vec2 {
    const center: Vec2 = .{ vp.cx, vp.cy };
    const s: Vec2 = @splat(vp.scale);
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    return (pt - center) / s + pan;
}

pub inline fn p2w(pt: Vec2, vp: RenderViewport, snap: f32) Point {
    const world = p2w_raw(pt, vp);
    const gs: f32 = if (snap > 0) snap else 1.0;
    return .{
        @intFromFloat(@round(world[0] / gs) * gs),
        @intFromFloat(@round(world[1] / gs) * gs),
    };
}
```

### GuiState Sub-Struct Addition Pattern
```zig
// state/types.zig -- additions for dialog/panel state
pub const FileExplorerState = struct {
    sections: std.ArrayListUnmanaged(FileExplorerSection) = .{},
    files: std.ArrayListUnmanaged(FileEntry) = .{},
    selected_section: i32 = -1,
    selected_file: i32 = -1,
    scanned: bool = false,
    preview_name: []const u8 = "",
    win_rect: dvui.Rect = .{ .x = 60, .y = 40, .w = 720, .h = 500 },
};

pub const GuiState = struct {
    // ... existing fields ...
    canvas: CanvasState = .{},
    file_explorer: FileExplorerState = .{},
    library_browser: LibraryBrowserState = .{},
    find_dialog: FindDialogState = .{},
    props_dialog: PropsDialogState = .{},
    keybinds_dialog: KeybindsDialogState = .{},
};
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Module-level `var` for GUI state | Sub-structs in AppState.gui | This phase | Eliminates global mutable state fragility |
| Monolithic Renderer.zig (1153 LOC) | Canvas/ subfolder with 8 files | This phase | Single-responsibility, testable units |
| page_allocator in hot paths | GPA threaded from AppState | This phase | Better memory efficiency, leak detection |
| Components/root.zig | Components/lib.zig | This phase | Aligns with module structure rules |

## Open Questions

1. **Theme.zig `current_overrides` pub var**
   - What we know: It's written by plugin runtime via SET_CONFIG message. It's intentionally global.
   - What's unclear: Should it move to AppState or stay as a pub var? Moving it requires the plugin runtime to have a path to AppState for theme writes.
   - Recommendation: Keep as pub var for now. It's the theme override protocol, not GUI dialog state. Moving it is a separate concern for Phase 11 (PLUG-01/THEME-01).

2. **FileExplorer Section/FileEntry Types**
   - What we know: These types are defined locally in FileExplorer.zig. Moving state to GuiState means these types need to be visible from state/types.zig.
   - What's unclear: Should the types live in state/types.zig or in a gui-accessible location?
   - Recommendation: Define minimal state types (just the data fields) in state/types.zig. The rendering-specific types stay in FileExplorer.zig.

3. **dvui.Rect in GuiState**
   - What we know: Several win_rect fields use `dvui.Rect`. The state module already imports dvui (indirectly via commands which imports dvui).
   - What's unclear: Does state/types.zig have access to dvui types?
   - Recommendation: Check build.zig -- the state module does NOT import dvui directly. The win_rect fields should use a plain struct `{ x: f32, y: f32, w: f32, h: f32 }` in state/types.zig, or add dvui as an import to the state module. The planner must resolve this dependency.

## Sources

### Primary (HIGH confidence)
- `src/gui/Renderer.zig` -- Full 1153 LOC analysis, all responsibility zones mapped
- `src/gui/lib.zig` -- Frame orchestrator, z-order, input handling (350 LOC)
- `src/gui/Bars/ToolBar.zig` -- Complete menu structure (290 LOC)
- `src/state/types.zig` -- Current GuiState definition (260 LOC)
- `src/state/AppState.zig` -- God object, allocator source (207 LOC)
- `build.zig` -- Module graph: gui is NOT a named module; part of exe_mod
- All gui/ dialog/panel files -- Complete module-level var inventory

### Secondary (MEDIUM confidence)
- `.planning/codebase/CONCERNS.md` -- Tech debt, fragile areas, page_allocator issues
- `.planning/codebase/STRUCTURE.md` -- Directory layout, naming conventions
- `.planning/codebase/TESTING.md` -- Test infrastructure and patterns
- `~/.claude/skills/Zig-Design-Patterns/skill.md` -- One-type-per-file, allocator contract patterns

### Tertiary (LOW confidence)
- None. All findings are from direct code analysis.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new dependencies, purely internal refactoring
- Architecture: HIGH -- decomposition boundaries clearly visible in existing 1153 LOC file
- Pitfalls: HIGH -- identified from direct code analysis of import paths, build.zig, and module-level state

**Research date:** 2026-04-04
**Valid until:** 2026-05-04 (stable -- internal refactoring, no external dependency risk)
