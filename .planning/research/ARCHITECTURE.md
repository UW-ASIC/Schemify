# Architecture Patterns: GUI/State/Core Layer Separation

**Domain:** EDA schematic editor -- Zig/dvui immediate-mode GUI
**Researched:** 2026-03-27
**Focus:** Restructuring GUI->state->core layering in existing codebase

## Recommended Architecture

### Current vs Target Data Flow

**Current (broken):**
```
User action -> GUI (imports core, dvui) -> command dispatch (imports dvui) -> handler mutates state -> GUI re-renders
                 |                              |
                 +-- Renderer.zig imports core --+-- View.zig imports dvui
                 +-- 6+ files have module-level vars not in AppState
```

**Target (clean):**
```
User action -> GUI (imports state + dvui only) -> command dispatch (state only) -> handler mutates state -> GUI re-renders
                |                                           |
                +-- Renderer reads from state.Document -----+-- View.zig sets flags, no dvui
                +-- All GUI state lives in AppState.GuiState
```

### Layer Rules (Enforced by build.zig Module Graph)

| Layer | May Import | Must Not Import | Responsibility |
|-------|-----------|-----------------|----------------|
| `core/` | `utility` only | `state`, `commands`, `dvui`, `gui` | Data model, parsing, netlist, synthesis |
| `state.zig` | `core`, `utility`, `commands` | `dvui`, `gui` | Single source of truth for all app state |
| `commands/` | `state`, `core`, `utility` | `dvui`, `gui` | Pure state mutation via handlers |
| `gui/` | `state`, `dvui`, `commands` (for Command type only), `theme_config` | `core` directly | Rendering state, dispatching commands |

**Key insight:** The build.zig module graph already partially enforces this. The `commands` module depends on `state` and `core` but also on `dvui` -- that dependency must be removed. The `gui/` files currently import `core` through the exe module's implicit access, not through the declared module graph. This is the root violation.

---

## Component Boundaries

### Existing Components (with current violations marked)

| Component | File(s) | LOC | Violations |
|-----------|---------|-----|------------|
| **Renderer** | `Renderer.zig` | 845 | Imports `core` directly; stores internal input state; has `Viewport` type that duplicates `state.Viewport` |
| **Frame orchestrator** | `lib.zig` | 277 | Has `var renderer_state: Renderer` as module-level state; reaches into renderer internals (`renderer_state.space_held`, `.dragging`) |
| **View handler** | `commands/View.zig` | 239 | Imports `dvui` for `dvui.themeSet()` and `dvui.Theme.builtin.*` |
| **FileExplorer** | `FileExplorer.zig` | 342 | 7 module-level vars including `std.ArrayListUnmanaged` with own allocator (`std.heap.page_allocator`) |
| **LibraryBrowser** | `LibraryBrowser.zig` | 104 | 4 module-level vars (`win_rect`, `search_buf`, `selected_idx`, `scanned`) |
| **Marketplace** | `Marketplace.zig` | 203 | 1 module-level var (`win_rect`) |
| **KeybindsDialog** | `Dialogs/KeybindsDialog.zig` | 58 | 2 module-level vars (`open`, `win_rect`) |
| **FindDialog** | `Dialogs/FindDialog.zig` | 77 | 4 module-level vars (`is_open`, `query_buf`, `query_len`, `result_count`) |
| **PropsDialog** | `Dialogs/PropsDialog.zig` | 95 | 4 module-level vars (`is_open`, `view_only`, `inst_idx`, `win_rect`) |
| **Theme** | `Theme.zig` | 161 | 1 module-level var (`current_overrides`) -- **acceptable** (theme config is conceptually global) |

### Clean Components (no changes needed)

