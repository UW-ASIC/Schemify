# commands

Every schematic mutation is expressed as a Command. Owns the type system, dispatch, text parser, queue, and handler implementations.

## Functionality

- Command types: Immediate (view/UI, no undo) and Undoable (schematic mutations, undo/redo ring)
- Dispatch: routes Command → handler via exhaustive switch
- Parser: text → Command (comptime-generated from union tag names + manual alias table)
- Queue: fixed-capacity ring buffer (64 slots), drained once per frame
- 15 handler sub-modules covering all schematic operations

## Public API

- `Command` — `union(enum) { immediate: Immediate, undoable: Undoable }`
- `Immediate` — 70+ view/UI/tool variants (most void, some with payloads)
- `Undoable` — 17 mutation variants (transforms, placement, properties, sim)
- `PrimitiveKind` — enum of insertable component types with `kindName()` and `prefix()`
- `CommandQueue` — `push(alloc, cmd)`, `pop()`, `isEmpty()`
- `dispatch(cmd, state)` — routes to handler, state is duck-typed
- `parser.parse(line)` — text command → `Result` (command, meta, meta_arg, or err)
- `parser.tryTagLookup(name)` — resolve a tag name to a Command
- `parser.printCommandList(file)` — emit help text
- `handlers.History` — fixed ring buffer (64 entries) for undo/redo
- `handlers.invertCommand(cmd)` — compute inverse for simple undoable commands

## Internal Structure

| File | Purpose |
|------|---------|
| `types.zig` | Command, Immediate, Undoable unions + payload structs |
| `Dispatch.zig` | Exhaustive switch routing to handlers |
| `parser.zig` | Text → Command with alias tables and arg parsers |
| `Queue.zig` | Ring-buffer command queue |
| `handlers/lib.zig` | Re-exports all handler functions |
| `handlers/Edit.zig` | Transforms, delete, duplicate, placement, properties |
| `handlers/View.zig` | Zoom, pan, toggle flags, SVG export |
| `handlers/Sim.zig` | Run simulation, waveform viewer |
| `handlers/Hierarchy.zig` | Descend/ascend, symbol↔schematic generation |
| `handlers/Selection.zig` | Select all/none/invert, highlight nets |
| `handlers/Clipboard.zig` | Copy, cut, paste |
| `handlers/File.zig` | New/open/save/close tabs, reload |
| `handlers/Undo.zig` | History ring, undo/redo, command inversion |
| `handlers/Wire.zig` | Wire/tool mode switching |
| `handlers/Dialog.zig` | Open modal dialogs |
| `handlers/Netlist.zig` | Generate and cache netlists |
| `handlers/Config.zig` | Preferences, config reload, clear sim cache |
| `handlers/Primitive.zig` | Insert primitive at cursor |
| `handlers/Import.zig` | Auto-detect format, open import dialog |
| `handlers/Optimize.zig` | Open optimizer dialog |

## Dependencies

- `schematic` — domain types for device kinds, instances, wires
- `simulation` — Netlist (for sim handler), results types
- `utility` — platform filesystem helpers
