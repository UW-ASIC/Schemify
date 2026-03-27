# Domain Pitfalls: GUI Layer Refactoring in Zig Immediate-Mode Application

**Domain:** Refactoring GUI layer of Zig EDA schematic editor (dvui immediate-mode, DOD, comptime dispatch)
**Researched:** 2026-03-27
**Sources:** Direct codebase analysis of 24 GUI files (3,521 LOC), state.zig (495 LOC), 14 command files (1,911 LOC), Zig 0.15 module system, dvui widget identity model

---

## Critical Pitfalls

Mistakes that cause rendering breakage, build failures, or require reverting an entire phase.

### Pitfall 1: dvui @src() Widget Identity Breakage When Moving Code Between Files

**What goes wrong:** dvui uses `@src()` (Zig's source location builtin) to generate stable widget IDs. Every `dvui.box(@src(), ...)`, `dvui.button(@src(), ...)`, `dvui.floatingWindow(@src(), ...)` call uses the file path + line number as its identity. When you move a widget call from one file to another (e.g., extracting `drawSchematic` from Renderer.zig into a new SchematicView.zig), every widget in that function gets a NEW identity. dvui interprets this as "old widgets disappeared, new widgets appeared."

**Why it happens:** Refactoring by definition changes source locations. dvui's immediate-mode state persistence (scroll positions, open/close state, drag rects, animation states) is keyed on `@src()`. The framework provides `id_extra` for disambiguation within loops, but the base identity always includes the source file and line.

**Consequences:**
- Floating windows (Marketplace, FileExplorer, LibraryBrowser, all Dialogs) snap back to their default `win_rect` position because `dvui.floatingWindow(@src(), .{.rect = &win_rect})` now has a new `@src()` identity, so dvui creates a fresh window instead of recognizing the existing one.
- Scroll positions in scrollAreas reset to top.
- Any `dvui.dataGet()`/`dvui.dataSet()` persisted state is lost for moved widgets.
- For the Schemify codebase: the Renderer.zig canvas box (line 52), all 6 floating windows, and all 3 dialog scroll areas would be affected.

**Warning signs:**
- After a refactoring commit, floating windows jump to default positions
- Scroll areas unexpectedly reset
- Widgets "flicker" for one frame (old destroyed, new created)

**Prevention:**
- **Do NOT extract dvui widget code into new files unless necessary.** Reorganize by extracting non-dvui logic (data processing, classification, coordinate math) into pure functions in separate files, while keeping the actual `dvui.xyz(@src(), ...)` calls in their original files.
- When a widget call MUST move: pass the `win_rect` as a pointer from the caller (already done for FloatingWindow component), ensuring the persistent rect survives the identity change. The window will jump once but then persist at its new identity.
- If splitting Renderer.zig: keep the top-level `dvui.box(@src(), ...)` canvas in the original file. Extract the drawing helper functions (drawSchematic, drawSymbolView, drawWirePreview) which do NOT use `@src()` for identity -- they only call `dvui.clip()`, `dvui.Path.stroke()`, and `dvui.labelNoFmt()` with explicit `id_extra`.
- Test by opening a floating window, repositioning it, then verifying it stays in position after the refactored code runs.

**Detection:** Manual test: open Marketplace, drag it to a corner, close/reopen -- does it remember position? If not, `@src()` identity changed.

**Which phase should address it:** Every phase that touches dvui code. This is a constant constraint, not a one-time fix. Phases splitting Renderer.zig or Dialog files must be especially careful.

---

### Pitfall 2: Dual Viewport Types Create Split-Brain During State Consolidation

**What goes wrong:** The codebase has TWO separate `Viewport` types that represent overlapping concerns:

1. `state.zig:Viewport` -- logical viewport: `pan: [2]f32`, `zoom: f32`, plus `zoomIn()`/`zoomOut()`/`zoomReset()` methods. This is what commands mutate.
2. `gui/Renderer.zig:Viewport` -- screen-space viewport: `cx: f32`, `cy: f32`, `scale: f32`, `pan: [2]f32`, `bounds: dvui.Rect.Physical`. This is computed per-frame from the dvui canvas rect and the logical viewport.

Additionally, `Renderer` struct itself stores `zoom: f32` and `pan: [2]f32` as fields -- a THIRD copy of viewport state. The `Renderer.draw()` method computes the screen-space Viewport from its own `self.zoom`/`self.pan` plus the dvui canvas dimensions, ignoring `app.view.zoom`/`app.view.pan` from AppState.

Meanwhile, `commands/View.zig` mutates `state.view.zoom` and `state.view.pan` (the AppState viewport). But Renderer reads from `self.zoom` and `self.pan` (its own copy). These two are NOT synchronized.

**Why it happens:** The Renderer was written as a self-contained widget with its own state. View commands were written to mutate AppState. Nobody wired them together.

**Consequences:**
- `zoomIn`/`zoomOut`/`zoomReset` commands appear to do nothing because they mutate `app.view` but Renderer reads `self.zoom`
- `zoomFitAll` in View.zig sets `state.view.zoom` and `state.view.pan` but Renderer ignores these
- Arrow key panning in lib.zig mutates `app.view.pan` but Renderer reads `self.pan`
- The mouse wheel zoom and middle-click drag in Renderer.handleInput() correctly update `self.zoom`/`self.pan` -- these are the ONLY zoom/pan operations that actually work

**Warning signs:**
- Keyboard zoom commands don't change the view
- `zoomFitAll` has no visible effect
- Pan via arrow keys doesn't move the canvas

**Prevention:**
- Eliminate the Renderer's own `zoom` and `pan` fields. The Renderer should read `app.view.zoom` and `app.view.pan` directly.
- Mouse wheel zoom in `handleInput()` should mutate `app.view.zoom` and `app.view.pan` (via AppState pointer).
- The screen-space `Renderer.Viewport` should remain as a computed per-frame value (it depends on dvui canvas rect which changes every frame). Rename it to `ScreenViewport` or `CanvasTransform` to avoid confusion with `state.Viewport`.
- Do this BEFORE splitting Renderer.zig. If you split first, you propagate the bug into multiple files.

**Detection:** Type `f` (zoom fit) after opening a schematic. If the view doesn't change, the dual-viewport bug is active.

**Which phase should address it:** Phase 1 or 2 (state consolidation). Must be fixed before Renderer.zig decomposition.

---

### Pitfall 3: Module-Level State Vars Are Invisible to AppState Serialization and Testing

**What goes wrong:** 26 module-level `var` declarations across 7 GUI files store persistent UI state outside of AppState:

| File | Module-level vars | What they store |
|------|------------------|-----------------|
| `lib.zig` | `renderer_state: Renderer` | zoom, pan, drag state, wire_start, snap, grid |
| `FileExplorer.zig` | `sections`, `files`, `selected_section`, `selected_file`, `scanned`, `preview_name`, `win_rect` | File browser state, heap-allocated lists |
| `LibraryBrowser.zig` | `win_rect`, `search_buf`, `selected_idx`, `scanned` | Library browser state |
| `Marketplace.zig` | `win_rect` | Window position |
| `Dialogs/FindDialog.zig` | `is_open`, `query_buf`, `query_len`, `result_count`, `win_rect` | Find dialog state |
| `Dialogs/PropsDialog.zig` | `is_open`, `view_only`, `inst_idx`, `win_rect` | Props dialog state |
| `Dialogs/KeybindsDialog.zig` | `open`, `win_rect` | Keybinds dialog state |

**Why it happens:** In immediate-mode GUI, it is natural to store transient UI state at module scope because the draw function is called every frame with no object context. dvui encourages this pattern. But it becomes a problem when:
1. You want to save/restore workspace layout (all `win_rect` values)
2. You want to reset GUI state (must call `reset()` on every module individually)
3. You want to test GUI logic (module-level vars persist across test cases)
4. You want multiple windows/instances (impossible with module-level state)

**Consequences:**
- `AppState.deinit()` cannot clean up `FileExplorer` heap allocations (they use `page_allocator` at module level, leaked)
- `main.zig:appDeinit()` already has a band-aid: `@import("gui/FileExplorer.zig").reset()` -- this is exactly the kind of manual cleanup that module-level state forces
- Workspace save/restore is impossible without reading from 7 different module-level vars
- Testing any dialog in isolation requires knowing to reset its module-level vars

**Warning signs:**
- `@import("somemodule.zig").reset()` calls in deinit -- each is a module-level state leak
- `page_allocator` used at module level (FileExplorer.zig line 36) -- this memory is never freed to the GPA, so leak detection can't find it
- `pub var open: bool` (KeybindsDialog.zig line 20) -- mutable pub state that lib.zig mutates directly

**Prevention:**
- Move ALL persistent GUI state into `AppState.GuiState` in state.zig. Group by feature:
  ```zig
  pub const GuiState = struct {
      // ... existing fields ...
      file_explorer: FileExplorerState = .{},
      library_browser: LibraryBrowserState = .{},
      find_dialog: FindDialogState = .{},
      props_dialog: PropsDialogState = .{},
      keybinds_dialog_open: bool = false,
      // win_rects for all floating windows
      win_rects: WindowRects = .{},
  };
  ```
- Each GUI draw function receives `*AppState` and reads/writes its state through `app.gui.*`.
- Exception: truly transient per-frame state (loop counters, temporary buffers for `bufPrint`) stays local. The test: "would this value matter if I saved and restored the workspace?" If yes, it goes in AppState.
- FileExplorer's heap-allocated `sections` and `files` lists should use `app.allocator()` instead of `page_allocator`, so they are covered by the GPA leak detector.

**Detection:** Run `zig build` with the GPA leak detector enabled. Module-level `page_allocator` usage won't show leaks (page_allocator doesn't track), but any `ArenaAllocator` or `GeneralPurposeAllocator` at module level will.

