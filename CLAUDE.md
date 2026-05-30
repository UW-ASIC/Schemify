# CLAUDE.md — SchemifyRS

Schematic capture tool for analog/circuit design. Rust + egui. Successor to the Zig SchemifyRS prototype.

## Build & Test

**Always run `nix develop` first.** All commands below assume you are inside the Nix dev shell. Do not run cargo outside of it — the nightly toolchain (with the `wasm32-unknown-unknown` target), clippy, rustfmt, `trunk`, `wasm-bindgen-cli`, and PySpice are only available inside the shell.

```bash
nix develop                                # REQUIRED — enter dev shell first
cargo build                                # build all crates
cargo build --features schemify-plugins/wasm   # build with WASM plugin transport
cargo run                                  # launch the GUI (schemify-engine)
cargo run -- <subcommand>                  # headless: run a Command against a schematic file
cargo nextest run                          # run all tests
cargo watch -x test                        # watch mode
trunk serve                                # build/serve schemify-display as WASM
```

`schemify-sim` consumes PySpice via the `PYSPICE_MODULE_DIR` env var exported by the dev shell; there is no `maturin`/PyO3 build step.

## Architecture

Workspace of 7 crates — see `CONTEXT-MAP.md` for the dependency graph and what lives where.
Each crate has its own `CONTEXT.md` and `docs/adr/` for context-scoped domain docs and decisions.

| Crate            | Purpose                                                                                              |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| schemify-core    | Shared types that cross crate boundaries — `Sym`, `DeviceKind`, `Schematic`/`Instance`/`Wire`, `Command`, `SimResult`, `Pdk`. **Zero logic, zero state.** |
| schemify-handler | App state + the `dispatch(Command)` API. Owns the string interner, undo/redo, selection, viewport. Exposes an opaque `App`. |
| schemify-io      | File I/O, format parsing, project config and persistence.                                            |
| schemify-display | egui/eframe GUI (`cdylib` + `rlib`, builds to WASM). Reads `handler` accessors, dispatches `Command`s. |
| schemify-sim     | SPICE IR and multi-dialect netlist emission; runs SPICE via PySpice, produces `SimResult`.           |
| schemify-plugins | Plugin runtime — subprocess (C-ABI) and optional WASM (`wasmtime`) transports.                       |
| schemify-engine  | The `schemify` binary: clap CLI that launches the GUI or runs a `Command` headless.                  |

---

## Engineering Principles

These are not aspirations. They are the standard. If a change violates one, the change is wrong, not the rule.

### Clean code = reusable code

A function with one reason to change is reusable; one tangled in caller state is not. Push side effects to the edges, keep the core pure. Reach for traits only when there are two real implementations, never for "what if". Small orthogonal pieces compose; clever monoliths don't. Delete code that isn't called — dead branches are the most expensive code in the repo.

### Clean API

The public surface is **`schemify-handler`**: an opaque `App`, the single `dispatch(Command)` entry point, and read-only accessors (`zoom()`, `is_instance_selected(idx)`, `resolve(Sym) -> &str`, …). Consumers never see `AppState` or its internals. `Command` and the shared data types live in `schemify-core`. Constructors are the **only** place invariants are validated; once a value exists, every downstream function trusts it. No public function takes more than three positional arguments — past that it's a `Config` struct with a builder. Public types are `#[non_exhaustive]` so we can extend without breaking semver. Internal types stay `pub(crate)`. Names describe what, not how: `app.dispatch(cmd)` not `app.intern_then_mutate_then_push_undo()`.

### Inter-crate boundaries — pure functions across the workspace

Crates talk to each other through **pure functions** wherever possible. Input in, output out, no hidden state, no mandatory call order, no required callbacks. This is what makes each crate independently testable and debuggable: you can reproduce a `schemify-sim` bug with three lines that build a `Schematic` and call the netlist emitter — no GUI, no handler, no plugin host needed.

