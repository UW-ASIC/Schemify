# Schemify MCP Command Reference

All commands are dispatched via `session/dispatch`:
```json
{"jsonrpc":"2.0","id":1,"method":"session/dispatch","params":{"command": <cmd>}}
```

## Unit commands (string, no parameters)

### View
`ZoomIn`, `ZoomOut`, `ZoomFit`, `ZoomReset`, `ToggleFullscreen`, `ToggleColorScheme`, `ToggleGrid`

### File
`FileNew`, `FileOpen`, `FileSave`, `FileSaveAs`, `NewTab`, `CloseActiveTab`, `ReloadFromDisk`

### Selection
`SelectAll`, `SelectNone`, `InvertSelection`

### Clipboard
`Copy`, `Cut`, `Paste`

### Edit
`Undo`, `Redo`, `DeleteSelected`, `DuplicateSelected`

### Transform
`RotateCw`, `RotateCcw`, `FlipHorizontal`, `FlipVertical`,
`NudgeUp`, `NudgeDown`, `NudgeLeft`, `NudgeRight`, `AlignToGrid`

### Align & distribute
`AlignLeft`, `AlignRight`, `AlignTop`, `AlignBottom`,
`AlignCenterH`, `AlignCenterV`, `DistributeH`, `DistributeV`

### Simulation
`RunSim`, `ExportNetlist`, `GenerateSymbolFromSchematic`

### Dialogs
`OpenFindDialog`, `OpenPropsDialog`, `OpenSettings`,
`OpenSpiceCodeEditor`, `OpenNewPrimDialog`, `OpenImportDialog`,
`OpenLibraryBrowser`, `OpenFileExplorer`, `OpenMarketplace`

## Parameterized commands (single-key object)

### Components

**PlaceDevice** — place an instance:
```json
{"PlaceDevice": {"symbol_path": "res", "name": "R1", "x": 100, "y": 200, "rotation": 0, "flip": false}}
```
- `symbol_path`: symbol name (`res`, `capa`, `ind`, `vsource`, `isource`, `nmos4`, `pmos4`, `nmos3`, `pmos3`, `npn`, `pnp`, `diode`, `lab_pin`, `gnd`)
- `rotation`: 0-3 (multiples of 90 degrees)
- `flip`: horizontal mirror (default false)

**RenameInstance**:
```json
{"RenameInstance": {"idx": 0, "new_name": "R2"}}
```

**SetInstanceProp**:
```json
{"SetInstanceProp": {"idx": 0, "key": "value", "value": "10k"}}
```

**MoveInstance**:
```json
{"MoveInstance": {"idx": 0, "dx": 10, "dy": 0}}
```

**DeleteInstance**: `{"DeleteInstance": 0}`

### Wiring

**AddWire**:
```json
{"AddWire": {"x0": 0, "y0": 0, "x1": 100, "y1": 0}}
```

**MoveWire**: `{"MoveWire": {"idx": 0, "dx": 10, "dy": 0}}`

**SplitWire**: `{"SplitWire": {"idx": 0, "x": 50, "y": 0}}`

**SetWireColor**: `{"SetWireColor": {"idx": 0, "color": "#FF0000"}}`

**DeleteWire**: `{"DeleteWire": 0}`

### Buses

**AddBus**:
```json
{"AddBus": {"label": "data", "width": 8, "start_bit": 0, "x0": 0, "y0": 0, "x1": 100, "y1": 0}}
```

**AddBusRipper**: `{"AddBusRipper": {"bus_idx": 0, "bit": 3, "x": 50, "y": 0, "direction": 0}}`

**SetBusWidth**: `{"SetBusWidth": {"idx": 0, "width": 16}}`

**RenameBus**: `{"RenameBus": {"idx": 0, "new_name": "addr"}}`

**DeleteBus**: `{"DeleteBus": 0}`

**DeleteBusRipper**: `{"DeleteBusRipper": 0}`

### Drawing primitives

**AddLine**: `{"AddLine": {"x0": 0, "y0": 0, "x1": 50, "y1": 50}}`

**AddRect**: `{"AddRect": {"x": 10, "y": 10, "w": 80, "h": 40}}`

**AddCircle**: `{"AddCircle": {"cx": 50, "cy": 50, "radius": 20}}`

**AddArc**: `{"AddArc": {"cx": 50, "cy": 50, "radius": 20, "start": 0.0, "sweep": 3.14}}`

**AddText**: `{"AddText": {"x": 10, "y": 10, "content": "Hello"}}`

**AddPolygon**: `{"AddPolygon": {"points": [[0,0],[50,0],[25,50]]}}`

### Bulk operations

**MoveSelected**: `{"MoveSelected": {"dx": 10, "dy": 0}}`

### Tabs

**CloseTab**: `{"CloseTab": 1}`

**SwitchTab**: `{"SwitchTab": 0}`

### Tool switching

**SetTool**: `{"SetTool": "wire"}`

Valid tools: `select`, `wire`, `bus`, `busripper`, `move`, `pan`, `line`, `rect`, `polygon`, `arc`, `circle`, `text`

### SPICE

**ExportSpice**: `{"ExportSpice": {"path": "/tmp/out.spice"}}`

**ImportSpice**: `{"ImportSpice": {"path": "/tmp/circuit.spice"}}`

Subckt resolution on import: every `X` master must already exist in the
project as `<name>.chn` (schematic cell) or `<name>.chn_prim` (symbol) —
or be a `.subckt` defined in the same netlist. Known components place as
blackboxes wired to their real pins (`.chn` cells use their generated box
symbol; `.chn_prim` symbols use their own pin geometry). An unknown master
FAILS the whole import with `subckt(s) could not resolve: <names>` — create
the component first, then re-import the testbench.

### Document metadata

**SetSpiceCode**: `{"SetSpiceCode": ".param vdd=1.8"}`

**SetDocumentation**: `{"SetDocumentation": "# Title\nDescription."}`

**SetStimulusLang**: `{"SetStimulusLang": "python"}`

**SetSimBackend**: `{"SetSimBackend": "ngspice"}`

**SetSimCorner**: `{"SetSimCorner": "tt"}`

### Waveform viewer

Active when a wave tab is open (`RunSim` auto-opens the result rawfile).

**WaveOpen**: `{"WaveOpen": {"path": "/tmp/circuit.raw"}}`

**WaveAddTrace**: `{"WaveAddTrace": {"expr": "db(v(out)/v(in))", "block": 0}}`
— `file`/`pane` optional (default: last-opened file, active pane).
Expressions: `v(net)`, `i(dev)`, `db()`, `mag()`, `ph()`, arithmetic.

**WaveRemoveTrace**: `{"WaveRemoveTrace": 0}` · **WaveClearTraces** (unit)

**WaveSetCursor**: `{"WaveSetCursor": {"cursor": 0, "x": 1000.0, "visible": true}}` (0=A, 1=B)

**WaveSetXLog**: `{"WaveSetXLog": true}` ·
**WaveSetXRange**: `{"WaveSetXRange": {"min": 1.0, "max": 1e6}}` ·
**WaveZoomFit** (unit) · **WaveReload** (unit)

**WaveExportCsv**: `{"WaveExportCsv": {"path": "/tmp/out.csv"}}`

### Project

**ReloadProjectConfig** (unit) — re-read Config.toml, re-resolve the PDK,
and re-register project `.chn` cells as placeable symbols. Run after saving
a new cell if you plan to `PlaceDevice` it (netlist_to_schematic refreshes
automatically).

**PluginsRefresh** (unit) — rescan plugin directories.

### Optimizers

Use the dedicated `optimizer_*` MCP tools instead of dispatch commands.
