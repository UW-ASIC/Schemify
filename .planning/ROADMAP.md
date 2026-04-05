# Roadmap: Schemify GUI Redesign

## Overview

Rebuild the entire gui/ module of a Zig-based EDA schematic editor from a broken shell into a fully functional editor. The work follows a strict bottom-up dependency chain: architecture first, then canvas/viewport, then read-only rendering, then interactive selection, then editing, then wire drawing. Undo/redo and file operations are independent tracks that parallelize with the editing chain. Properties, productivity, theme validation, and plugin integration complete the editor.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: GUI Architecture & Cleanup** - Decompose Renderer.zig, establish Canvas/ subfolder, create components/ library, merge state.zig, eliminate module-level vars, fix allocators
- [ ] **Phase 2: Canvas Foundation** - Pan, zoom, grid, crosshair cursor, coordinate display -- the viewport interaction layer everything else depends on
- [ ] **Phase 3: Schematic Rendering** - Read-only display of components, wires, labels, junctions with enforced z-order and subcircuit caching
- [ ] **Phase 4: Selection** - Click-select, rubber-band box select, multi-select, select-all, select-connected net tracing
- [ ] **Phase 5: Component Editing** - Place, move, drag (rubber-band), rotate, flip, delete, nudge, duplicate, align -- full interactive editing
- [ ] **Phase 6: Wire Drawing** - Click-to-route wires with orthogonal routing, junction auto-placement, pin snap, and cancel
- [ ] **Phase 7: Undo/Redo** - Fix broken redo with forward+inverse command pairs, redo stack management
- [ ] **Phase 8: File Operations** - New, open, save, save-as (custom file picker), unsaved changes warning, multi-tab management
- [ ] **Phase 9: Properties & Command Bar** - Property viewing/editing via command bar, find/search, vim-style command input and status display
- [ ] **Phase 10: Productivity & Polish** - Context menus, copy/paste, library browser, keybinds dialog
- [ ] **Phase 11: Theme & Plugin Validation** - Theme compliance across all components, dark/light toggle, plugin panel rendering, dual-backend final validation

## Phase Details

### Phase 1: GUI Architecture & Cleanup
**Goal**: Establish the decomposed GUI module structure that all subsequent phases build on -- Canvas/ subfolder, components/ library, clean state management, correct allocators
**Depends on**: Nothing (first phase)
**Requirements**: INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-05, INFRA-06, INFRA-07, INFRA-08
**Success Criteria** (what must be TRUE):
  1. Renderer.zig is replaced by a Canvas/ subfolder with separate files for viewport, grid, symbol rendering, wire rendering, selection overlay, and interaction handling
  2. gui/Components/ subfolder exists with reusable themed widget abstractions (buttons, panels, floating windows)
  3. Toolbar shows only File, Edit, View menus with zero stub or unimplemented entries
  4. Both native (zig build run) and WASM (zig build -Dbackend=web) compile and render the GUI shell without crashes
  5. Zero module-level `var` declarations remain in gui/ files -- all persistent state lives in AppState.gui
**Plans:** 3 plans

Plans:
- [x] 01-01-PLAN.md -- Types foundation: Canvas/types.zig, GuiState sub-structs, Components/ restructure, Arch.md cleanup
- [ ] 01-02-PLAN.md -- Renderer decomposition: Split Renderer.zig into Canvas/ subfolder, rewire gui/lib.zig
- [ ] 01-03-PLAN.md -- Toolbar stripping, module-level var migration, allocator fixes, dual backend verification

### Phase 2: Canvas Foundation
**Goal**: Users can navigate the schematic canvas with fluid pan, zoom, and grid -- the viewport interaction layer that every editing feature depends on
**Depends on**: Phase 1
**Requirements**: CANV-01, CANV-02, CANV-03, CANV-04, CANV-05, CANV-06, CANV-07, CANV-08
**Success Criteria** (what must be TRUE):
  1. User can pan the canvas via middle-click drag, right-click drag, trackpad gestures, and spacebar + mouse drag (hand tool)
  2. User can zoom via scroll wheel centered on the cursor position (not viewport center) and use zoom-to-fit / zoom-to-selection
  3. Grid displays in configurable styles (dots, lines, none) with adaptive density that stays legible at all zoom levels
  4. Crosshair cursor tracks mouse position snapped to grid, and current canvas coordinates display in the command bar / status area
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 02-01: TBD
- [ ] 02-02: TBD

