# Feature Landscape: EDA Schematic Editor GUI

**Domain:** EDA schematic editor (GUI redesign of existing Zig-based editor)
**Researched:** 2026-04-04
**Competitors analyzed:** KiCad 9/10, Xschem, LTspice, EasyEDA, Altium (reference), Cadence Virtuoso (reference)
**Confidence:** HIGH (cross-referenced multiple professional EDA tools, verified against official docs)

---

## Table Stakes

Features users expect from any schematic editor. Missing any of these and the tool feels broken or unusable. Ordered by foundational dependency (build bottom-up).

### Canvas Interaction

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Pan (middle-click drag / right-click drag) | Every 2D editor has this. Without it users cannot navigate. | Low | Schemify has this partially via Renderer.zig but it is fragile. Must work on both mouse and trackpad. |
| Zoom (scroll wheel, pinch-to-zoom on trackpad) | Fundamental navigation. Users zoom constantly between overview and detail. | Low | Schemify has zoom_in/zoom_out/zoom_reset commands. Scroll-wheel zoom must center on cursor position, not viewport center. |
| Zoom-to-fit (entire schematic) | Users need to reorient after getting lost. KiCad: `Home`. Xschem: `f`. All editors have this. | Low | Schemify has `zoom_fit` command. Must calculate bounding box of all elements. |
| Zoom-to-selection | After selecting components, users need to focus on them. KiCad: `Ctrl+Shift+F`. | Low | Schemify has `zoom_fit_selected`. |
| Grid display (dots or lines) | Visual alignment reference. KiCad, EasyEDA, Xschem all show grid. Users toggle between dot/line/none. | Low | Schemify has grid toggle. Support dot and line styles. |
| Grid snap | Components and wires MUST snap to grid. Off-grid placement causes connection failures. KiCad default: 50mil. EasyEDA recommends 10/20/100 pixel increments. | Low | Schemify has snap_double/snap_halve. Grid snap must be always-on by default. Adjustable snap size is table stakes. |
| Crosshair cursor | Shows exact cursor position relative to grid. Visual aid for precise placement. All professional tools have this. | Low | Schemify has toggle_crosshair command. |
| Canvas origin/coordinates display | Users need to know where they are. Status bar showing X,Y coordinates. | Low | Should be in CommandBar or status area. |

### Selection

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Click-to-select (instance or wire) | The most basic interaction. Click an element, it highlights. | Low | Schemify has this in some form via Renderer.zig canvas events. |
| Rubber-band / box selection (drag to select area) | Selecting multiple items is fundamental. Every EDA tool has rectangular drag selection. KiCad 10 added lasso selection too, but rectangular is table stakes. | Medium | Schemify CONCERNS.md lists this as missing. Critical gap. Left-to-right = select fully enclosed, right-to-left = select partially enclosed (KiCad convention). |
| Select all / Select none | Bulk operations. Ctrl+A / Ctrl+Shift+A. | Low | Schemify has both commands. |
| Multi-select (Shift+click to add/remove) | Users need to build selections incrementally. Every editor supports this. | Low | Must toggle individual items in/out of selection. |
| Select connected (net tracing) | Select all wires/components on a net. Essential for debugging connectivity. Xschem, KiCad both have this. | Medium | Schemify has `select_connected` but junction detection is broken (documented in CONCERNS.md). BFS is O(n^2). |