**Which phase should address it:** Phase 2 (state consolidation). This is the core deliverable of the GUI cleanup -- it must happen before any structural refactoring of the files themselves.

---

### Pitfall 4: Renderer.zig Decomposition Breaks Coordinate Transform Coupling

**What goes wrong:** Renderer.zig (844 lines) contains tightly coupled systems that share coordinate transforms and constants:

1. **Input handling** (`handleInput`, `handleClick`) -- uses `p2w`, `p2w_raw` for mouse-to-world conversion
2. **Grid drawing** (`drawGrid`, `drawOrigin`) -- uses `w2p` for world-to-pixel, shares `snap_size`
3. **Schematic drawing** (`drawSchematic`, `drawSymbolView`) -- uses `w2p` for every element
4. **Wire preview** (`drawWirePreview`) -- uses `w2p`
5. **Symbol lookup** (`lookupPrim`, `kindToName`, `drawPrimEntry`, `drawGenericBox`) -- uses `applyRotFlip` and `w2p`
6. **Primitive stroke helpers** (`strokeLine`, `strokeDot`, `strokeCircle`, `strokeArc`, `strokeRectOutline`) -- pure dvui wrappers

The `w2p`, `p2w`, `p2w_raw`, and `applyRotFlip` functions are the glue. If you naively split Renderer.zig into GridRenderer.zig, SchematicRenderer.zig, SymbolRenderer.zig etc., each needs access to these transforms AND to the `Viewport` struct AND to the palette.

