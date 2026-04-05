# Phase 1: GUI Architecture & Cleanup - Context

**Gathered:** 2026-04-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish the decomposed GUI module structure that all subsequent phases build on. Decompose Renderer.zig into a Canvas/ subfolder, build out the Components/ library with reusable themed widgets, strip the toolbar to File/Edit/View only, migrate all module-level `var` state into AppState.gui, replace page_allocator with GPA in GUI hot paths, remove Arch.md files, and verify both backends compile and render.

This phase delivers **architecture only** — no new user-facing features. Canvas interaction (pan/zoom), rendering, selection, editing, and all other functional work happens in later phases.

</domain>

<decisions>
## Implementation Decisions

### Renderer Decomposition (INFRA-02)
- **D-01:** Split Renderer.zig (1152 LOC) into a `Canvas/` subfolder with single-responsibility files:
  - `Canvas/Viewport.zig` — coordinate transforms, pan/zoom math, world↔screen conversion
  - `Canvas/Grid.zig` — grid rendering (dots/lines/none), adaptive density
  - `Canvas/SymbolRenderer.zig` — instance/subcircuit drawing + LRU subcircuit cache
  - `Canvas/WireRenderer.zig` — wire, junction dot, net label rendering
  - `Canvas/SelectionOverlay.zig` — selection highlight, rubber-band preview
  - `Canvas/Interaction.zig` — mouse/keyboard dvui events → CanvasEvent translation
  - `Canvas/lib.zig` — orchestrator that calls each sub-renderer in z-order, public API
  - `Canvas/types.zig` — shared canvas types (CanvasEvent, RenderContext, etc.)
- **D-02:** The orchestrator in `Canvas/lib.zig` preserves the existing frame z-order: Grid → Wires → Junctions → Symbols → Labels → Selection → Rubber-band → Crosshair

### Component Library (INFRA-01)
- **D-03:** Keep existing FloatingWindow and HorizontalBar in Components/
- **D-04:** Extract new reusable widgets only where the pattern appears 3+ times in the codebase:
  - Themed button (wraps dvui.button with Theme palette colors)
  - Themed panel (consistent padding, background, border from Theme)
  - Scrollable list (pattern repeats in FileExplorer, LibraryBrowser, Marketplace, KeybindsDialog)
- **D-05:** Components/ follows the module structure: `lib.zig` + `types.zig` + one pub struct per file

### Toolbar Stripping (INFRA-03)
- **D-06:** Strip ToolBar to File, Edit, View menus only. Remove Draw, Sim, Plugins menus entirely.
- **D-07:** No stubs or placeholder items. Removed items get re-added in their respective phases (Phase 5: Draw, Phase 9: Sim, Phase 11: Plugins).
- **D-08:** Review remaining File/Edit/View items — remove any that reference unimplemented functionality.

### State Migration (INFRA-04)
- **D-09:** Move all 25+ module-level `var` declarations from gui/ files into sub-structs within `GuiState` (in `src/state/types.zig`):
  - `GuiState.file_explorer: FileExplorerState`
  - `GuiState.library_browser: LibraryBrowserState`
  - `GuiState.marketplace: MarketplaceState`
  - `GuiState.find_dialog: FindDialogState`
  - `GuiState.props_dialog: PropsDialogState`
  - `GuiState.keybinds_dialog: KeybindsDialogState`
- **D-10:** Renderer state (subcircuit cache, arena) moves into a `CanvasState` struct. CanvasState is owned by AppState (not module-level).
- **D-11:** Each dialog/panel `draw()` function receives `*AppState` and reads its state from the appropriate GuiState sub-struct.

### Allocator Fixes (INFRA-07)
- **D-12:** Replace `std.heap.page_allocator` with the application GPA in:
  - `gui/Renderer.zig` line 39 (subcircuit cache arena) → use allocator from AppState
  - `gui/FileExplorer.zig` line 38 (global gpa) → accept allocator parameter
  - `gui/Theme.zig` line 163 (theme JSON parsing) → accept allocator parameter
- **D-13:** Thread `std.mem.Allocator` from AppState through to all GUI callsites that currently use page_allocator.

### Cleanup (INFRA-05, INFRA-06)
- **D-14:** Remove all Arch.md files from source tree (src/Arch.md, src/commands/Arch.md, src/core/Arch.md, src/plugins/Arch.md, src/utility/Arch.md, src/web/Arch.md)
- **D-15:** state.zig merged into state/types.zig — state is types, not a separate module concept. (Note: state/ module already exists with proper structure; this confirms the old `src/state.zig` singleton is fully superseded.)

### Dual Backend (INFRA-08)
- **D-16:** After all changes, both `zig build run` (native) and `zig build -Dbackend=web` must compile and render the GUI shell without crashes.
- **D-17:** No platform-specific code in gui/ — all backend differences handled by dvui.

### Claude's Discretion
- Exact naming of Canvas/ sub-files (the responsibility split above is the intent; Claude can adjust file boundaries if implementation reveals a better split)
- Whether to create a `RenderContext` struct that threads allocator + viewport + theme through sub-renderers, or pass them individually
- Internal helper organization within each Canvas/ file

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Module Structure
- `CLAUDE.md` §Module Structure Rules — lib.zig/types.zig/one-pub-struct-per-file rules
- `CLAUDE.md` §Source Layout — directory structure reference
- `CLAUDE.md` §GUI Architecture — frame rendering order, data flow, dvui patterns

### Existing Code
- `src/gui/Renderer.zig` — the 1152 LOC file being decomposed (read fully before splitting)
- `src/gui/lib.zig` — frame orchestrator, z-order, input handling (349 LOC)
- `src/gui/Components/FloatingWindow.zig` — existing component pattern (57 LOC)
- `src/gui/Components/HorizontalBar.zig` — existing component pattern (53 LOC)
- `src/gui/Bars/ToolBar.zig` — current menu structure (289 LOC, needs stripping)
- `src/state/types.zig` — current GuiState definition (where new sub-structs go)
- `src/state/AppState.zig` — god object, allocator source

### Codebase Analysis
- `.planning/codebase/STRUCTURE.md` — directory layout and naming conventions
- `.planning/codebase/CONCERNS.md` — module-level var fragility, page_allocator issues, Renderer fragility

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `gui/Components/FloatingWindow.zig` — dialog window wrapper, already used by FileExplorer/LibraryBrowser/Marketplace
- `gui/Components/HorizontalBar.zig` — horizontal layout bar, used in toolbar area
- `gui/Theme.zig` — color palette with JSON overrides, already defines the theming pattern
- `gui/Keybinds.zig` — comptime sorted table with binary search, clean pattern

### Established Patterns
- dvui immediate-mode: `var box = dvui.box(@src(), ...); defer box.deinit();`
- Command dispatch: `actions.enqueue(app, .{ .undoable = .X }, "msg")` for undoable, `.immediate` for instant
- Module structure: lib.zig re-exports, types.zig holds shared types, one pub struct per file
- State access: `app.gui` for GUI state, `app.active()` for current document

### Integration Points
- `gui/lib.zig:frame()` — the single entry point called by main.zig each frame
- `main.zig:appFrame()` — drains command queue, ticks plugins, then calls gui.frame()
- `app.plugin_runtime_ptr` — cast to `*Runtime` in PluginPanels for widget rendering
- `build.zig` — module graph wiring (gui module imports dvui, state, commands, core, plugins, utility, theme_config)

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. The decomposition follows naturally from the responsibility boundaries already visible in Renderer.zig.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 01-gui-architecture-cleanup*
*Context gathered: 2026-04-04*
