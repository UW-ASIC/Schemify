# agent

MCP (Model Context Protocol) server for AI-assisted circuit design. Listens on a Unix domain socket, speaks JSON-RPC 2.0, exposes schematic state and mutation tools to LLM clients.

## Functionality

- **Server**: background-threaded Unix domain socket server. Accepts multiple concurrent clients (one thread per client). Handles the full MCP lifecycle: `initialize`, `notifications/initialized`, `ping`, plus `tools/*`, `resources/*`, `prompts/*`.
- **Tools (12)**: 5 mutation, 4 diagnostic, 3 file I/O. Mutation tools dispatch `AgentCommand`s through a callback; diagnostic tools operate on a read-only `*const Schemify`.
- **Resources (6 static + 2 templates)**: read-only views of schematic state (instances, nets, wires, selection, info, skills doc) plus per-instance and per-net detail via URI templates.
- **Prompts (7)**: multi-step design workflow templates that return structured message sequences for LLM clients.
- **Diagnostics**: validation, DRC (5 checks), unrouted pin detection, floating net detection, SPICE netlist generation.

## Public API

| Symbol | Type | Purpose |
|--------|------|---------|
| `init(allocator, ctx) !McpServer` | fn | Resolve socket path, create and start MCP server on background thread |
| `deinit(server)` | fn | Stop server, close socket, clean up |
| `McpServer` | type | `Server` from `server.zig` -- the server handle |
| `types.JsonRpcId` | union(enum) | JSON-RPC id: `.integer` or `.string` |
| `types.ErrorCode` | enum(i32) | JSON-RPC + MCP error codes (-32700..-32003) |
| `types.ToolAnnotations` | struct | readOnlyHint, destructiveHint, idempotentHint |
| `types.PromptArgument` | struct | Prompt argument descriptor (name, description, required) |
| `types.AgentCommand` | union(enum) | place, add_wire, delete_instance, set_instance_prop |
| `types.AgentContext` | struct | Bridge to app: getSchematic, dispatchCommand, getProjectDir, app ptr |
| `types.writeJsonStr(w, s)` | fn | Write JSON-escaped string with quotes to any writer |
| `types.successResponse(a, id, json)` | fn | Build JSON-RPC 2.0 success response |
| `types.errorResponse(a, id, code, msg)` | fn | Build JSON-RPC 2.0 error response |
| `tools.listTools(a)` | fn | Serialize all 12 tool definitions to JSON |
| `tools.callTool(a, name, args, ctx)` | fn | Dispatch a tool call by name |
| `tools.ToolEntry` | struct | Tool definition: name, description, schema_json, annotations, handler |
| `resources.listResources(a)` | fn | Serialize all resources + templates to JSON |
| `resources.readResource(a, uri, ctx)` | fn | Read a resource by URI, dispatch to handler |
| `prompts.listPrompts(a)` | fn | Serialize all 7 prompt definitions to JSON |
| `prompts.getPrompt(a, name, args)` | fn | Instantiate a prompt by name with arguments |
| `diagnostics.validateCircuit(a, sch)` | fn | Full validation: empty check, missing symbols, dupes, zero-length wires, DRC, unrouted pins |
| `diagnostics.unroutedPins(a, sch)` | fn | Find pins with no net connection or no connections at all |
| `diagnostics.floatingNets(a, sch)` | fn | Find nets with only one instance-pin connection |
| `diagnostics.drcCheck(a, sch)` | fn | 5 DRC checks: min W/L, unconnected pins, short circuits, missing body, floating gates |
| `diagnostics.netlist(a, sch)` | fn | Generate SPICE netlist via `simulation.Netlist.emitSpice` |
| `diagnostics.extractJsonArrayField(w, a, json, field)` | fn | Extract and re-serialize a JSON array field (helper for tools) |

## Tools