### Component Placement and Manipulation

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Place component from library | The core workflow: browse library, pick component, place on canvas. KiCad has symbol chooser dialog. EasyEDA has drag-from-library. Xschem uses Ins key. | Medium | Schemify has `insert_from_library` command and LibraryBrowser.zig. Must show component preview before placement. |
| Move component (disconnect wires) | Pick up and reposition. KiCad: `M`. Xschem: `m`. All editors. | Low | Schemify has `move_interactive`. This is the basic move that breaks wire connections. |
| Drag component (maintain wire connections / rubber-band) | Move component while stretching connected wires. KiCad: `G`. This is THE most important manipulation feature -- without it, every move requires rewiring. | High | Schemify CONCERNS.md lists stretch/insert modes as no-ops. This is a critical gap. Altium calls it "Always Drag" mode. KiCad distinguishes Move (M, disconnects) from Drag (G, rubber-bands). |
| Rotate CW/CCW | Rotate selected components 90 degrees. KiCad: `R`. All editors. | Low | Schemify has `rotate_cw` / `rotate_ccw`. |
| Mirror / Flip (horizontal and vertical) | Flip component orientation. KiCad: `X` (flip H), `Y` (flip V). All editors. | Low | Schemify has `flip_horizontal` / `flip_vertical`. |
| Delete selected | Remove components/wires. Del key universally. | Low | Schemify has `delete_selected`. |
| Duplicate | Copy-in-place with offset. KiCad: `Ctrl+D`. Xschem: `c` (copy). | Low | Schemify has `duplicate_selected` but does not duplicate wires (CONCERNS.md bug). |
| Align to grid | Snap selected items back to nearest grid point. Essential cleanup tool. | Low | Schemify has `align_to_grid` command. |
| Nudge (arrow key move) | Fine positioning with arrow keys. Small incremental moves by grid step. | Low | Schemify has nudge_left/right/up/down. |

### Wire Drawing

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Click-to-route wire drawing | Click start pin, click intermediate points, click end pin. The fundamental wiring interaction. LTspice, KiCad, Xschem, EasyEDA all use this pattern. | Medium | Schemify has `start_wire` and `start_wire_snap` commands. Must support orthogonal (90-degree) routing as default mode. |
| Orthogonal wire routing (90-degree) | Wires route in horizontal/vertical segments only. This is the default in every professional schematic editor. Some support 45-degree as an option. | Medium | Schemify has `toggle_orthogonal_routing`. KiCad supports free-angle, 90-degree, and 45-degree modes. Default must be 90-degree. |
| Wire-to-pin auto-connection | When a wire endpoint lands on a pin, it connects automatically. No manual "attach" step. | Low | This is implicit in snap-to-grid if pins are on-grid. |
| Junction dots | When three or more wires meet at a point, a junction dot appears to indicate electrical connection. KiCad auto-places junctions. All professional tools show these. | Medium | Schemify's core model likely tracks junctions but the GUI rendering of junction dots must be explicit and correct. Incorrect junction display = incorrect schematics. |
| Wire segment deletion | Delete individual wire segments. | Low | Part of general delete_selected. |
| Cancel wire in progress (Escape) | Abort current wire-drawing operation. | Low | Schemify has `cancel_wire`. |

### Undo/Redo

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Undo (Ctrl+Z) | Non-negotiable. Every editor. | Low (exists) | Schemify has undo but redo is broken (CONCERNS.md: forward commands discarded). |
| Redo (Ctrl+Y / Ctrl+Shift+Z) | Almost as important as undo. Users expect to be able to redo after undo. KiCad, Xschem, LTspice, EasyEDA all have redo. | Medium | Schemify's redo returns null. This MUST be fixed in the GUI redesign. Extend History to store forward+inverse pairs. |

### File Operations

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| New / Open / Save / Save-As | Basic file management. Every application. | Low-Medium | Schemify has these but Save-As falls back to CLI (CONCERNS.md). Must work from GUI. |
| Multi-tab (multiple open documents) | Users work on multiple schematics simultaneously. KiCad has tabs. EasyEDA has tabs. | Low (exists) | Schemify has tab management (new_tab, close_tab, next_tab, prev_tab, reopen_last_closed). |
| Unsaved changes warning | Prompt before closing tab/quitting with unsaved changes. Missing this = data loss. | Low | Schemify CONCERNS.md lists this as missing. Critical for user trust. |
| Recent files list | Quick access to previously opened files. | Low | Nice-to-have approaching table stakes. Every desktop app has this. |

