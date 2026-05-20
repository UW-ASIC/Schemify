# A3: Canvas + Interaction

## Goal
Interactive schematic canvas in egui. Renders schematic, handles input, dispatches commands. Built on A2's plugin types (theme tokens, overlay slots).

## Branch
`feat/canvas`

## Decisions (resolved)
- egui 0.31 (latest) + eframe 0.31
- Layered shape cache: each layer = `Vec<egui::Shape>`, dirty flags, rebuild only changed layers
- `AppRead` trait in core for render surface (returns core types + primitives only)
- `AppWrite` trait in core for mutations (dispatch + setters)
- Handler implements both traits
- Display depends on core (traits) + handler (impl + panel state for cold path)
- Canvas + interaction = one agent (tightly coupled coordinate systems)
- Hot path: handler does ZERO per-frame work. Display reads refs + paints cached shapes.
- Selection: expose `&HashSet<usize>` directly, not per-item queries
- Plugin overlays render as additional shape layers via `OverlayLayer` from A2

## Zig Reference Files
- `../Schemify/src/gui/lib.zig` — main frame loop
- `../Schemify/src/gui/state.zig` — AppState (for reference only, already ported)
- `../Schemify/src/gui/Canvas/lib.zig` — z-order rendering orchestration
- `../Schemify/src/gui/Canvas/render.zig` — primitive rendering
- `../Schemify/src/gui/Canvas/symbols.zig` — symbol rendering
- `../Schemify/src/gui/Canvas/wires.zig` — wire rendering + junctions
- `../Schemify/src/gui/Canvas/overlays.zig` — ghost overlays
- `../Schemify/src/gui/Canvas/interaction.zig` — mouse/keyboard + hit detection
- `../Schemify/src/gui/Canvas/types.zig` — RenderContext, CanvasEvent
- `../Schemify/src/gui/Input/` — keybinds, key mapping

## Crate/File Map

### core (`crates/core/src/`)
- NEW `traits.rs` — `AppRead`, `AppWrite` traits
- `lib.rs` — add `pub mod traits;`

### handler (`crates/handler/src/`)
- `lib.rs` — `impl AppRead for App { ... }`, `impl AppWrite for App { ... }`

### display (`crates/display/src/`)
- `main.rs` — eframe entry point, `SchemifyApp` struct
- NEW `canvas.rs` — canvas widget, coordinate transform, shape layer cache
- NEW `render.rs` — build shape layers from schematic data
- NEW `interaction.rs` — mouse/keyboard handling, hit detection, tool dispatch
- NEW `theme_bridge.rs` — `ThemeTokens` → `egui::Visuals` + custom colors
- NEW `overlay.rs` — render `OverlayLayer` shapes as egui shapes
- `lib.rs` — module declarations

### display Cargo.toml additions
```toml
[dependencies]
schemify-core = { path = "../core" }
schemify-handler = { path = "../handler" }
eframe = "0.31"
egui = "0.31"
```

## AppRead / AppWrite Traits (in core)

```rust
// core/src/traits.rs
use crate::commands::Command;
use crate::schematic::*;
use crate::types::Sym;
use std::collections::HashSet;

pub trait AppRead {
    // schematic data
    fn schematic(&self) -> &Schematic;
    fn resolve(&self, sym: Sym) -> &str;

    // viewport
    fn zoom(&self) -> f32;
    fn pan(&self) -> [f32; 2];

    // selection (batch-friendly: return set ref, not per-item)
    fn selected_instances(&self) -> &HashSet<usize>;
    fn selected_wires(&self) -> &HashSet<usize>;

    // view state
    fn show_grid(&self) -> bool;
    fn canvas_size(&self) -> [f32; 2];
    fn active_tool(&self) -> crate::commands::Tool;
}

pub trait AppWrite {
    fn dispatch(&mut self, cmd: Command);
    fn set_canvas_size(&mut self, w: f32, h: f32);
    fn set_cursor_world(&mut self, x: i32, y: i32);
}
```

## Shape Layer Architecture

```
Layer stack (bottom to top):
  0: Grid          — rebuild on zoom/pan change
  1: Wires         — rebuild on schematic wire mutation
  2: Symbols       — rebuild on schematic instance mutation
  3: Labels        — rebuild on schematic mutation
  4: Selection     — rebuild on selection change
  5: Ghost         — rebuild every frame (placement/wire preview)
  6+: Plugin[0..]  — rebuild on plugin overlay push
  N: Crosshair     — rebuild every frame
```

