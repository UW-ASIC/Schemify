# Commands TODO

Status of every command defined in `command.zig`, grouped by handler file.

## View.zig (Immediate)

- [x] `zoom_in` / `zoom_out` / `zoom_fit` / `zoom_reset` — delegates to `state.view.*`
- [x] `zoom_fit_selected` — computes bounding box of selected items, fits viewport
- [x] `toggle_fullscreen` — sets flag (no runtime fullscreen API yet, flag only)
- [x] `toggle_colorscheme` — swaps dvui adwaita dark/light theme
- [x] `toggle_fill_rects` / `toggle_text_in_symbols` / `toggle_symbol_details` / `toggle_crosshair` / `toggle_show_netlist` — boolean flag toggles
- [x] `show_all_layers` / `show_only_current_layer` — layer visibility flags
- [x] `increase_line_width` / `decrease_line_width` — clamped increment/decrement
- [x] `snap_halve` / `snap_double` — halve/double snap grid size
- [x] `show_keybinds` / `pan_interactive` / `show_context_menu` — UI state triggers
- [x] `export_svg` — writes SVG via `writeSvgFile`
- [x] `export_png` — writes SVG then shells out to `rsvg-convert`
- [x] `export_pdf` — writes SVG then shells out to `rsvg-convert -f pdf`
- [ ] `screenshot_area` — currently identical to `export_png`; needs rubber-band area selection before export

## Selection.zig (Immediate)

- [x] `select_all` — delegates to `state.selectAll()`
- [x] `select_none` — delegates to `state.selection.clear()`
- [x] `select_connected` — BFS expansion through shared wire endpoints (up to 8 rounds)
- [ ] `select_connected_stop_junctions` — calls `selectConnected` but `stop_at_junctions` param is ignored; needs junction detection (3+ wires meeting at a point)
- [x] `highlight_dup_refdes` — finds instances with duplicate names, selects them
- [x] `rename_dup_refdes` — appends `_N` suffix to duplicate instance names
- [ ] `find_select_dialog` — stub: prints status text; needs FindDialog GUI component to accept a query string and select matching instances/nets
- [x] `highlight_selected_nets` — ORs selected wire indices into `highlighted_nets` bitset
- [x] `unhighlight_selected_nets` — clears selected wire indices from `highlighted_nets`
- [x] `unhighlight_all` — clears entire `highlighted_nets` bitset
- [x] `select_attached_nets` — selects wires whose endpoints touch selected instances

## Clipboard.zig (Immediate)

- [x] `copy_selected` / `clipboard_copy` — copies selected instances+wires to clipboard
- [x] `clipboard_cut` — copies then deletes selected via `edit.handleUndoable(.delete_selected)`
- [x] `clipboard_paste` — pastes clipboard contents with +20,+20 offset, selects pasted items

## Edit.zig (Immediate + Undoable)

### Immediate
- [x] `align_to_grid` — snaps selected instance positions to nearest grid point
- [x] `move_interactive` — sets tool mode to `.move`
- [ ] `move_interactive_stretch` — sets tool to `.move` but does not rubber-band wires; needs stretch logic that keeps connected wires attached during drag
- [ ] `move_interactive_insert` — sets tool to `.move` but does not auto-insert wire segments; needs wire-insertion logic to maintain connectivity
- [x] `escape_mode` — clears wire start, resets tool to `.select`, clears selection

### Undoable
- [x] `rotate_cw` / `rotate_ccw` / `flip_horizontal` / `flip_vertical` — per-instance transform on selected set
- [x] `nudge_left` / `nudge_right` / `nudge_up` / `nudge_down` — 10-unit position offset on selected instances
- [x] `delete_selected` — removes selected instances+wires, snapshots for undo
- [x] `duplicate_selected` — appends copies of selected instances with +20,+20 offset
- [x] `place_device` — places a new instance via `fio.placeSymbol`, pushes inverse
- [x] `delete_device` — removes instance by index, pushes inverse with snapshot
- [x] `move_device` — moves instance by delta, pushes inverse with negated delta
- [x] `set_prop` — sets a property key/value on an instance
- [x] `add_wire` — adds a wire segment via `fio.addWireSeg`, pushes inverse
- [x] `delete_wire` — removes wire by index, pushes inverse with endpoints

## Wire.zig (Immediate)

- [x] `start_wire` / `start_wire_snap` — sets tool to `.wire` mode
- [x] `cancel_wire` — clears wire start, resets tool to `.select`
- [x] `finish_wire` — status message only (actual wire commit is via undoable `add_wire`)
- [x] `toggle_wire_routing` / `toggle_orthogonal_routing` — boolean flag toggles
- [x] `break_wires_at_connections` — splits wires at interior points where other wire endpoints touch
- [x] `join_collapse_wires` — merges collinear wires sharing an endpoint
- [x] `start_line` / `start_rect` / `start_polygon` / `start_arc` / `start_circle` — sets tool mode for shape drawing

