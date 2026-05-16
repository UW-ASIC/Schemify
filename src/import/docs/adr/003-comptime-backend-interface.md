# ADR-003: Comptime Interface Check via BackendUnion

## Status
Accepted

## Context
The `EasyImport` facade wraps three backends (XSchem, Virtuoso, SPICE) behind a uniform API. Each backend must implement: `init`, `deinit`, `label`, `detectProjectRoot`, `convertProject`, `getFiles`. Zig has no trait/interface language feature.

Options:
1. **Vtable (function pointer struct)** -- runtime dispatch, each backend fills a function table.
2. **Tagged union + comptime check** -- `BackendUnion = union(BackendKind)`, with a comptime block that verifies each variant has the required methods. Dispatch via `switch` on the active tag.
3. **`anytype` / duck typing** -- generic `EasyImport(BackendT)`, no enforcement.

## Decision
Option 2: `BackendUnion` tagged union with a comptime interface conformance check in `lib.zig`.

## Consequences

**Why not vtable (option 1):** Vtables work but introduce indirection for no benefit -- the backend set is closed (three backends, known at comptime). A tagged union with `switch` generates a direct call per branch, which is both faster and produces better error messages when a method is missing.

**Why not duck typing (option 3):** `anytype` gives no error until instantiation, and the error message points at the call site inside EasyImport, not at the backend that is missing a method. The comptime check in option 2 produces a `@compileError` naming the exact backend and missing method.

**Trade-off:** Adding a new backend requires adding a variant to `BackendKind` and `BackendUnion`, then implementing all six methods. If you forget one, you get a compile error. If you want a backend that genuinely cannot implement one of the methods (like `getFiles` for non-XSchem backends), you must still provide the method -- it just returns an error. This is the `getFiles` leak documented in the Gaps section.

**Reversal cost:** Medium. Switching to vtable requires defining a function pointer struct, changing EasyImport to store a pointer + vtable instead of a union, and removing the comptime check. The public API (`EasyImport.convertProject()` etc.) would not change.
