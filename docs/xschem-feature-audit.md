# XSchem Complete Feature Audit

Exhaustive feature list of XSchem (the schematic editor by Stefan Schippers) for competitive analysis. Every feature, capability, and UI element documented below.

---

## Canvas & Navigation

| Feature | Description |
|---------|-------------|
| Pan (middle mouse drag) | Drag the viewable area with middle mouse button |
| Pan (Space key) | Pan schematic with space key (also toggles wire path during wire drawing) |
| Pan (Shift+P) | Dedicated pan mode |
| Zoom in (Shift+Z) | Zoom into the schematic |
| Zoom out (Ctrl+Z) | Zoom out of the schematic |
| Zoom box (z key) | Draw a rectangle to zoom into that area |
| Zoom area (right button drag) | Drag right mouse button to zoom into a rectangular region |
| Fit/full zoom (f key) | Fit entire schematic into the visible window |
| Zoom full selected (Ctrl+Shift+F) | Zoom to fit only selected elements |
| Mouse wheel zoom | Scroll wheel zooms in/out at cursor position |
| Grid display toggle (% key) | Show/hide the snap grid |
| Grid snap value (g / Shift+G) | Halve or double the snap factor |
| Set snap factor (Ctrl+G) | Set exact snap value via dialog |
| Snap to grid | All objects snap to configurable grid multiples (default 10.0 units) |
| Big grid points | Scale grid point visibility with zoom level (config: `big_grid_points`) |
| Crosshair (Alt+X) | Toggle crosshair cursor display at mouse position |
| Arrow key navigation | Move viewport with Up/Down/Left/Right arrow keys |
| Unzoom no-drift | Config option to prevent viewport drift during zoom operations (`unzoom_nodrift`) |
| Double-precision coordinates | All coordinates stored as double-precision floats |
| Background color | Configurable background layer (layer 0) |
| Light/dark color scheme toggle (Shift+O) | Switch between light and dark display themes |
| Rainbow color mode (--rainbow / -z) | Apply rainbow-style layer coloring |
| Fullscreen toggle (\ key) | Toggle fullscreen display mode |

---

## Schematic Editing

### Wire Drawing

| Feature | Description |
|---------|-------------|
| Place wire (w key) | Start drawing a wire; rubber-band follows mouse until click places endpoint |
| Snap wire to pin (Shift+W) | Place wire, snapping to closest pin or net endpoint |
| Orthogonal routing toggle (Shift+L) | Toggle automatic horizontal-vertical or vertical-horizontal routing |
| Wire path toggle (Space during draw) | Toggle wire bend direction while placing wire |
| Constrained horizontal (h key) | Constrain move/copy to horizontal axis |
| Constrained vertical (v key) | Constrain move/copy to vertical axis |
| Bus wire display (bus=true) | Set `bus=true` property on wires to draw them thicker |
| Cut wire at mouse (Alt+Right button) | Cut a wire at mouse position, creating two adjacent wire segments |
| Cut wire without snap (Alt+Shift+Right) | Cut wire without aligning to snap setting |
| Break wires at connections (! key) | Break selected wires at any wire or component pin connection point |
| Join/break/collapse wires (& key) | Join, break, or collapse wire segments |
| Autotrim wires | Auto-join and auto-trim overlapping wires (config: `autotrim_wires`) |
| Wire end drag as stretch | Config: `wire_end_drag_is_stretch` modifies existing wire end on drag |
| Persistent command mode | Continue drawing wire segments after each click (config: `persistent_command`) |

### Component Placement

| Feature | Description |
|---------|-------------|
| Insert symbol (Insert key) | Open library browser to place a component |
| Persistent insert dialog (Shift+Insert / Ctrl+I) | Keep symbol insertion dialog open |
| Place text (t key) | Place text annotation on schematic |
| Place line (l key) | Place non-electrical graphical line |
| Place rectangle (r key) | Place rectangle on specified layer |
| Place polygon (p key) | Place multi-point polygon (click points, close with right-click or Return) |
| Place arc (Shift+C) | Place arc (start point, end point, placement) |
| Place circle (Ctrl+Shift+C) | Place full circle |
| Add schematic ipin (Ctrl+P) | Place input pin for hierarchical port |
| Add schematic opin (Ctrl+Shift+P) | Place output pin for hierarchical port |
| Add symbol pin (Alt+P) | Add a pin to a symbol definition |
| Add lab_pin (Alt+L) | Add a net label pin (by-name connection) |
| Add lab_wire (Alt+Shift+L) | Add a wire label |

### Editing Operations

| Feature | Description |
|---------|-------------|
| Move selected (m key) | Move selected objects |
| Move with stretch (Ctrl+M) | Move selected objects, stretching attached wires |
| Move with insert wires (Shift+M / Alt+M) | Move and auto-insert wires when separating touching pins |
| Move combined (Ctrl+Shift+M) | Combined stretch and insert-wire move |
| Copy selected (c key) | Copy selected objects |
| Copy with inserted wires (Alt+C) | Copy and insert wires when separating touching pins |
| Save to clipboard (Ctrl+C) | Copy selection to system clipboard |
| Paste from clipboard (Ctrl+V) | Paste from system clipboard |
| Cut to clipboard (Ctrl+X) | Cut selection to system clipboard |
| Delete selected (Delete key) | Delete selected objects |
| Delete files (Ctrl+D) | Delete schematic/symbol files |
| Rotate (Shift+R) | Rotate selected objects 90 degrees |
| Rotate around anchor (Alt+R) | Rotate around anchor points |
| Horizontal flip (Shift+F) | Flip selected objects horizontally |
| Horizontal flip around anchor (Alt+F) | Flip around anchor points |
| Vertical flip (Shift+V) | Flip selected objects vertically |
| Vertical flip around anchor (Alt+V) | Flip around anchor points |
| Undo (u key) | Undo last operation |
| Redo (Shift+U) | Redo last undone operation |
| Undo storage mode | Configurable disk or memory storage (`undo_type`) |
| Align to grid (Alt+U) | Align selected objects to current grid |
| Stretch operation (Ctrl+Left drag) | Select objects for stretch by dragging with Ctrl |
| Toggle stretching wires (y key) | Toggle wire stretch behavior |
| Change element order (Shift+S) | Change drawing/selection order of elements |
| Merge file (b key) | Merge another schematic file into current |
| Clear schematic (Ctrl+N) | Clear entire schematic |
| Clear symbol (Ctrl+Shift+N) | Clear entire symbol |