### Phase 3: Schematic Rendering
**Goal**: Users see their schematic content rendered correctly -- components, wires, labels, junctions displayed in proper z-order from the core data model
**Depends on**: Phase 2
**Requirements**: REND-01, REND-02, REND-03, REND-04, REND-05, REND-06, REND-07
**Success Criteria** (what must be TRUE):
  1. Component symbols render from core data model with LRU subcircuit cache (max 256 entries, proper eviction)
  2. Wires render with orthogonal corners, configurable thickness, and junction dots at 3+ wire intersections
  3. Net labels, reference designators, and component values display legibly next to their respective elements
  4. Canvas z-order is enforced: Grid -> Wires -> Junctions -> Symbols -> Labels -> Selection highlight -> Rubber-band -> Crosshair
  5. Selected elements display with distinct highlight color and thickness
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 03-01: TBD
- [ ] 03-02: TBD

### Phase 4: Selection
**Goal**: Users can select schematic elements through multiple interaction modes -- click, box, multi-select, and net tracing
**Depends on**: Phase 3
**Requirements**: SEL-01, SEL-02, SEL-03, SEL-04, SEL-05
**Success Criteria** (what must be TRUE):
  1. User can click to select a single instance or wire, and Shift+click to toggle items in/out of a multi-selection
  2. User can rubber-band box select with directional convention: left-to-right selects fully enclosed items, right-to-left selects partially intersecting items
  3. User can select all (Ctrl+A), deselect all (Escape), and select-connected to trace an entire net through junctions
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 04-01: TBD
- [ ] 04-02: TBD

### Phase 5: Component Editing
**Goal**: Users can interactively edit the schematic -- place, move, drag, rotate, flip, delete, nudge, duplicate, and align components
**Depends on**: Phase 4
**Requirements**: EDIT-01, EDIT-02, EDIT-03, EDIT-04, EDIT-05, EDIT-06, EDIT-07, EDIT-08, EDIT-09
**Success Criteria** (what must be TRUE):
  1. User can place components from the library onto the canvas at grid-snapped positions
  2. User can move selected components (M key -- disconnects wires) and drag selected components (G key -- rubber-band stretches connected wires)
  3. User can rotate CW/CCW (R / Shift+R), flip horizontally/vertically, and nudge with arrow keys in grid-step increments
  4. User can delete selected components and wires (Del key), duplicate with offset, and align selection to grid
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 05-01: TBD
- [ ] 05-02: TBD

### Phase 6: Wire Drawing
**Goal**: Users can draw and route wires between component pins with automatic orthogonal routing and junction management
**Depends on**: Phase 4
**Requirements**: WIRE-01, WIRE-02, WIRE-03, WIRE-04, WIRE-05
**Success Criteria** (what must be TRUE):
  1. User can draw wires via click-to-route: click start point, click intermediate points, click end point to finish
  2. Wire routing defaults to orthogonal (90-degree) mode with endpoints that auto-connect when landing on a pin (snap-to-grid)
  3. User can cancel a wire-in-progress with Escape, and junction dots auto-place when 3+ wires meet at a point
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 06-01: TBD
- [ ] 06-02: TBD

### Phase 7: Undo/Redo
**Goal**: Users can confidently undo and redo any editing action with full bidirectional command history
**Depends on**: Phase 1 (parallelizable with Phases 4-6)
**Requirements**: UNDO-01, UNDO-02, UNDO-03
**Success Criteria** (what must be TRUE):
  1. User can undo actions with Ctrl+Z, stepping backward through full command history
  2. User can redo actions with Ctrl+Y / Ctrl+Shift+Z using forward+inverse command pairs (not the current broken system)
  3. Redo stack is cleared when any new undoable command is executed
**Plans**: TBD

