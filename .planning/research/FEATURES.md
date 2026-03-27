# Feature Landscape: GUI Layer Cleanup & Refactoring

**Domain:** Immediate-mode GUI layer refactoring in Zig EDA schematic editor (dvui)
**Researched:** 2026-03-27
**Confidence:** HIGH (direct codebase analysis -- every file read and catalogued)

---

## Table Stakes

Features that must be completed for the GUI layer to be considered "clean." Omitting any of these leaves the codebase in an inconsistent half-refactored state that is worse than the current state.

| # | Feature | Why Expected | Complexity | Current State |
|---|---------|--------------|------------|---------------|
| T1 | Delete dead Input/ stubs | 3 files (52 lines total) that do nothing. Handler.zig and KeyboardInputHandler.zig are 5-line doc comments. MouseInputHandler.zig defines a `PanState` struct that is never imported by any other file. Dead code confuses contributors and obscures where input actually lives. | Low | Input/Handler.zig (5L), Input/KeyboardInputHandler.zig (5L), Input/MouseInputHandler.zig (42L) -- all dead |
| T2 | Remove Renderer.zig `@import("core")` | Renderer.zig imports `core` directly to access `Schemify`, `DeviceKind`, and `primitives`. This violates the GUI->state->core layering rule. GUI should only read data through `state.AppState`. | Med | Line 5: `const core = @import("core");` used for `core.Schemify`, `core.DeviceKind`, `core.primitives` |
| T3 | Remove View.zig `@import("dvui")` | The commands layer (View.zig) imports dvui to call `dvui.themeSet()` and `dvui.Theme.builtin.*` in `toggle_colorscheme`. Commands should set flags; GUI reads flags and calls dvui. | Med | Line 5: `const dvui = @import("dvui");` used only in `toggle_colorscheme` handler (lines 43-48) |
| T4 | Consolidate module-level GUI state into AppState.GuiState | 8 files store state in module-level `var` declarations instead of in `AppState.GuiState`. This state is invisible to serialization, testing, and reset logic. | Med-High | FileExplorer (7 vars), LibraryBrowser (4 vars), Marketplace (1 var: win_rect), FindDialog (4 vars), PropsDialog (4 vars), KeybindsDialog (2 vars), lib.zig (1 var: renderer_state), Theme.zig (1 var: current_overrides) |
| T5 | Consolidate Renderer pan/zoom state into AppState | Renderer.zig stores `zoom`, `pan`, `snap_size`, `show_grid`, `wire_start`, `dragging`, `drag_last`, `space_held`, `last_click_time`, `last_click_pos` as struct fields on a module-level `renderer_state` var. Most of these duplicate or shadow `AppState.view` and `AppState.tool`. | Med | `Renderer` struct has 10 fields; `AppState.view` has `pan` and `zoom`; `AppState.tool` has `snap_size` and `wire_start`. Two sources of truth for the same data. |
| T6 | Split Renderer.zig (<400 LOC per file target) | At 844 lines, Renderer.zig is the largest file and mixes: coordinate transforms (60L), grid drawing (40L), schematic drawing (160L), symbol drawing (90L), wire preview (10L), primitive lookup/mapping (100L), stroke helpers (80L), input handling (90L), generic/prim drawing (60L). These are separable concerns. | Med | 844 lines. Natural split: canvas input, drawing primitives, schematic render, coordinate math |
| T7 | Standardize GUI draw function signatures | Most GUI files follow `draw(app: *AppState) void` but some deviate: KeybindsDialog.draw ignores app (`_ = app`), FindDialog.draw uses module-level state instead of app. All draw functions should take `*AppState` and source their state from it. | Low | Inconsistency across dialogs; some take app but don't use it |

---

## Differentiators

Refactoring improvements that go beyond fixing violations to actively improve the architecture. These make the codebase noticeably better to work in but are not strictly required to fix the identified problems.

