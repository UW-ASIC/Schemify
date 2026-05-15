# Context Map — Schemify

9 bounded contexts. Each is a Zig build module with its own `CONTEXT.md`.

## Module Dependency Graph

```
                    ┌──────────┐
                    │  utility  │  (leaf — logging, platform, ring buffer)
                    └────┬─────┘
                         │
              ┌──────────┴──────────┐
              │                     │
        ┌─────▼─────┐        ┌─────▼─────┐
        │  schematic │        │  plugins   │
        │ (domain)   │        │ (extension)│
        └──┬──┬──┬───┘        └─────┬─────┘
           │  │  │                  │
     ┌─────┘  │  └──────┐          │
     │        │         │          │
┌────▼───┐ ┌──▼────┐ ┌──▼───┐     │     ┌──────────┐
│simulate│ │import  │ │agent │     │     │ settings │
│        │ │        │ │(MCP) │     │     │  (leaf)  │
└───┬────┘ └────────┘ └──┬───┘     │     └────┬─────┘
    │                    │         │          │
    └────────┬───────────┘         │          │
             │                     │          │
       ┌─────▼─────┐              │          │
       │  commands  │◄─────────────┘          │
       └─────┬─────┘                          │
             │                                │
       ┌─────▼─────────────────────────────────▼──┐
       │                  gui                      │
       │  (frame, canvas, panels, input, state)    │
       └───────────────────────────────────────────┘
```

## Modules

| Module | Path | Purpose | Deps |
|--------|------|---------|------|
| **utility** | `modules/utility/` | Logger, platform, RingBuffer | (none) |
| **settings** | `modules/settings/` | User config: theme.json, keybinds.json | (none) |
| **schematic** | `modules/schematic/` | Domain model: types, Schemify, devices, fileio, digital | utility |
| **simulation** | `modules/simulation/` | Netlist, SPICE, results, optimizer | schematic |
| **import** | `modules/import/` | XSchem, Virtuoso, SPICE importers | schematic |
| **agent** | `modules/agent/` | MCP server for AI-assisted design | schematic, simulation |
| **plugins** | `modules/plugins/` | Native plugin loading and lifecycle | utility, dvui |
| **commands** | `modules/commands/` | Command types, dispatch, handlers | schematic, simulation |
| **gui** | `modules/gui/` | Frame, canvas, panels, input, state | schematic, commands, plugins, settings, simulation, import |

## Relationships

- **Conformist**: `simulation`, `import`, `agent`, `commands` all conform to `schematic`'s types — schematic is upstream, they adapt
- **Shared Kernel**: `schematic/types.zig` is the shared kernel — Instance, Wire, Pin, Property are the lingua franca
- **Anti-Corruption Layer**: `import/` translates foreign formats (XSchem, Virtuoso, SPICE) into native schematic types
- **Published Language**: `agent/` exposes schematic state via MCP protocol (JSON-RPC 2.0) — the protocol is the published language
- **Separate Ways**: `settings/` and `plugins/` are independent — they share no types with each other

## Build Modules vs Directory Modules

Two files in `gui/` are separate **build modules** (not just directory members):
- `gui/state.zig` → build module `"state"` (breaks gui <-> commands cycle)
- `gui/theme.zig` → build module `"theme_config"`

## Entry Points

- `modules/main.zig` — Application lifecycle, dvui callbacks
- `modules/cli.zig` — CLI subcommands (plugin install, netlist export, etc.)

## Cleanup

See `modules/CLEANUP-PROTOCOL.md` for the operational cleanup guide (processing order, dead code detection, commit strategy, decision rules).