### Instance Vector / Array Placement

| Feature | Description |
|---------|-------------|
| Instance vectors | Name instances with vector notation (e.g., `x22[15:0]`) to create 16 instances |
| Multiplier attribute | Use `m=N` attribute for parallel device instances |
| Repetition operators | `2*signal[1:0]` prefix/postfix multipliers for bus expansion |

---

## Hierarchy & Symbols

### Hierarchical Navigation

| Feature | Description |
|---------|-------------|
| Descend to schematic (e key) | Push into a component's schematic |
| Back to parent (BackSpace / Ctrl+E) | Pop back to parent schematic level |
| Descend to symbol (i key) | View a component's symbol definition |
| Edit symbol in new window (Alt+I) | Open symbol in a new editing window |
| Edit schematic in new window (Alt+E) | Open schematic in a new window |
| Edit in new process (Alt+Shift+E) | Open in an entirely new XSchem process |
| Multiple hierarchy levels | Unlimited depth of hierarchical nesting |
| Designs with 1M+ transistors | Proven to handle very large hierarchical IC designs |

### Symbol Creation & Editing

| Feature | Description |
|---------|-------------|
| Auto-generate symbol (a key) | Create symbol from pin list of current schematic |
| Manual symbol editing | Draw symbol graphics with lines, rectangles, polygons, arcs, text |
| Pin definition | Pins are rectangles on the 'pin' layer with name and direction |
| Pin directions | in, out, inout |
| Pin ordering (sim_pinnumber) | Control port ordering in netlists |
| Highlight propagation (propag) | Configure which pins propagate net highlighting |
| Symbol type attribute | subcircuit, primitive, label, probe, ngprobe, netlist_commands |
| Template attribute | Default parameter values for new instances |
| Format attribute | Netlist generation format string with token substitution |
| Bezier curves | `bezier=true` attribute transforms polygons into bezier curves |
| Symbol embedding (embed=true) | Embed symbol definition inside schematic file for portability |
| Clone/copy cell | Copy existing component to create independent variant |
| Make schematic from symbol (Ctrl+L) | Generate schematic view from selected symbol |
| Create symbol pins from schematic (Alt+H) | Generate symbol pins from existing schematic pins |
| Make schematic+symbol from selection (Ctrl+Shift+H) | Create both from selected components |

### Library Management

| Feature | Description |
|---------|-------------|
| XSCHEM_LIBRARY_PATH | Configurable list of library search paths |
| Library browser | Navigate libraries via Insert key dialog |
| Case-insensitive lookup | Config option for case-insensitive symbol search (`case_insensitive`) |
| Custom library colors (dircolor) | Color-code library directories in browser |
| PDK library integration | Automatic PDK library detection (SKY130, GF180, IHP130, etc.) |
| Devices library | Built-in standard devices (resistor, capacitor, MOS, BJT, diode, sources, etc.) |
| Component browser on top | Config to keep browser window above canvas |
| File browser depth | Configurable search depth for file browsing |
| File browser extensions | Configurable file extension filters |
| noprint_libs | Exclude specific libraries from hierarchical printing |
| nolist_libs | Exclude specific libraries from hierarchy listing |
| xschem_libs | Exclude specific cells from netlisting |

---

## Properties & Attributes

### Instance Properties

| Feature | Description |
|---------|-------------|
| Edit properties (q key) | Open property editor for selected object |
| Edit with vim (Shift+Q) | Edit properties in external vim editor |
| View properties (Ctrl+Shift+Q) | View properties without editing |
| Edit schematic file (Alt+Q) | Directly edit raw schematic text (dangerous) |
| name attribute | Unique instance identifier (auto-renamed on duplicate) |
| model attribute | Simulator model reference |
| value attribute | Component value |
| Arbitrary parameters | Any key=value pairs (w, l, m, etc.) |
| lock attribute | `lock=true` prevents selection (still editable via double-click) |
| hide attribute | `hide=true` shows only bounding box |
| hide_texts attribute | Hide all text annotations on instance |
| text_size_N / text_layer_N | Per-instance text size and color override |
| attach attribute | Group objects together by name reference |
| url attribute | Link to documentation/web page (opened with Ctrl+click or Shift+H) |
| tclcommand attribute | Execute TCL on Ctrl+click |
| program attribute | Specify viewer application for url |

### Global/Schematic Properties

| Feature | Description |
|---------|-------------|
| Schematic global property (q with nothing selected) | Edit global properties of .sch/.sym |
| SPICE global property (S record) | Global SPICE netlist directives |
| Verilog global property (V record) | Global Verilog code |
| VHDL global property (E record) | Global VHDL code |
| tEDAx global property (K record) | Global tEDAx data |
| Spectre global property (F record) | Global Spectre directives |
| Generic global property (G record) | General-purpose global data |
| Header/license metadata (Shift+B) | Edit schematic header and license info |

### Parametric Design

