# Requirements: Schemify GUI Redesign

**Defined:** 2026-04-04
**Core Value:** A functional schematic editor where users can place components, draw wires, edit properties, and manage files through a clean, minimal GUI on both native and web.

## v1 Requirements

Requirements for the GUI redesign. Each maps to roadmap phases.

### Infrastructure

- [ ] **INFRA-01**: GUI module rebuilt with components/ subfolder containing reusable themed widgets
- [ ] **INFRA-02**: Renderer.zig (1152 LOC) decomposed into Canvas/ subfolder with single-responsibility components
- [ ] **INFRA-03**: Minimal toolbar with File, Edit, View menus only — all stubs removed
- [ ] **INFRA-04**: Module-level `var` state eliminated from GUI files — all persistent state in AppState.gui
- [ ] **INFRA-05**: state.zig merged into types.zig (state is types, not a separate concept)
- [ ] **INFRA-06**: All Arch.md files removed from source tree
- [ ] **INFRA-07**: page_allocator replaced with GPA in GUI hot paths (Renderer, FileExplorer, Theme)
- [ ] **INFRA-08**: Both native (raylib) and WASM (web) backends functional and tested

### Canvas

- [ ] **CANV-01**: User can pan canvas via middle-click drag, right-click drag, and trackpad gestures
- [ ] **CANV-02**: User can pan canvas via spacebar + mouse drag (hand tool — moves opposite to mouse direction)
- [ ] **CANV-03**: User can zoom via scroll wheel centered on cursor position (not viewport center)
- [ ] **CANV-04**: User can zoom-to-fit (entire schematic) and zoom-to-selection
- [ ] **CANV-05**: Grid displays in configurable style (dots, lines, or none) with adaptive density at high zoom
- [ ] **CANV-06**: Grid snap is always-on by default with adjustable snap size
- [ ] **CANV-07**: Crosshair cursor tracks mouse position on grid
- [ ] **CANV-08**: Canvas coordinates (X,Y) displayed in status bar / command bar

### Rendering

- [ ] **REND-01**: Component symbols rendered from core data model with subcircuit cache (LRU eviction, max 256 entries)
- [ ] **REND-02**: Wires rendered with proper orthogonal corners and configurable line thickness
- [ ] **REND-03**: Net labels displayed legibly on wires
- [ ] **REND-04**: Reference designators and component values displayed next to components
- [ ] **REND-05**: Selection highlighting with distinct color and thickness
- [ ] **REND-06**: Junction dots rendered at 3+ wire intersection points
- [ ] **REND-07**: Canvas render z-order enforced: Grid → Wires → Junctions → Symbols → Labels → Selection → Rubber-band → Crosshair

### Selection

- [ ] **SEL-01**: User can click to select a single instance or wire
- [ ] **SEL-02**: User can rubber-band box select (L-to-R: fully enclosed, R-to-L: partially intersecting)
- [ ] **SEL-03**: User can multi-select via Shift+click to toggle items in/out of selection
- [ ] **SEL-04**: User can select all (Ctrl+A) and deselect all (Escape)
- [ ] **SEL-05**: User can select-connected to trace a net (with fixed junction detection and improved BFS)

### Editing

- [ ] **EDIT-01**: User can place components from library browser onto canvas
- [ ] **EDIT-02**: User can move selected components (M key — disconnects wires)
- [ ] **EDIT-03**: User can drag selected components (G key — rubber-band stretches connected wires)
- [ ] **EDIT-04**: User can rotate selected components CW/CCW (R key, Shift+R)
- [ ] **EDIT-05**: User can flip selected components horizontally and vertically
- [ ] **EDIT-06**: User can delete selected components and wires (Del key)
- [ ] **EDIT-07**: User can nudge selected components with arrow keys (grid-step increments)
- [ ] **EDIT-08**: User can duplicate selected components and wires with offset
- [ ] **EDIT-09**: User can align selected components to grid

### Wire Drawing