**Why it happens:** Renderers naturally share coordinate systems. The transforms are simple (5-line functions) but they thread through everything.

**Consequences:**
- Extracting files forces either: (a) duplicating transform functions in each file, or (b) creating a shared `transforms.zig` module that all renderer files import
- Option (a) violates DRY and drifts over time
- Option (b) works but adds import complexity and can create circular dependencies if the Viewport struct is defined in one of the renderer files

**Warning signs:**
- Multiple files with identical `w2p`/`p2w` functions
- Viewport struct defined in renderer but needed by commands (View.zig already has its own `BBox` and coordinate helpers)

**Prevention:**
- Extract coordinate transforms (`w2p`, `p2w`, `p2w_raw`, `applyRotFlip`) and the screen-space Viewport struct into a dedicated `gui/Transforms.zig` module FIRST, before any other Renderer.zig decomposition.
- Similarly extract stroke helpers (`strokeLine`, `strokeDot`, `strokeCircle`, etc.) into `gui/Draw.zig` -- these are pure dvui wrappers with no state.
- Then the remaining Renderer.zig functions become thin orchestrators importing from Transforms.zig and Draw.zig.
- The `lookupPrim`/`kindToName` symbol resolution (lines 500-594) is pure data logic with no dvui dependency -- extract to `core/` or a shared location, since it maps `DeviceKind` -> primitives names.