| # | Feature | Value Proposition | Complexity | Notes |
|---|---------|-------------------|------------|-------|
| D1 | Extract Renderer coordinate math to state/core | `w2p`, `p2w`, `p2w_raw` are pure math functions that transform between world coordinates and pixel coordinates given a viewport. They have no dvui dependency and belong in `state.zig` alongside the Viewport type, or in a small utility. This makes them testable without a GUI context. | Low | 30 lines. `w2p`, `p2w`, `p2w_raw` are `pub inline fn` -- pure math on `Viewport` struct. Currently in Renderer.zig lines 765-790. |
| D2 | Extract kindToName / lookupPrim to core | `kindToName` (44 lines) maps `DeviceKind` enum to `.chn_prim` file names. `lookupPrim` (47 lines) chains kind-based lookup, symbol name resolution, and alias map. Both are data-model logic that happens to be called from the renderer. Moving them to `core/Devices.zig` or `core/primitives.zig` makes them testable and reusable by netlist/export code. | Low | 91 lines. Pure data mapping, no dvui dependency. |
| D3 | Data-orient remaining menus with comptime tables | ToolBar.zig already uses comptime `MenuItem` tables effectively. ContextMenu.zig also uses comptime tables. But the Toolbar `drawMenus` function (lines 175-282) is 107 lines of repetitive `if (dvui.menuItemLabel(...)) |r| { var fw = dvui.floatingMenu(...); renderItems(...); }` -- one block per menu. A comptime array of `Menu` structs (name + items slice) with a generic `drawMenuBar` function would cut this to ~20 lines. | Med | Would consolidate 9 near-identical menu blocks into one comptime loop. Toolbar already has the MenuItem abstraction; needs one more level. |
| D4 | Create `Components/ScrollList.zig` pattern | FileExplorer, LibraryBrowser, and Marketplace all implement the same pattern: a scrollable list of selectable cards with highlight-on-selected and click-to-select. Each reimplements it with ~40 lines of dvui box+scroll+card+click code. A comptime-parameterized `ScrollList` component (like `FloatingWindow` and `HorizontalBar`) would DRY these up. | Med | 3 consumers already exist. Pattern: scroll area -> for items -> box with conditional highlight -> click handler. |
| D5 | Move SVG export logic out of View.zig | `writeSvgFile` (lines 192-238) and `doExport` (lines 147-190) in View.zig are 90 lines of SVG generation and process spawning. This is business logic in the command layer, not view-flag handling. It should move to core (SVG export) and a separate command handler (process spawning). | Med | `writeSvgFile` constructs SVG markup and writes via Vfs. `doExport` spawns rsvg-convert. Neither belongs in a "View" command handler that should only toggle flags. |
| D6 | Unify dialog open/close through AppState flags | Dialogs currently use a mix of: module-level `var is_open: bool` (FindDialog, PropsDialog), `pub var open: bool` (KeybindsDialog), `app.gui.keybinds_open` flag + sync dance (lib.zig lines 71-73), and `app.open_file_explorer` / `app.open_library_browser` (direct AppState bools). A single `DialogState` enum set in `GuiState` would make open/close consistent and serializable. | Low-Med | Currently 6 different mechanisms for dialog visibility. Some are AppState bools, some are module vars, one uses both with a sync dance. |
| D7 | Remove duplicate `classifyFile` | `classifyFile` is defined identically in both `Renderer.zig` (lines 210-219) and `Bars/TabBar.zig` (lines 22-31). It classifies `Origin` into `FileType`. Should exist once, in `state.zig` alongside the `Origin` type. | Low | Exact duplicate. 10 lines each. |
| D8 | Extract `drawSchematic` entity-type iteration to helpers | `drawSchematic` (lines 225-384, 160 lines) iterates over wires, lines, rects, circles, arcs, instances, net labels, and texts with nearly identical SoA-access + w2p + strokeLine patterns. Extracting `drawEntities(comptime EntityType, sch, vp, pal, drawOneFn)` would make each entity type a 5-line call instead of a 20-line block. | Med | 8 entity types with similar iteration patterns. Comptime generic possible because `sch.wires.items(.x0)` etc. follow the same MultiArrayList API. |
| D9 | Move `applyRotFlip` to core geometry utilities | `applyRotFlip` is a pure 2D transform (8 lines). It has no GUI dependency and is general-purpose EDA geometry. Belongs alongside coordinate transforms in core or state. | Low | Pure math, 8 lines. Used by `drawPrimEntry` and `drawGenericBox`. |

