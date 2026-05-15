# ADR-0001: Duck-typed dispatch via `anytype` state

## Status: accepted

## Context

The command module must call into GUI state (zoom, tool mode, selection, dialogs) and schematic state (instances, wires, properties) to execute commands. The natural approach would be to import the state type directly, but that creates a circular dependency: `gui` depends on `commands` for the Command type, and `commands` would depend on `gui` for the state type. Zig's build system does not allow module cycles.

Alternatives considered:
1. **Extract a state interface module** depended on by both. Requires defining a vtable or comptime interface with 30+ methods and 20+ fields — heavy maintenance burden for a single consumer.
2. **Split commands into types-only + handlers.** Types module has no dependency, handlers module depends on gui. Workable but fragments the module and still couples handlers to gui internals.
3. **`anytype` (duck typing).** Handlers take `state: anytype` and access fields/methods directly. The compiler verifies at instantiation that all accessed fields exist with correct types.

## Decision

Use `anytype` for the `state` parameter throughout dispatch and all handlers. The command module has zero imports from gui or state modules. The compiler enforces correctness at each call site.

## Consequences

- **Pro:** No circular dependency. The commands module is a leaf dependency of gui, not a peer.
- **Pro:** Adding a new field to state that a handler needs requires no interface update — just use it.
- **Con:** No single place documents what `state` must provide. The "interface" is implicit across 15 handler files.
- **Con:** Unit-testing a handler requires building a mock struct with every field the handler touches. There is no minimal trait to satisfy.
- **Con:** Refactoring a field name on state requires grep-based discovery of all handler usages — no type-level rename support.
- **Mitigation:** If the implicit interface grows unmanageable, extract a `StateContract` comptime check that asserts required fields/methods exist, called once at the dispatch call site.
