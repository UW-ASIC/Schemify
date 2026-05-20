# A2: Plugin Interface Types

## Goal
Define plugin extension point types in core. Slots, theme tokens, canvas overlay API. These types are consumed by display (A3) and later by plugin runtime (wave 2).

## Branch
`feat/plugin-types`

## Decisions (resolved)
- Plugin scope: panels + commands + canvas overlays + theme/layout override
- Slot + hook model (not widget tree) — named slots, priority ordering
- Token-level theme: flat map of ~30-50 named tokens (colors, spacing, bools)
- `ThemeTokens` + `ThemeValue` enum in core
- Overlay = named layer that provides `Vec<OverlayShape>` (serializable, no egui dep in core)
- Plugin panels register into named slots with priority
- All types in `core/src/` — they cross plugin/display/handler boundaries
- Core stays logic-free: only types + derives + trivial constructors

## Zig Reference Files
- `../Schemify/src/plugins/types.zig` — PanelDef, WidgetTag, PluginState
- `../Schemify/src/plugins/Capability.zig` — capability negotiation types
- `../Schemify/src/gui/PluginPanels.zig` — panel rendering types
- `../Schemify/src/gui/Palette.zig` — color palette / theme
- `../Schemify/src/gui/theme.zig` — theme system
- `../Schemify/src/gui/Canvas/types.zig` — RenderContext

## Crate/File Map

### core (`crates/core/src/`)
- NEW `plugin_types.rs` — slot, panel, command, overlay types
- NEW `theme.rs` — theme token system
- `lib.rs` — add `pub mod plugin_types; pub mod theme;`

## Theme Token System

```rust
// core/src/theme.rs

#[derive(Debug, Clone)]
pub struct ThemeTokens {
    pub tokens: HashMap<String, ThemeValue>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ThemeValue {
    Color([u8; 4]),     // RGBA
    Float(f32),         // spacing, line width, font size
    Bool(bool),         // dark_mode, show_grid
    Int(i32),           // grid spacing, snap size
}
```

### Default tokens (~30-50):
**UI tokens**: `bg_primary`, `bg_secondary`, `bg_panel`, `text_primary`, `text_dim`, `accent`, `border`, `error`, `warning`, `success`
**Canvas tokens**: `canvas_bg`, `grid_color`, `grid_major_color`, `wire_default`, `wire_bus`, `wire_selected`, `selection_fill`, `selection_stroke`, `ghost_color`, `crosshair_color`, `pin_color`, `symbol_stroke`, `symbol_fill`, `label_color`
**Spacing tokens**: `grid_spacing`, `snap_size`, `wire_thickness`, `symbol_stroke_width`, `selection_stroke_width`, `font_size_label`, `font_size_param`
**Bool tokens**: `dark_mode`, `show_grid`, `show_crosshair`, `fill_symbols`

## Slot System

```rust
// core/src/plugin_types.rs

/// Named locations where plugins can insert content
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SlotId {
    LeftSidebar,
    RightSidebar,
    BottomBar,
    Toolbar,
    MenuBar,
    CanvasOverlay,
    StatusBar,
}

/// A plugin-registered panel
#[derive(Debug, Clone)]
pub struct PanelRegistration {
    pub plugin_id: String,
    pub name: String,
    pub slot: SlotId,
    pub priority: i32,       // lower = earlier in slot
    pub default_visible: bool,
}

/// A plugin-registered command
#[derive(Debug, Clone)]
pub struct CommandRegistration {
    pub plugin_id: String,
    pub name: String,
    pub description: String,
    pub keybind: Option<String>,
}
```

## Canvas Overlay API

```rust
// core/src/plugin_types.rs

/// Serializable overlay shape (no egui dependency)
#[derive(Debug, Clone)]
pub enum OverlayShape {
    Line { x0: f32, y0: f32, x1: f32, y1: f32, color: [u8; 4], width: f32 },
    Circle { cx: f32, cy: f32, radius: f32, stroke: [u8; 4], fill: Option<[u8; 4]>, width: f32 },
    Rect { x: f32, y: f32, w: f32, h: f32, stroke: [u8; 4], fill: Option<[u8; 4]>, width: f32 },
    Text { x: f32, y: f32, content: String, color: [u8; 4], size: f32 },
    Marker { x: f32, y: f32, kind: MarkerKind, color: [u8; 4] },
}

#[derive(Debug, Clone, Copy)]
pub enum MarkerKind {
    Error,      // DRC violation
    Warning,    // advisory
    Info,       // annotation
    Pin,        // pin highlight
}

/// A named overlay layer from a plugin
#[derive(Debug, Clone)]
pub struct OverlayLayer {
    pub plugin_id: String,
    pub name: String,
    pub z_order: i32,        // relative to built-in layers
    pub visible: bool,
    pub shapes: Vec<OverlayShape>,
}
```

## Theme Override API

```rust
// core/src/plugin_types.rs

/// Plugin's theme modifications
#[derive(Debug, Clone, Default)]
pub struct ThemeOverride {
    pub plugin_id: String,
    pub priority: i32,       // higher priority wins on conflict
    pub overrides: HashMap<String, ThemeValue>,
}
```

## Checklist
- [ ] Create `core/src/theme.rs` with `ThemeTokens`, `ThemeValue`, default token set
- [ ] Create `core/src/plugin_types.rs` with `SlotId`, `PanelRegistration`, `CommandRegistration`
- [ ] Add `OverlayShape`, `MarkerKind`, `OverlayLayer` to plugin_types
- [ ] Add `ThemeOverride` to plugin_types
- [ ] Add `pub mod theme; pub mod plugin_types;` to `core/src/lib.rs`
- [ ] Derive `serde::Serialize, Deserialize` on overlay types (for JSON-RPC in wave 2)
- [ ] Add `serde` dependency to core's Cargo.toml (with `derive` feature)
- [ ] Default theme constructor: `ThemeTokens::dark()`, `ThemeTokens::light()`
- [ ] `ThemeTokens::with_overrides(&self, overrides: &[ThemeOverride]) -> ThemeTokens`
- [ ] Tests: default dark theme has all expected tokens
- [ ] Tests: override replaces token value
- [ ] Tests: priority ordering on conflicting overrides
- [ ] Commit after each meaningful change

## Do NOT Touch
- `handler/` — not your crate
- `display/` — not your crate (A3 consumes these types)
- `sim/` — not your crate
- No rendering logic — these are pure data types
- Don't add egui as a dependency to core