| Feature | Description |
|---------|-------------|
| Parameter passing | Subcircuit parameters passed via format string tokens |
| Parameter defaults (template) | Default values defined in symbol template |
| Instance parameter override | Instance values override template defaults |
| Mathematical expressions | Expressions in curly braces: `{OFFSET + AMPLITUDE/2*(tanh(...))}` |
| TCL evaluation (tcleval) | `tcleval(...)` wraps TCL interpreter calls in any attribute |
| @ token substitution | `@parameter` expands to instance attribute values |
| % token substitution | `%parameter` with fallback to literal if undefined |
| expr() evaluation | `expr(...)` evaluates math expressions with substituted values |
| Conditional expressions | `tcleval([if {$VAR == 1} {return val1} else {return val2}])` |

### Netlist Token System

| Feature | Description |
|---------|-------------|
| @name | Instance reference designator |
| @pinlist | All nets in pin creation order |
| @@pin_name | Net connected to specific named pin |
| @#n | Net at pin index n |
| @#n:pin_attribute | Attribute of pin at index n |
| @#pin_name:net_name | Net attached to named pin |
| @#n:resolved_net | Full hierarchical net name |
| @model | Model attribute value |
| @symname | Symbol filename |
| @symref | Symbol reference |
| @path | Full hierarchy path |
| @schname | Containing schematic name |
| @topschname | Top-level schematic name |
| @spice_get_voltage | Backannotated voltage |
| @spice_get_current | Backannotated current |
| @spice_get_modelparam | Backannotated model parameter |
| @prop_ptr | Entire property string |
| @sch_last_modified | Schematic modification timestamp |
| @sym_last_modified | Symbol modification timestamp |
| @time_last_modified | General modification timestamp |

---

## Simulation

### Netlist Generation

| Feature | Description |
|---------|-------------|
| SPICE netlist (n key) | Generate hierarchical SPICE netlist |
| Verilog netlist | Generate hierarchical Verilog netlist |
| VHDL netlist | Generate hierarchical VHDL netlist |
| tEDAx netlist | Generate tEDAx netlist for PCB tools |
| Spectre netlist | Generate Cadence Spectre format netlist |
| Top-level only netlist (Shift+N) | Generate netlist for top level only |
| Flat netlist (: key / --flat_netlist) | Generate flattened netlist (SPICE only) |
| Toggle netlist format (Ctrl+Shift+V) | Cycle through spice/vhdl/verilog/spectre |
| Show netlist (Shift+A) | Toggle display of generated netlist |
| Netlist directory | Configurable output path (`netlist_dir`) |
| Local netlist directory | Place netlists in `./simulation/` relative to schematic |
| Netlist filename override (-N) | Custom top-level netlist filename |
| Post-process command | Run command after netlist generation (`netlist_postprocess`) |
| LVS netlist mode | Generate netlist suitable for LVS comparison |
| lvs_format attribute | Separate format string for LVS netlisting |
| Ignore attributes | Per-format ignore (spice_ignore, vhdl_ignore, verilog_ignore, etc.) |
| Short attribute | `spice_ignore=short` shorts all pins together |
| Stop attributes | Prevent descent into subcircuit (spice_stop, vhdl_stop, etc.) |
| Primitive attributes | Only dump format string, ignore schematic entirely |
| only_toplevel | Netlist commands only at top hierarchy level |
| Bus replacement char | Replace [] with custom characters in netlist (`bus_replacement_char`) |
| Verilog 2001 mode | Generate Verilog-2001 compliant output |
| Verilog bitblast | Group contiguous bus bits in Verilog |

### Simulator Integration

| Feature | Description |
|---------|-------------|
| Run simulation (s key) | Launch configured simulator with confirmation |
| Configure simulators | Simulation->Configure Simulators and tools dialog |
| ngspice integration | Native support for ngspice (default SPICE simulator) |
| XSPICE integration | Correct netlist generation for XSPICE event-driven subsystem |
| Xyce support | Sandia Xyce parallel SPICE simulator |
| HSPICE support | Commercial SPICE simulator |
| Icarus Verilog | Default open-source Verilog simulator |
| GHDL | Default open-source VHDL simulator |
| Cadence NCSIM | Commercial Verilog/VHDL simulator support |
| Mentor Modelsim | Commercial HDL simulator support |
| Spectre/VACASK | Spectre-compatible simulator support |
| Simulator command config | Configurable command with $N (netlist path), $n (circuit name) |
| Saved in simrc | Simulator settings stored in ~/.xschem/simrc |
| Edit netlist before sim | Simulation->Edit Netlist option |
| Simulation directives on schematic | devices/code.sym and devices/code_shown.sym for embedded commands |
| .include/.lib management | Include model files and libraries via schematic symbols |
| netlist.sym / netlist_not_shown.sym | Containers for SPICE models/supplementary data |

### Waveform Viewing (Built-in)

| Feature | Description |
|---------|-------------|
| Embedded waveform graphs | Add graphs directly on schematic canvas |
| Add waveform graph | Simulation->Graph->Add waveform graph |
| Multiple graphs per schematic | Each graph independently configurable |
| Load raw files | Load .raw simulation output (op, dc, ac, tran, noise, sp) |
| Multiple raw files per graph | Each graph can reference different .raw file |
| Signal addition (Alt+G) | Send highlighted nets to graph or external viewer |
| Cursor A/B | Horizontal measurement cursors showing delta values |
| Cursor a/b (vertical) | Vertical cursors showing sweep variable differences |
| Live cursor backannotation | Cursor b position updates schematic annotations in real-time |
| Full zoom in graph (f) | Zoom graph to show all data |
| Graph pan/scroll | Arrow keys or left-mouse drag inside graph |
| Graph zoom | Right-mouse drag in X or Y direction |
| Digital signal display | Digital/logic level waveform viewing |
| Bus grouping | Group digital signals as buses with configurable thresholds |
| Wave color customization | Double-click to change signal color |
| Bold formatting | Right-click signals for bold display |
| Signal search/filter | Regular expression pattern filtering |
| RPN expression engine | Reverse Polish Notation calculated waveforms |
| Math operations | +, -, *, /, comparison, exponentiation, max, min |
| Trig/hyperbolic functions | sin, cos, tan, sinh, cosh, tanh, asin, acos, atan |
| Calculus | Derivative, integration |
| Conditional expressions | Three-argument conditional (?) |
| X/Y axis labels | Configurable axis annotations |
| Minor ticks | Adjustable tick mark density |
| Graph line width | Configurable (`graph_linewidth_mult`) |
| Hide empty graphs | Config to hide graphs without loaded data |
| Graph Ctrl key requirement | Config to require Ctrl for graph mouse operations |
| Graph configs saved with schematic | All graph state persists in .sch file |