### Property Editing

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| View instance properties | See component name, value, reference designator, symbol path, custom attributes. Double-click or `E`/`Q` to open. | Medium | Schemify has PropsDialog.zig but it is a stub -- "(Properties editor not yet implemented)". |
| Edit instance properties | Change reference designator, value, custom attributes. KiCad: full field editor with add/delete/reorder. Xschem: attribute editing is core workflow. | Medium-High | Schemify's `setProp` is a no-op (CONCERNS.md). Blocked by dvui text entry instability for free-form editing. Workaround: use command-bar for property value input. |
| Reference designator annotation | Auto-number components (R1, R2, C1, C2...). KiCad has auto-annotate. EasyEDA has annotate function. | Medium | Schemify has `rename_dup_refdes` but it calls the stub `setProp`. |

### Visual Display

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Component symbol rendering | Draw component symbols (resistors, capacitors, ICs, etc.) from the symbol library. | Medium (exists) | Schemify Renderer.zig handles this including subcircuit symbol cache. |
| Wire rendering with proper corners | Clean orthogonal wire display with proper line thickness. | Low (exists) | Schemify renders wires. Configurable line width exists. |
| Net labels / names | Display net names on wires. Essential for readability. KiCad has local labels, global labels, hierarchical labels. Xschem has labels. | Medium | Schemify has label-related functionality in the core model. GUI must render labels legibly. |
| Reference designator display | Show R1, C1, U1 etc. on the schematic next to components. | Low | Part of component rendering. |
| Value display | Show "10k", "100nF" etc. next to components. | Low | Part of component rendering. |
| Selection highlighting | Selected items must be visually distinct (different color, thicker outline, handles). | Low | Schemify has selection overlay rendering. |
| Theme / color scheme | At minimum: light and dark mode. KiCad 10 added dark mode. EasyEDA has schematic themes. | Low (exists) | Schemify has Theme.zig with JSON overrides and `toggle_colorscheme`. |

### Keyboard Shortcuts

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Standard keyboard shortcuts | Ctrl+S (save), Ctrl+Z (undo), Ctrl+C/V/X (clipboard), Del (delete), R (rotate), M (move), W (wire). All professional EDA tools have consistent single-key shortcuts. | Low (exists) | Schemify has comprehensive Keybinds.zig with 50+ bindings. KiCad-compatible keys are important. |
| Keybind display/help | Users need to discover shortcuts. KiCad has hotkey list. | Low | Schemify has KeybindsDialog. |

### Context Menus

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Right-click context menu | Context-sensitive actions on components, wires, and canvas. Every desktop application. | Low (exists) | Schemify has ContextMenu.zig with instance_items, wire_items, canvas_items. Needs to be functional, not just present. |

---

## Differentiators

Features that set a product apart. Not strictly expected, but valued by power users. Ordered by impact-to-effort ratio (best ROI first).

### High Impact, Moderate Effort

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Vim-style command bar | Power users can type commands instead of mousing. No other EDA tool has this. Xschem has Tcl console but it is scripting, not command mode. This is genuinely unique and aligns with the developer/hacker audience for an open-source EDA tool. | Low (exists) | Schemify already has CommandBar with vim-style command parsing. This is a real differentiator -- polish it. |
| Web/WASM deployment | Run in browser with no install. EasyEDA is web-native but closed-source. No open-source EDA tool runs in the browser with full functionality. KiCad, Xschem, LTspice are all desktop-only. | Medium (exists) | Schemify's dual backend is its strongest differentiator. Keep it working. Web demo is powerful for adoption. |
| Plugin ecosystem (ABI v6) | Extensibility via plugins in Zig, C, Rust, Go, Python. KiCad has Python scripting. Xschem has Tcl scripting. Neither has a proper plugin ABI with UI rendering capability. | Medium (exists) | Schemify has a mature plugin system with multi-language SDKs. Plugin panels can render custom UI. This is ahead of competitors. |
| Net highlighting (multi-color) | Highlight specific nets with distinct colors to trace signals visually. KiCad has single-net highlight. Xschem has probe-based highlighting. Multi-net with distinct colors is a step beyond. | Low-Medium | Schemify has `highlight_selected_nets`, `unhighlight_selected_nets`, `unhighlight_all`. Polish the visual feedback. |
| Inline waveform display | Show simulation results overlaid on schematic. Xschem 3.4+ embeds waveform graphs in the schematic canvas. LTspice shows waveforms by clicking on nets. This bridges the gap between design and verification. | High | Not in current Schemify scope. Would require tight ngspice integration. Defer to future milestone but keep in mind as aspirational. |