**Detection:** After splitting, `zig build` fails if imports are wrong. But correctness must be verified visually: render a schematic, verify all elements appear at correct positions.

**Which phase should address it:** The phase that decomposes Renderer.zig. Extract transforms first, stroke helpers second, then split by drawing concern.

---

### Pitfall 5: View.zig dvui Import Creates Cross-Layer Contamination

**What goes wrong:** `commands/View.zig` imports `dvui` directly (line 5) and calls `dvui.themeSet()` in the `toggle_colorscheme` handler (line 44-48). This violates the GUI->state->core layering because commands should be pure state mutations, not GUI framework calls. The dvui import also means the commands module has a build-time dependency on dvui, which prevents the command system from being tested without a GUI context.

**Why it happens:** Setting the dvui theme is a side effect that feels natural in the "toggle dark mode" command. The developer needed the theme to change immediately, and `dvui.themeSet()` is the only way to do it.

**Consequences:**
- The `commands` module cannot be compiled or tested without dvui as a dependency
- If dvui's theme API changes, command code breaks
- The pattern invites other commands to import dvui ("View does it, so I can too")
- `dvui.themeSet()` during command dispatch (not during frame rendering) may violate dvui's expected call timing

**Warning signs:**
- `@import("dvui")` in any file under `src/commands/`
- Any command handler calling a rendering framework function
- Command unit tests requiring a GUI context

**Prevention:**
- Replace the direct `dvui.themeSet()` call with a flag: `state.cmd_flags.dark_mode` is already set by the command. Move the `dvui.themeSet()` call to the GUI layer (lib.zig or Actions.zig), where it reads `cmd_flags.dark_mode` each frame and applies the theme.
- Pattern: command sets flag -> GUI layer reads flag -> GUI layer calls dvui
- The fullscreen toggle already follows this pattern correctly: it only sets `state.cmd_flags.fullscreen` without calling any raylib/dvui function.
- After removing the dvui import from View.zig, verify that `zig build` still passes for the commands module in isolation.

**Detection:** `grep -r '@import("dvui")' src/commands/` -- should return zero results after the fix.

**Which phase should address it:** Early phase (dead code + violation cleanup). This is a surgical fix: remove 2 lines of dvui calls, add 3 lines in the GUI layer.

---

## Moderate Pitfalls

### Pitfall 6: Renderer.zig Imports core Directly, Bypassing State

**What goes wrong:** Renderer.zig line 5: `const core = @import("core");` and then uses `core.Schemify`, `core.DeviceKind`, `core.primitives` directly. The PROJECT.md rule is "GUI never imports core directly -- all access through state." But the Renderer needs the Schemify struct to read DOD arrays (wires, instances, etc.) and needs DeviceKind for symbol lookup.

**Why it happens:** The Renderer draws FROM the Schemify data model. It needs the struct layout to call `.items(.x0)`, `.items(.y0)` etc. on MultiArrayLists. Re-exporting every field through state would be verbose and fragile.

