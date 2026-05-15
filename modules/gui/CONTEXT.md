# gui

Immediate-mode GUI module. Builds the entire UI every frame from `AppState`. No persistent widget tree. All mutation flows through the command queue — the GUI never writes to the schematic directly.

## Responsibility

- **Frame orchestration**: toolbar -> tab bar -> canvas/sidebars -> overlays -> dialogs -> command bar
- **Canvas**: schematic rendering (grid, wires, symbols, overlays), symbol-view rendering, hit-testing, mouse/keyboard interaction
- **Panels**: file explorer, library browser, plugin marketplace, context menu, startup download overlay, missing symbols overlay
- **Input**: vim-first keybinds (binary-search lookup), command-mode line editor, space-bar pan, plugin key dispatch
- **Bars**: menu bar (File/Edit/View/Place/Hierarchy/Simulate/Plugins/Help), tab bar with dirty indicators, command/status bar with coordinates
- **Dialogs**: properties, multi-properties, find, keybinds, spice code, new primitive, settings (JSON editor), optimizer, import project
- **State**: `AppState` (global singleton), `Document` (per-tab), `Selection`, `Viewport`, `Clipboard`, `GuiState` (hot/cold split), `TbIndex` (testbench reverse index)
- **Theme**: `Palette` (canvas colors), `ThemeOverrides` (plugin-writable), chrome color getters, color math (`blend`/`colorScale`/`withAlpha`), runtime JSON theme application
- **Welcome screen**: shown when no documents are open — quick actions, recent files, keyboard hints

## Boundaries

- `state.zig` is a **separate build module** (`"state"`) to break the gui <-> commands circular dependency
- `theme.zig` is a **separate build module** (`"theme_config"`) so canvas renderers and chrome can share palette without pulling in all of gui
- GUI never mutates the schematic directly — enqueues `Command` values via `actions.enqueue()`
- All per-frame visual state lives in `GuiState`; persistent state is owned by `AppState`
- Canvas rendering uses dvui's `renderTriangles` for batched geometry and `renderText` for labels — no custom GPU code

## Public API

| Symbol | File | Description |
|--------|------|-------------|
| `frame(app)` | `lib.zig` | Top-level frame orchestrator. Called once per tick. |
| `actions.enqueue(app, cmd, msg)` | `actions.zig` | Push a `Command` onto the queue with status message. |
| `actions.runVimCommand(app, line)` | `actions.zig` | Parse and execute a vim-bar command string. |
| `actions.runGuiCommand(app, gui_cmd)` | `actions.zig` | Execute a GUI-only command (view switch, file ops). |
| `actions.GuiCommand` | `actions.zig` | Enum: `view_schematic`, `view_symbol`, `file_new`, `file_open`, `file_save`. |
| `file_explorer.draw(app)` | `Panels/file_explorer.zig` | Render file explorer modal. Also re-exported from `lib.zig`. |
| `file_explorer.onKeyChar/onKeyBackspace/onKeyEscape` | `Panels/file_explorer.zig` | Keyboard input hooks for file explorer modal. |
| `file_explorer.reset(app)` | `Panels/file_explorer.zig` | Clear cached scan data. |
| `theme.Palette` | `theme.zig` | Canvas color set. Constructors: `dark()`, `fromDvui(dvui.Theme)`. |
| `theme.ThemeOverrides` | `theme.zig` | Plugin-writable color/shape overrides (global mutable). |
| `theme.applyJson(alloc, json)` | `theme.zig` | Apply a theme JSON blob to `current_overrides`. |
| `theme.chrome*()` | `theme.zig` | ~15 getters for chrome colors/dimensions (toolbar, tabbar, sidebar, etc). |
| `theme.blend/colorScale/withAlpha` | `theme.zig` | Color math utilities. |
| `AppState` | `state.zig` | Top-level application state. Owns documents, queue, plugins, config. |
| `Document` | `state.zig` | Per-open-file state: `Schemify` schematic, selection, viewport, undo history. |
| `Selection` | `state.zig` | Bitset pair (instances + wires). |
| `Viewport` | `state.zig` | Pan + zoom. Methods: `zoomIn`, `zoomOut`, `zoomReset`. |
| `Clipboard` | `state.zig` | Instance + wire lists for copy/paste. |
| `TbIndex` | `state.zig` | Reverse index: cell name -> list of `.chn_tb` paths. |
| `CanvasEvent` | `Canvas/types.zig` | Tagged union: `none`, `click`, `double_click`, `right_click`, `rubber_band_complete`. |

