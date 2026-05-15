# CLAUDE.md — &lt;project&gt;

Full-Zig GUI [library / application]. _One-line description — fill in._

## Build & Test

```bash
nix develop                                # enter dev shell (if applicable)
zig build                                  # build the project
zig build test                             # run all tests
zig build run                              # build and run
zig build -Doptimize=ReleaseFast           # release build
zig build --watch                          # watch mode (zig 0.14+)
```

## Architecture

Modules under `src/`. See `CONTEXT-MAP.md` for relationships.

| Module  | Purpose                                                |
| ------- | ------------------------------------------------------ |
| core    | Foundational types: rect, point, id, color, units      |
| input   | Per-frame input snapshot — keyboard, mouse, touch      |
| layout  | Layout solver: spec tree in, rectangles out            |
| draw    | Draw command list, batching, command emission          |
| render  | Backend rendering (OpenGL / Vulkan / Metal / software) |
| widgets | Widget implementations: button, slider, text input, …  |
| text    | Font loading, glyph cache, shaping                     |
| app     | Frame loop, window, event pump                         |

---

## Engineering Principles

These are not aspirations. They are the standard. If a change violates one, the change is wrong, not the rule.

### Clean code = reusable code

A function with one reason to change is reusable; one tangled in caller state is not. Push side effects to the edges, keep the core pure. Reach for vtables or `comptime` interfaces only when there are two real implementations, never for "what if". Small orthogonal pieces compose; clever monoliths don't. Delete code that isn't called — dead branches are the most expensive code in the repo.

### Clean API

Public API at each module's top level. Constructors are the **only** place units, frames, and invariants are validated; once a value exists, every downstream function trusts it. No public function takes more than three positional arguments — past that it's a `Config` struct with sensible defaults. Internal declarations stay file-scoped (no `pub`). Names describe what, not how: `App.render()` not `App.run_render_pipeline_v2()`.

### Inter-module boundaries — pure functions

Modules talk through **pure functions** wherever possible. Input in, output out, no hidden state, no mandatory call order, no required callbacks. This is what makes each module independently testable and debuggable: you reproduce a layout bug with three lines constructing a node tree and calling `layout()` — no input system, no renderer, no app loop needed.

Follow Casey Muratori's five characteristics of reusable APIs (_Designing and Evaluating Reusable Components_, 2004):

- **Granularity.** Every high-level entry point must be replaceable by a few lower-level ones doing the same work. If `frame()` exists, `pollInput` → `buildUI` → `layout` → `render` must also be callable. No high-level function may hide functionality you can't reach otherwise.
- **Redundancy.** One canonical way to do each thing. Convenience wrappers fine; duplicate paths with subtly different semantics are not.
- **Coupling.** No hidden ordering. If `f()` must run before `g()`, the type system enforces it (distinct types per state, or `g` consumes the result of `f`). "Remember to call `init` first" is a bug, not documentation.
- **Retention.** Immediate-mode at the granular tier: data in, result out. Retained-mode structures exist only as convenience layers built **on top of** the immediate-mode primitives, never instead of them.
- **Flow control.** The caller drives. Modules expose functions the caller invokes; they don't take callbacks, register listeners, or spawn threads behind the user's back. If iteration is needed, return an iterator type, don't take a `fn` pointer.

Write the usage code first. Before adding a public function, write the three lines a caller would use. If those three lines are awkward, the function is wrong — fix it before writing the body.

### Data-oriented design

Hot loops iterate `[]T` packed by access pattern — never `[]*SomeInterface`. Prefer SoA (parallel slices of fields) over AoS when the loop touches a subset of fields. Indices (`u32`, often smaller) beat pointers: smaller, copyable, serializable, cache-friendly. Use dense arrays keyed by integer IDs over hash maps when keys are dense. Sort data by access order before the loop, not inside it.

### No hidden allocations

Zig makes this easy — every allocation goes through an explicit `Allocator`. Use that affordance ruthlessly.

- Public functions that allocate take an `Allocator` parameter. Always.
- Per-frame work uses an **arena** that is `reset()` at frame end. The render loop allocates zero from the general heap.
- Hot paths take `*std.ArrayList(T)` buffers; they do **not** return owned slices.
- Bounded collections use `std.BoundedArray(T, N)` when N is known at comptime.
- `[]const u8` over `[]u8` for strings you don't own. `[:0]const u8` only at FFI boundaries.
- Never allocate a buffer proportional to screen pixels in the per-frame loop. If you must, allocate once at init.
- Every `alloc` has a matching `defer` or `errdefer` on the next line. No exceptions.
- A general-purpose allocator inside a hot path needs a one-line justification in the commit.

### Performance

Pick the algorithm with the best constant factor for **our** `n`, not the asymptotically optimal one. For 200 widgets, an O(n²) layout pass with a tight inner loop beats an O(n) one with a hash map. Document the chosen complexity at the top of every algorithm:

```zig
//! Layout: O(n) two-pass (measure + position).
//! Cached when input tree hash is unchanged.
```

