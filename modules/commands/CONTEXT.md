# commands

Command system for the schematic editor. Every user action — keypress, menu click, CLI input, plugin call — is expressed as a `Command` value, queued, and dispatched to a handler. Separates intent from execution: the GUI, CLI, and plugins all produce the same `Command` values.

## Public API

Exported from `lib.zig`:

| Symbol | Type | Description |
|--------|------|-------------|
| `Command` | `union(enum) { immediate, undoable }` | Top-level command envelope |
| `Immediate` | `union(enum)` — 89 variants | View/UI/tool commands; never enter undo history |
| `Undoable` | `union(enum)` — 23 variants | Schematic mutations; enter undo ring when invertible |
| `PrimitiveKind` | `enum` — 27 values | Insertable component types; has `kindName()` and `prefix()` |
| `PlaceDevice` | `struct { sym_path, name, x, y }` | Payload for `place_device` |
| `AddWire` | `struct { x0, y0, x1, y1, net_name? }` | Payload for `add_wire` |
| `SetInstanceProp` | `struct { idx, key, val }` | Payload for `set_instance_prop` |
| `PluginMutation` | `struct { tag, payload? }` | Payload for `plugin_mutation` |
| `RunImport` | `struct { path }` | Payload for `run_import` |
| `CommandQueue` | struct wrapping `RingBuffer(Command, 64)` | Fixed-capacity FIFO; `push(alloc, cmd)`, `pop()`, `isEmpty()` |
| `dispatch(cmd, state)` | fn | Route command to handler; `state` is duck-typed (`anytype`) |
| `parser.parse(line)` | fn → `Result` | Text line to command/meta/error; supports underscore, kebab-case, aliases, `:` prefix |
| `parser.tryTagLookup(name)` | fn → `?Command` | Resolve a union tag name to a `Command` |
| `parser.printCommandList(file)` | fn | Emit CLI help text to a writer |
| `handlers.History` | struct — ring buffer, cap 64 | Undo/redo history storage |
| `handlers.invertCommand(cmd)` | fn → `?Undoable` | Compute inverse for simple commands; returns null for non-invertible |

## Command Variant Inventory

**Immediate — 89 variants** (86 void, 3 with payloads)

| Category | Count | Variants |
|----------|-------|----------|
| View | 22 | zoom_in/out/fit/reset/fit_selected, toggle_fullscreen/colorscheme/fill_rects/text_in_symbols/symbol_details/crosshair/show_netlist/grid/orthogonal_routing, show_all_layers, show_only_current_layer, increase/decrease_line_width, snap_halve/double, show_keybinds, pan_interactive, show_context_menu |
| File/Tab | 11 | file_new/open/save/save_as/save_all, new_tab, close_tab, next/prev_tab, reopen_closed_tab, reload_from_disk |
| Selection | 4 | select_all/none, invert_selection, find_select_dialog |
| Clipboard | 3 | clipboard_copy/cut/paste |
| Mode/Tool | 12 | escape_mode, start_wire, tool_select/move/pan/line/rect/polygon/arc/circle/text, insert_primitive(PrimitiveKind) |
| Dialogs | 7 | open_find_dialog/props_dialog/spice_code_dialog/marketplace/new_prim_dialog/import_project, edit_properties |
| Plugin | 2 | plugins_refresh, plugin_command{tag, payload?} |
| Undo/Redo | 2 | undo, redo |
| Net | 5 | highlight_selected_nets, unhighlight_all, netlist_hierarchical/top_only/flat |
| Hierarchy | 4 | descend_schematic/symbol, ascend, edit_in_new_tab |
| Browser/Nav | 2 | open_file_explorer, insert_from_library |
| Export | 4 | export_pdf/png/svg/netlist |
| Print | 1 | print_schematic |
| Config | 3 | open_preferences, reload_config, clear_sim_cache |
| Stubs | 3 | select_attached_nets, make_symbol_from_schematic, make_schematic_from_symbol |
| Waveform | 1 | open_waveform_viewer |
| Import | 1 | run_import(RunImport) |
| Optimizer | 1 | run_optimize |

**Undoable — 23 variants** (11 void, 12 with payloads)

| Category | Count | Variants |
|----------|-------|----------|
| Selection ops | 2 | delete_selected, duplicate_selected |
| Transform | 9 | rotate_cw/ccw, flip_horizontal/vertical, nudge_left/right/up/down, align_to_grid |
| Placement | 2 | place_device(PlaceDevice), add_wire(AddWire) |
| Deletion | 2 | delete_instance(DeleteInstance), delete_wire(DeleteWire) |
| Move | 2 | move_instance(MoveInstance), move_wire(MoveWire) |
| Properties | 4 | set_instance_prop(SetInstanceProp), rename_instance(RenameInstance), rename_net(RenameNet), set_spice_code(SetSpiceCode) |
| Simulation | 1 | run_sim(RunSim) |
| Plugin | 1 | plugin_mutation(PluginMutation) |

## Internal Structure

