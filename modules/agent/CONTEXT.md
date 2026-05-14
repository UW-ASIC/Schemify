# agent

MCP server for AI-assisted circuit design over Unix domain socket (JSON-RPC 2.0).

## Functionality

- MCP server with background thread, accepts multiple clients
- 12 tools: place_component, add_wire, remove_component, set_property, create_from_topology, validate_circuit, check_connectivity, drc_check, generate_netlist, read_file, write_file, list_project_files
- 6 static resources + 2 URI templates for schematic state access
- 7 prompt templates for common design workflows
- Circuit diagnostics: validation, unrouted pins, floating nets, DRC, netlist generation

Removed in cleanup: `SchematicRef` opaque wrapper struct, `connectivity` fn (zero callers), `validate`/`checkConnectivity`/`drc` opaque wrappers (tools.zig calls non-opaque versions directly).

## Public API

| Symbol | Purpose |
|--------|---------|
| `init(allocator, ctx)` | Start MCP server on background thread |
| `deinit(server)` | Stop MCP server |
| `McpServer` | Server handle type |
| `diagnostics.validateCircuit` | Circuit validation → JSON |
| `diagnostics.unroutedPins` | Find unconnected pins → JSON |
| `diagnostics.floatingNets` | Find single-connection nets → JSON |
| `diagnostics.drcCheck` | Design rule check → JSON |
| `diagnostics.netlist` | Generate netlist → JSON |

## Internal Structure

| File | Purpose |
|------|---------|
| `lib.zig` | Public API: init/deinit, socket path |
| `server.zig` | MCP server, JSON-RPC routing, client threads |
| `tools.zig` | Tool definitions and handlers |
| `resources.zig` | Resource definitions and handlers |
| `prompts.zig` | Prompt templates |
| `diagnostics.zig` | Circuit validation, DRC, connectivity analysis |
| `types.zig` | MCP protocol types, AgentContext, AgentCommand |

## Dependencies

- `schematic` — Schemify, types, helpers (for diagnostics)
- `simulation` — Netlist (for netlist generation in diagnostics)
