# Display Crate — Gap Analysis vs Zig Reference

Cross-reference: `../Schemify/src/gui/` (Zig) vs `crates/display/src/` (Rust/egui).

Status key: `[x]` done, `[-]` partial/stub, `[ ]` missing.

---

## 1. Canvas Rendering (P0)

The app is useless without this. Zig ref: `Canvas/lib.zig`, `Canvas/render.zig`, `Canvas/symbols.zig`, `Canvas/wires.zig`, `Canvas/overlays.zig`.

Currently: `ui.weak("Canvas")` placeholder in `lib.rs:103-108`.

### 1a. Viewport & Coordinate System
- [ ] World <-> pixel coordinate transform (center, scale, pan offset, DPI)
- [ ] Grid snapping in world coordinates
- [ ] Rotation/flip transformation helpers

### 1b. Grid Rendering
- [ ] Dot grid (default)
- [ ] Line grid
- [ ] Cross grid
- [ ] Min 3px step culling, max 16K points cap
- [ ] Origin crosshair marker

### 1c. Wire Rendering
- [ ] Wire segments with color override
- [ ] Bus indicator (slash at midpoint, 2.5x thickness)
- [ ] Junction detection (filled square where 3+ wires meet)
- [ ] Wire endpoints (green dots)
- [ ] Net name labels (when show_netlist enabled)
- [ ] Selective rendering by zoom level

### 1d. Instance/Symbol Rendering
- [ ] Primitive symbol lookup + render
- [ ] Subcircuit symbol resolution (doc dir -> project dir -> PDK cache)
- [ ] Generic box fallback with pins for missing symbols
- [ ] Pin markers (hollow circles, yellow)
- [ ] Instance name labels (scaled, hide below 0.3x zoom)
- [ ] Port pin special styling
- [ ] Missing symbol tracking/reporting

### 1e. Geometry Shape Rendering
- [ ] Lines
- [ ] Rectangles (filled option via fill_rects flag)
- [ ] Circles
- [ ] Arcs (variable-segment)
- [ ] Polygons
- [ ] Text labels (deferred queue after batched geometry)

### 1f. Selection Rendering
- [ ] Selection highlight on instances
- [ ] Selection highlight on wires
- [ ] Rubber-band selection rectangle

### 1g. Overlays
- [ ] Wire preview (crosshair at start, manhattan preview to cursor, endpoint marker)
- [ ] Placement ghost (component outline following cursor with label)
- [ ] Drawing tool previews (line/rect/circle/arc/polygon/text with live constraints)
- [ ] Testbench linkage overlays (button strip, ghost wires)
- [ ] Sim ghost geometry (imported from sim results)

### 1h. Z-Order (bottom to top)
- [ ] Grid -> Origin -> Wires -> Instances -> Text -> Selection -> Rubber-band -> Wire preview -> Placement ghost -> Draw preview -> Crosshair

---

## 2. Canvas Interaction (P0)

Zig ref: `Canvas/interaction.zig`. Currently: all CanvasState fields exist in handler but unused.

### 2a. Gestures
- [ ] Middle-drag pan
- [ ] Space + left-drag pan
- [ ] Space tap -> sticky grab mode
- [ ] Scroll wheel zoom (centered on cursor)
- [ ] Drag to move selected instances (4px deadzone threshold)
- [ ] Rubber-band selection drag

### 2b. Hit Testing
- [ ] Instance hit-test (distance-based within tolerance)
- [ ] Wire hit-test (point-to-line distance with tolerance)
- [ ] Rectangular selection (rubber-band -> select enclosed)

### 2c. Event Emission
- [ ] Click (with hit indices)
- [ ] Double-click (with hit indices)
- [ ] Right-click -> context menu (with hit data: inst_idx, wire_idx)

### 2d. Tool Behaviors
- [ ] Select tool: click-select, shift-click multi-select, drag-move
- [ ] Wire tool: click start -> manhattan routing -> click end
- [ ] Drawing tools: line/rect/arc/circle/polygon/text placement
- [ ] Placement tool: ghost follows cursor, click to place

---

## 3. Theme & Palette (P1)

Zig ref: `theme.zig`, `Palette.zig`, `settings.zig`. Currently: `theme_bridge.rs` maps tokens to egui visuals (partial).

### 3a. Canvas Palette
- [ ] 13 canvas color slots (canvas_bg, grid_dot, wire, wire_sel, wire_endpoint, bus, inst_body, inst_sel, inst_pin, symbol_line, symbol_pin, wire_preview, origin)
- [ ] Dark/light mode auto-detection + computed palette
- [ ] Plugin theme overrides (RGB + RGBA with alpha)

