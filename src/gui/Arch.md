# GUI Architecture

This directory is the UI shell for Schemify's interactive editor.

## Top-Level Structure

- `lib.zig` is the orchestration entrypoint called from `main.zig` once per frame.
- It composes the full frame in a fixed order:
  1. Input handling (`handleInput`)
  2. Top bars (`ToolBar`, `TabBar`)
  3. Middle region (left plugin sidebar, renderer + bottom panel area, right plugin sidebar)
  4. Command/status bar
  5. Overlay layers and dialogs (plugin overlays, file explorer, library browser, context menu, keybinds/find/props dialogs, marketplace)
- `Renderer.zig` owns canvas drawing + canvas-local interaction (pan/zoom/click/double-click/right-click).
- `Actions.zig` and `Keybinds.zig` are command routing/controller helpers (no rendering).

## Rendering Flow

Per frame (`gui.frame(app)`):

1. **Global input pass**
   - Iterates `dvui.events()` and dispatches keyboard behavior to:
     - command-mode editing/execution
     - static keybind table lookups
     - plugin keybinds and panel toggle shortcuts
     - global editor controls (grid toggle, arrow pan, escape mode)

2. **Layout pass**
   - Creates nested dvui boxes for vertical shell + horizontal middle strip.
   - Delegates each visual region to its module (`Bars/*`, `PluginPanels`, `Renderer`).

3. **Canvas pass** (`Renderer.draw`)
   - Builds viewport from widget bounds + current pan/zoom.
   - Handles canvas-targeted mouse/key events.
   - Draws background guides (grid, origin), schematic content (wires/geometry/instances/labels), and transient overlays (wire preview).
   - Emits a `CanvasEvent` (click/double_click/right_click/none) for caller-side interaction logic.

4. **Overlay/dialog pass**
   - Draws optional floating widgets and side tools after main canvas content so they appear on top.

## Key Components

- `Bars/ToolBar.zig`: menu-bar actions (queued commands + direct GUI commands).
- `Bars/TabBar.zig`: document tabs + schematic/symbol mode toggle.
- `Bars/CommandBar.zig`: status line and command mode UI.
- `PluginPanels.zig`: runtime-driven plugin sidebars, bottom panel, and overlay windows.
- `Renderer.zig`: viewport transforms, hit/input plumbing, schematic rendering primitives.
- `Theme.zig`: palette derivation + runtime theme override parsing (`applyJson`).
- `ContextMenu.zig`: right-click contextual actions.
- `FileExplorer.zig`, `LibraryBrowser.zig`, `Marketplace.zig`: floating browsers/tools.
- `Dialogs/*`: focused modal/non-modal utility dialogs.
- `Components/*`: small reusable dvui wrappers (`HorizontalBar`, `FloatingWindow`).

## Data/Control Boundaries

- `AppState` (from `state`) is the shared model consumed by all GUI modules.
- GUI modules do **not** execute core commands directly; they enqueue `commands.Command` where possible.
- Plugin panel widgets are declarative data from runtime (`ParsedWidget` list), rendered by `PluginPanels.drawPanelBody` and routed back through runtime dispatch callbacks.

## Safety/Refactor Notes

- Keep frame ordering stable; it defines z-order and interaction precedence.
- Prefer helper extraction over behavior changes in input/render paths.
- Changes in this directory should preserve:
  - keybind/command semantics
  - visible layer ordering
  - existing public module entrypoints used by `main.zig` and command dispatch.