| Name | Category | Annotations | What it does |
|------|----------|-------------|--------------|
| `place_component` | mutation | rw, non-destructive | Dispatch `AgentCommand.place` via callback |
| `add_wire` | mutation | rw, non-destructive | Dispatch `AgentCommand.add_wire` via callback |
| `remove_component` | mutation | destructive, idempotent | Look up instance by name, dispatch `delete_instance` |
| `set_property` | mutation | rw, idempotent | Look up instance by name, dispatch `set_instance_prop` |
| `create_from_topology` | mutation | rw, non-destructive | Parse topology JSON (components + nets), validate, auto-place on grid, dispatch multiple place + add_wire commands |
| `validate_circuit` | diagnostic | read-only, idempotent | Calls `diagnostics.validateCircuit` |
| `check_connectivity` | diagnostic | read-only, idempotent | Combines `unroutedPins` + `floatingNets` |
| `drc_check` | diagnostic | read-only, idempotent | Calls `diagnostics.drcCheck` |
| `generate_netlist` | diagnostic | read-only, idempotent | Calls `diagnostics.netlist` (SPICE only; `format` param accepted but ignored) |
| `read_file` | file I/O | read-only, idempotent | Read file from disk (10MB limit) |
| `write_file` | file I/O | destructive, idempotent | Write file to disk, create parent dirs |
| `list_project_files` | file I/O | read-only, idempotent | List files in project dir by extension filter (max 200) |

## Resources

| URI | Type | Handler reads |
|-----|------|---------------|
| `schemify://instances` | static | All instances: name, symbol, x, y, kind, properties |
| `schemify://nets` | static | All nets with their connections |
| `schemify://wires` | static | All wire segments: endpoints, net_name, bus flag |
| `schemify://selection` | static | Stub -- returns note that selection requires GUI state |
| `schemify://info` | static | File name, instance/wire/net/pin counts, schematic type, project dir |
| `schemify://skills/core` | static | Hardcoded markdown: device names, naming conventions, workflow |
| `schemify://instance/{name}` | template | Single instance detail: properties, pin-to-net connections |
| `schemify://net/{name}` | template | Single net detail: connections, wires on that net |

## Prompts

| Name | Arguments | Purpose |
|------|-----------|---------|
| `design_amplifier` | gain, bandwidth, power, supply, process, topology, load | Guided diff-amp design with gm/Id methodology |
| `import_xschem` | project_path, pdk, top_cell, include_testbenches | XSchem project import workflow (sky130/gf180/ihp) |
| `optimize_sizing` | target, gm_id, vds_min, ids, devices, process | gm/Id transistor sizing optimization |
| `design_current_mirror` | type, iref, ratio, supply | Current mirror design (simple/cascode/wide_swing/wilson) |
| `analyze_circuit` | focus | Analyze existing schematic topology and performance |
| `create_testbench` | analysis, corners, duration, freq_range | Generate SPICE testbench with stimulus and measurements |
| `explain_circuit` | (none) | Read and explain current schematic |

## Internal Structure

| File | LOC | Purpose |
|------|-----|---------|
| `lib.zig` | 58 | Entry point: `init`/`deinit`, socket path resolution, re-exports |
| `server.zig` | 416 | `Server` struct: Unix socket, accept loop, per-client thread, JSON-RPC routing, message processing |
| `types.zig` | 193 | Protocol types: `JsonRpcId`, `ErrorCode`, `AgentCommand`, `AgentContext`, `ToolAnnotations`, JSON helpers |
| `tools.zig` | 1037 | 12 tool definitions + handlers. `create_from_topology` is the largest (~360 lines): parses topology JSON, validates, auto-places, dispatches |
| `resources.zig` | 522 | 6 static + 2 template resources. Handlers read SoA fields from `Schemify` and build JSON manually |
| `prompts.zig` | 604 | 7 prompt templates. Each handler interpolates arguments into multi-step design workflow text |
| `diagnostics.zig` | 1047 | 5 DRC checks, validation, unrouted/floating detection, netlist generation, JSON helpers |

## Dependencies