```rust
struct ShapeCache {
    layers: Vec<CachedLayer>,
}

struct CachedLayer {
    name: &'static str,
    shapes: Vec<egui::Shape>,
    dirty: bool,
    z_order: i32,
}
```

Dirty flag triggers:
- **Grid**: zoom or pan changed (compare prev values)
- **Wires/Symbols/Labels**: schematic generation counter bumped (handler increments on mutation)
- **Selection**: selection generation counter bumped
- **Ghost/Crosshair**: always dirty (rebuild every frame, cheap)
- **Plugin overlays**: plugin pushes new shapes (version counter per overlay)

## Coordinate System
- World coords: `i32` (schematic units, matches Zig ref's grid)
- Screen coords: `f32` (egui pixels)
- `world_to_screen(wx, wy, pan, zoom) -> (sx, sy)`
- `screen_to_world(sx, sy, pan, zoom) -> (wx, wy)`
- Canvas widget allocates rect, applies transform for all painting

## Hit Detection
- Instance: axis-aligned bounding box from `PrimEntry` geometry, transformed by rotation/flip
- Wire: point-to-segment distance < threshold (adjusted for zoom)
- Pin snap: closest pin within snap radius
- Priority: pin > instance > wire > empty canvas

## Input → Command Flow
```
egui event (click/drag/key)
  → interaction.rs (interpret based on active tool)
    → Command enum variant
      → app.dispatch(cmd)
        → handler mutates state
          → dirty flags set
            → next frame rebuilds dirty layers
```

## Checklist

### Phase 1: Scaffold
- [ ] Add `AppRead`, `AppWrite` traits to `core/src/traits.rs`
- [ ] Implement both traits on `App` in `handler/src/lib.rs`
- [ ] Create `display/src/main.rs` eframe entry point with empty canvas
- [ ] Add egui/eframe 0.31 deps to display Cargo.toml
- [ ] Theme bridge: `ThemeTokens` → `egui::Visuals` mapping
- [ ] Commit

### Phase 2: Canvas Rendering
- [ ] Canvas widget with pan (middle-drag) + zoom (scroll)
- [ ] Coordinate transform fns (world ↔ screen)
- [ ] Grid layer rendering (dots or lines based on zoom level)
- [ ] Wire rendering (color, thickness, bus style)
- [ ] Symbol rendering from `PrimEntry` geometry (segments, circles, arcs, rects, texts)
- [ ] Instance rendering (symbol + rotation/flip + translate + name/param labels)
- [ ] Selection highlight overlay
- [ ] Commit

### Phase 3: Shape Cache
- [ ] `ShapeCache` struct with dirty flag per layer
- [ ] Generation counters on handler side (schematic_gen, selection_gen)
- [ ] Rebuild only dirty layers each frame
- [ ] Plugin overlay layers rendered from `OverlayLayer` shapes
- [ ] Commit

### Phase 4: Interaction
- [ ] Hit detection (instance bbox, wire proximity, pin snap)
- [ ] Select tool: click-select, shift-click multi-select, rubber-band
- [ ] Move tool: drag selected instances/wires
- [ ] Wire tool: click-click orthogonal wire drawing
- [ ] Pan tool: drag to pan (also middle-mouse in any tool)
- [ ] Draw tools: line, rect, circle, arc, text placement
- [ ] Keyboard shortcuts → Command dispatch
- [ ] Context menu (right-click)
- [ ] Commit

### Phase 5: Ghost Overlays
- [ ] Placement preview (symbol follows cursor)
- [ ] Wire-in-progress preview
- [ ] Rubber-band rectangle
- [ ] Crosshair at cursor
- [ ] Commit

## Do NOT Touch
- `handler/src/dispatch.rs` — commands already handled
- `handler/src/state.rs` — state types already defined
- `sim/` — not your crate
- `plugins/` — not your crate (you consume A2 types, don't define them)
- Don't add handler-internal state types to core (use traits only)

## Soft Dependencies
- **A2 (plugin types)**: need `ThemeTokens`, `OverlayLayer`, `SlotId` from core. If A2 not done yet, stub with local types and swap later.
- **A1 (connectivity)**: nice-to-have for net highlighting. Render without it initially — just draw wires with default colors.