### Medium Impact, Low Effort

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Schematic/Symbol view toggle | Switch between schematic editing and symbol editing in the same window. KiCad uses separate applications for this. Having it in one UI is cleaner. | Low (exists) | Schemify has `view_schematic` / `view_symbol` toggle with keybinds (S/Shift+V). |
| Hierarchy navigation (descend/ascend) | Navigate into subcircuit schematics and back up. KiCad uses hierarchy navigator panel. Xschem uses click-to-descend. | Low (exists) | Schemify has `descend_schematic`, `ascend`, `descend_symbol`, `edit_in_new_tab`. Polish the visual feedback (breadcrumb trail showing current hierarchy depth). |
| Customizable keybinds | Let users remap keyboard shortcuts. KiCad has a full hotkey editor. EasyEDA allows full reconfiguration. | Medium | Schemify has static comptime keybind table. Making it runtime-configurable requires a config file and lookup table changes. Not urgent but valued. |
| Export to SVG/PNG/PDF | Produce publication-quality output. KiCad exports to SVG, PDF, postscript. Xschem exports to SVG, PNG, PDF. | Low (exists) | Schemify has export commands. PNG/PDF depend on rsvg-convert (external). SVG is native. |

### Lower Impact, Higher Effort

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Electrical Rules Check (ERC) | Detect unconnected pins, shorted power outputs, missing power connections. KiCad has comprehensive ERC with configurable severity. This is expected in production-grade tools but Schemify targets a different niche (ASIC/analog education). | High | Not in current scope. Requires deep integration with netlist/connectivity model. Defer to a future milestone. |
| Symbol editor (built-in) | Create and edit component symbols within the application. KiCad has a separate symbol editor. EasyEDA has an inline editor. | High | Schemify has symbol view toggle but no dedicated symbol editing workflow. Defer. |
| Bill of Materials (BOM) generation | Extract component list. Standard feature in KiCad, Altium, EasyEDA. | Medium | Can be done via netlist/CLI. GUI integration is nice-to-have. |
| Auto-annotation (batch numbering) | Automatically assign R1, R2, R3... to all unannotated components. KiCad has this as a menu action. | Medium | Useful but can be done via command bar or CLI. |
| Design variants | KiCad 10 added design variants (component substitution per build variant). | Very High | Way beyond current scope. |
| Grouping (component groups) | Group related components for easier manipulation. KiCad 10 brought this from PCB to schematic. | Medium | Not a priority for initial redesign. |
| Bus notation / vector instances | DATA[7:0] bus notation with automatic net expansion. Xschem has this natively. KiCad supports vector and group buses. | High | Schemify's core may support this but GUI rendering of buses is complex. Defer. |

---

## Anti-Features