---

## Anti-Features

Features to explicitly NOT build during this cleanup. Each has specific rationale tied to the project constraints.

| # | Anti-Feature | Why Avoid | What to Do Instead |
|---|--------------|-----------|-------------------|
| A1 | New GUI features (functional file explorer, working library browser, property editor) | PROJECT.md explicitly marks "No new features." FileExplorer, LibraryBrowser, and PropsDialog are stubs with TODO comments. Adding functionality is scope creep. | Clean up the stubs (consolidate state, fix signatures), but keep TODO comments. Stubs are legitimate scaffolding. |
| A2 | Retained-mode widget abstraction layer | dvui is immediate-mode by design. Adding a retained-mode wrapper (widget tree, persistent widget objects, event delegation) fights the framework. The draw-every-frame model means state lives in AppState, not in widgets. | Keep immediate-mode: each `draw()` function reads AppState, calls dvui, done. This is the correct pattern for dvui. |
| A3 | Full MVC/MVVM architecture | Over-structured for immediate-mode GUI. In IMGUI, the "view model" IS the app state -- there is no separate view model layer. Adding one creates busywork forwarding. | State.zig IS the model. GUI files ARE the view. Commands ARE the controller. The layering is already MVC-like without the ceremony. |
| A4 | Abstract dvui behind a custom rendering interface | Wrapping dvui in an abstract `Renderer` trait to enable "future backend swap" adds indirection for a swap that will never happen. dvui is the framework; it is embedded in every draw call. | Call dvui directly. The abstraction boundary is GUI -> state, not GUI -> abstract_renderer -> dvui. |
| A5 | Unit tests for GUI draw functions | Immediate-mode draw functions produce side effects (dvui draw calls). Testing them requires mocking dvui's entire widget system. The ROI is low. | Test the data layer (state mutations, coordinate transforms, property lookups) which is now extractable thanks to this refactoring. Test GUI behavior with dvui's snapshot testing if needed later. |
| A6 | Merge all GUI into fewer files | Going from 24 files to 3-4 mega-files fights Zig's one-type-per-file convention and makes diffs harder to review. | Keep files small and focused. The target is <400 LOC per file, not fewer files. |
| A7 | Runtime plugin-configurable GUI layout | Plugins already register panels with layout hints (overlay, sidebar, bottom_bar). Making the entire GUI layout plugin-driven (custom toolbars, custom tab bars) is a different feature. | Keep the fixed shell layout in lib.zig. Plugin panels render in their designated slots. |

---

## Feature Dependencies

```
T1 (delete Input/ stubs) -- independent, no dependencies

T2 (remove core import from Renderer) requires:
  -> Decision: expose Schemify/DeviceKind/primitives through state.zig re-exports
  -> OR: pass needed data as function parameters from lib.zig

T3 (remove dvui from View.zig) requires:
  -> Add a `pending_theme_change: ?bool` flag to AppState.GuiState (or CommandFlags)
  -> GUI reads the flag, calls dvui.themeSet(), clears it

T4 (consolidate module-level state) requires:
  -> Expand AppState.GuiState with: FileExplorerState, LibraryBrowserState,
     FindDialogState, PropsDialogState, DialogWindowRects
  -> Update all draw() functions to read from app.gui.* instead of module vars

T5 (consolidate Renderer state) requires:
  -> T4 (because Renderer state moves into AppState)
  -> Resolve which fields are viewport (move to AppState.view) vs transient
     input state (keep in a small local struct)

T6 (split Renderer.zig) requires:
  -> T2 (core import removal should happen first so split files don't propagate the violation)
  -> T5 (state consolidation should happen first to avoid splitting state across files)
  -> Natural split points: SchematicDraw.zig, GridDraw.zig, StrokeHelpers.zig,
     CoordTransform.zig, CanvasInput.zig, SymbolLookup.zig

T7 (standardize draw signatures) -- independent, can happen anytime

D1 (extract coord math) pairs naturally with T6 (Renderer split)
D2 (extract kindToName) pairs naturally with T6 (Renderer split)
D7 (deduplicate classifyFile) should happen before T6 to avoid propagating the duplicate
```