| File | Lines | Purpose |
|------|-------|---------|
| `lib.zig` | 19 | Re-exports: Command, Immediate, Undoable, payloads, CommandQueue, dispatch, handlers, parser |
| `types.zig` | 289 | All type definitions: Command, Immediate (89), Undoable (23), PrimitiveKind (27), 10 payload structs |
| `Dispatch.zig` | 197 | `dispatch()` — exhaustive switch routing Immediate and Undoable to handlers; undo recording before Undoable dispatch |
| `Queue.zig` | 45 | `CommandQueue` — `RingBuffer(Command, 64)` wrapper; 2 tests |
| `parser.zig` | 632 | Text parser: `parse()`, alias map (62 entries), meta map (20 entries), 13 arg parsers, `printCommandList()`, 8 tests |
| `handlers/lib.zig` | 85 | Hub: re-exports all handler fns; defines shared `Error` set; imports 15 handler modules |
| `handlers/View.zig` | 398 | Zoom, pan, toggle flags, SVG export (full renderer with primitives, junctions, arcs) |
| `handlers/Edit.zig` | 322 | Core mutations: rotate, flip, nudge, align, delete, duplicate, place, wire, move, properties, rename |
| `handlers/Sim.zig` | 325 | Run simulation (Python/PySpice), generate analysis template, regenerate auto-section, waveform viewer launch |
| `handlers/Hierarchy.zig` | 249 | Descend/ascend hierarchy, edit in new tab, make_symbol_from_schematic, make_schematic_from_symbol |
| `handlers/Selection.zig` | 96 | Select all/none/invert, highlight nets, select attached nets |
| `handlers/Clipboard.zig` | 88 | Copy/cut/paste instances and wires with offset |
| `handlers/File.zig` | 85 | New/open/save/close/next/prev tab, reload from disk |
| `handlers/Wire.zig` | 31 | Wire mode start, escape mode, tool switching |
| `handlers/Dialog.zig` | 51 | Open find/props/spice-code/marketplace/new-prim/import dialogs; smart single vs multi-props detection |
| `handlers/Config.zig` | 42 | Open preferences, reload config, clear sim cache |
| `handlers/Primitive.zig` | 27 | Insert primitive at cursor with auto-generated name |
| `handlers/Undo.zig` | 79 | History ring buffer (cap 64), invertCommand(), handleUndo/handleRedo |
| `handlers/Netlist.zig` | 54 | Generate netlist via fio.createNetlist(), cache in state |
| `handlers/Import.zig` | 59 | Detect format from file extension, populate import dialog state |
| `handlers/Optimize.zig` | 12 | Open optimizer dialog |

## Dependencies

| Dependency | Used by | For |
|------------|---------|-----|
| `schematic` | View.zig, Edit.zig, Hierarchy.zig | Device kinds, primitives, instances, wires, SymData |
| `simulation` | Sim.zig, Netlist.zig | `Netlist.emitPySpice()`, `results.SimError` |
| `utility` | View.zig, Sim.zig, Hierarchy.zig, Import.zig, Config.zig | `platform.fs`, `RingBuffer` |

No dependency on `gui`, `plugins`, or `settings`. The module communicates with GUI state purely through duck-typed `state: anytype` — handlers read/write fields on `state` without importing the type.

## Gaps

### Missing Features

- **Non-invertible undo.** Only 10 of 23 Undoable variants are invertible (rotate, flip, nudge, move). Delete, place, property changes, and wire additions silently skip undo recording. A snapshot-based or command-log undo system would cover all mutations.
- **Command composition / macros.** No way to define a sequence of commands as a single named macro. Batch mode exists (stdin pipe) but there is no in-app recording or playback.
- **Transactional multi-command undo.** Each command is a separate undo entry. No grouping (e.g., "paste" = add N instances + M wires should be one undo step).
- **Command history persistence.** The undo ring is in-memory only, lost on close. No command log file for crash recovery or session replay.
- **Async command support.** `run_sim` blocks the main thread waiting for `child.wait()`. Long simulations freeze the UI.
- **Command validation / dry-run.** No way to check if a command will succeed before executing. `dispatch()` mutates state directly; errors are reported via `state.setStatus()` after partial execution in some cases.
- **Command permissions / capabilities.** All commands are equally available. No mechanism to restrict commands based on context (e.g., read-only mode, plugin sandboxing).
- **Batch operations.** No built-in "apply command to each selected item" — handlers manually iterate selection. A higher-level `forEachSelected(cmd)` would reduce duplication.
- **Command scripting API.** The text parser covers CLI; there is no structured API (JSON, s-expression) for programmatic command submission from plugins or external tools.

### API Issues

- **Duck-typed dispatch.** `dispatch(cmd, state: anytype)` compiles against any type with the right field names. No interface or contract defines what `state` must provide. A typo in a field name is a compile error in one handler, not at the call site. Makes handler testing require constructing the full application state or a mock with 20+ fields.
- **Handler error swallowing.** Many handlers silently return on failure (e.g., `catch continue`, `catch return`) after calling `state.setStatus()`. The caller of `dispatch()` has no way to distinguish success from failure for most commands.
- **Duplicated helper functions.** `selInst()` and `selWire()` are defined identically in View.zig, Edit.zig, Selection.zig, and Clipboard.zig. Should be a shared utility.
- **SVG export in View handler.** `View.zig` contains a 250-line SVG renderer. This is export logic, not view logic. Should be a separate module or at minimum a separate handler file.
- **`run_sim` as Undoable.** Simulation execution is categorized as `Undoable` but is never actually undone (invertCommand returns null for it). It mutates `fio.sim_results` which is display state, not schematic state.
- **Mixed concerns in Hierarchy.zig.** Combines navigation (descend/ascend) with file generation (make_symbol_from_schematic, make_schematic_from_symbol). The generation functions are 70+ lines each and could be separate.
- **Plugin commands are log-only.** `plugin_command` and `plugin_mutation` just log a message. No dispatch to actual plugin handlers — the plugin system is not wired into the command module.
- **Unused allocator parameter.** `CommandQueue.push()` takes an `Allocator` but ignores it (`_ = alloc`). The `deinit()` method is also a no-op. Vestigial from a previous design where the queue heap-allocated.