Features to explicitly NOT build during the GUI redesign. Either too complex for the return, wrong for the audience, or actively harmful.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Marketplace / plugin store UI | dvui text entry is unstable (search is broken). Install logic is a stub. The UX will be frustrating and incomplete. Building this now wastes effort on a poor experience. | Defer entirely. Plugins are installed via CLI (`zig build`, file copy). Document the CLI workflow. |
| Mobile / touch input support | Desktop-first tool for engineers. Touch adds enormous complexity to canvas interaction (pinch-zoom, tap-vs-drag disambiguation, fat finger selection). No professional EDA tool targets mobile. | Ignore mobile. Support trackpad zoom/pan as the extent of non-mouse input. |
| HDL synthesis GUI | The CLI already handles HDL synthesis. Building a GUI for this adds complexity with little value -- users comfortable with HDL are comfortable with CLI. | Keep synthesis as CLI-only (`:netlist`, `zig build run -- netlist`). |
| WYSIWYG text editing in canvas | Free-form text editing on the canvas requires stable text input. dvui text entry is unstable. Attempting this will produce a frustrating, buggy experience. | Use command-bar for all text input (property values, net labels, search queries). This is the vim-way and aligns with the command bar differentiator. |
| Animated transitions / fancy UI effects | Smooth zoom animations, panel slide-in effects, etc. These add complexity, hurt performance on WASM, and are irrelevant for an engineering tool. | Instant transitions. Snap zoom. No animations. Engineers want responsiveness, not polish. |
| Complex multi-pane layout customization | Draggable/dockable panels like VSCode or Altium. Massive GUI complexity. dvui is not designed for this. | Fixed layout: toolbar, tab bar, optional sidebars for plugins, canvas, command bar. Users can toggle sidebars but not rearrange them. |
| Screenshot area selection | Rubber-band area selection for partial screenshot. Nice-to-have with low usage. Full-schematic export covers 95% of cases. | Export full schematic to SVG. Users can crop externally. |
| Move stretch/insert modes | Rubber-band wire tracking during move is HIGH complexity. Wire splitting for insert mode even more so. These are important features but not for the initial GUI rebuild phase. | Ship basic move (disconnect) and drag (rubber-band simple) first. Stretch/insert as a follow-up milestone. |
| Cross-document copy/paste testing | The clipboard is already shared in AppState. Edge cases around allocator lifetimes are real but testing them blocks higher-priority work. | Copy/paste within a single document. Cross-document is best-effort with no guarantees initially. |

---

## Feature Dependencies

These dependencies dictate build order. Features above the arrow must work before features below it.

```
Canvas pan/zoom/grid
  |
  +-> Grid snap
  |     |
  |     +-> Component placement from library
  |     |     |
  |     |     +-> Component move/drag
  |     |     |     |
  |     |     |     +-> Rotate / Flip / Mirror
  |     |     |     +-> Nudge (arrow keys)
  |     |     |     +-> Duplicate
  |     |     |
  |     |     +-> Wire drawing (click-to-route)
  |     |           |
  |     |           +-> Junction rendering
  |     |           +-> Orthogonal routing modes
  |     |           +-> Wire-to-pin auto-connection
  |     |
  |     +-> Click-to-select
  |           |
  |           +-> Multi-select (Shift+click)
  |           +-> Rubber-band box selection
  |           +-> Selection highlighting
  |           |
  |           +-> Delete selected
  |           +-> Context menus (on selection)
  |           +-> Properties dialog (on selection)
  |           +-> Select connected (net tracing)
  |
  +-> Component symbol rendering
  +-> Wire rendering
  +-> Net label rendering
  +-> Ref des / value display

Undo (independent, can be built alongside anything)
  |
  +-> Redo (extends undo system)

File operations (New/Open/Save) -- independent
  |
  +-> Save-As (needs file picker dialog)
  +-> Unsaved changes warning (needs dirty tracking)
  +-> Multi-tab management
  +-> Recent files

Command bar (independent, already exists)
  |
  +-> Property editing via command bar (workaround for dvui text)
  +-> Search/find via command bar

Theme system (independent, already exists)
  |
  +-> Dark/light mode toggle

Plugin panel rendering (independent, already exists)
  |
  +-> Plugin event dispatch
```

### Critical Path

The longest dependency chain that determines minimum time to a usable editor:

```
Canvas rendering -> Grid snap -> Component placement -> Wire drawing ->
Click-to-select -> Box selection -> Delete/Move/Rotate -> Properties viewing
```

This chain represents the minimum feature set for a schematic that can be drawn, edited, and examined.

---

## MVP Recommendation

### Phase 1: Canvas Foundation (must work first)

Prioritize these -- nothing else works without them:

1. **Canvas pan/zoom/grid** -- scrollwheel zoom (centered on cursor), middle-click pan, grid dots, coordinates in status bar
2. **Grid snap** -- always-on by default, adjustable snap size
3. **Component symbol rendering** -- draw instances from the core data model
4. **Wire rendering** -- draw wires with proper corners and line width
5. **Net label and ref-des display** -- readable text on the schematic

