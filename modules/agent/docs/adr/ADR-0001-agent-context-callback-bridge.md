# ADR-0001: AgentContext callback bridge instead of direct command module dependency

## Status: accepted

## Context

Tool handlers need to mutate the schematic (place components, add wires, delete instances, set properties). The obvious approach is to import the `commands` module and push `Command` values onto the command queue directly. This creates a dependency cycle: `agent` -> `commands` -> `schematic`, and `commands` -> `gui` (for some handlers), pulling half the application into the agent module. It also makes the agent module untestable without the full application stack.

## Decision

Define a local `AgentCommand` union in `types.zig` with four variants (`place`, `add_wire`, `delete_instance`, `set_instance_prop`). Define `AgentContext` as a struct of function pointers (`getSchematic`, `dispatchCommand`, `getProjectDir`) plus an opaque `app: *anyopaque`. The application (main.zig) constructs an `AgentContext` that translates `AgentCommand` values into real `commands.Command` values and pushes them onto the queue. Tool handlers only see `AgentContext` and never import `commands`.

## Consequences

- Agent module depends only on `schematic` and `simulation`. No dependency on `commands`, `gui`, or `plugins`.
- Agent module is fully testable with a mock `AgentContext` (null dispatch, null schematic). All tool tests use this pattern.
- Every new mutation tool requires adding a variant to `AgentCommand` and a translation case in `main.zig`. This is intentional friction -- it forces review of what the agent can do.
- `AgentCommand` is a strict subset of `commands.Command`. Features like undo grouping, rotation, mirroring, and annotation are not exposed. Adding them requires expanding the union.