| Component | File(s) | LOC | Notes |
|-----------|---------|-----|-------|
| ToolBar | `Bars/ToolBar.zig` | 309 | Comptime menu tables, no module-level state |
| TabBar | `Bars/TabBar.zig` | 115 | Clean -- reads from `app.*` |
| CommandBar | `Bars/CommandBar.zig` | 69 | Clean -- reads from `app.*` |
| ContextMenu | `ContextMenu.zig` | 72 | Clean -- comptime menu tables, reads `app.gui.ctx_menu` |
| PluginPanels | `PluginPanels.zig` | 124 | Clean -- reads from `app.gui.plugin_panels` |
| Actions | `Actions.zig` | 268 | Clean controller -- enqueues commands, runs GUI commands |
| Keybinds | `Keybinds.zig` | 156 | Clean -- comptime sorted table, O(log n) lookup |
| Components/* | 4 files | ~250 | Clean comptime-parameterized wrappers |

---

## Specific Changes Required

### 1. Remove `core` Import from Renderer.zig

**Problem:** `Renderer.zig` directly imports `core` for:
- `core.Schemify` type (line 8)
- `core.DeviceKind` enum (line 9)
- `core.primitives` module (line 10)

These are used in:
- `drawSchematic()` -- iterates `doc.sch.wires`, `doc.sch.instances`, etc.
- `lookupPrim()` -- maps `DeviceKind` to `PrimEntry`
- `drawPrimEntry()` -- reads `PrimEntry` geometry data
- `kindToName()` -- maps `DeviceKind` enum to string

**Solution:** The Renderer already receives `app: *st.AppState`, and `AppState` contains `Document` which contains `sch: core.Schemify`. The Renderer accesses schematic data through `app.active()` -> `doc.sch`. The types `Schemify`, `DeviceKind`, and `primitives` flow transitively through the `state` module, which re-exports `Instance` and `Wire` from core.

The fix requires two parts:

**Part A -- Add re-exports to `state.zig`:**
```zig
// state.zig already has:
pub const Instance = core.Instance;
pub const Wire = core.Wire;

// Add:
pub const Schemify = core.Schemify;
pub const DeviceKind = core.DeviceKind;
pub const primitives = core.primitives;
```

**Part B -- Change Renderer.zig imports:**
```zig
// BEFORE:
const core = @import("core");
const Schemify = core.Schemify;
const DeviceKind = core.DeviceKind;
const primitives = core.primitives;

// AFTER:
const Schemify = st.Schemify;
const DeviceKind = st.DeviceKind;
const primitives = st.primitives;
// Remove: const core = @import("core");
```

This is a mechanical change. `Renderer.zig` already accesses schematic data through `app.documents.items[app.active_idx].sch` -- it never constructs core types or calls core methods directly except through the Document wrapper. The re-exports make the type identity match without requiring the GUI to know about `core`.

**Build graph change:** The exe module's `gui/lib.zig` (which is the exe root's child, not a declared module) currently gets `core` access implicitly through the exe module. After this change, it only needs `state` to access core types. No build.zig change needed since the exe module already imports both `core` and `state`.

### 2. Remove `dvui` Import from commands/View.zig

**Problem:** `View.zig` imports `dvui` (line 5) and uses it for:
- `dvui.themeSet()` (line 44) -- changes the active dvui theme
- `dvui.Theme.builtin.adwaita_dark` / `adwaita_light` (lines 45-47) -- theme constants

This happens in the `toggle_colorscheme` handler.

**Solution:** Split the colorscheme toggle into flag-set (command layer) and theme-apply (GUI layer).

**Step 1 -- View.zig sets only the flag:**
```zig
// BEFORE (View.zig):
.toggle_colorscheme => {
    state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
    dvui.themeSet(if (state.cmd_flags.dark_mode)
        dvui.Theme.builtin.adwaita_dark
    else
        dvui.Theme.builtin.adwaita_light);
    state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
},

// AFTER (View.zig):
.toggle_colorscheme => {
    state.cmd_flags.dark_mode = !state.cmd_flags.dark_mode;
    state.setStatus(if (state.cmd_flags.dark_mode) "Dark mode on" else "Dark mode off");
},
```

**Step 2 -- GUI applies theme each frame from `cmd_flags.dark_mode`:**
```zig
// gui/lib.zig frame() -- add at top:
fn syncThemeFromFlags(app: *AppState) void {
    const want_dark = app.cmd_flags.dark_mode;
    const is_dark = dvui.themeGet().dark;
    if (want_dark != is_dark) {
        dvui.themeSet(if (want_dark)
            dvui.Theme.builtin.adwaita_dark
        else
            dvui.Theme.builtin.adwaita_light);
    }
}
```

This is the standard immediate-mode pattern: state holds the desired value, GUI reads it each frame and applies side effects. The `dvui` import is removed from `View.zig` entirely.

**Build graph change:** Remove `"dvui"` from the `commands` module dependencies in `build.zig`:
```zig
// BEFORE:
.{ "commands", "src/commands/command.zig", &.{ "state", "core", "utility", "dvui" } },
// AFTER:
.{ "commands", "src/commands/command.zig", &.{ "state", "core", "utility" } },
```

### 3. Move Module-Level GUI State into AppState.GuiState

**Problem:** 6+ GUI files store state in module-level `var` declarations instead of `AppState.GuiState`. This state is invisible to serialization, testing, and reset logic.

**Inventory of module-level state to migrate:**

| File | Var | Type | Destination |
|------|-----|------|-------------|
| `lib.zig` | `renderer_state` | `Renderer` | `AppState.renderer` (new field) |
| `Marketplace.zig` | `win_rect` | `dvui.Rect` | `GuiState.marketplace.win_rect` |
| `LibraryBrowser.zig` | `win_rect` | `dvui.Rect` | `GuiState.library_browser.win_rect` (new struct) |
| `LibraryBrowser.zig` | `search_buf` | `[128]u8` | `GuiState.library_browser.search_buf` |
| `LibraryBrowser.zig` | `selected_idx` | `i32` | `GuiState.library_browser.selected_idx` |
| `LibraryBrowser.zig` | `scanned` | `bool` | `GuiState.library_browser.scanned` |
| `KeybindsDialog.zig` | `open` | `bool` | `GuiState.keybinds_open` (already exists!) |
| `KeybindsDialog.zig` | `win_rect` | `dvui.Rect` | `GuiState.keybinds_rect` (new field) |
| `FindDialog.zig` | `is_open` | `bool` | `GuiState.find_open` (new field) |
| `FindDialog.zig` | `query_buf` | `[128]u8` | `GuiState.find_query` (new field) |
| `FindDialog.zig` | `query_len` | `usize` | `GuiState.find_query_len` |
| `FindDialog.zig` | `result_count` | `usize` | `GuiState.find_result_count` |
| `FindDialog.zig` | `win_rect` | `dvui.Rect` | `GuiState.find_rect` |
| `PropsDialog.zig` | `is_open` | `bool` | `GuiState.props_open` |
| `PropsDialog.zig` | `view_only` | `bool` | `GuiState.props_view_only` |
| `PropsDialog.zig` | `inst_idx` | `usize` | `GuiState.props_inst_idx` |
| `PropsDialog.zig` | `win_rect` | `dvui.Rect` | `GuiState.props_rect` |
| `FileExplorer.zig` | `sections` | `ArrayListUnmanaged(Section)` | `GuiState.file_explorer.sections` (new struct) |
| `FileExplorer.zig` | `files` | `ArrayListUnmanaged(FileEntry)` | `GuiState.file_explorer.files` |
| `FileExplorer.zig` | `selected_section` | `i32` | `GuiState.file_explorer.selected_section` |
| `FileExplorer.zig` | `selected_file` | `i32` | `GuiState.file_explorer.selected_file` |
| `FileExplorer.zig` | `scanned` | `bool` | `GuiState.file_explorer.scanned` |
| `FileExplorer.zig` | `preview_name` | `[]const u8` | `GuiState.file_explorer.preview_name` |
| `FileExplorer.zig` | `win_rect` | `dvui.Rect` | `GuiState.file_explorer.win_rect` |

**Important -- dvui.Rect in state.zig:** Since `state.zig` must not import `dvui`, window rects should be stored as a framework-agnostic type:

```zig
// state.zig
pub const WinRect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 320, h: f32 = 240 };
```

`dvui.Rect` is `struct { x: f32, y: f32, w: f32, h: f32 }` -- identical layout. At the GUI boundary, convert via `@ptrCast`:

```zig
// gui/ conversion helper
inline fn toDvuiRect(r: *st.WinRect) *dvui.Rect {
    return @ptrCast(r); // Same memory layout: 4 contiguous f32
}
```

**New state.zig additions:**

```zig
pub const WinRect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 320, h: f32 = 240 };

pub const FileExplorerState = struct {
    sections: std.ArrayListUnmanaged(Section) = .{},
    files: std.ArrayListUnmanaged(FileEntry) = .{},
    selected_section: i32 = -1,
    selected_file: i32 = -1,
    scanned: bool = false,
    preview_name: []const u8 = "",
    win_rect: WinRect = .{ .x = 60, .y = 40, .w = 720, .h = 500 },

    pub const Section = struct { label: []const u8, path: []const u8 };
    pub const FileEntry = struct { name: []const u8, path: []const u8, is_dir: bool };
};

pub const LibraryBrowserState = struct {
    win_rect: WinRect = .{ .x = 100, .y = 60, .w = 420, .h = 380 },
    search_buf: [128]u8 = [_]u8{0} ** 128,
    selected_idx: i32 = -1,
    scanned: bool = false,
};

pub const FindDialogState = struct {
    open: bool = false,
    query_buf: [128]u8 = [_]u8{0} ** 128,
    query_len: usize = 0,
    result_count: usize = 0,
    win_rect: WinRect = .{ .x = 80, .y = 80, .w = 340, .h = 220 },
};

pub const PropsDialogState = struct {
    open: bool = false,
    view_only: bool = false,
    inst_idx: usize = 0,
    win_rect: WinRect = .{ .x = 120, .y = 100, .w = 480, .h = 380 },
};

pub const CanvasInputState = struct {
    dragging: bool = false,
    drag_last: [2]f32 = .{ 0, 0 },
    space_held: bool = false,
    last_click_time: f64 = 0,
    last_click_pos: [2]f32 = .{ 0, 0 },
};
```

**Updated GuiState:**
```zig
pub const GuiState = struct {
    // Existing fields unchanged...
    ctx_menu: CtxMenu = .{},
    keybinds_open: bool = false,
    view_mode: GuiViewMode = .schematic,
    command_mode: bool = false,
    command_buf: [128]u8 = [_]u8{0} ** 128,
    command_len: usize = 0,
    plugin_panels: std.ArrayListUnmanaged(PluginPanel) = .{},
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,
    marketplace: MarketplaceState = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},
    // NEW fields:
    keybinds_rect: WinRect = .{ .x = 100, .y = 80, .w = 520, .h = 420 },
    find: FindDialogState = .{},
    props: PropsDialogState = .{},
    file_explorer: FileExplorerState = .{},
    library_browser: LibraryBrowserState = .{},
    canvas_input: CanvasInputState = .{},
};
```

### 4. Decompose Renderer.zig (845 lines -> 4 files ~200 lines each)

**Current structure of Renderer.zig:**

| Section | Lines | Description |
|---------|-------|-------------|
| Renderer struct + draw/handleInput/handleClick | 1-202 | Input handling + canvas setup |
| File classification | 204-219 | `classifyFile()` helper |
| drawSchematic | 221-384 | Main schematic rendering loop |
| drawSymbolView | 386-478 | Symbol view rendering |
| drawWirePreview | 480-490 | Wire placement overlay |
| Symbol lookup + drawing | 492-658 | `lookupPrim`, `kindToName`, `drawPrimEntry`, `drawGenericBox` |
| Transform helpers | 660-673 | `applyRotFlip` |
| Stroke helpers | 675-759 | `strokeLine`, `strokeDot`, `strokeRectOutline`, `strokeCircle`, `strokeArc`, `drawLabel` |
| Coordinate transforms | 761-790 | `w2p`, `p2w_raw`, `p2w` |
| Grid/origin drawing | 792-845 | `drawGrid`, `drawOrigin`, constants |

**Proposed decomposition:**

```
gui/
  Renderer.zig          (~200 lines) -- Canvas draw entry point, handleInput(), handleClick()
                                        Exports CanvasEvent, Viewport, coord transform fns
  renderer/
    Schematic.zig        (~180 lines) -- drawSchematic(), drawWirePreview(), classifyFile()
    Symbols.zig          (~180 lines) -- lookupPrim(), kindToName(), drawPrimEntry(),
                                        drawGenericBox(), drawSymbolView()
    Primitives.zig       (~120 lines) -- strokeLine, strokeDot, strokeCircle, strokeArc,
                                        strokeRectOutline, drawLabel, drawGrid, drawOrigin,
                                        applyRotFlip, constants
```

Each sub-file imports the others as needed. `Renderer.zig` remains the public API and calls into sub-modules. The `Primitives.zig` file is pure dvui drawing helpers with no state access -- it can be reused by the file explorer preview renderer later.

**Key:** `Renderer.zig` keeps the `draw()` free function and its input handling. The extraction is purely mechanical -- moving free functions to sub-modules and importing them back. No behavior change.

### 5. Renderer Internal State vs AppState

**Problem:** The `Renderer` struct stores its own `zoom`, `pan`, `snap_size`, `show_grid`, and `wire_start` which duplicate fields already in `AppState.view` and `AppState.tool`. Additionally, `lib.zig` stores `var renderer_state: Renderer` as module-level state.

**Current duplication:**

| Renderer field | AppState equivalent |
|---------------|-------------------|
| `zoom` | `app.view.zoom` |
| `pan` | `app.view.pan` |
| `snap_size` | `app.tool.snap_size` |
| `show_grid` | `app.show_grid` |
| `wire_start` | `app.tool.wire_start` |

The Renderer struct also has input state that has no AppState equivalent:
- `dragging: bool`
- `drag_last: Vec2`
- `space_held: bool`
- `last_click_time: f64`
- `last_click_pos: Vec2`

**Solution: Eliminate the Renderer struct entirely.**

The `draw()` method becomes a free function `drawCanvas(app: *st.AppState) CanvasEvent` that:
- Reads zoom/pan/snap from `app.view` and `app.tool`
- Reads/writes transient input state from `app.gui.canvas_input`
- Writes pan/zoom changes back to `app.view` directly

This eliminates the module-level `var renderer_state` in `lib.zig`, removes the field duplication, and means `lib.zig` no longer needs to reach into renderer internals (`.space_held`, `.dragging`).

The `Viewport` type in Renderer.zig (which differs from `state.Viewport` -- it includes dvui canvas bounds and computed scale) stays as a frame-local computed struct since it is only needed during rendering.

### 6. FileExplorer Allocator Fix

**Problem:** `FileExplorer.zig` uses `const gpa = std.heap.page_allocator` (line 37) as a module-level allocator. This is a separate allocator from `AppState.gpa`, meaning:
- Memory is not tracked by the GPA leak detector
- No consistent cleanup path
- Different allocation strategy than the rest of the app

**Solution:** After moving FileExplorer state into `GuiState.file_explorer`, the allocator comes from `app.allocator()`. The `scanSections()` and `clearSections()/clearFiles()` functions receive `alloc: std.mem.Allocator` as a parameter instead of using the module-level `gpa`. The `deinit` path is wired through `AppState.deinit()` -> `GuiState` cleanup.

---

## Data Flow (After Refactoring)

### Per-Frame Loop (from main.zig)

```
appFrame():
  1. Drain command queue:
     while (app.queue.pop()) |c|
       command.dispatch(c, &app)        // commands/ mutate state, never touch dvui

  2. Plugin tick:
     plugins.tick(&app, dt)             // plugins read/write state

  3. GUI frame:
     gui.frame(&app)
       a. syncThemeFromFlags(app)       // NEW: apply dark_mode flag to dvui
       b. handleInput(app)              // read dvui events, enqueue commands
       c. toolbar.draw(app)             // read state, enqueue on click
       d. tabbar.draw(app)              // read state
       e. drawCanvas(app)               // read state.view, state.Document.sch (via state re-exports)
                                        // write state.gui.canvas_input, state.view (pan/zoom)
                                        // return CanvasEvent
       f. command_bar.draw(app)         // read state
       g. dialogs, overlays             // read/write state.gui.find, state.gui.props, etc.
```

### Event Flow Example: User Zooms In

```
1. dvui mouse wheel event arrives in canvas handleInput()
2. handleInput reads app.view.zoom, computes new zoom, writes app.view.zoom directly
3. Next frame: drawCanvas() reads app.view.zoom, renders at new zoom
   (No command needed -- direct state mutation for real-time interaction)
```

### Event Flow Example: User Toggles Dark Mode

```
1. Keybind Shift+O -> Keybinds.lookup() -> KeybindAction.queue(.toggle_colorscheme)
2. Actions.enqueue(app, .{ .immediate = .toggle_colorscheme }, ...)
3. app.queue contains the command
4. Next frame: appFrame() drains queue -> command.dispatch -> View.handle()
5. View.handle() sets app.cmd_flags.dark_mode = !dark_mode (pure state mutation)
6. gui.frame() calls syncThemeFromFlags(app) -> sees dark_mode changed -> dvui.themeSet()
7. dvui renders with new theme
```

---

## Patterns to Follow

### Pattern 1: State-Driven Immediate Mode

**What:** Every GUI widget reads from AppState and writes actions back to AppState (either directly for real-time interaction or via command queue for trackable mutations).

**When:** Always. This is the fundamental architecture pattern.

**Example (existing, clean -- CommandBar):**
```zig
fn drawContents(app: *AppState) void {
    if (app.gui.command_mode) {
        // Read state -> render
        dvui.labelNoFmt(@src(), cmd_text, .{}, .{ .style = .highlight });
    }
    // Read state -> render
    dvui.labelNoFmt(@src(), app.status_msg, .{}, .{ .style = msg_style });
}
```

### Pattern 2: Command Queue for Trackable Mutations

**What:** User actions that modify document data go through the command queue. GUI never mutates documents directly.

**When:** Any action that changes the schematic, selection, clipboard, or should be undoable.

**Example (existing, clean -- ContextMenu):**
```zig
if (dvui.button(@src(), item.label, .{}, .{ .id_extra = @intCast(i) })) {
    actions.enqueue(app, item.cmd, item.status);  // queue, don't execute
    app.gui.ctx_menu.open = false;                // direct GUI state mutation is fine
}
```

### Pattern 3: Comptime Menu/Keybind Tables

**What:** Define menu items, keybinds, and command mappings as comptime arrays. Use `StaticStringMap` or sorted arrays with binary search for O(1)/O(log n) lookup.

**When:** Any fixed set of actions/bindings.

**Example (existing, clean -- Keybinds):**
```zig
pub const static_keybinds = blk: {
    var sorted = table;
    std.sort.insertion(Keybind, &sorted, {}, lessThan);
    break :blk sorted;
};

pub fn lookup(key: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) ?*const Keybind {
    // O(log n) binary search on sorted comptime table
}
```

### Pattern 4: Flag-Based GUI-Command Separation

**What:** Commands set boolean flags or enum values on state. GUI reads those flags each frame and performs framework-specific side effects (theme changes, window operations).

**When:** Any time a command handler would need to call a GUI framework function.

**Already partially used for:** `cmd_flags.fullscreen`, `gui.keybinds_open`, `open_library_browser`, etc.

**Needs to be applied to:** `toggle_colorscheme` (the only remaining violation).

### Pattern 5: Comptime-Parameterized Components

**What:** Create reusable UI widgets via comptime function that returns a struct with a `draw` method. Zero-cost abstraction -- no vtable, no indirect calls.

**When:** Any UI pattern used in 2+ places.

**Example (existing, clean -- FloatingWindow):**
```zig
pub fn FloatingWindow(comptime opts: Options) type {
    return struct {
        pub fn draw(win_rect: *dvui.Rect, open: *bool, comptime ContentFn: anytype, ctx: anytype) void {
            if (!open.*) return;
            var fwin = dvui.floatingWindow(@src(), .{ .modal = opts.modal, ... }, ...);
            ContentFn(ctx);
        }
    };
}
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Module-Level Mutable State in GUI Files

**What:** `var foo: SomeType = .{};` at file scope in GUI modules.

**Why bad:**
- Invisible to the rest of the system (can't serialize, can't test, can't reset)
- Creates hidden coupling between frames
- In WASM builds, module-level vars persist across what the user thinks are separate sessions
- `AppState.deinit()` can't clean them up

**Instead:** Put all mutable state in `AppState.GuiState` sub-structs. Pass `app: *AppState` to draw functions.

### Anti-Pattern 2: GUI Files Importing `core` Directly

**What:** `const core = @import("core");` in any `gui/` file.

**Why bad:**
- Creates a transitive dependency that bypasses the state layer
- Makes it possible for GUI code to call core mutations directly
- Breaks the layering guarantee: if core API changes, GUI files need updating even though state is the intermediary

**Instead:** Access core types through `state` re-exports. If a core type is needed in GUI, add a re-export in `state.zig`.

### Anti-Pattern 3: Command Handlers Calling GUI Framework

**What:** `dvui.themeSet()` or any dvui call from inside `commands/` handlers.

**Why bad:**
- Commands should be testable without a GUI
- Breaks when running in headless/CLI mode
- Prevents command handlers from being reused in non-dvui contexts (e.g., WASM with a different UI)

**Instead:** Set a flag, let the GUI layer read it.

### Anti-Pattern 4: Separate Allocator in GUI Module

**What:** `const gpa = std.heap.page_allocator;` in FileExplorer.zig.

**Why bad:**
- Memory leaks are invisible to the GPA leak detector
- Different allocation strategy than the rest of the app
- No way to track or bound GUI memory usage

**Instead:** Use `app.allocator()` passed through function parameters.

---

## Scalability Considerations

| Concern | Current (8K LOC core) | At 20K LOC | At 50K LOC |
|---------|----------------------|------------|------------|
| Layer violations | 3 violations, manageable | Would multiply without enforcement | Build would catch -- module graph enforces |
| Module-level state | 20+ vars across 6 files | Hard to find, test, serialize | All in AppState -- searchable, testable |
| Renderer size | 845 lines in one file | Would grow with features | Split into 4 files, each under 250 lines |
| Command handler deps | 1 dvui import (View.zig) | More handlers might import GUI | build.zig removes dvui from commands -- compile error on violation |

---

## Build Order for Implementation

**Phase ordering rationale:** Each phase must pass `zig build` before proceeding. Dependencies flow downward. Earlier phases remove violations that block later phases from being clean.

### Phase 1: Delete Dead Code (no dependencies)
- Delete `gui/Input/` directory (3 files, 52 lines, completely unused)
- Verify: `zig build`

### Phase 2: View.zig dvui Removal (no dependencies)
- Remove `dvui` import from `commands/View.zig`
- Move `dvui.themeSet()` call to `gui/lib.zig` as `syncThemeFromFlags()`
- Remove `"dvui"` from commands module deps in `build.zig`
- Verify: `zig build`

### Phase 3: State Re-exports + Renderer Core Removal (depends on Phase 2)
- Add `Schemify`, `DeviceKind`, `primitives` re-exports to `state.zig`
- Replace `@import("core")` with `st.*` re-exports in `Renderer.zig`
- Verify: `zig build`

### Phase 4: Move Module-Level State to AppState (depends on Phase 3)
Split into sub-phases to keep each change small:
- 4a: Add `WinRect`, dialog state structs, `CanvasInputState`, `FileExplorerState`, `LibraryBrowserState` to `state.zig`; update `GuiState`; wire `deinit`
- 4b: Migrate `lib.zig` renderer_state -- eliminate Renderer struct, use free function `drawCanvas(app)`, read/write `app.gui.canvas_input` and `app.view`
- 4c: Migrate dialog vars (KeybindsDialog, FindDialog, PropsDialog) to read from `app.gui.*`
- 4d: Migrate FileExplorer vars (includes allocator fix -- replace `page_allocator` with `app.allocator()`)
- 4e: Migrate LibraryBrowser and Marketplace vars
- Each sub-phase: Verify `zig build`

### Phase 5: Decompose Renderer.zig (depends on Phase 4)
- Extract `renderer/Primitives.zig` (stroke helpers, grid, constants)
- Extract `renderer/Symbols.zig` (lookupPrim, kindToName, drawPrimEntry, drawSymbolView)
- Extract `renderer/Schematic.zig` (drawSchematic, drawWirePreview)
- Renderer.zig keeps: Viewport, CanvasEvent, drawCanvas, handleInput, coordinate transforms
- Verify: `zig build`

---

## Integration Points Between Layers

### state.zig <-> core/ (existing, clean)
- `Document.sch: core.Schemify` -- state owns the core data model
- `Document.open()` calls `core.Schemify.readFile()`
- `Document.createNetlist()` calls `sch.emitSpice()`
- Re-exports: `Instance`, `Wire`, `Sim` (add: `Schemify`, `DeviceKind`, `primitives`)

### gui/ -> state.zig (existing, mostly clean)
- All GUI files receive `app: *AppState` as parameter
- GUI reads `app.documents`, `app.view`, `app.tool`, `app.gui.*`
- GUI writes `app.view.pan/zoom` (real-time interaction), `app.gui.*` (dialog state)
- GUI dispatches commands via `actions.enqueue(app, cmd, msg)`

### gui/ -> commands/ (existing, clean)
- GUI imports `commands` only for the `Command` type definition
- Never calls `command.dispatch()` directly -- that's done in `main.zig`
- Uses `actions.enqueue()` to push commands onto `app.queue`

### commands/ -> state.zig (existing, clean)
- Handlers receive `state: anytype` (duck-typed to AppState interface)
- Handlers mutate state fields: `state.view.*`, `state.tool.*`, `state.cmd_flags.*`
- Handlers access documents via `state.active()`
- No handler constructs core types -- they work through Document methods

### main.zig orchestration (existing, clean)
- `appFrame()` is the single integration point:
  1. Drains command queue: `command.dispatch(c, &app)`
  2. Ticks plugins: `plugins.tick(&app, dt)`
  3. Renders GUI: `gui.frame(&app)`
- This ordering ensures commands are processed before rendering

---

## New Components Summary

| Component | Action | File | LOC Est |
|-----------|--------|------|---------|
| `WinRect` | New type | `state.zig` | 1 |
| `CanvasInputState` | New struct | `state.zig` | 7 |
| `FileExplorerState` | New struct | `state.zig` | 15 |
| `LibraryBrowserState` | New struct | `state.zig` | 6 |
| `FindDialogState` | New struct | `state.zig` | 7 |
| `PropsDialogState` | New struct | `state.zig` | 6 |
| `syncThemeFromFlags()` | New function | `gui/lib.zig` | 8 |
| `renderer/Primitives.zig` | Extracted from Renderer.zig | `gui/renderer/Primitives.zig` | ~120 |
| `renderer/Symbols.zig` | Extracted from Renderer.zig | `gui/renderer/Symbols.zig` | ~180 |
| `renderer/Schematic.zig` | Extracted from Renderer.zig | `gui/renderer/Schematic.zig` | ~180 |

**Total new code:** ~50 lines in state.zig (struct definitions) + ~8 lines in lib.zig.
**Total moved code:** ~500 lines from Renderer.zig to 3 sub-files (no new logic).
**Total deleted code:** ~52 lines (Input/ stubs) + ~20 lines (module-level vars replaced by state fields).

**Net effect:** Same functionality, cleaner layering, all state visible in AppState.

## Sources

- Direct codebase analysis of all 24 GUI files, 14 command files, state.zig, main.zig, build.zig
- dvui immediate-mode patterns observed from existing clean components (ToolBar, TabBar, CommandBar, ContextMenu)
- Zig build system module graph analysis from build.zig module_defs
- HIGH confidence: all findings are from direct code inspection, no external sources needed