## File.zig (Immediate + Undoable)

### Immediate
- [x] `new_tab` — creates a new untitled document
- [x] `close_tab` — closes active tab, remembers path for reopen
- [x] `next_tab` / `prev_tab` — cycles active tab index
- [x] `reopen_last_closed` — pops from closed_tabs stack and opens
- [ ] `save_as_dialog` — stub: shows status text; needs native file dialog or command-bar prompt to pick a save path
- [x] `save_as_symbol_dialog` — saves active document as `.chn_prim`
- [x] `reload_from_disk` — re-opens the active document from its disk path
- [x] `clear_schematic` — clears all instances and wires from active document
- [ ] `merge_file_dialog` — stub: shows status text; needs file dialog to pick a file, then merge its contents into the active document
- [x] `place_text` — sets tool mode to `.text`

### Undoable
- [x] `load_schematic` — delegates to `state.openPath()`
- [x] `save_schematic` — delegates to `state.saveActiveTo()`

## Hierarchy.zig (Immediate)

- [x] `descend_schematic` — opens the selected instance's `.chn` file, pushes hierarchy stack
- [x] `descend_symbol` — opens the selected instance's `.chn_prim` file, pushes hierarchy stack
- [x] `ascend` — pops hierarchy stack, returns to parent document
- [x] `edit_in_new_tab` — opens the selected instance's file in a new tab (no hierarchy stack)
- [x] `make_symbol_from_schematic` — saves active document as `.chn_prim`
- [x] `make_schematic_from_symbol` — saves symbol document as `.chn`
- [x] `make_schem_and_sym` — saves both `.chn` and `.chn_prim`
- [x] `insert_from_library` — opens library browser
- [x] `open_file_explorer` — toggles file explorer panel

## Netlist.zig (Immediate)

- [x] `netlist_hierarchical` / `netlist_flat` / `netlist_top_only` — generates SPICE netlist via `core.Schemify`, writes `.sp` file, caches in `state.last_netlist`
- [x] `toggle_flat_netlist` — boolean flag toggle

## Sim.zig (Immediate + Undoable)

### Immediate
- [x] `open_waveform_viewer` — spawns `gtkwave` with the expected `.raw` output path

### Undoable
- [ ] `run_sim` — calls `fio.createNetlist()` + `fio.runSpiceSim()`; the SPICE backend (ngspice/Xyce bridge via SpiceIF) is not yet wired up, so this will fail at runtime until SpiceIF integration is complete

## Props.zig (Immediate)

- [ ] `edit_properties` — stub: shows status text; needs PropsDialog GUI wired to selected instance's property list for editing
- [ ] `view_properties` — stub: shows status text; needs read-only PropsDialog GUI
- [ ] `edit_schematic_metadata` — stub: shows status text; needs dialog/prompt for schematic-level metadata (name, author, etc.); currently only via CLI `:rename`

## Plugin.zig (Immediate)

- [x] `plugins_refresh` — sets `plugin_refresh_requested` flag
- [ ] `plugin_command` — logs the tag but does not dispatch to the plugin runtime; needs to forward tag+payload to the appropriate plugin via `runtime.dispatchEvent()`

## Undo.zig (Immediate + History)

- [x] `undo` — pops inverse from history, applies it via `applyInverse()`
- [ ] `redo` — stub: shows status text; History only stores inverses, not forward commands; needs a redo stack that stores the original `Undoable` alongside each inverse

---

## Summary

| Category | Implemented | Partially done | Not implemented |
|----------|-------------|----------------|-----------------|
| View     | 23          | 0              | 1 (screenshot_area) |
| Selection| 8           | 1 (select_connected_stop_junctions) | 1 (find_select_dialog) |
| Clipboard| 4           | 0              | 0               |
| Edit     | 15          | 2 (stretch/insert move) | 0      |
| Wire     | 13          | 0              | 0               |
| File     | 10          | 0              | 2 (save_as_dialog, merge_file_dialog) |
| Hierarchy| 9           | 0              | 0               |
| Netlist  | 4           | 0              | 0               |
| Sim      | 1           | 1 (run_sim)    | 0               |
| Props    | 0           | 0              | 3               |
| Plugin   | 1           | 0              | 1 (plugin_command) |
| Undo     | 1           | 0              | 1 (redo)        |
| **Total**| **89**      | **4**          | **9**           |