### 3b. Widget Theming
- [x] Dark/light mode base visuals
- [x] Token -> egui color mapping (bg, text, accent, border)
- [-] Theme preset loading from JSON files (~/.config/Schemify/themes/)
- [ ] Widget type variants (18 types x 9 variants in Zig)
- [ ] Canvas style options (pin shape, grid pattern, wire routing)

### 3c. Settings Dialog — Theme Tab
- [-] Theme JSON editor (UI exists, no save/apply)
- [ ] Theme preset selector (dropdown)
- [ ] Live preview on change
- [ ] Persist to config

---

## 4. Keyboard Shortcuts (P1)

Zig ref: `Input/keybinds.zig` (60+ bindings, binary search), `Input/lib.zig`. Currently: 24 hardcoded shortcuts in `lib.rs::handle_shortcuts()`.

### 4a. Missing Bindings
- [x] File: Ctrl+N, Ctrl+S, Ctrl+O (open is in welcome only)
- [ ] File: Ctrl+Shift+S (Save As), Ctrl+Shift+N (New Primitive)
- [ ] Tabs: Ctrl+T (New Tab), Ctrl+W (Close Tab), Ctrl+Tab/Shift+Tab (cycle tabs)
- [ ] Hierarchy: H (descend schematic), Shift+H (descend symbol), Backspace (ascend)
- [ ] Simulation: F5 exists; missing backend selector shortcuts
- [ ] Net highlight: N (highlight selected nets), Shift+N (unhighlight all)
- [ ] View: Ctrl+L (toggle library), Ctrl+E (toggle file explorer)
- [ ] Place: B (bus mode toggle)
- [ ] Tools: L (line), A (arc), C (circle), P (polygon), T (text)

### 4b. Input Architecture
- [ ] Keybind table (static sorted array for O(log n) lookup)
- [ ] Mode-aware dispatch (normal, command, file explorer, text input, doc view)
- [ ] Plugin key dispatch (plain-key toggles for panel visibility)
- [-] Vim command bar (`:` enters command mode; no command parsing yet)

### 4c. Settings Dialog — Keybinds Tab
- [ ] Keybind viewer (searchable table)
- [ ] Preset selector (Vim / Conventional / Custom)
- [ ] Keybind editor

---

## 5. Plugin Panel Widgets (P2)

Zig ref: `PluginPanels.zig`. Currently: `plugin_panels.rs` renders layout shells but no widget content.

### 5a. Widget Rendering
- [ ] Row nesting (max 8 levels)
- [ ] Collapsible sections (max 32)
- [ ] Label widget
- [ ] Button widget (with command dispatch)
- [ ] Toggle widget
- [ ] Slider widget
- [ ] Text input widget
- [ ] Dropdown widget
- [ ] Await messages for async plugin responses

### 5b. Plugin Integration
- [x] 4 layout positions (left sidebar, right sidebar, bottom bar, overlay)
- [x] Panel visibility toggle
- [-] Panel body rendering (spinner/error/placeholder — no actual widgets)
- [ ] Plain-key toggle mapping (single key -> toggle panel visibility)
- [ ] Vim command aliases per panel

---

## 6. Hierarchy Navigation (P2)

Zig ref: Hierarchy menu in `bars.zig`, hierarchy_stack in state. Currently: menu items missing.

- [ ] "Hierarchy" menu in menu bar
- [ ] Descend Schematic (enter subcircuit, push stack)
- [ ] Descend Symbol (open symbol view of subcircuit)
- [ ] Ascend (pop hierarchy stack)
- [ ] Edit in New Tab
- [ ] Hierarchy stack display in status bar

---

## 7. Context Menu Enhancements (P2)

Zig ref: `Panels/context_menu.zig`. Currently: `context_menu.rs` has basic actions.

- [x] Instance: Properties, Delete, Rotate, Flip
- [-] Instance: Move (need drag impl), Descend (need hierarchy)
- [ ] Wire: Delete, Select Connected, Set Color (8 presets + default)
- [ ] Group (multi-selection): Edit All, Delete, Rotate, Flip, Duplicate
- [ ] Canvas (no selection): Paste, Insert from Library

---

## 8. Dialogs — Gaps (P2)

### 8a. Find Dialog
- [x] Search by name (case-insensitive substring)
- [ ] Double-click result -> select + pan to instance
- [ ] Navigate with arrow keys + Enter

