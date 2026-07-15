---
name: schemify-mcp
description: Drive the Schemify schematic editor via its MCP server (JSON-RPC 2.0 over stdio). Use when the user wants to create, modify, query, or export circuit schematics programmatically — placing components, wiring nets, querying instances/nets/netlist, importing/exporting SPICE, or building circuits from a description.
---

# Schemify MCP

You are an agent driving Schemify, an analog/mixed-signal schematic editor,
through its MCP server. The server speaks JSON-RPC 2.0 over newline-delimited
stdio. You send one JSON line per request; you receive one JSON line back.

## Quick start

Start the server: `schemify --mcp`

Ping it to verify:
```json
{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
```

## Core workflow

1. **Open** a schematic (`session/open` for files, `session/open_content` for inline)
2. **Build** — place devices, draw wires, add buses
3. **Inspect** — `query/view` for a text summary with DRC warnings, `query/instances` and `query/nets` for structured data
4. **Export** — `query/netlist` for SPICE, `session/dispatch` with `ExportSpice` for file output
5. **Save** — `session/save`

## Methods

### Session

| Method | Params | What it does |
|---|---|---|
| `ping` | — | Returns `{"ok": true}` |
| `session/reset` | — | Blank slate |
| `session/open` | `{"path": "..."}` | Open a `.chn` file |
| `session/open_content` | `{"name": "...", "content": "..."}` | Open from string |
| `session/save` | `{"path": "..."}` (optional) | Save active doc |
| `session/set_project_dir` | `{"path": "..."}` | Set project root |
| `session/state` | — | Documents, active tool, status |
| `session/dispatch` | `{"command": <cmd>}` | Dispatch any command |

### Queries

| Method | What it returns |
|---|---|
| `query/instances` | Array of `{idx, name, symbol, kind, x, y, rotation, flip}` |
| `query/nets` | Array of `{idx, name}` |
| `query/view` | Text schematic with instance list, net connectivity, and `⚠` DRC warnings |
| `query/netlist` | SPICE netlist string |
| `query/theme` | `{"dark_mode": bool}` |

## Dispatching commands

Pass commands via `session/dispatch`. Two forms:

**Unit** (no params) — pass the command name as a string:
```json
{"jsonrpc":"2.0","id":1,"method":"session/dispatch","params":{"command":"Undo"}}
```

**Parameterized** — pass a single-key object:
```json
{"jsonrpc":"2.0","id":2,"method":"session/dispatch","params":{"command":{"PlaceDevice":{"symbol_path":"res","name":"R1","x":100,"y":200}}}}
```

### Essential commands

**Place a component:**
```json
{"PlaceDevice": {"symbol_path": "res", "name": "R1", "x": 100, "y": 200, "rotation": 0, "flip": false}}
```
Common symbol_path values: `res`, `capa`, `ind`, `vsource`, `isource`,
`nmos4`, `pmos4`, `nmos3`, `pmos3`, `npn`, `pnp`, `diode`,
`lab_pin` (label), `gnd` (ground).

**Wire two points:**
```json
{"AddWire": {"x0": 100, "y0": 30, "x1": 100, "y1": 170}}
```

**Edit instances:**
```json
{"RenameInstance": {"idx": 0, "new_name": "R2"}}
{"SetInstanceProp": {"idx": 0, "key": "value", "value": "10k"}}
{"MoveInstance": {"idx": 0, "dx": 50, "dy": 0}}
```

**Delete by index:**
```json
{"DeleteInstance": 0}
{"DeleteWire": 2}
```

**SPICE I/O:**
```json
{"ExportSpice": {"path": "/tmp/out.spice"}}
{"ImportSpice": {"path": "/tmp/circuit.spice"}}
```

**Testbenches over existing components:** an imported netlist may instantiate
project components directly as blackboxes — `X1 in out vdd 0 my_amp` resolves
against `my_amp.chn` (cell) or `my_amp.chn_prim` (symbol) and is placed with
wires on its real pins. Subckts REQUIRE that file to exist (or a `.subckt` in
the same netlist): an unknown master fails the import with
`subckt(s) could not resolve: <names>` — create the component first
(build + save the cell, or add the prim), then import the testbench.

For the full command reference, see [REFERENCE.md](REFERENCE.md).

## Example: build an RC low-pass filter

```json
{"jsonrpc":"2.0","id":1,"method":"session/open_content","params":{"name":"rc-filter","content":""}}
{"jsonrpc":"2.0","id":2,"method":"session/dispatch","params":{"command":{"PlaceDevice":{"symbol_path":"vsource","name":"Vin","x":0,"y":0}}}}
{"jsonrpc":"2.0","id":3,"method":"session/dispatch","params":{"command":{"PlaceDevice":{"symbol_path":"res","name":"R1","x":160,"y":0}}}}
{"jsonrpc":"2.0","id":4,"method":"session/dispatch","params":{"command":{"PlaceDevice":{"symbol_path":"capa","name":"C1","x":320,"y":160}}}}
{"jsonrpc":"2.0","id":5,"method":"session/dispatch","params":{"command":{"PlaceDevice":{"symbol_path":"gnd","name":"gnd","x":0,"y":160}}}}
{"jsonrpc":"2.0","id":6,"method":"session/dispatch","params":{"command":{"PlaceDevice":{"symbol_path":"gnd","name":"gnd","x":320,"y":320}}}}
{"jsonrpc":"2.0","id":7,"method":"session/dispatch","params":{"command":{"AddWire":{"x0":0,"y0":30,"x1":160,"y1":30}}}}
{"jsonrpc":"2.0","id":8,"method":"session/dispatch","params":{"command":{"AddWire":{"x0":160,"y0":30,"x1":320,"y1":30}}}}
{"jsonrpc":"2.0","id":9,"method":"session/dispatch","params":{"command":{"AddWire":{"x0":320,"y0":30,"x1":320,"y1":130}}}}
{"jsonrpc":"2.0","id":10,"method":"session/dispatch","params":{"command":{"SetInstanceProp":{"idx":2,"key":"value","value":"100n"}}}}
{"jsonrpc":"2.0","id":11,"method":"session/dispatch","params":{"command":{"SetInstanceProp":{"idx":1,"key":"value","value":"1k"}}}}
{"jsonrpc":"2.0","id":12,"method":"query/view","params":{}}
{"jsonrpc":"2.0","id":13,"method":"query/netlist","params":{}}
```

## Guidelines

- Always call `query/view` after building to check for DRC warnings (floating pins, stub nets, isolated devices).
- Use `query/instances` to get current indices before `MoveInstance`, `RenameInstance`, `DeleteInstance` — indices can shift after deletions.
- Ground symbols (`gnd`) and labels (`lab_pin`) create named nets. Wire endpoints that meet at the same coordinate are connected.
- The grid spacing is 10 units. Place components on multiples of 10.
- `rotation` is 0-3 (0/90/180/270 degrees). `flip` mirrors horizontally.

## Error codes

| Code | Meaning |
|---|---|
| `-32700` | JSON parse error |
| `-32600` | Invalid request |
| `-32601` | Unknown method |
| `-32001` | Plugins not available |