**Consequences:**
- If core types change (e.g., Schemify adds a field), GUI code breaks directly
- The GUI becomes coupled to core's internal data layout
- But: the alternative (re-exporting everything through state) creates a massive boilerplate layer

**Prevention:**
- Accept a pragmatic exception: read-only access to core types through state re-exports is acceptable. state.zig already does this: `pub const Instance = core.Instance; pub const Wire = core.Wire;`
- Add re-exports for the types Renderer actually needs: `pub const Schemify = core.Schemify; pub const DeviceKind = core.DeviceKind;`
- The Renderer then imports `state` and uses `st.Schemify`, `st.DeviceKind` etc.
- The key restriction is: GUI must not call mutating methods on core types. Read-only access to DOD arrays for rendering is acceptable.
- `primitives` (the comptime lookup table for symbol drawing data) is trickier -- it is a large comptime dataset. Re-export `pub const primitives = core.primitives;` from state.zig.

**Detection:** `grep -r '@import("core")' src/gui/` -- should return zero after the fix. All access goes through `@import("state")`.

**Which phase should address it:** Same phase as state consolidation. Add re-exports to state.zig, then update Renderer.zig imports.

---

### Pitfall 7: FileExplorer Uses page_allocator at Module Level, Creating Untracked Memory

**What goes wrong:** `FileExplorer.zig` line 36: `const gpa = std.heap.page_allocator;`. It then uses this to allocate `sections` and `files` list entries (line 298-306). `page_allocator` is the OS-level allocator that allocates whole pages. It has no leak detection, no tracking, and no integration with Schemify's `GeneralPurposeAllocator`.

**Why it happens:** The file explorer was written as a standalone module that doesn't receive an allocator from the caller. Using `page_allocator` avoids the need to thread an allocator through.

**Consequences:**
- Memory allocated by FileExplorer is invisible to the GPA leak detector
- `AppState.deinit()` does not free FileExplorer memory -- `main.zig:appDeinit()` has a manual `@import("gui/FileExplorer.zig").reset()` call as a band-aid
- If `reset()` is not called (e.g., crash path, test cleanup), pages are leaked to the OS
- The pattern encourages other GUI modules to use their own allocators, fragmenting memory management

**Prevention:**
- FileExplorer.draw() already receives `*AppState`. Use `app.allocator()` instead of the module-level `page_allocator`.
- Move `sections` and `files` lists into `AppState.GuiState` so they are managed by AppState lifecycle.
- Remove the module-level `const gpa = std.heap.page_allocator;` entirely.
- Remove the `@import("gui/FileExplorer.zig").reset()` call from `main.zig:appDeinit()` -- AppState.deinit() handles cleanup.

**Detection:** After the fix, run with the GPA leak detector. Any leaks from FileExplorer will now be caught.

**Which phase should address it:** Phase 2 (state consolidation). Part of moving module-level state into AppState.

---

### Pitfall 8: Renderer.handleInput Mutates Self-State That Should Be AppState

**What goes wrong:** `Renderer.handleInput()` (line 93-183) processes mouse and keyboard events and mutates `self.*` fields:
- `self.dragging`, `self.drag_last` -- drag state
- `self.space_held` -- spacebar pan modifier
- `self.last_click_time`, `self.last_click_pos` -- double-click detection
- `self.zoom`, `self.pan` -- viewport (covered by Pitfall 2)

Additionally, `lib.zig:handleInput()` (line 89-90) directly mutates `renderer_state.space_held` and `renderer_state.dragging` from outside the Renderer. This means input state is split between two handlers in two files, with cross-mutation.

**Why it happens:** The Renderer was designed as a self-contained widget. Then the global input handler needed to intercept spacebar for pan mode, creating the cross-mutation.

**Consequences:**
- `space_held` is mutated from two places: inside Renderer.handleInput() AND from lib.zig's handleInput()
- If Renderer is split into multiple files, it is unclear which file "owns" the drag state
- Input state cannot be inspected or reset from AppState