### 8b. Properties Dialog
- [x] Single instance: name, properties edit + apply
- [ ] Multi-instance batch edit (MultiPropsDialogState exists, no UI)
- [ ] Position fields (x, y, rotation, flip)
- [ ] Symbol info section

### 8c. Settings Dialog
- [-] Theme tab (editor exists, no save/apply/preset)
- [ ] Keybinds tab (says "coming soon")
- [ ] LLM settings (Claude/OpenAI/Ollama API keys)

### 8d. New Primitive Dialog
- [-] UI exists (type/name/pins input + validation)
- [ ] Actually write .chn_prim file to project dir

### 8e. Missing Dialogs
- [ ] Keybinds viewer dialog (separate from settings)
- [ ] Missing Symbols panel (list unresolved + path resolution)

---

## 9. Status Bar Enhancements (P1)

Zig ref: `bars.zig::drawCommandBar`. Currently: `status_bar.rs` (25 lines, read-only display).

- [x] Status message display
- [x] Cursor world pos
- [x] Active tool
- [x] Zoom percentage
- [ ] Snap size display
- [ ] View mode indicator
- [ ] "[: for commands]" hint
- [ ] Command input mode (`:` prefix, input buffer, Enter/Esc hints)
- [ ] Vim command parsing + dispatch (`actions.zig::runVimCommand` has ~100 commands)

---

## 10. Simulate Menu — Gaps (P2)

Zig ref: Simulate menu in `bars.zig`. Currently: Run Simulation + Spice Code Editor only.

- [x] Run Simulation (F5)
- [x] Spice Code Editor
- [ ] Backend selector (ngspice/Xyce/LTSpice/Spectre with availability probing)
- [ ] Netlist generation options (Hierarchical/Flat/Top-only)
- [ ] Highlight Selected Nets / Unhighlight All
- [ ] Waveform Viewer
- [ ] Optimizer Window (4 tabs: Setup/Run/Results/Sweep — see `optimizer_window.zig`)
- [ ] Clear Simulation Cache

---

## 11. Doc View (P3)

Zig ref: `doc_view.zig`, `md_render.zig`, `math_render.zig`. Currently: ViewMode::Documentation exists but no renderer.

- [ ] Dual-mode editor: Edit / Preview toggle
- [ ] Markdown rendering
- [ ] Math notation rendering (LaTeX-like)
- [ ] Theme JSON editing overlay
- [ ] Word counter
- [ ] Save/sync to schematic

---

## 12. Miscellaneous (P3)

### 12a. Import Formats
- [x] SPICE import (dispatches ImportSpice)
- [-] Xschem import (UI exists, "not yet supported" message)
- [-] Virtuoso import (UI exists, "not yet supported" message)

### 12b. Export
- [ ] SVG export
- [ ] Netlist export

### 12c. Marketplace
- [ ] Plugin marketplace panel (discovery/installation UI)
- [ ] Startup download panel (first-run)

### 12d. Fullscreen
- [ ] Toggle fullscreen (F11)

### 12e. Config Persistence
- [ ] Save/load PersistentSettings (theme, keybinds, ui_scale, last_session)
- [ ] Recent files list (up to 8, shown on welcome screen)

---

## Priority Summary

| Priority | Section | Scope |
|----------|---------|-------|
| **P0** | 1. Canvas Rendering | ~30 tasks — shapes, wires, instances, grid, overlays |
| **P0** | 2. Canvas Interaction | ~15 tasks — pan, zoom, hit-test, tools, selection |
| **P1** | 3. Theme & Palette | ~10 tasks — canvas colors, presets, settings |
| **P1** | 4. Keyboard Shortcuts | ~15 tasks — missing binds, keybind table, modes |
| **P1** | 9. Status Bar | ~5 tasks — command mode, vim parsing |
| **P2** | 5. Plugin Widgets | ~10 tasks — actual widget rendering |
| **P2** | 6. Hierarchy | ~5 tasks — descend/ascend, stack |
| **P2** | 7. Context Menu | ~5 tasks — wire/group/canvas menus |
| **P2** | 8. Dialog Gaps | ~10 tasks — find nav, batch props, settings |
| **P2** | 10. Simulate Menu | ~7 tasks — backends, netlist, optimizer |
| **P3** | 11. Doc View | ~6 tasks — markdown, math, editor |
| **P3** | 12. Misc | ~8 tasks — export, marketplace, config |

**Total: ~125 tasks. P0 alone is ~45 tasks.**
