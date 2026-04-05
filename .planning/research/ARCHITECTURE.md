# Architecture Patterns: EDA Schematic Editor GUI

**Domain:** EDA schematic editor GUI (immediate-mode, dual-backend)
**Researched:** 2026-04-04

## Recommended Architecture

### Current State (Problem)

Renderer.zig (1152 LOC) is a monolith handling: canvas viewport transforms, grid rendering, component symbol drawing (including subcircuit cache), wire rendering, selection overlay, mouse interaction processing, and coordinate transforms. This makes it fragile, untestable, and hard to modify.

Module-level mutable state (global `var` declarations) in dialogs and the renderer creates stale-reference bugs when documents switch.

### Proposed Architecture (Solution)

Decompose the GUI into a layered component architecture that follows the existing dvui immediate-mode pattern.

```
gui/
  lib.zig              -- Frame orchestration (existing pattern, keep)
  types.zig            -- Shared GUI types (CanvasEvent, ToolMode, etc.)
  Actions.zig          -- Command dispatch (existing, keep)
  Keybinds.zig         -- Keybind table (existing, keep)
  Theme.zig            -- Color palette (existing, keep)
  Canvas/
    lib.zig            -- Canvas public API: draw(app), handleInput(app)
    types.zig          -- ViewportState, GridConfig, CanvasEvent
    Viewport.zig       -- Pan, zoom, coordinate transforms (world <-> screen)
    GridRenderer.zig   -- Grid dots/lines rendering
    SymbolRenderer.zig -- Component symbol drawing, subcircuit cache
    WireRenderer.zig   -- Wire segment + junction rendering
    SelectionOverlay.zig -- Selection highlight, rubber-band preview
    InteractionHandler.zig -- Mouse click/drag -> CanvasEvent dispatch
  Bars/
    ToolBar.zig        -- Menu bar (existing)
    TabBar.zig         -- Document tabs (existing)
    CommandBar.zig     -- Status + vim command input (existing)
  Dialogs/
    PropsDialog.zig    -- Property viewer/editor
    FindDialog.zig     -- Search (command-bar fallback)
    KeybindsDialog.zig -- Shortcut reference
    SaveWarningDialog.zig -- Unsaved changes confirmation (NEW)
    FilePickerDialog.zig  -- Save-as file selection (NEW, extends FileExplorer)
  Components/
    FloatingWindow.zig -- Reusable floating window (existing)
    HorizontalBar.zig  -- Reusable horizontal bar (existing)
  ContextMenu.zig      -- Right-click menus (existing)
  FileExplorer.zig     -- File browser (existing)
  LibraryBrowser.zig   -- Component library (existing)
  PluginPanels.zig     -- Plugin widget rendering (existing)
```

### Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| gui/lib.zig | Frame orchestration, z-order enforcement, input routing | All GUI modules, AppState |
| Canvas/Viewport.zig | World-to-screen coordinate transform, pan/zoom state | Canvas/*, InteractionHandler |
| Canvas/GridRenderer.zig | Grid dot/line rendering relative to viewport | Viewport (reads transform) |
| Canvas/SymbolRenderer.zig | Draw component symbols from core data model | Viewport (coords), core.Schemify (data), subcircuit cache |
| Canvas/WireRenderer.zig | Draw wire segments, junction dots, net labels | Viewport (coords), core.Schemify (data) |
| Canvas/SelectionOverlay.zig | Highlight selected items, draw rubber-band rect | Viewport, AppState.selection |
| Canvas/InteractionHandler.zig | Translate mouse events to CanvasEvents | dvui events, Viewport (screen->world), AppState |
| Actions.zig | Route commands to command queue or GUI mutations | CommandQueue, AppState |
| CommandBar.zig | Vim command parsing, status display, text input | Actions.zig, AppState |
| PluginPanels.zig | Render ParsedWidget arrays from plugin runtime | plugins.Runtime, dvui |

### Data Flow

```
1. INPUT
   dvui.events()
     |-> Keybinds.lookup() -> KeybindAction
     |     |-> .queue -> Actions.enqueue() -> CommandQueue
     |     |-> .gui   -> Actions.runGuiCommand() -> direct state mutation
     |
     |-> InteractionHandler.process()
           |-> CanvasEvent (click, drag, box-select, wire-draw)
           |-> gui/lib.zig handles CanvasEvent
           |     |-> Selection changes (click-select, box-select)
           |     |-> Tool mode changes (wire draw, move, etc.)
           |     |-> Actions.enqueue() for undoable operations

2. COMMAND PROCESSING (main.zig appFrame)
   CommandQueue.pop()
     |-> command.dispatch() -> state mutations
     |-> Undo.push() (for undoable commands)

3. PLUGIN TICK
   runtime.tick()
     |-> schemify_process() calls
     |-> ParsedWidget[] updates per panel

4. RENDERING (gui/lib.zig frame())
   Strict z-order:
     ToolBar.draw()
     TabBar.draw()
     Canvas/lib.draw()    -- grid, symbols, wires, selection overlay
     CommandBar.draw()
     PluginPanels (sidebars + overlay)
     ContextMenu.draw()
     Dialogs (floating, on top)
```

## Patterns to Follow

### Pattern 1: Immediate-Mode Component with State in AppState

**What:** GUI components read state from AppState, render based on it, and dispatch commands to mutate it. No component stores its own persistent state.

**When:** Always, for all GUI components. This eliminates the stale-reference bugs from module-level `var` declarations.

**Example:**
```zig
// GOOD: State lives in AppState.gui
pub fn draw(app: *AppState) void {
    if (!app.gui.props_dialog.open) return;
    const inst = app.activeDoc().instances.get(app.gui.props_dialog.inst_idx);
    // render based on inst...
}

// BAD: Module-level mutable state
var is_open: bool = false;  // stale across document switches
var inst_idx: usize = 0;    // dangling index
```

### Pattern 2: Viewport Transform Isolation

**What:** All world-to-screen and screen-to-world coordinate transforms go through a single Viewport struct. No component does its own coordinate math.

**When:** Any code that converts between schematic coordinates and pixel coordinates.

**Example:**
```zig
const Viewport = struct {
    offset_x: f32,
    offset_y: f32,
    zoom: f32,

    pub fn worldToScreen(self: Viewport, wx: f32, wy: f32) struct { x: f32, y: f32 } {
        return .{
            .x = (wx - self.offset_x) * self.zoom,
            .y = (wy - self.offset_y) * self.zoom,
        };
    }

    pub fn screenToWorld(self: Viewport, sx: f32, sy: f32) struct { x: f32, y: f32 } {
        return .{
            .x = sx / self.zoom + self.offset_x,
            .y = sy / self.zoom + self.offset_y,
        };
    }

    pub fn zoomAtPoint(self: *Viewport, sx: f32, sy: f32, factor: f32) void {
        const before = self.screenToWorld(sx, sy);
        self.zoom *= factor;
        const after = self.screenToWorld(sx, sy);
        self.offset_x += before.x - after.x;
        self.offset_y += before.y - after.y;
    }
};
```

### Pattern 3: Command Queue for All Mutations

**What:** All state mutations that affect the schematic go through the command queue. GUI components never mutate core data directly.

**When:** Any edit operation (place, move, delete, rotate, wire, property change).

**Example:**
```zig
// GOOD: Enqueue undoable command
actions.enqueue(app, .{ .undoable = .delete_selected }, "Delete");

// BAD: Direct mutation
app.activeDoc().schematic.instances.delete(idx);
```

### Pattern 4: Comptime Menu/Keybind Tables

**What:** Menu items and keybinds are defined as comptime arrays, sorted at comptime for O(log n) lookup. No runtime registration.

**When:** Static configuration that does not change during execution.

**Why:** Already used in Keybinds.zig and ToolBar.zig. Fast, zero allocation, compile-time verified. Continue this pattern for any new menus or command tables.

### Pattern 5: Canvas Render Order Contract

**What:** Canvas sub-renderers are called in a fixed order that defines the visual z-layering. This order is documented and enforced by the Canvas/lib.zig orchestrator.

**When:** Whenever adding or modifying canvas rendering.

**Order:**
```
1. Grid (bottom layer)
2. Wires
3. Junction dots
4. Component symbols
5. Net labels / reference designator text
6. Selection overlay (semi-transparent highlight)
7. Rubber-band preview (wire-in-progress, box-select-in-progress)
8. Cursor crosshair (top layer)
```

## Anti-Patterns to Avoid

### Anti-Pattern 1: Module-Level Mutable State in GUI

**What:** Using `var` at module level to store dialog state, selected indices, cached values.
**Why bad:** State persists across document switches. A dialog opened on Document A shows stale data when document B becomes active. Index references become dangling.
**Instead:** Store all persistent GUI state in `AppState.gui` (the GuiState struct). Dialog open/close flags, selected indices, scroll positions -- all in GuiState.

### Anti-Pattern 2: God Renderer

**What:** A single file that handles rendering, interaction, caching, and coordinate transforms.
**Why bad:** Untestable (1152 LOC with zero tests). Any change risks breaking unrelated functionality. Difficult to reason about.
**Instead:** Decompose into Canvas/ subfolder with single-responsibility components.

### Anti-Pattern 3: Silent Error Swallowing

**What:** Using `catch {}` to discard errors silently.
**Why bad:** Over 90 occurrences in the codebase. Allocation failures produce silently corrupt data. Debugging becomes impossible.
**Instead:** `catch |err| { log.warn("operation failed: {}", .{err}); return; }` at minimum. Propagate errors where the caller can handle them.

### Anti-Pattern 4: page_allocator in Hot Paths

**What:** Using `std.heap.page_allocator` directly for per-frame or per-operation allocations.
**Why bad:** Requests whole OS pages (4KB minimum). Excessive syscall overhead and memory waste.
**Instead:** Thread the application's GPA (General Purpose Allocator) to all modules. Use ArenaAllocator for per-frame temporaries.

## Scalability Considerations

| Concern | Small (50 components) | Medium (500 components) | Large (5000+ components) |
|---------|----------------------|------------------------|--------------------------|
| Rendering | No issues | No issues | Viewport culling needed (only render visible elements) |
| Selection (box) | O(n) scan fine | O(n) acceptable | Consider spatial index (quadtree) for hit testing |
| Select connected | Trivial | Current O(n^2) tolerable | Need endpoint hash map |
| Undo history | 64 steps fine | 64 steps fine | May need more steps; ring buffer helps |
| Subcircuit cache | No eviction needed | Monitor size | Need LRU eviction (max 256 entries) |
| Wire junction detection | Scan all wires | Acceptable | Need endpoint index for O(1) lookup |

## Sources

- Schemify CLAUDE.md -- GUI architecture, frame rendering order, data flow, dvui widget patterns
- Schemify CONCERNS.md -- Renderer.zig fragility, module-level mutable state, performance bottlenecks
- Schemify PROJECT.md -- Constraints (module structure rules, dual backend, plugin contract)
- KiCad Eeschema -- Component separation model (separate concerns for symbol rendering, schematic editing, hierarchy navigation)
- dvui widget patterns -- Immediate-mode rendering model documented in CLAUDE.md
