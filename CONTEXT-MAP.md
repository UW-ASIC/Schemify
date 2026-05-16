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
| **utility** | `src/utility/` | Logger, platform, RingBuffer | (none) |
| **settings** | `src/settings/` | User config: theme.json, keybinds.json | (none) |
| **schematic** | `src/schematic/` | Domain model: types, Schemify, devices, fileio, digital | utility |
| **simulation** | `src/simulation/` | Netlist, SPICE, results, optimizer | schematic |
| **import** | `src/import/` | XSchem, Virtuoso, SPICE importers | schematic |
| **agent** | `src/agent/` | MCP server for AI-assisted design | schematic, simulation |
| **plugins** | `src/plugins/` | Native plugin loading and lifecycle | utility, dvui |
| **commands** | `src/commands/` | Command types, dispatch, handlers | schematic, simulation |
| **gui** | `src/gui/` | Frame, canvas, panels, input, state | schematic, commands, plugins, settings, simulation, import |

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

- `src/main.zig` — Application lifecycle, dvui callbacks
- `src/cli.zig` — CLI subcommands (plugin install, netlist export, etc.)

## Cleanup

See `src/CLEANUP-PROTOCOL.md` for the operational cleanup guide (processing order, dead code detection, commit strategy, decision rules).
