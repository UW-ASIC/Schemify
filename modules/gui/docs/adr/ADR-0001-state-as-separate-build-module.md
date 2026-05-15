# ADR-0001: state.zig as a Separate Build Module

## Status: accepted

## Context

`gui` depends on `commands` (to enqueue Commands), and `commands` depends on gui state types (to read Selection, Document, etc. when executing handlers). This creates a circular dependency: `gui -> commands -> gui`.

Zig's build system does not allow circular module imports.

## Decision

Extract `state.zig` into its own build module named `"state"`. Both `gui` and `commands` import `"state"` instead of each other. `state.zig` has no dependency on `gui` or `commands` — it only imports `schematic`, `simulation`, `commands` (for `CommandQueue` and `handlers.History`), `plugins`, `settings`, and `utility`.

`theme.zig` is similarly extracted as `"theme_config"` so canvas renderers can access palette colors without depending on the full gui module.

## Consequences

- `AppState`, `Document`, `Selection`, and all dialog state types live in `state.zig`, not in `gui/lib.zig`. This is surprising to newcomers who expect GUI state to be in the GUI module.
- `state.zig` has grown to ~1050 LOC because it is the meeting point for all cross-cutting state. Splitting it further would require additional build modules.
- Adding a new dialog requires adding its state struct to `state.zig`, not to the dialog's own file.
- The `commands` module can read and write `AppState` fields freely, which means the boundary between "GUI state" and "command state" is blurred.