## Internal Structure

| File | Purpose |
|------|---------|
| **`lib.zig`** | Frame orchestrator. Calls input, bars, canvas, panels, dialogs in z-order. Dispatches `CanvasEvent` to selection/wire-placement logic. |
| **`state.zig`** | All application state types. `AppState` (global singleton), `Document`, `Selection`, `Viewport`, `Clipboard`, `ClosedTabs`, `Tool`, `ToolState`, `CommandFlags`, `GuiState` (hot/cold split), `TbIndex`, dialog state structs, marketplace state, plugin panel types. ~1050 LOC. Separate build module. |
| **`theme.zig`** | `Palette` (canvas colors with plugin override application), `ThemeOverrides`, chrome color/dimension getters, color math, `applyJson` for runtime theme switching. Separate build module. |
| **`actions.zig`** | `enqueue()`, `runGuiCommand()`, `runVimCommand()`. Contains the vim command table (~50 entries) as a `StaticStringMap`. Falls through to `commands.parser` for unrecognized commands. |
| **`bars.zig`** | Menu bar (8 dropdown menus with shortcut hints), tab bar (dirty indicators, close buttons, SCH/SYM toggle), command/status bar (coordinates, snap, tool, view mode). |
| **`dialogs.zig`** | `drawAll()` dispatches to 10 dialog renderers: properties, multi-properties, find, keybinds, spice code, new primitive, missing symbols, settings (JSON editor), optimizer (gm/Id), import project. Generic `dialog()` shell for consistent window chrome. |
| **`welcome.zig`** | Welcome screen: title, quick-action buttons (New/Open/Import), recent files list from `ClosedTabs`, keyboard hints. Shown when `documents.len == 0`. |
| **`helpers.zig`** | Two utilities: `toDvui(theme.Color) -> dvui.Color`, `baseName(path) -> []const u8`. |
| **`Palette.zig`** | **Dead file.** Duplicate of palette logic now in `theme.zig`. Imports from non-existent `Theme.zig`. Not referenced by any live code. |
| **`PluginPanels.zig`** | Renders plugin panels in sidebar, bottom bar, or overlay layout. Interprets `ParsedWidget` lists from `PluginHost` (label, button, slider, checkbox, progress, collapsible, text input/area). Handles vim-command toggle and plain-key toggle for panels. |
| **`Input.zig`** | **Dead file.** Older version of input handling. Imports from `Actions.zig`, `Keybinds.zig`, `FileExplorer.zig`, `PluginPanels.zig` — capitalization differs from actual filenames. Not imported by `lib.zig`. |
| **`Canvas/lib.zig`** | Canvas orchestrator. Sets up viewport, clips, calls sub-renderers in z-order: grid -> origin -> wires -> symbols -> overlays -> rubber band. Dispatches hover events to plugin host. |
| **`Canvas/types.zig`** | Shared types: `Point`, `Vec2`, `RenderViewport`, `CanvasEvent`, `RenderContext`, drawing constants (hit tolerances, grid limits). |
| **`Canvas/render.zig`** | Rendering primitives: world-to-pixel transforms (`w2p`, `p2w`), rotation/flip, immediate stroke helpers, `LineBatch` (batched triangle geometry), `LabelList` (deferred text), grid rendering, origin cross. |
| **`Canvas/symbols.zig`** | Instance rendering: primitive lookup, subcircuit symbol resolution (reads `.chn` files, builds auto-layout box), port-pin fill, pin markers, instance name labels. Symbol-view rendering (geometry + auto-generated box from pins). |
| **`Canvas/wires.zig`** | Wire segment rendering with selection highlighting, endpoint dots, geometry (lines, rects, circles, arcs), net labels on wires, text annotations. |
| **`Canvas/overlays.zig`** | Wire preview crosshair, rubber-band selection rectangle, testbench overlay (button strip + ghost wires), auto-generate symbol button. |
| **`Canvas/interaction.zig`** | Mouse/keyboard -> `CanvasEvent`. Gestures: middle-drag pan, space+drag pan, sticky grab, wheel zoom (cursor-anchored), drag-to-move (4px threshold), rubber-band selection. Hit-testing for instances (shape-aware AABB) and wires (point-to-segment distance). |
| **`Canvas/TbOverlay.zig`** | **Dead file.** Earlier standalone testbench overlay with module-level `var` state. Superseded by testbench code in `Canvas/overlays.zig` which stores state in `AppState.gui.hot.canvas.tb_overlay`. Imports non-existent `Viewport.zig` and `draw_helpers.zig`. |
| **`Input/lib.zig`** | Input dispatcher. Handles space-bar pan (cross-cutting), delegates to file-explorer mode, command mode, or normal mode. Dispatches plugin key events and plugin keybinds. |
| **`Input/keybinds.zig`** | Static keybind table (~40 entries), comptime-sorted. O(log n) binary-search lookup. Maps `Key + modifiers -> Command` or `GuiCommand`. |
| **`Input/key_mapping.zig`** | `keyToChar(Key, shift) -> u8` via comptime lookup table. `packMods(ctrl, shift, alt) -> u8`. |
| **`Input/keys.zig`** | Standalone `Key` enum (platform-independent keycodes), `Action` enum, `Modifiers` struct. Not imported by live code (dvui's own `Key` enum is used instead). |
| **`Panels/file_explorer.zig`** | Modal file browser. Sections (components/testbenches/primitives/PDK), file list with badges, substring search filter, PDK cell browser, preview cache. Module-level `var` state for scan results. |
| **`Panels/library.zig`** | Library browser: scrollable list of built-in primitives with category badges (PAS/SEM/DIO/SRC/CTL/SW/TLN/PWR). Double-click or "Place Selected" button to insert at cursor. |
| **`Panels/context_menu.zig`** | Right-click context menu. Four item sets: instance (6 items), wire (2), group/multi-select (5), canvas (2). Uses `dvui.floatingMenu`, auto-dismisses on focus loss. |
| **`Panels/marketplace.zig`** | Plugin marketplace. Fetches registry JSON from GitHub, displays plugin list with install/uninstall. Downloads `.so` via `curl`, writes `plugin.toml` manifest. Background threads for fetch/install/uninstall. |
| **`Panels/startup_download.zig`** | Startup plugin download overlay. Progress bar + retry/continue buttons. Shown when config lists plugins not on disk. |
| **`Dialogs/MissingSymbolsPanel.zig`** | Floating overlay listing unresolved subcircuit symbols. Auto-reopens when the missing set changes. |

## Dependencies

| Dependency | Usage |
|------------|-------|
| `schematic` | `Schemify`, `Instance`, `Wire`, `Pin`, `DeviceKind`, `primitives`, `types`, `fileio.Toml` |
| `commands` | `Command`, `CommandQueue`, `parser`, `handlers.History`, `PrimitiveKind`, `Immediate`, `Undoable` |
| `plugins` | `PluginHost` for panel rendering, key dispatch, hover dispatch |
| `settings` | `SettingsDialogState` |
| `simulation` | `results.SimResult`, `optimizer` (gm/Id dialog) |
| `utility` | `Logger`, `platform.fs`, `platform.httpGetSync`, `platform.pluginConfigDir` |
| `dvui` | GUI framework: widgets, layout, events, rendering, fonts, colors |

## Gaps

### Missing Features

- **Zoom-to-fit animation**: zoom jumps instantly, no smooth transition
- **Minimap / overview**: no bird's-eye navigation for large schematics
- **Ruler / measurement tools**: no way to measure distances on the canvas
- **Grid snapping options**: only uniform grid; no per-axis snap, no snap-to-object
- **Layer visibility**: no layer system; `show_all_layers` flag exists but unused
- **Print preview**: print command exists in menu but no preview dialog
- **PDF/PNG/SVG export**: menu items exist but export handlers are stubs in commands module
- **Annotation tools**: no freehand drawing, callouts, or dimension lines
- **Collaborative editing indicators**: single-user only
- **Dark/light auto-switching**: only manual toggle; no OS preference detection
- **HiDPI per-monitor scaling**: single `rs_s` scale factor, no per-monitor awareness
- **Undo visualization**: undo/redo works but no visual history panel or tree
- **Property editor panel**: properties only accessible via modal dialog, not as a persistent side panel
- **Waveform viewer panel**: menu item exists, command is defined, but no actual waveform rendering
- **Net highlighting across hierarchy**: highlight works within one document, not across hierarchy levels
- **Multi-monitor support**: no awareness of monitor boundaries or drag-to-second-monitor
- **Accessibility / screen reader**: no ARIA-like semantics, no focus indicators beyond dvui defaults
- **Touch / tablet input**: no touch gesture recognition, no stylus pressure support
- **Drag-and-drop from file manager**: no external DnD support
- **Tab reordering**: tabs cannot be reordered by dragging
- **Search/replace in properties**: find dialog searches instances by name, not property values
- **Bus/array wire notation**: wires are individual segments, no bus grouping
- **Snap-to-pin**: no magnetic snap when wire endpoint approaches a pin

### API Issues

- **Global mutable state in theme**: `current_overrides` is a module-level `var`, making theme non-thread-safe and preventing multiple independent GUI instances
- **Module-level `var` in panels**: `file_explorer.zig`, `Palette.zig`, `Input.zig`, `Canvas/TbOverlay.zig` use file-scoped mutable state. This prevents testing panels in isolation and couples them to the singleton `AppState`
- **Dead files**: `Palette.zig`, `Input.zig`, `Canvas/TbOverlay.zig`, `Input/keys.zig` are not imported by any live code and reference non-existent modules. Should be deleted
- **`AppState` is a god object**: ~180 fields across hot/cold/warm tiers. Owns documents, queue, plugins, GUI state, config, logger, toolbar flags, clipboard, hierarchy stack, testbench index. Difficult to test any subsystem without constructing the entire object
- **`state.zig` is ~1050 LOC**: mixes domain types (`Document`, `TbIndex`), UI state (`CanvasState`, dialog states), plugin types, and marketplace types. Should be split
- **`GuiState` hot/cold split is manual**: fields are annotated with comments (`// 8-byte`, `// 1-byte`) but the split is not enforced by the type system or verified by tests
- **`Document.placeSymbol` belongs in commands**: it mutates the schematic directly, bypassing the command queue and undo system
- **No arena for per-frame canvas allocations**: `LineBatch` and `LabelList` use dvui's `lifo()` allocator (stack-like), which is correct, but `symbols.zig` reads `.chn` files during rendering to resolve subcircuit symbols — a blocking I/O operation in the render loop
- **Hit-testing is O(n) linear scan**: both `hitTestInstance` and `hitTestWire` iterate all elements. Fine for <1000 elements but will degrade on large schematics
- **Subcircuit resolution does disk I/O per frame**: `resolveSubcktSymbol` reads and parses `.chn` files on cache miss. Cache exists (`SubcktCache`) but misses trigger synchronous file reads during rendering
- **`dialogs.zig` uses `@ptrCast` for `WinRect -> dvui.Rect`**: relies on layout-compatible structs without a `// SAFETY:` comment. Brittle if either struct changes
- **Marketplace uses `curl` subprocess**: no fallback if curl is not installed; no progress reporting during download; thread-safety of `MarketplaceState` mutations is ensured only by atomic status flag