### Waveform Viewing (External)

| Feature | Description |
|---------|-------------|
| GAW integration | Send nets to GAW viewer (Alt+G or menu) |
| GAW TCP connection | Configurable socket address (`gaw_tcp_address`) |
| BeSpice (bspwave) | Commercial viewer integration (bespice_listen_port) |
| ngspice internal plot | Use ngspice's built-in plotting |
| GTKWave | Supported for digital waveform display |
| Xplot | Create xplot file for ngspice (Ctrl+Shift+X) |
| Custom viewer config | Configure any viewer via Simulation->Configure tools |

### Backannotation

| Feature | Description |
|---------|-------------|
| Operating point annotation | Simulation->Annotate Operating Point into schematic |
| ngspice_probe.sym | Voltage viewer attached to nets |
| ngspice_get_value.sym | Display any raw file variable near component |
| ngspice_get_expr.sym | TCL expressions combining simulation data |
| Engineering notation | `[to_eng ...]` for automatic SI prefix formatting |
| Dynamic pull method | ngprobe elements fetch data dynamically per instance |
| Device parameters | Access @m.device[param] (vth, gm, id, etc.) |
| Current display | Through ammeters and voltage source current |
| Power calculation | V * I expressions for power annotation |
| launcher.sym | Ctrl+Click trigger for annotation commands |
| .option savecurrents | Required for current backannotation |
| .save directives | Control what data is saved for backannotation |

---

## File Formats & I/O

### Native Format

| Feature | Description |
|---------|-------------|
| .sch files | Schematic files (ASCII text) |
| .sym files | Symbol files (ASCII text, same format as .sch) |
| Version string (v record) | File version tracking (current: 1.3) |
| Text-based/diff-friendly | Plain ASCII format suitable for version control |
| Object type tags | Single character identifies each record type (L, B, P, A, T, N, C) |
| Symbol embedding ([/]) | Embed symbol definitions inside schematic for portability |

### Import

| Feature | Description |
|---------|-------------|
| gschem/Lepton import | gschemtoxschem.awk converter for GEDA schematics |
| Pre-translated geda library | All geda symbols available pre-converted |
| translate2coralEDA | Third-party multi-format converter |
| Merge file (b key) | Import/merge another schematic into current |

### Export

| Feature | Description |
|---------|-------------|
| PDF export (--pdf / Shift+*) | Print/export to PDF |
| SVG export (--svg / Alt+Shift+*) | Export as SVG vector graphics |
| PNG export (--png / Ctrl+Shift+*) | Export as PNG raster image |
| PostScript export (-p / Shift+*) | Export as PostScript |
| XPM export | Export as XPM pixmap |
| Color PostScript (--color_ps) | Enable color in PS/PDF output |
| Plot file destination (--plotfile) | Specify output file for exports |
| Page size (A3/A4/custom) | Configurable paper size (`ps_paper_size`, `--a3page`) |
| ps2pdf conversion | Configurable PS-to-PDF tool (`to_pdf` variable) |
| XPM-to-PNG conversion | Configurable tool (`to_png` variable) |
| Screen grab (Print Screen) | Capture screen area to image |

### Netlist Export

| Feature | Description |
|---------|-------------|
| SPICE (.spice) | Standard SPICE netlist |
| Verilog (.v) | Verilog HDL netlist |
| VHDL (.vhdl) | VHDL netlist |
| tEDAx | PCB interchange format for pcb-rnd |
| Spectre | Cadence Spectre format |
| Flat SPICE | Flattened (non-hierarchical) netlist |

### LVS Support

| Feature | Description |
|---------|-------------|
| LVS netlist generation | "LVS netlist: Top level is a .subckt" option |
| lvs_format attribute | Separate netlist format for LVS |
| lvs_ignore attribute | Conditionally ignore components in LVS mode |
| Netgen integration | Workflow with netgen for schematic vs. layout comparison |
| Magic layout tool | Standard pairing with Magic for layout and extraction |

---

## Selection & Search