**Prevention:**
- Move transient input state (dragging, drag_last, space_held, last_click_time, last_click_pos) into `AppState.GuiState` as an `InputState` sub-struct.
- Remove the cross-file mutation: lib.zig should set `app.gui.input.space_held` and Renderer should read it, not have its own copy.
- Keep the event processing logic in Renderer (it needs dvui events and canvas coordinates), but have it mutate AppState instead of self.

**Which phase should address it:** Phase 2 (state consolidation). Do this together with the Viewport unification (Pitfall 2).

---

### Pitfall 9: lib.zig handleInput and Renderer.handleInput Both Process dvui Events, Causing Double-Handling

**What goes wrong:** dvui events are processed by TWO separate handlers each frame:
1. `lib.zig:handleInput()` -- catches spacebar, dispatches keybinds, enters command mode
2. `Renderer.handleInput()` -- catches spacebar (again), processes mouse events on canvas

Both iterate `dvui.events()` and check `ev.handled`. The spacebar is handled by BOTH: lib.zig sets `renderer_state.space_held` (line 89), and Renderer.handleInput also checks for space (line 101-103). The `ev.handled = true` in one prevents the other from processing it... but only if the ordering is right.

**Why it happens:** The lib.zig handler was added to centralize keybind dispatch. The Renderer handler existed first for canvas-specific input. Neither was refactored to defer to the other.

**Consequences:**
- Event handling order matters: lib.zig's `handleInput(app)` runs BEFORE `renderer_state.draw(app)` (which calls Renderer.handleInput). So lib.zig gets first crack at events.
- If lib.zig marks spacebar as handled (line 91: `ev.handled = true`), Renderer never sees it. But Renderer also has spacebar handling for its own `self.space_held`.
- The current code works by accident: lib.zig sets `renderer_state.space_held` directly, so Renderer doesn't need to see the event.
- During refactoring, if input handling is restructured, this fragile ordering could break.

**Prevention:**
- Unify input handling into ONE location. Options:
  - (a) lib.zig handles ALL key events and produces an `InputResult` that Renderer reads (preferred: GUI layer is the entry point)
  - (b) Renderer handles all canvas-area events, lib.zig handles only global shortcuts that don't overlap
- The key principle: each event should be processed by exactly ONE handler. Use `ev.handled` consistently.
- Move spacebar tracking to AppState (see Pitfall 8) so both handlers read the same state without cross-mutation.

**Which phase should address it:** The phase that restructures input handling. Can be deferred to after state consolidation.

---

### Pitfall 10: KeybindsDialog.zig Uses pub var Crossed by lib.zig

**What goes wrong:** `Dialogs/KeybindsDialog.zig` exports `pub var open: bool = false;`. `lib.zig` mutates this directly at line 71-72:
```zig
keybinds_dlg.open = keybinds_dlg.open or app.gui.keybinds_open;
app.gui.keybinds_open = false;
```

This creates a two-step synchronization: commands set `app.gui.keybinds_open = true`, then lib.zig copies it to `keybinds_dlg.open` and clears the flag. This is fragile choreography.

