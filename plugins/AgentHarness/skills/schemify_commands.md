# Schemify Command Reference

All commands can be issued via the AgentHarness JSON-RPC socket:
```json
{"method": "command", "params": {"text": "<command>"}}
```

Commands use the same syntax as the Schemify vim bar (`:command`).

## No-Argument Commands

### View / UI (Immediate — not undoable)
- `zoom_in`, `zoom_out`, `zoom_fit`, `zoom_reset`, `zoom_fit_selected`
- `toggle_fullscreen`, `toggle_colorscheme`, `toggle_grid`, `toggle_crosshair`
- `toggle_fill_rects`, `toggle_text_in_symbols`, `toggle_symbol_details`
- `show_all_layers`, `show_only_current_layer`
- `increase_line_width`, `decrease_line_width`
- `snap_halve`, `snap_double`

### File / Tab
- `file_new`, `file_open`, `file_save`, `file_save_as`, `file_save_all`
- `new_tab`, `close_tab`, `next_tab`, `prev_tab`, `reopen_closed_tab`
- `reload_from_disk`

### Selection
- `select_all`, `select_none`, `invert_selection`
- `highlight_selected_nets`, `unhighlight_all`

### Clipboard
- `clipboard_copy`, `clipboard_cut`, `clipboard_paste`

### Modes / Tools
- `escape_mode`, `start_wire`
- `tool_select`, `tool_move`, `tool_pan`
- `tool_line`, `tool_rect`, `tool_polygon`, `tool_arc`, `tool_circle`, `tool_text`

### Hierarchy
- `descend_schematic`, `descend_symbol`, `ascend`, `edit_in_new_tab`
- `insert_from_library`, `open_file_explorer`

### Export
- `export_pdf`, `export_png`, `export_svg`, `export_netlist`

### Netlist
- `netlist_hierarchical`, `netlist_top_only`, `netlist_flat`

### Undo / Redo
- `undo`, `redo`

### Schematic Mutations (Undoable)
- `delete_selected`, `duplicate_selected`
- `rotate_cw`, `rotate_ccw`, `flip_horizontal`, `flip_vertical`
- `nudge_left`, `nudge_right`, `nudge_up`, `nudge_down`
- `align_to_grid`

## Commands with Arguments

### place (Undoable)
```
place <symbol> <name> <x> <y>
```
Place a device instance. Symbol is a primitive kind name or a path.
```
place nmos4 M1 100 200
place resistor R1 300 -100
place vsource V1 0 0
```

### add-wire (Undoable)
```
add-wire <x0> <y0> <x1> <y1> [net_name]
```
Add a wire segment between two points, optionally naming the net.
```
add-wire 0 0 100 0 VDD
add-wire 100 200 100 300
```

### delete-instance / delete-wire (Undoable)
```
delete-instance <idx>
delete-wire <idx>
```

### move-instance / move-wire (Undoable)
```
move-instance <idx> <dx> <dy>
move-wire <idx> <dx> <dy>
```

### set-prop (Undoable)
```
set-prop <idx> <key> <value>
```
Set an instance property (W, L, nf, model, value, etc.).
```
set-prop 0 W 10u
set-prop 0 L 180n
set-prop 1 value 10k
```

### rename / rename-net (Undoable)
```
rename <idx> <new_name>
rename-net <wire_idx> <new_name>
```

### set-spice-code (Undoable)
```
set-spice-code <code>
```

### sim (Undoable)
```
sim [ngspice|xyce|vacask]
```

### insert (Immediate)
```
insert <primitive_kind>
```
Inserts a primitive into placement mode. Kinds:
`nmos`, `pmos`, `nmos3`, `pmos3`, `resistor`, `capacitor`, `inductor`,
`diode`, `zener`, `npn`, `pnp`, `njfet`, `pjfet`, `vsource`, `isource`,
`gnd`, `vdd`, `input_pin`, `output_pin`, `inout_pin`, `lab_pin`,
`probe`, `ammeter`, `vcvs`, `vccs`, `ccvs`, `cccs`, `tline`,
`vswitch`, `iswitch`, `generic`

### plugin (Immediate)
```
plugin <tag> [payload]
```
Send a command to a named plugin. Tag is the plugin's vim command name.
```
plugin ccreator export
plugin ccreator import /path/to/generator.py
plugin ccreator template IdealADC
plugin spiceimport /path/to/netlist.sp
plugin pdkswitch sky130A gf180mcuA
plugin gmidopt
```

## Meta Commands
- `save` / `w` — save active document
- `saveas <path>` / `w! <path>` — save to new path
- `open <path>` / `e <path>` — open file
- `quit` / `q` — exit
- `list-instances` / `li` — print instance table
- `list-wires` / `lw` — print wire table
- `info` — print document info
- `print-netlist` / `nl` — print SPICE netlist
- `commands` — list all commands
- `select-instance <idx>` / `si` — select instance by index
- `select-wire <idx>` / `sw` — select wire by index
- `snap <value>` — set snap grid size

## Short Aliases
| Alias | Command |
|-------|---------|
| `rotcw` | `rotate_cw` |
| `rotccw` | `rotate_ccw` |
| `fliph` | `flip_horizontal` |
| `flipv` | `flip_vertical` |
| `zoomin` | `zoom_in` |
| `zoomfit` | `zoom_fit` |
| `delete` / `del` | `delete_selected` |
| `dup` | `duplicate_selected` |
| `wire` | `start_wire` |
| `netlist` | `netlist_hierarchical` |
| `props` | `edit_properties` |
| `find` | `find_select_dialog` |
| `library` | `insert_from_library` |
| `new` | `file_new` |