Plans:
- [ ] 07-01: TBD

### Phase 8: File Operations
**Goal**: Users can create, open, save, and manage schematic files with safety against data loss
**Depends on**: Phase 1 (parallelizable with Phases 4-6)
**Requirements**: FILE-01, FILE-02, FILE-03, FILE-04, FILE-05, FILE-06
**Success Criteria** (what must be TRUE):
  1. User can create new schematics (new tab), open existing .chn files, and save the current schematic (Ctrl+S)
  2. User can save-as to a new path via a custom file picker dialog (not native OS dialog -- WASM compatible)
  3. User is warned about unsaved changes before closing a tab or quitting, with Save/Discard/Cancel options
  4. User can manage multiple open documents via tabs: switch between them, close tabs, and reopen the last closed tab
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 08-01: TBD
- [ ] 08-02: TBD

### Phase 9: Properties & Command Bar
**Goal**: Users can view and edit component properties and search the schematic, all through the vim-style command bar
**Depends on**: Phase 4, Phase 7
**Requirements**: PROP-01, PROP-02, PROP-03, PROD-02, PROD-04
**Success Criteria** (what must be TRUE):
  1. User can view instance properties (name, value, refdes, symbol, custom attributes) in a read-only dialog
  2. User can edit instance properties via command bar commands (`:set refdes R1`, `:set value 10k`) with the setProp implementation fully functional
  3. User can find/search instances and nets via command bar (`:find R1`, `:find net_name`) with the canvas centering on results
  4. Command bar displays status information and accepts vim-style command input with proper keybind suppression when focused
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 09-01: TBD
- [ ] 09-02: TBD

### Phase 10: Productivity & Polish
**Goal**: Users have the productivity tools that make real schematic work efficient -- context menus, clipboard, component browsing, and shortcut reference
**Depends on**: Phase 5, Phase 6
**Requirements**: PROD-01, PROD-03, PROD-05, PROD-06
**Success Criteria** (what must be TRUE):
  1. User can right-click on components, wires, and canvas to get context-appropriate action menus
  2. User can copy/paste selected components within a document
  3. User can browse the component library to select components for placement
  4. User can view all keyboard shortcuts in a keybinds dialog
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 10-01: TBD
- [ ] 10-02: TBD

### Phase 11: Theme & Plugin Validation
**Goal**: The editor has consistent theming across every component with dark/light mode support, plugins render correctly in the new architecture, and both backends are validated end-to-end
**Depends on**: Phase 10 (all components must exist for theme validation)
**Requirements**: THEME-01, THEME-02, THEME-03, THEME-04, PLUG-01, PLUG-02, PLUG-03
**Success Criteria** (what must be TRUE):
  1. All GUI components use Theme.zig palette with zero hardcoded colors, and theme is fully customizable via JSON overrides
  2. Dark/light mode toggle works correctly across every component including new Components/ widgets
  3. Plugin panels render correctly in the new Canvas/ architecture with event dispatch (button clicks, slider changes, checkbox toggles) working
  4. ParsedWidget rendering contract is preserved with no ABI v6 breakage
  5. Both native and WASM backends produce identical behavior across all features
**Plans**: TBD
**UI hint**: yes

Plans:
- [ ] 11-01: TBD
- [ ] 11-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11
Note: Phases 7 and 8 depend only on Phase 1 and can be parallelized with Phases 4-6.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. GUI Architecture & Cleanup | 0/3 | Planning complete | - |
| 2. Canvas Foundation | 0/2 | Not started | - |
| 3. Schematic Rendering | 0/2 | Not started | - |
| 4. Selection | 0/2 | Not started | - |
| 5. Component Editing | 0/2 | Not started | - |
| 6. Wire Drawing | 0/2 | Not started | - |
| 7. Undo/Redo | 0/1 | Not started | - |
| 8. File Operations | 0/2 | Not started | - |
| 9. Properties & Command Bar | 0/2 | Not started | - |
| 10. Productivity & Polish | 0/2 | Not started | - |
| 11. Theme & Plugin Validation | 0/2 | Not started | - |