**Critical path:** T1 -> T3 -> T2 -> T5 -> T4 -> T6 -> D*

T1 is trivially first (delete dead files). T3 is low-risk (one function in one file). T2 is medium-risk (touches Renderer's core import chain). T5 and T4 are the largest changes (state consolidation). T6 is the reward: once state is consolidated and imports are clean, the 844-line file splits cleanly.

---

## Specific Refactoring Techniques for dvui Immediate-Mode

### Pattern 1: Flag-then-render for cross-layer effects

**Problem:** View.zig calls `dvui.themeSet()` directly -- a GUI framework call in the command layer.

**Solution:** Commands set flags on AppState. GUI reads flags in its frame loop and acts on them. The flag is the interface between layers.

```zig
// In commands/View.zig (no dvui import):
.toggle_colorscheme => {
    state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
    state.gui.theme_changed = true;  // flag, not action
    state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
},

// In gui/lib.zig frame():
if (app.gui.theme_changed) {
    dvui.themeSet(if (app.cmd_flags.dark_mode)
        dvui.Theme.builtin.adwaita_dark
    else
        dvui.Theme.builtin.adwaita_light);
    app.gui.theme_changed = false;
}
```

### Pattern 2: State re-export for layering compliance

**Problem:** Renderer.zig needs `core.Schemify` type to access `doc.sch` fields. Importing `core` directly violates GUI->state->core.

**Solution:** `state.zig` already imports `core` and re-exports `Instance`, `Wire`, `Sim`. Add re-exports for the types GUI actually needs.

```zig
// In state.zig:
pub const Schemify = core.Schemify;
pub const DeviceKind = core.DeviceKind;
pub const primitives = core.primitives;

// In gui/Renderer.zig: replace @import("core") with @import("state")
const st = @import("state");
const Schemify = st.Schemify;
```

This is not a real abstraction boundary (it's a re-export), but it enforces the import direction rule at the module level: GUI files only import `state` and `dvui`, never `core` directly.

### Pattern 3: Thin-wrapper draw functions

**Problem:** GUI files that store state in module-level vars are not thin wrappers. They are stateful modules with hidden state.

**Solution:** Every `draw()` function receives `*AppState` and returns `void`. All state lives in `AppState.GuiState`. Module-level vars are only acceptable for comptime tables (constant data).

```zig
// WRONG: stateful module
var is_open: bool = false;
var win_rect = dvui.Rect{ .x = 80, .y = 80, .w = 340, .h = 220 };

pub fn draw(app: *AppState) void {
    if (!is_open) return;  // reads module state, not AppState
    ...
}

// RIGHT: thin wrapper over AppState
pub fn draw(app: *AppState) void {
    const dlg = &app.gui.find_dialog;
    if (!dlg.is_open) return;

    var fwin = dvui.floatingWindow(@src(), .{
        .open_flag = &dlg.is_open,
        .rect = &dlg.win_rect,
    }, .{ ... });
    ...
}
```

### Pattern 4: Comptime menu/keybind tables (already used well)

ToolBar.zig, ContextMenu.zig, Actions.zig, and Keybinds.zig all use comptime tables effectively. This is the correct pattern for immediate-mode GUI in Zig: static data defined at comptime, iterated at runtime with `inline for`.

The one gap is ToolBar.drawMenus, which hardcodes 9 menu blocks procedurally. A final comptime table layer would complete the pattern:

```zig
const Menu = struct { label: []const u8, items: []const MenuItem };
const menus = [_]Menu{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
    // ...
};
// One loop renders all menus
```

### Pattern 5: Comptime-parameterized Components (already used well)

`FloatingWindow`, `HorizontalBar`, `Button`, `DropdownButton` demonstrate the correct pattern for reusable immediate-mode components: comptime options baked into the type, runtime data passed to `draw()`. No allocations, no vtables, zero-cost abstraction.

**Candidate for new component:** `ScrollList` for the card-select-scroll pattern used by FileExplorer, LibraryBrowser, and Marketplace.

---

## Quantitative Breakdown of Module-Level State

Total module-level `var` declarations across GUI files: **28 vars in 8 files**

| File | Vars | What They Store | Migration Target |
|------|------|----------------|-----------------|
| FileExplorer.zig | 7 | sections, files, selected_section, selected_file, scanned, preview_name, win_rect | `GuiState.file_explorer: FileExplorerState` |
| FindDialog.zig | 5 | is_open, query_buf, query_len, result_count, win_rect | `GuiState.find_dialog: FindDialogState` |
| PropsDialog.zig | 4 | is_open, view_only, inst_idx, win_rect | `GuiState.props_dialog: PropsDialogState` |
| LibraryBrowser.zig | 4 | win_rect, search_buf, selected_idx, scanned | `GuiState.library_browser: LibraryBrowserState` |
| KeybindsDialog.zig | 2 | open, win_rect | `GuiState.keybinds_dialog: KeybindsDialogState` |
| Marketplace.zig | 1 | win_rect | `GuiState.marketplace.win_rect` (MarketplaceState already in GuiState, just add win_rect) |
| lib.zig | 1 | renderer_state | Merge Renderer fields into `AppState.view` + `GuiState.canvas_input` |
| Theme.zig | 1 | current_overrides | `GuiState.theme_overrides: ThemeOverrides` |

**Note on `win_rect` vars:** dvui requires a `*dvui.Rect` for floating window position persistence. These MUST be persistent across frames. They can live in AppState but must be stable pointers (not stack vars). This is fine -- AppState fields are heap-stable.

**Note on `page_allocator` in FileExplorer:** Line 37 uses `std.heap.page_allocator` directly instead of `app.gpa.allocator()`. This should be fixed during state consolidation -- all allocations should use the app allocator for proper cleanup.

---

## MVP Recommendation

### Must do (core cleanup -- these fix real violations):

1. **T1** -- Delete Input/ stubs (5 minutes, zero risk)
2. **T3** -- Fix View.zig dvui leak (add flag, move themeSet to GUI)
3. **T2** -- Fix Renderer.zig core import (add state.zig re-exports)
4. **D7** -- Deduplicate classifyFile (move to state.zig)
5. **T4** -- Consolidate module-level state into AppState.GuiState
6. **T5** -- Consolidate Renderer state into AppState
7. **T6** -- Split Renderer.zig into focused files

### Should do (meaningful improvements):

8. **D1** -- Extract coordinate math to state (enables testing)
9. **D2** -- Extract kindToName/lookupPrim to core (enables testing)
10. **T7** -- Standardize draw signatures
11. **D5** -- Move SVG export out of View.zig
12. **D6** -- Unify dialog open/close through AppState flags

### Defer (nice but optional):

13. **D3** -- Comptime menu table for ToolBar.drawMenus
14. **D4** -- ScrollList component
15. **D8** -- Comptime entity-draw helpers for drawSchematic
16. **D9** -- Move applyRotFlip to core

**Rationale:** Fix violations first (T1-T3), then consolidate state (T4-T5) which is the largest structural change, then split the big file (T6) which depends on clean state. Differentiators improve testability (D1, D2) and consistency (D5-D7) but are not blocking.

---

## Sources

- Direct codebase analysis of all 24 GUI files in `src/gui/` (every file read in full)
- Direct analysis of `src/commands/View.zig` for dvui import violation
- Direct analysis of `src/state.zig` for AppState structure
- [dvui GitHub repository](https://github.com/david-vanderson/dvui) -- framework architecture reference
- [dvui Core Architecture (DeepWiki)](https://deepwiki.com/david-vanderson/dvui/3-core-architecture) -- immediate-mode paradigm, widget composition, event processing patterns
- [Immediate Mode GUI design patterns (Rust forum)](https://users.rust-lang.org/t/immediate-mode-design-patterns/106833) -- cross-language IMGUI patterns
- [Gio Architecture](https://gioui.org/doc/architecture) -- immediate-mode GUI architecture in Go (comparable design philosophy)
- [Casey Muratori: Immediate-Mode Graphical User Interfaces (2005)](https://caseymuratori.com/blog_0001) -- foundational IMGUI theory