### Phase 2: Core Editing

The interactions that make it an editor, not a viewer:

6. **Click-to-select** with selection highlighting
7. **Rubber-band box selection** (left-to-right: fully enclosed; right-to-left: partial)
8. **Multi-select** (Shift+click toggle)
9. **Component placement** from library browser
10. **Move and Drag** (Move disconnects; Drag rubber-bands wires)
11. **Wire drawing** (click-to-route, orthogonal routing)
12. **Delete selected**
13. **Rotate / Flip / Mirror**
14. **Undo + Redo** (fix the redo system)

### Phase 3: Productivity Features

Features that make the editor practical for real work:

15. **File operations** (New, Open, Save, Save-As with file picker)
16. **Unsaved changes warning**
17. **Property viewing** (read-only dialog showing instance attributes)
18. **Property editing** via command bar (`:set refdes R1`, `:set value 10k`)
19. **Context menus** (functional, not just present)
20. **Junction dot rendering**
21. **Select connected** (fix junction detection, improve BFS performance)
22. **Copy/Paste** (clipboard operations)
23. **Duplicate** (fix to include wires)

### Defer to Future Milestones

- **Inline waveform display** -- high value but enormous effort
- **ERC** -- requires deep connectivity analysis
- **Symbol editor** -- separate workflow
- **Bus notation rendering** -- complex
- **Marketplace UI** -- blocked by dvui text entry
- **Customizable keybinds** (runtime) -- nice-to-have
- **Move stretch/insert modes** -- high complexity wire tracking
- **Design variants** -- KiCad 10 territory, way beyond scope

---

## Sources

- [KiCad 10 Release Notes](https://www.kicad.org/blog/2026/03/Version-10.0.0-Released/) -- KiCad 10 features: dark mode, lasso selection, grouping, design variants, hop-over wire crossings
- [KiCad Schematic Editor Docs (9.0)](https://docs.kicad.org/9.0/en/eeschema/eeschema.html) -- Comprehensive feature reference
- [KiCad Schematic Editor Docs (10.0)](https://docs.kicad.org/10.0/en/eeschema/eeschema.html) -- Latest features
- [Xschem GitHub](https://github.com/StefanSchippers/xschem) -- Hierarchy, parametric design, bus notation
- [Xschem Commands Reference](https://xschem.sourceforge.io/stefan/xschem_man/commands.html) -- Editor commands and keyboard shortcuts
- [Xschem Graphs / Waveform Display](https://xschem.sourceforge.io/stefan/xschem_man/graphs.html) -- Inline waveform rendering
- [LTspice Schematic Editing](https://ltwiki.org/LTspiceHelpXVII/LTspiceHelp/html/Schematic_Editing.htm) -- Verb-noun interface, wire drawing, component placement
- [EasyEDA Schematic Capture Docs](https://docs.easyeda.com/en/Introduction/Schematic-Capture/) -- Web-based editor features
- [EasyEDA Canvas Settings](https://docs.easyeda.com/en/Schematic/Canvas-Settings/) -- Grid, snap, pan/zoom configuration
- [EasyEDA Wiring Tools](https://docs.easyeda.com/en/Schematic/Wiring-Tools/) -- Wire routing and rubber-band behavior
- [Altium Schematic Editing Essentials](https://techdocs.altium.com/node/296790) -- Move vs Drag distinction, rubber-banding
- [KiCad ERC Documentation](https://kicad-sch-api.readthedocs.io/en/latest/ERC_USER_GUIDE.html) -- Electrical rules check features
- [KiCad Forum: Moving Components](https://forum.kicad.info/t/moving-components-in-schematic-editor/36095) -- Move vs Drag community discussion
- [CNX Software: KiCad 10 Release](https://www.cnx-software.com/2026/03/22/kicad-10-release-dark-mode-graphical-drc-rule-editor-new-file-importers-and-more/) -- Feature summary