- [ ] **WIRE-01**: User can draw wires via click-to-route (click start, click intermediate points, click end)
- [ ] **WIRE-02**: Orthogonal (90-degree) wire routing is the default mode
- [ ] **WIRE-03**: Wire endpoints auto-connect when landing on a pin (snap-to-grid)
- [ ] **WIRE-04**: User can cancel wire-in-progress with Escape
- [ ] **WIRE-05**: Junction dots auto-placed when 3+ wires meet at a point

### Undo/Redo

- [ ] **UNDO-01**: User can undo actions (Ctrl+Z) with full command history
- [ ] **UNDO-02**: User can redo actions (Ctrl+Y / Ctrl+Shift+Z) — fix broken redo system with forward+inverse pairs
- [ ] **UNDO-03**: Redo stack cleared on any new undoable command

### File Operations

- [ ] **FILE-01**: User can create new schematic (new tab)
- [ ] **FILE-02**: User can open existing .chn files
- [ ] **FILE-03**: User can save current schematic (Ctrl+S)
- [ ] **FILE-04**: User can save-as to a new path via custom file picker dialog (not native OS dialog)
- [ ] **FILE-05**: User warned about unsaved changes before closing tab or quitting (Save/Discard/Cancel)
- [ ] **FILE-06**: User can manage multiple open documents via tabs (switch, close, reopen last closed)

### Properties

- [ ] **PROP-01**: User can view instance properties in a dialog (name, value, refdes, symbol, custom attributes)
- [ ] **PROP-02**: User can edit instance properties via command bar (`:set refdes R1`, `:set value 10k`)
- [ ] **PROP-03**: setProp implementation functional (currently a no-op stub)

### Productivity

- [ ] **PROD-01**: Right-click context menus functional on components, wires, and canvas
- [ ] **PROD-02**: User can find/search instances and nets via command bar (`:find R1`, `:find net_name`)
- [ ] **PROD-03**: User can copy/paste selected components within a document
- [ ] **PROD-04**: Command bar with vim-style command input and status display
- [ ] **PROD-05**: Library browser for browsing and selecting components for placement
- [ ] **PROD-06**: Keybinds dialog showing all keyboard shortcuts

### Theme

- [ ] **THEME-01**: All GUI components use Theme.zig palette — zero hardcoded colors
- [ ] **THEME-02**: Theme fully customizable via JSON overrides (colors, spacing, sizing)
- [ ] **THEME-03**: Dark/light mode toggle works across all components
- [ ] **THEME-04**: New reusable components (Components/) all accept theme configuration

### Plugin Integration

- [ ] **PLUG-01**: Plugin panels render correctly in new GUI architecture
- [ ] **PLUG-02**: Plugin event dispatch (button clicks, slider changes, checkbox toggles) works
- [ ] **PLUG-03**: ParsedWidget rendering contract preserved (no ABI breakage)

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Advanced Editing
- **AEDIT-01**: Move stretch mode (rubber-band wire tracking with segment insertion)
- **AEDIT-02**: Move insert mode (wire splitting and auto-insertion)
- **AEDIT-03**: Runtime-customizable keybinds (save to config file)

### Advanced Features
- **AFEAT-01**: Inline waveform display overlaid on schematic
- **AFEAT-02**: Electrical Rules Check (ERC)
- **AFEAT-03**: Built-in symbol editor workflow
- **AFEAT-04**: Bus notation rendering (DATA[7:0])
- **AFEAT-05**: Net highlighting with multiple distinct colors
- **AFEAT-06**: Hierarchy navigation breadcrumb trail
- **AFEAT-07**: Auto-annotation (batch ref-des numbering)