Follow Casey Muratori's five characteristics of reusable APIs (from _Designing and Evaluating Reusable Components_, 2004):

- **Granularity.** Every high-level entry point must be replaceable by a few lower-level entry points doing the same work. If `dispatch(cmd)` exists, the steps it performs (intern strings → mutate document → push undo entry) must also be reachable. No high-level function may hide functionality you can't reach otherwise.
- **Redundancy.** One canonical way to do each thing. Don't ship two netlist emitters with overlapping behavior. Convenience wrappers are fine — duplicate paths with subtly different semantics are not.
- **Coupling.** No hidden ordering between calls. If `f()` must be called before `g()`, the type system enforces it (typestate, or `g` consumes the value `f` produced). "Remember to call `init` first" is a bug, not documentation.
- **Retention.** Immediate-mode at the granular tier: pass the data in, get the result out. Retained-mode structures (`App` holding state across frames) exist only as convenience layers built **on top of** the immediate-mode primitives, never instead of them.
- **Flow control.** The caller drives. Crates expose functions the caller invokes; they don't take callbacks, demand a trait `impl`, or spawn threads behind the user's back. If iteration is needed, return an `Iterator`, don't take a `FnMut`.

Write the usage code first. Before adding a public function, write the three lines a caller would use to invoke it. If those three lines are awkward, the function is wrong — fix it before writing the body.

### Data-oriented design (ADR-004)

Consult the data-oriented design skill before touching hot data structures. The real wins already in the codebase:

- **String interning:** `Sym` (4 bytes, `lasso::Spur`) replaces `String` (24 bytes) in hot types. The interner lives in `handler`; resolve via `app.resolve(sym)`.
- **SoA:** `Instance` (~36 bytes) and `Wire` (~26 bytes) derive `soa_derive` so bulk loops touch positions without dragging in props/color. Prefer SoA over AoS when a loop touches a subset of fields.
- **Property pool:** instances index a shared `Vec` with `(start, count)` instead of owning a `Vec` each.
- **Packed types:** `#[repr(u8)]` enums (`DeviceKind`, `Tool`, …), `InstanceFlags(u8)`, `Color::NONE` as a "use theme default" sentinel.

Hot loops iterate `Vec<T>` packed by access pattern — never `Vec<Box<dyn Trait>>`. Indices (`u32`/`Sym`) beat pointers: smaller, `Copy`, serializable, cache-friendly. Use `IdVec<Id, T>` over `HashMap<Id, T>` when keys are dense. Sort data by access order before the loop, not inside it.

### No hidden allocations

- Hot paths take `&mut Vec<T>` buffers; they do **not** return `Vec<T>`.
- `SmallVec<[T; N]>` for things bounded by topology (pins/device, wire endpoints).
- `&str` over `String` in arguments; `Cow<'a, str>` only when ownership is genuinely conditional. Prefer passing `Sym` and resolving at the edge.
- Iterator chains stay lazy. `.collect()` belongs at API boundaries, not inside loops.
- `Box`, `Rc`, `Arc`, `clone()` on a `Vec` — each needs a one-line justification in the commit message.
- Per-frame render code must not allocate proportional to the schematic. Iterate the SoA fields in place; build geometry into a reused scratch buffer.

### Performance

Pick the algorithm with the best constant factor for **our** `n`, not the asymptotically optimal one. A schematic has thousands of instances/wires, not millions — a flat `Vec` scan with good cache behavior beats a fancy spatial index at this scale. Document the chosen complexity at the top of any non-trivial algorithm module:

```rust
//! Connectivity rebuild: O(n) over wires + instances, grid-hashed endpoints.
//! Re-run only on topology-changing Commands, not every frame.
```

Profile before optimizing; benchmark with `criterion` in `benches/`. A "faster" change without a benchmark is a guess.

### Compact types — without tradeoffs

Use the smallest integer that **provably** can't overflow for our problem. Overflow is a correctness bug, not a performance bug — when in doubt, go wider.