- **schematic** -- `Schemify` (instances, wires, nets, conns, props, sym_data, pins SoA fields), `types` (DeviceKind, Instance, Wire, Net, etc.), `helpers`
- **simulation** -- `Netlist.emitSpice` (called from `diagnostics.netlist`)
- **std** -- posix sockets, threads, JSON parsing, filesystem

No dependency on `gui`, `commands`, `plugins`, or `import`. The bridge to the application is entirely through `AgentContext` function pointers.

## Gaps

### Missing Features

- **Streaming tool results**: long-running tools (netlist generation, DRC on large schematics) block the client thread with no progress indication. MCP supports streaming via SSE; not implemented.
- **Tool cancellation**: no way to abort a running tool call. The per-client thread runs to completion.
- **Session management**: no client authentication, no session IDs, no capability negotiation beyond the initial handshake. Any process that can reach the socket gets full access.
- **Multi-user coordination**: concurrent mutations from multiple clients are dispatched as independent `AgentCommand`s with no conflict detection or ordering guarantees.
- **Undo integration**: mutation tools dispatch commands but have no way to group them into an undo transaction. `create_from_topology` dispatches N commands that cannot be atomically rolled back.
- **Simulation result streaming**: `generate_netlist` returns the netlist text but there is no tool to run a simulation and stream waveform results back.
- **Design space exploration tools**: no parametric sweep, corner analysis, or Monte Carlo tools. Prompts describe these workflows but no tool automates them.
- **Constraint-based placement**: `create_from_topology` uses a fixed 4-column grid layout. No constraint solver, no symmetry enforcement, no alignment to existing components.
- **Tool chaining / workflows**: no server-side tool pipelines. Each tool call is independent; the LLM must orchestrate multi-step sequences.
- **Hierarchy navigation**: no tools to descend into or create subcircuits. All operations are flat (single schematic level).
- **Selection-aware tools**: `schemify://selection` is a stub. No tool operates on the current GUI selection.
- **Spectre netlist format**: `generate_netlist` accepts a `format` parameter but only produces SPICE.
- **Resource subscriptions**: MCP supports `resources/subscribe` for change notifications. Not implemented.
- **Sampling**: MCP `sampling/createMessage` (server-initiated LLM requests) not implemented.

### API Issues

- **`DeviceKind` duplication**: `tools.zig` defines a local `DeviceKind` enum (23 variants) that is a subset of `schematic.types.DeviceKind`. These can drift apart silently. The comment says "kept local to avoid cross-module import" but `tools.zig` already imports `schematic`.
- **`generate_netlist` ignores `format` param**: the schema declares `format` with enum `["spice","spectre"]` but the handler never reads it. Spectre requests silently produce SPICE output.
- **`schemify://selection` is a dead resource**: always returns a static note string. Listed in `resources/list` but never returns real data.
- **`create_from_topology` does not set properties**: the handler dispatches `place` commands but never dispatches `set_instance_prop` for the parsed W/L/value/model properties. The comment at line 648-652 acknowledges this gap.
- **File I/O path traversal**: `read_file` and `write_file` accept absolute paths and paths with `..` components. No sandboxing to project directory.
- **`list_project_files` is shallow**: only iterates the top-level project directory (no recursion), despite the schema default of `**/*.chn` implying recursive glob support.
- **`checkShortCircuits` location bug**: on line 389, reports `xs[0]`/`ys[0]` (first instance in the schematic) instead of the actual power symbol location.
- **Error swallowing in resource handlers**: JSON build errors are caught with `catch {}` throughout `resources.zig`, silently producing truncated JSON.
- **No `tools/call` error differentiation**: tool-not-found returns `isError:true` in the result content rather than a JSON-RPC error response with code `-32002`.
- **Mutation tools return stale data**: `place_component` returns the echoed input (`placed:true, symbol, name, x, y`) but does not confirm the command was actually executed -- it only confirms the command was enqueued.
- **Arena lifetime in `processMessage`**: the arena is freed at the end of `processMessage`, but the response is duped into the long-lived allocator first. Correct, but fragile -- any handler that returns arena memory without going through `dupeResponse` would be use-after-free.