Profile before optimizing; benchmark in `bench/`. A "faster" change without a benchmark is a guess.

### Compact types — without tradeoffs

Use the smallest integer that **provably** can't overflow. Overflow is a correctness bug, not a performance bug — when in doubt, go wider.

```zig
/// Widget id within a frame. Frame is rebuilt each tick; 65k widgets is plenty.
pub const WidgetId = u16;

/// Color channel, 0..=255. sRGB 8-bit.
pub const Channel = u8;

/// Subpixel coordinate. 1/64 pixel, signed. ±33 million pixels of range.
pub const SubPx = i32;
```

Each alias documents its bound. If you can't write that bound comment honestly, the type is too small.

### Type-driven safety

Zig's type system is leaner than Rust's but still does real work. Use it.

- **Distinct types for units.** `Point` and `Vector` (a delta between points) are different structs. You cannot add two points; you can add a vector to a point.
- **Distinct types for coordinate spaces.** `ScreenPx`, `LogicalPx`, `SubPx` are separate types. Conversion is explicit and named.
- **Tagged unions for variants.** `union(enum) { button: Button, slider: Slider, ... }` beats a struct with a `kind` field and optional payloads. Exhaustive `switch` catches missing cases at compile time.
- **`comptime` generics** when there are real call sites for each instantiation. Don't go generic for the feel of it.
- **Narrow error sets.** `error{InvalidLayout,OutOfMemory}!T` says exactly what can go wrong. `anyerror` is for outer boundaries only.
- **`enum` over `bool` parameters.** `Direction.horizontal` is clearer than `is_horizontal: bool`, and adding `.diagonal` later becomes an exhaustive-switch prompt instead of a silent bug.
- **Distinct types per state**, where Zig's lack of typestate would otherwise let stale handles slip through. If `Layout` becomes `LaidOut` after solving, make them separate types and have the solve function consume the input.

### GUI design — immediate-mode, single-path

The UI is built every frame from application state. Casey Muratori coined "Single-path Immediate Mode" in 2002 for exactly this reason: it eliminates the entire class of bugs that come from synchronizing a retained widget tree with application data.

- **The application owns all state.** The UI library holds only frame-scoped state — hot/active widget IDs, layout cache, draw command list. When the app exits there is nothing for the UI to "remember".
- **Widgets are function calls.** `if (ui.button("Save")) saveFile();`. No subscription, no event handler registration, no widget objects to construct and destroy.
- **Layout is data, not control flow.** Spec tree in, flat array of rectangles out. Layout allocates only from the frame arena.
- **Input is sampled once per frame.** Build an `InputFrame` snapshot at the top of the tick and pass it down. Widgets read from it; they never poll the OS mid-frame.
- **Drawing is deferred.** Widgets emit `DrawCommand`s into a list; the renderer consumes the list at end of frame, batching by texture/shader. Widgets never call the backend directly.
- **Every interactive widget has visible feedback for `idle` / `hot` / `active` / `disabled`.** Encode states in a tagged union, not scattered booleans. Animate transitions with two persistent floats per widget (`hot_t`, `active_t`) — that is the _only_ per-widget retained state we keep.
- **Keyboard reachability is a correctness property.** Every action the mouse can do, the keyboard can do. Tab order is explicit, not inferred from widget order.
- **No color-only cues.** Information conveyed by color is also conveyed by shape, position, or text. Greyscale CI render catches regressions.
- **Pixel snapping at the draw boundary, not earlier.** Logical coordinates are subpixel; the draw layer snaps to integer pixels for crisp lines. Snapping early causes accumulated rounding drift.
- **No allocation in the per-frame UI loop.** The frame arena handles everything transient. Persistent widget data (text edit buffers, scroll positions) is owned by the application and passed in.

---

## Units — defined once, never again

- **Internal storage:** subpixels at 1/64 pixel, `i32`, wrapped in `SubPx`. Sufficient for any reasonable display.
- **DPI / physical pixels:** conversion happens **only** at the window/event boundary in `app`.
- **Public API:** accepts `Length.px(12)`, `Length.dp(12)`, `Length.em(1.5)` — never raw integers.
- **Display:** human/debug output formats as logical pixels with 2 decimal places.
- A bare `i32` in a function signature is a code smell. Name the unit in the type.

Unit construction is centralized in `core/units.zig`. Adding a new unit constructor requires adding the conversion test alongside it.

---

## Code Style

- All numeric storage in the smallest provably-safe integer, wrapped in domain types.
- Errors via narrow error sets. `anyerror` only at the outermost boundary.
- `@panic` and `unreachable` are forbidden in library code outside of provably-impossible branches with a comment justifying the invariant.
- `test "..."` blocks live next to the code under test in each file. Integration tests in `tests/`.
- Every `alloc` has a matching `defer`/`errdefer` on the next line. Reviewers count these in PRs.
- `zig fmt` is CI-enforced. No exceptions.
- `@ptrCast`, `@alignCast`, and `@intCast` on untrusted input each require a `// SAFETY:` comment citing the invariant and where it is established.