```rust
/// Interned string handle. 4 bytes; resolve via the handler's interner.
pub type Sym = lasso::Spur;

/// Device classification, 0..=255. `#[repr(u8)]`, Unknown = 0.
#[repr(u8)] pub enum DeviceKind { /* ... */ }

/// Per-instance flags packed into one byte.
pub struct InstanceFlags(pub u8);

/// Schematic grid coordinate. Signed integer grid units.
pub x: i32,
```

Each alias/field documents its bound. If you can't write that bound comment honestly, the type is too small.

### Type-driven safety

The type system is a tool. Use it.

- **Newtypes for handles.** `Sym` is a distinct interned handle, not a bare `u32` you can do arithmetic on. Resolution is explicit: `app.resolve(sym) -> &str`.
- **Opaque state.** `App` hides `AppState`; consumers cannot reach in and mutate fields. All change flows through `dispatch(Command)`.
- **Enums over booleans.** `Tool::Wire` / `DeviceKind::Nmos4` beat `is_wire: bool` — adding a variant later becomes an exhaustive-match prompt instead of a silent bug.
- **Typestate / consuming APIs** where call ordering matters — encode "remember to call X first" in the types, never in a comment.
- **Sealed traits** for our extension points: marker `Sealed` in a private module. Open traits leak internals into semver.
- **Generics where they cost nothing.** Go generic only when there are real call sites for each instantiation — not for the feel of it.

---

## Coordinates, interning & state — the load-bearing invariants

- **Geometry** is stored as **`i32` grid coordinates** in `schemify-core` (`x`, `y`, `x0/y0/x1/y1`, `radius`, `width/height`). Only angles are `f32`. There are **no** physical units (picometers, nm) in the schematic model — those belong to a fabrication P&R tool, not a schematic editor. The `display` crate maps grid → screen via the viewport's zoom/pan.
- **Strings** are interned to `Sym`. The interner is owned by `handler`; a `Sym` is only valid within its interner's lifetime. Resolve at the edge with `app.resolve(sym)`; don't store resolved `&str` across frames.
- **All mutation goes through `dispatch(Command)`.** No setters, no `&mut` leaks out of `handler`. Every `Command` is undoable (single flat `Command` enum — ADR-003).
- **Core has zero logic.** Only `#[derive]` impls and trivial constructors live in `schemify-core`.
- **Data flows one way.** `handler` never depends on `display`. Input → `display` builds a `Command` → `app.dispatch(cmd)` → `handler` mutates private state + pushes undo → `display` reads back via accessors and renders.

---

## Workflow

### One issue, one commit

Every issue is an atomic unit of work. When an issue's acceptance criteria are met and all tests pass (`cargo nextest run`), **create a commit immediately** before moving to the next issue. Do not batch multiple issues into one commit. The commit message references the issue: `feat(core): DeviceKind classification enum [core/01]`. This keeps `git bisect` useful and makes reverts surgical.

---

## Code Style

- Schematic geometry stored as `i32` grid coordinates; strings interned to `Sym`.
- Errors via `thiserror`; library code returns `Result<T, E>`. `panic!` / `unwrap` forbidden outside tests. `expect("…")` allowed only with a message explaining why the invariant holds.
- `#[cfg(test)]` modules in each file; integration tests in `tests/`; benchmarks in `benches/`.
- `#[derive(Serialize, Deserialize)]` on all public types for JSON debug/cache.
- `cargo fmt` and `cargo clippy --all-targets -- -D warnings` are CI-enforced. No exceptions, no `#[allow(clippy::…)]` without a comment explaining the specific case.
- `unsafe` requires a `// SAFETY:` block citing the invariant the caller relies on and where it is established. (The plugin C-ABI boundary is the main place this shows up.)

## Agent skills

### Issue tracker

Local markdown issues under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Multi-context. `CONTEXT-MAP.md` at root, per-crate `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.