### Platform
- **PLAT-01**: Marketplace plugin UI (blocked by dvui text entry)
- **PLAT-02**: Cross-document copy/paste with allocator safety
- **PLAT-03**: Recent files list

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Mobile / touch input | Desktop-first tool. Touch adds enormous complexity. No professional EDA tool targets mobile. |
| WYSIWYG text editing on canvas | dvui text entry unstable. Command bar is the workaround and a differentiator. |
| Animated transitions / fancy UI effects | Irrelevant for engineering tool. Hurts WASM performance. |
| Complex dockable/draggable panel layout | dvui not designed for this. Fixed layout with toggle-able sidebars. |
| Screenshot area selection | Full schematic export covers 95% of cases. Users can crop externally. |
| HDL synthesis GUI | CLI handles this already. Users comfortable with HDL are comfortable with CLI. |
| Design variants | KiCad 10 territory. Way beyond current scope. |
| Marketplace install (download plugins) | Install logic is a stub, search blocked by dvui text. CLI plugin install works. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | TBD | Pending |
| INFRA-02 | TBD | Pending |
| INFRA-03 | TBD | Pending |
| INFRA-04 | TBD | Pending |
| INFRA-05 | TBD | Pending |
| INFRA-06 | TBD | Pending |
| INFRA-07 | TBD | Pending |
| INFRA-08 | TBD | Pending |
| CANV-01 | TBD | Pending |
| CANV-02 | TBD | Pending |
| CANV-03 | TBD | Pending |
| CANV-04 | TBD | Pending |
| CANV-05 | TBD | Pending |
| CANV-06 | TBD | Pending |
| CANV-07 | TBD | Pending |
| CANV-08 | TBD | Pending |
| REND-01 | TBD | Pending |
| REND-02 | TBD | Pending |
| REND-03 | TBD | Pending |
| REND-04 | TBD | Pending |
| REND-05 | TBD | Pending |
| REND-06 | TBD | Pending |
| REND-07 | TBD | Pending |
| SEL-01 | TBD | Pending |
| SEL-02 | TBD | Pending |
| SEL-03 | TBD | Pending |
| SEL-04 | TBD | Pending |
| SEL-05 | TBD | Pending |
| EDIT-01 | TBD | Pending |
| EDIT-02 | TBD | Pending |
| EDIT-03 | TBD | Pending |
| EDIT-04 | TBD | Pending |
| EDIT-05 | TBD | Pending |
| EDIT-06 | TBD | Pending |
| EDIT-07 | TBD | Pending |
| EDIT-08 | TBD | Pending |
| EDIT-09 | TBD | Pending |
| WIRE-01 | TBD | Pending |
| WIRE-02 | TBD | Pending |
| WIRE-03 | TBD | Pending |
| WIRE-04 | TBD | Pending |
| WIRE-05 | TBD | Pending |
| UNDO-01 | TBD | Pending |
| UNDO-02 | TBD | Pending |
| UNDO-03 | TBD | Pending |
| FILE-01 | TBD | Pending |
| FILE-02 | TBD | Pending |
| FILE-03 | TBD | Pending |
| FILE-04 | TBD | Pending |
| FILE-05 | TBD | Pending |
| FILE-06 | TBD | Pending |
| PROP-01 | TBD | Pending |
| PROP-02 | TBD | Pending |
| PROP-03 | TBD | Pending |
| PROD-01 | TBD | Pending |
| PROD-02 | TBD | Pending |
| PROD-03 | TBD | Pending |
| PROD-04 | TBD | Pending |
| PROD-05 | TBD | Pending |
| PROD-06 | TBD | Pending |
| PLUG-01 | TBD | Pending |
| PLUG-02 | TBD | Pending |
| THEME-01 | TBD | Pending |
| THEME-02 | TBD | Pending |
| THEME-03 | TBD | Pending |
| THEME-04 | TBD | Pending |
| PLUG-01 | TBD | Pending |
| PLUG-02 | TBD | Pending |
| PLUG-03 | TBD | Pending |

**Coverage:**
- v1 requirements: 60 total
- Mapped to phases: 0
- Unmapped: 60 ⚠️

---
*Requirements defined: 2026-04-04*
*Last updated: 2026-04-04 after initial definition*