**Why it happens:** The keybind command can't directly set the dialog's module-level var (it doesn't import the dialog module). So it sets a flag in AppState, and lib.zig bridges the gap.

**Consequences:**
- The dialog's open state exists in TWO places: `app.gui.keybinds_open` and `keybinds_dlg.open`
- If lib.zig forgets to synchronize (e.g., code is reordered), the dialog never opens from keyboard
- Other dialogs (FindDialog, PropsDialog) have their own `is_open` module-level vars with the same pattern risk

**Prevention:**
- Move ALL dialog open states into `AppState.GuiState`:
  ```zig
  pub const GuiState = struct {
      keybinds_open: bool = false,
      find_open: bool = false,
      props_open: bool = false,
      props_view_only: bool = false,
      props_inst_idx: usize = 0,
  };
  ```
- Each dialog's `draw()` function reads `app.gui.keybinds_open` directly. No module-level `pub var`.
- No synchronization step in lib.zig.

**Which phase should address it:** Phase 2 (state consolidation). Part of the module-level var migration.

---

## Minor Pitfalls

### Pitfall 11: classifyFile Duplicated in Renderer.zig and TabBar.zig

**What goes wrong:** The `classifyFile(origin: st.Origin) FileType` function is duplicated verbatim in `Renderer.zig` (line 210-219) and `Bars/TabBar.zig` (line 22-31). Both define their own `FileType` enum. If one is updated but not the other, file classification diverges.

**Prevention:** Extract `classifyFile` into state.zig or a shared utility. The `FileType` enum and the classification function are pure data logic with no GUI dependency.

**Which phase should address it:** Phase 2 or 3. Quick fix -- move the function, update imports.

---

### Pitfall 12: lookupPrim / kindToName in Renderer.zig Are Core Logic in GUI

**What goes wrong:** `lookupPrim()` (lines 500-546) and `kindToName()` (lines 550-594) in Renderer.zig are pure data mapping functions. They map `DeviceKind` enum values to primitive symbol names and look up drawing data. They have zero dvui dependency. But they live in the GUI layer, violating the layering rule.

**Prevention:** Move `lookupPrim` and `kindToName` to `core/Devices.zig` or a new `core/SymbolLookup.zig`. The Renderer then calls `core.lookupPrim()` (or through state re-exports). This also makes the lookup testable without a GUI context.

**Which phase should address it:** The phase that decomposes Renderer.zig. Extract before splitting drawing code.

---

### Pitfall 13: Build Must Pass After Each Individual Change

**What goes wrong:** Zig's module system is strict about unused imports, missing symbols, and type mismatches. Unlike languages with incremental compilation, Zig compiles everything at once. A refactoring sequence like "move type A, then update all references, then move type B" can leave the build broken between steps if the intermediate state has dangling references.

**Why it happens:** Zig does not have `#ifdef` or conditional compilation that can bridge intermediate states. Every `@import` must resolve. Every referenced symbol must exist.

**Prevention:**
- **Add before remove:** When moving a type or function, first add a re-export (`pub const Foo = @import("new_location.zig").Foo;`) in the OLD location. Verify build passes. Then update callers. Then remove the re-export.
- **One logical change per build check:** Do not batch multiple moves into one step. Move one type, `zig build`, move the next.
- **Use `pub usingnamespace` sparingly:** It can bridge transitions but makes dependencies invisible. Prefer explicit re-exports.
- **Build between EVERY file save** during refactoring. This is the single most important discipline.

**Which phase should address it:** All phases. This is a process constraint, not a code fix.

---

### Pitfall 14: Removing core Imports from GUI Breaks Type Access for DOD Slices

**What goes wrong:** The Renderer accesses DOD MultiArrayList slices like `sch.wires.items(.x0)`. The `sch` variable is of type `*const core.Schemify`. If you remove the `core` import from Renderer and replace it with state re-exports, you need `st.Schemify` to be the EXACT same type (not a wrapper, not a subset). Any re-export that changes the type (e.g., wrapping in a read-only interface) breaks all `.items()` calls.

**Prevention:**
- Re-exports must be type aliases, not wrappers: `pub const Schemify = core.Schemify;` in state.zig
- Do NOT create an abstraction layer between GUI and the DOD data. The whole point of DOD is direct, cache-friendly access to arrays. An abstraction layer negates the performance benefit.
- The layering rule "GUI accesses core only through state" means type re-exports, not runtime indirection.

**Which phase should address it:** Phase 2 (state consolidation). When adding re-exports, verify Renderer.zig compiles with `@import("state")` instead of `@import("core")`.

---

### Pitfall 15: Dead Input/ Stubs Can Break Build If Other Files Import Them

**What goes wrong:** `Input/Handler.zig` (5 lines), `Input/KeyboardInputHandler.zig` (5 lines), `Input/MouseInputHandler.zig` (42 lines) are dead stubs. They exist but are not imported by anything. Deleting them is safe -- unless a build.zig module declaration or test file references them.

**Prevention:**
- Before deleting: `grep -r "Input/" src/` and `grep -r "Input/" build.zig` to verify nothing imports them.
- Delete all three files in one commit.
- Run `zig build` immediately.

**Which phase should address it:** Phase 1 (dead code removal). This is the easiest win.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|---|---|---|
| Dead code removal (Input/ stubs, unused imports) | Build break if something references them (#15) | Grep before delete. One commit per deletion group. `zig build` after each. |
| State consolidation (module vars -> AppState) | Dual Viewport (#2), module-level state (#3), input state split (#8), dialog open state (#10), FileExplorer allocator (#7) | Move state in order: Viewport first (fixes commands), then dialog open states, then win_rects, then FileExplorer heap data. Build between each. |
| View.zig dvui removal | Cross-layer contamination (#5) | Set flag in command, apply theme in GUI layer. Two-line fix + three-line addition. |
| Renderer.zig core import removal | Type access for DOD slices (#14), core logic in GUI (#12) | Add type re-exports to state.zig first. Move lookupPrim/kindToName to core. Then update Renderer imports. |
| Renderer.zig decomposition | Coordinate transform coupling (#4), @src() identity (#1) | Extract transforms.zig first. Keep top-level dvui.box in Renderer.zig. Extract drawing helpers (no @src() dependency). |
| Input handler unification | Double event handling (#9) | Unify to one handler per event type. Test spacebar pan, keyboard zoom, mouse drag all still work. |
| Widget extraction to Components/ | @src() identity breakage (#1) | Only extract parameterized components (like FloatingWindow). Never move raw dvui.widget(@src()) calls. |

## Integration Pitfalls

### Ordering Dependencies Between Fixes

Some pitfalls must be fixed in a specific order:

1. **Viewport unification (#2) BEFORE Renderer decomposition (#4)** -- otherwise you propagate the split-brain into multiple files
2. **State consolidation (#3) BEFORE file splitting** -- otherwise each new file creates its own module-level vars
3. **Core import removal (#6, #14) BEFORE GUI file restructuring** -- otherwise new files re-introduce core imports
4. **View.zig dvui fix (#5) can be done independently** -- no dependencies on other fixes
5. **Dead code removal (#15) should be FIRST** -- reduces noise, zero risk

### The "Build-Break Chain" Anti-Pattern

The most dangerous anti-pattern during this refactoring:

1. Move `Viewport` from Renderer to AppState (breaks Renderer)
2. Start fixing Renderer references (build still broken)
3. While fixing, also start moving dialog state (more breakage)
4. Get confused about what's broken because of step 2 vs step 3
5. Revert everything

**Prevention:** ONE logical change. `zig build`. Green. THEN the next change. Never have more than one change in flight.

## Sources

- Direct analysis of all files in `src/gui/` (24 files, 3,521 lines)
- Direct analysis of `src/state.zig` (495 lines)
- Direct analysis of `src/commands/View.zig` (239 lines) -- dvui import on line 5
- Direct analysis of `src/commands/Dispatch.zig` (191 lines) -- comptime dispatch architecture
- Direct analysis of `src/gui/Renderer.zig` (844 lines) -- dual Viewport, core import, coordinate transforms
- Direct analysis of `src/main.zig` (91 lines) -- frame loop, FileExplorer.reset() band-aid
- [dvui GitHub repository](https://github.com/david-vanderson/dvui) -- @src() widget identity model
- [dvui DeepWiki - Getting Started](https://deepwiki.com/david-vanderson/dvui/2-getting-started) -- widget identity and state persistence
- [Zig Documentation](https://ziglang.org/documentation/master/) -- module system, @import semantics
- [Immediate Mode GUI Programming](https://eliasnaur.com/blog/immediate-mode-gui-programming) -- state management patterns in IMGUI
- [Statefulness in GUIs](https://samsartor.com/guis-1/) -- global state pitfalls in immediate mode