| Feature | Description |
|---------|-------------|
| Click select (left button) | Select single object, clearing previous selection |
| Shift+click select | Add to existing selection |
| Box select (left drag) | Select objects by rectangular area |
| Shift+box select | Add area selection without clearing |
| Ctrl+drag select | Select for subsequent stretch operation |
| Select all (Ctrl+A) | Select all objects in schematic |
| Unselect object (d key / Alt+left) | Deselect specific object under mouse |
| Unselect by area (Shift+D / Alt+left drag) | Deselect objects in rectangular area |
| Unselect attached floaters (Ctrl+U) | Unselect attached objects |
| Find/select by substring (Ctrl+F) | Find components by name/attribute substring or regexp |
| Select connected wires (Shift+Right button) | Select all electrically connected wires/labels/pins |
| Select connected to junction (Ctrl+Right button) | Select connected wires stopping at junctions |
| Select by net (Alt+K) | Select all nets attached to selected wire/label/pin |
| Highlight selected nets (k key) | Highlight nets with different colors |
| Unhighlight all (Shift+K) | Clear all net highlights |
| Unhighlight selected (Ctrl+K) | Clear only selected highlights |
| Highlight through hierarchy | Follow highlighted nets into child/parent schematics |
| Propagate highlight (Ctrl+Shift+K) | Highlight nets passing through elements with 'propag' property |
| Highlight duplicates (# key) | Find components with duplicated reference designators |
| Rename duplicates (Ctrl+#) | Auto-rename duplicated reference designators |
| Highlight discrepancies (Shift+X) | Show mismatches between object ports and attached nets |
| View only probes (5 key) | Hide everything except highlighted probe nets |

---

## Display & Rendering

### Colors & Layers

| Feature | Description |
|---------|-------------|
| 22 default layers | Configurable at compile time (cadlayers variable) |
| Layer 0 - Background | Background color |
| Layer 1 - Wire | Net/wire color |
| Layer 2 - Selection/Grid | Selection highlight and grid color |
| Layer 3 - Text | Text annotation color |
| Layer 4 - Symbol drawing | Symbol graphic primitives |
| Layer 5 - Pin | Pin connection points |
| Layers 6-21 | General purpose user layers |
| Custom color palettes | `light_colors` and `dark_colors` arrays in xschemrc |
| Per-layer fill styles | Different fill patterns per layer |
| Layer visibility toggle | Enable/disable individual layers (`enable_layer()`) |
| Show all layers (Shift+<) | Make all layers visible |
| Show only current layer (Shift+>) | Show only selected layer set |
| Set current layer (Ctrl+0-9) | Quick layer selection |
| Line width control | Fixed width or auto-scaling |
| Increase line width (Ctrl++) | Make lines thicker |
| Decrease line width (Ctrl+-) | Make lines thinner |
| Set line width (Alt+-) | Set specific line width value |
| Toggle line width change (_ key) | Toggle dynamic line width |
| Fill rectangles toggle (Ctrl+=) | Toggle filled rectangle display |

### Text Display

| Feature | Description |
|---------|-------------|
| Font specification | Per-text font family selection |
| Text size | Configurable per text object |
| Bold/italic styles | Font weight and slant options |
| Horizontal centering (hcenter=true) | Center text horizontally |
| Vertical centering (vcenter=true) | Center text vertically |
| Hide text (hide=true) | Hide specific text objects |
| Show hidden texts | Config to reveal hidden text (`show_hidden_texts`) |
| Toggle show text in symbol (Ctrl+B) | Show/hide text within symbol views |
| Cairo font scaling | Configurable font scale factor (`cairo_font_scale`) |
| Cairo font line spacing | Adjustable line spacing (`cairo_font_line_spacing`) |
| Cairo vertical correction | Text vertical positioning (`cairo_vert_correct`) |

### Rendering Options

| Feature | Description |
|---------|-------------|
| X11 framebuffer rendering | Software rendering on fbdev (fastest/most precise) |
| XCopyArea toggle (Ctrl+$) | Toggle between XCopyArea and drawing primitives |
| Pixmap saving toggle ($) | Toggle pixmap-based saving |
| Show only bounding boxes (Alt+B) | Toggle showing symbol details vs. bounding box only |
| Dash patterns (dash=n) | Configurable dashed lines for graphical primitives |
| Fill modes | true (patterned), false (no fill), full (solid fill) |
| Anti-aliased rendering | Via Cairo graphics when available |
| Tk scaling for HiDPI | Widget/font scaling for high-DPI displays (`tk_scaling`) |

---

## UI & Interface

### Menu Bar Structure

| Menu | Contents |
|------|----------|
| File | New, Open, Save, Save As, Close, Recent files, Merge, Export (PDF/SVG/PNG/PS), Quit |
| Edit | Undo, Redo, Copy, Cut, Paste, Delete, Select All, Find, Properties, Move, Rotate, Flip |
| View | Zoom (in/out/fit/box/selected), Toggle colorscheme, Toggle grid, Show layers, Fullscreen |
| Options | Netlist format (SPICE/Verilog/VHDL/tEDAx/Spectre), LVS mode, Snap settings, Various toggles |
| Simulation | Netlist, Simulate, Configure simulators, Edit netlist, Annotate OP, Waves, Graph management |
| Hilight | Highlight nets, Unhighlight, Send to viewer, Highlight duplicates, Rename duplicates |
| Tools | Various utility operations |

### Toolbar

| Feature | Description |
|---------|-------------|
| Toolbar visibility | Configurable show/hide (`toolbar_visible`) |
| Netlist button | One-click netlist generation |
| Simulate button | Launch simulation |
| Waves button | Open waveform viewer |
| Layer selector | Quick layer/color selection for drawing |

### Keyboard Shortcuts (Complete)

See the dedicated keybindings section above - 100+ keybindings covering all operations.

### Mouse Bindings (Complete)

| Action | Function |
|--------|----------|
| Left click | Select (clear previous) |
| Shift+Left click | Add to selection |
| Ctrl+Left click | Open URL / execute tclcommand |
| Left drag | Area select |
| Ctrl+Left drag | Stretch select |
| Shift+Left drag | Add area select |
| Shift+Ctrl+Left drag | Add stretch select |
| Alt+Left click | Unselect object |
| Alt+Left drag | Unselect by area |
| Left double-click | Edit attributes / terminate polygon |
| Middle drag | Pan view |
| Right drag | Zoom to area |
| Right click release | Context menu |
| Shift+Right click | Select all connected wires |
| Ctrl+Right click | Select connected to junction |
| Alt+Right click | Cut wire at position |
| Mouse wheel | Zoom in/out |

### Status Bar & Information

| Feature | Description |
|---------|-------------|
| Coordinate display | Show mouse position in schematic coordinates |
| Info window | Display ERC error messages (`show_infowindow`) |
| Show info after netlist | Auto-display errors after netlist generation |
| TCL console (= key) | Interactive TCL command prompt |
| Help (? key) | Display keybinding help |
| Keybinding cheatsheet (/ key) | Fullscreen image of all bindkeys |

### Tabbed & Multi-Window

| Feature | Description |
|---------|-------------|
| Tabbed interface | Multiple schematics in tabs (`tabbed_interface`) |
| New tab (Ctrl+T) | Open new tab/window |
| Close tab (Ctrl+W) | Close current schematic |
| Next tab (Ctrl+Right) | Switch to next tab |
| Previous tab (Ctrl+Left) | Switch to previous tab |
| Tab navigation (Shift+Tab, Ctrl+Tab) | Additional tab switching shortcuts |
| Open in new tab (Alt+O) | Open file in new tab/window |
| Multiple XSchem instances | Each window is separate process (crash isolation) |
| Clipboard across hierarchy | Copy/paste works between hierarchy levels and windows |
| Load last closed (Ctrl+Shift+T) | Reopen most recently closed file |
| Load most recent (Ctrl+Shift+O) | Load most recent schematic |
| Autofocus on mouseover | Config to focus window on mouse entry (`autofocus_mainwindow`) |

---

## Tcl Scripting

### Interpreter

| Feature | Description |
|---------|-------------|
| Embedded Tcl/Tk | Full Tcl interpreter built into XSchem |
| Interactive console (= key) | Type TCL commands directly |
| xschem command | Primary extension command with many subcommands |
| Standard Tcl/Tk | All standard Tcl/Tk libraries available |

### Script Execution

| Feature | Description |
|---------|-------------|
| --tcl flag | Execute TCL after xschemrc, before GUI |
| --preinit flag | Execute TCL before xschemrc (internal testing) |
| --command flag | Execute TCL after full startup (all xschem commands available) |
| --script flag | Source a TCL file after startup |
| tcl_files variable | Auto-load list of scripts at startup |
| postinit_commands | TCL code executed during initialization |
| user_startup_commands | UI code hooks at startup |
| source command | Load and execute .tcl files interactively |
| Batch processing | Run XSchem headless (-x) with scripts |

### Scriptable Operations

| Feature | Description |
|---------|-------------|
| xschem get | Query internal state (current_name, etc.) |
| xschem setprop | Modify instance properties programmatically |
| xschem netlist | Generate netlist from script |
| xschem simulate | Launch simulation from script |
| All editor commands | Every interactive operation accessible via TCL |
| Custom menu items | Add custom entries to menus via TCL |
| Event handling | Respond to xschem events in scripts |
| Variable access | Read/write xschem internal variables |
| tcleval() in attributes | Inline TCL evaluation in any property |

### Remote Control

| Feature | Description |
|---------|-------------|
| TCP socket interface | Send commands to running XSchem via TCP |
| Default port 2021 | Configurable listen port (`xschem_listen_port`) |
| Multi-instance port negotiation | Automatic port allocation for multiple instances |
| setup_tcp_xschem | Command to negotiate alternative ports |
| netcat compatibility | Send commands via standard netcat utility |
| All xschem commands | Full command access via remote interface |

---

## Configuration

### Configuration Files

| Feature | Description |
|---------|-------------|
| System xschemrc | `/usr/share/xschem/xschemrc` (installation defaults) |
| User xschemrc | `~/.xschem/xschemrc` (user overrides) |
| Project xschemrc | `./xschemrc` (project-specific, highest priority) |
| simrc | `~/.xschem/simrc` (simulator configurations) |
| --rcfile option | Specify custom config file path |
| --no_rcload (-i) | Skip loading xschemrc entirely |
| .spiceinit | ngspice initialization file |

### Key Configuration Variables

| Variable | Description |
|----------|-------------|
| XSCHEM_SHAREDIR | Installation directory |
| XSCHEM_LIBRARY_PATH | Library search paths |
| XSCHEM_START_WINDOW | Initial file to load |
| PDK_ROOT | PDK installation root |
| PDK | PDK variant selection |
| netlist_dir | Netlist output directory |
| local_netlist_dir | Use local simulation/ directory |
| netlist_type | Default netlist format |
| editor | External editor command |
| terminal | Terminal emulator command |
| cadgrid | Grid spacing value |
| cadsnap | Snap spacing value |
| cadlayers | Number of color layers |
| light_colors / dark_colors | Color palette definitions |
| initial_geometry | Window size and position |
| tk_scaling | HiDPI scaling factor |
| toolbar_visible | Show/hide toolbar |
| tabbed_interface | Enable tabbed mode |
| persistent_command | Continue command after placement |
| autotrim_wires | Auto-join/trim wires |
| disable_unique_names | Allow duplicate instance names |
| undo_type | Undo storage (disk/memory) |
| line_width | Default line width |
| change_lw | Allow line width changes |
| color_ps | Color exports |
| bus_replacement_char | Custom bus notation character |
| verilog_2001 | Verilog-2001 mode |
| show_infowindow | Show ERC info window |
| case_insensitive | Case-insensitive symbol lookup |
| zoom_full_center | Center on full zoom |
| big_grid_points | Scale grid points |
| unzoom_nodrift | Prevent zoom drift |
| launcher_default_program | Default URL opener |
| download_url_helper | Web download tool |
| gaw_tcp_address | GAW viewer address |
| bespice_listen_port | BeSpice TCP port |
| xschem_listen_port | XSchem listen port |
| live_cursor2_backannotate | Real-time cursor annotation |
| hide_empty_graphs | Hide empty graph boxes |
| graph_use_ctrl_key | Require Ctrl for graph ops |
| graph_linewidth_mult | Graph line thickness |
| search_schematic | Find schematics in full paths |

### Keybinding Customization

| Feature | Description |
|---------|-------------|
| replace_key() | Override any default keybinding in xschemrc |
| Swap keybindings | Exchange key assignments |
| Custom bindings | Map any key to any xschem command |

---

## Advanced Features

### Parametric & Evaluated Expressions

| Feature | Description |
|---------|-------------|
| Parametric symbols | Symbols with configurable parameters |
| Parameter defaults | Template attribute provides defaults |
| Instance override | Each instance can have unique parameter values |
| Unlimited parameters | Any number/type of parameters supported |
| Math in parameters | Mathematical expressions in curly braces |
| tcleval() | TCL evaluation in any attribute |
| expr() | Mathematical expression evaluation |
| Conditional attributes | Dynamic ignore/include based on conditions |
| SPICE parameter functions | tanh, sin, cos, exp, etc. in behavioral sources |

### Bus & Vector Support

| Feature | Description |
|---------|-------------|
| Bus notation (AAA[3:0]) | Range notation for signal bundles |
| Comma-separated bundles | AAA,BBB,CCC for named signal groups |
| Step notation (AAA[6:0:2]) | Every Nth bit selection |
| Repetition (2*signal) | Prefix/postfix multipliers |
| Grouped repetition (2*(A,B)) | Repeat entire signal groups |
| Dot notation (AAA[3..0]) | Alternative bracket-free syntax |
| Bus taps (bus_tap.sym) | Connect to bus slices by index |
| Thick bus wires | Visual bus/wire distinction |
| Instance vectors (x1[7:0]) | Create arrays of instances |
| Bus expansion in netlist | Proper multi-bit connectivity |

### Power & Global Nets

| Feature | Description |
|---------|-------------|
| vdd.sym / gnd.sym | Power/ground supply symbols (create .GLOBAL) |
| Global attribute | `global=1` on any label makes it global |
| Local supply (global=0) | Override vdd/gnd to be non-global |
| .GLOBAL statement | Automatic generation in SPICE netlist |
| Spectre ground support | `global=ground` for Spectre format |

### Special Symbols

| Feature | Description |
|---------|-------------|
| lab_pin.sym | Net label (by-name connection) |
| lab_wire.sym | Wire-attached label |
| ipin.sym | Input port |
| opin.sym | Output port |
| iopin.sym | Bidirectional port |
| code.sym | Hidden simulation directives container |
| code_shown.sym | Visible simulation directives |
| netlist.sym | SPICE model/include container |
| netlist_not_shown.sym | Hidden netlist data |
| title.sym | Title block with date/author |
| launcher.sym | Clickable command launcher |
| noconn.sym | No-connect indicator |
| corner.sym (PDK) | Process corner selection |

### Testbench Management

| Feature | Description |
|---------|-------------|
| Self-contained testbenches | Store circuit + stimuli + settings in one schematic |
| Simulation directives on schematic | .tran, .ac, .dc analysis setup via code blocks |
| .include/.lib in schematic | Model inclusion via schematic symbols |
| Process corner selection | Corner symbols for PDK variation (tt, ss, sf, fs, ff) |
| Multiple analysis types | Support AC, DC, transient, noise, S-parameter setups |
| Reload launchers | Quick-reload buttons for different analysis types |

### Instance-Based Implementation Selection

| Feature | Description |
|---------|-------------|
| schematic= attribute | Specify alternate schematic for specific instance |
| Per-instance implementation | Different instances of same symbol use different schematics |
| spice_sym_def | Include external netlist for specific instance |
| Parasitic extraction inclusion | Reference extracted netlists per-instance |
| default_schematic=ignore | Prevent descent into default schematic |

### Schematic Comparison

| Feature | Description |
|---------|-------------|
| --diff option | Compare against specified file |
| Visual diff | Grey for elements different in file 1, red for elements only in file 2 |
| Alt+X re-compare | Repeat comparison after changes |
| Netlist-focused diff | Flags attribute differences affecting netlist |
| Instance and net comparison | Compares both component and connectivity differences |

### Logic Simulation (Built-in)

| Feature | Description |
|---------|-------------|
| Set net to 0 (0 key) | Force logic '0' on selected net |
| Set net to 1 (1 key) | Force logic '1' on selected net |
| Set net to X (2 key) | Force unknown state |
| Set net to Z (3 key) | Force high-impedance |
| Toggle net (4 key) | Toggle between 0 and 1 |
| function attribute | Logic function definition for gates |
| Logic operators | AND (&), OR (|), XOR (^), NOT (~) |
| Stack operations | duplicate (d), exchange (x), rotate (r) |
| Mux/tristate | M (mux), m (guarded mux), z (tri-state) |
| Clock specification | clock=0/1/2/3 for clocked elements |
| goto attribute | Route logic values to output pins |

### Object Locking

| Feature | Description |
|---------|-------------|
| lock=true attribute | Prevent selection of object |
| Double-click override | Locked objects still editable via double-click |
| Per-object locking | Lock specific instances or primitives |
| Toggle lock in properties | Enable/disable via property editor |

### Ignore Flags

| Feature | Description |
|---------|-------------|
| Toggle ignore (Shift+T) | Toggle *_ignore flag on selected instances |
| Dynamic ignore | TCL-evaluated conditional ignore |
| spice_ignore | Exclude from SPICE netlist |
| vhdl_ignore | Exclude from VHDL netlist |
| verilog_ignore | Exclude from Verilog netlist |
| tedax_ignore | Exclude from tEDAx netlist |
| spectre_ignore | Exclude from Spectre netlist |

### Printing & Page Setup

| Feature | Description |
|---------|-------------|
| PostScript/PDF print (Shift+*) | Generate print output |
| PNG print (Ctrl+Shift+*) | Raster image export |
| SVG print (Alt+Shift+*) | Vector image export |
| Paper size configuration | Named sizes or custom height/width |
| A3 page support (--a3page) | A3 format PDF export |
| Color/monochrome | Toggle color in exports |
| Hierarchical print | Print all hierarchy levels |

---

## Integration

### PDK Integration

| Feature | Description |
|---------|-------------|
| SKY130 (Google/SkyWater) | Full symbol library and model integration |
| GF180MCU (GlobalFoundries) | Supported via open_pdks |
| IHP SG13G2 (IHP 130nm BiCMOS) | Supported PDK |
| PDK_ROOT auto-detection | Searches standard paths for PDK installation |
| open_pdks workflow | Standard PDK installation via open_pdks |
| Process corner symbols | Quick selection of tt/ss/sf/fs/ff corners |
| TCL path variables | Portable schematics without hardcoded paths |
| .option scale | Support for PDK dimension scaling |

### Layout Tools

| Feature | Description |
|---------|-------------|
| Magic VLSI | Standard layout tool pairing |
| KLayout | Alternative layout editor integration |
| LVS via netgen | Compare schematic netlist with layout extraction |
| Extracted netlist reference | Include parasitic/extracted netlists per-instance |

### PCB Design

| Feature | Description |
|---------|-------------|
| pcb-rnd integration | tEDAx netlist export for PCB layout |
| pinnumber attribute | Map schematic pins to footprint pads |
| CoralEDA ecosystem | Integration with broader open-source EDA toolchain |

### External Tools

| Feature | Description |
|---------|-------------|
| External editor support | Configurable editor for property editing |
| Custom terminal | Configurable terminal emulator |
| Custom URL launcher | Configurable application for opening links |
| Download helper | Configurable web download utility |
| xdg-open integration | Standard desktop file/URL opening |

---

## Command-Line Interface

| Option | Description |
|--------|-------------|
| -h / --help | Display help |
| -v / --version | Show version |
| -b / --detach | Detach from terminal (background mode) |
| -x / --no_x | Headless mode (no GUI) |
| -q / --quit | Exit after completing operations |
| -n / --netlist | Generate netlist |
| -s / --spice | SPICE format |
| -w / --verilog | Verilog format |
| -V / --vhdl | VHDL format |
| -t / --tedax | tEDAx format |
| -y / --symbol | Symbol mode |
| -f / --flat_netlist | Flat SPICE netlist |
| -S / --simulate | Run simulation |
| -W / --waves | Show waveforms |
| -p / --postscript / --pdf | PDF export |
| --png | PNG export |
| --svg | SVG export |
| -c / --color_ps | Color export |
| --plotfile | Export destination |
| --a3page | A3 paper size |
| -o / --netlist_path | Netlist output directory |
| -N / --netlist_filename | Custom netlist filename |
| --tcl | Pre-startup TCL execution |
| --preinit | Early TCL execution |
| --command | Post-startup TCL execution |
| --script | Source TCL file |
| --tcp_port | Set TCP listen port |
| --diff | Compare against file |
| --rcfile | Custom config file |
| -i / --no_rcload | Skip xschemrc |
| -r / --no_readline | Disable tclreadline |
| -z / --rainbow | Rainbow colors |
| -l / --log | Log file |
| -d / --debug | Debug verbosity |
| --pipe | Pipe mode |
| --lastclosed | Reopen last closed |
| --lastopened | Reopen last opened |

---

## Performance Characteristics

| Feature | Description |
|---------|-------------|
| Very low memory footprint | Data purged on hierarchy traversal |
| Fast netlist generation | Optimized for 1M+ transistor designs |
| Efficient rendering | Designed for large schematics |
| Framebuffer rendering | Fastest X11 rendering path |
| Keyboard-first interface | Minimizes mouse movement for speed |
| Cadence-like keybindings | Natural for experienced IC designers |
| Crash isolation | Each window is separate process |

---

## Sources

- [XSchem Official Site](https://xschem.sourceforge.io/)
- [XSchem GitHub Repository](https://github.com/StefanSchippers/xschem)
- [XSchem Manual - Editor Commands](https://xschem.sourceforge.io/stefan/xschem_man/commands.html)
- [XSchem Manual - Graphs/Waveforms](https://xschem.sourceforge.io/stefan/xschem_man/graphs.html)
- [XSchem Manual - Symbol Property Syntax](https://xschem.sourceforge.io/stefan/xschem_man/symbol_property_syntax.html)
- [XSchem Manual - Component Property Syntax](https://xschem.sourceforge.io/stefan/xschem_man/component_property_syntax.html)
- [XSchem Manual - Developer Info/File Format](https://xschem.sourceforge.io/stefan/xschem_man/developer_info.html)
- [XSchem Manual - Netlisting](https://xschem.sourceforge.io/stefan/xschem_man/netlisting.html)
- [XSchem Manual - Simulation](https://xschem.sourceforge.io/stefan/xschem_man/simulation.html)
- [XSchem Manual - Bus/Vector Tutorial](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_busses.html)
- [XSchem Manual - Backannotation Tutorial](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_ngspice_backannotation.html)
- [XSchem Manual - Sky130 Integration](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_xschem_sky130.html)
- [XSchem Manual - Parameters](https://xschem.sourceforge.io/stefan/xschem_man/parameters.html)
- [XSchem Manual - Remote Control](https://xschem.sourceforge.io/stefan/xschem_man/xschem_remote.html)
- [XSchem Manual - FAQ](https://xschem.sourceforge.io/stefan/xschem_man/faq.html)
- [XSchem Manual - Instance-Based Implementation](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_instance_based_implementation.html)
- [XSchem Man Page](https://www.mankier.com/1/xschem)
- [XSchem Sky130 xschemrc](https://github.com/StefanSchippers/xschem_sky130/blob/main/xschemrc)
- [XSchem gschem Translation Tutorial](https://xschem.sourceforge.io/stefan/xschem_man/tutorial_gschemtoxschem.html)
- [XSchem FSiC2022 Presentation](https://xschem.sourceforge.io/stefan/xschem_man/video_tutorials/xschem_fsic2022_presentation.pdf)
- [XSchem SourceForge Reviews](https://sourceforge.net/projects/xschem/reviews/)
