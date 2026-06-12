# Plugin SDK Reference

Everything lives in `schemify_plugins::sdk`. Your plugin implements the
`Plugin` trait and runs inside a `PluginRuntime`.

## The `Plugin` trait

All callbacks are optional (default no-op):

```rust
trait Plugin {
    fn on_initialize(&mut self, rt: &mut PluginRuntime, event: InitializeEvent) -> Result<(), RuntimeError>;
    fn on_shutdown(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError>;
    fn on_command(&mut self, rt: &mut PluginRuntime, cmd: CommandInvocation) -> Result<(), RuntimeError>;
    fn on_ui_action(&mut self, rt: &mut PluginRuntime, action: UiAction) -> Result<(), RuntimeError>;
    fn on_schematic_changed(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError>;
    fn on_selection_changed(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError>;
    fn on_theme_changed(&mut self, rt: &mut PluginRuntime, theme: ThemeTokens) -> Result<(), RuntimeError>;
    fn on_response(&mut self, rt: &mut PluginRuntime, response: ResponseMessage) -> Result<(), RuntimeError>;
    fn on_notification(&mut self, rt: &mut PluginRuntime, method: String, params: Option<Value>) -> Result<(), RuntimeError>;
}
```

## `PluginRuntime` API

### Panels

```rust
rt.register_panel("My Panel", PanelLayout::RightSidebar, priority, default_visible)?;
rt.update_widgets("My Panel", vec![...])?;
```

### Commands

```rust
rt.register_command("do_thing", "Does the thing", Some("Ctrl+T"))?;
```

### Overlays

```rust
rt.update_overlay("my-layer", z_order, visible, vec![
    OverlayShape::Marker { x, y, kind: MarkerKind::Warning, color: [255, 180, 0, 200] },
    OverlayShape::Line { x0, y0, x1, y1, color: [255, 0, 0, 255], width: 2.0 },
    OverlayShape::Circle { cx, cy, radius, stroke, fill: None, width: 1.0 },
])?;
```

### Theme

```rust
rt.set_theme_override(priority, [
    ("accent".into(), ThemeValue::Color([0, 120, 255, 255])),
])?;
```

### Queries

```rust
let instances: Vec<InstanceRecord> = rt.query_instances()?;
let nets: Vec<NetRecord> = rt.query_nets()?;
let theme: ThemeTokens = rt.query_theme()?;
let project: ProjectRecord = rt.query_project()?;      // project_dir, pdk, pdk_path
let pdk: Option<PdkRecord> = rt.query_pdk()?;          // active PDK (lib, corners, cells)
let netlist: NetlistRecord = rt.query_netlist()?;      // SPICE + instance↔refdes map
let opts = rt.query_optimizers(None)?;                  // optimizer summaries (raw JSON)
let state = rt.query_optimizers(Some(0))?;              // one optimizer's full state
```

`InstanceRecord` fields: `idx`, `name`, `symbol`, `kind`, `x`, `y`, `rotation`, `flip`,
`props` (`[key, value]` pairs: W, L, model, …).

`NetRecord` fields: `idx`, `name`.

### Host actions

```rust
rt.dispatch_action("undo")?;         // trigger a host command (snake_case)
rt.dispatch_command(json!({          // full editor command, same JSON as CLI/MCP
    "SetInstanceProp": {"idx": 3, "key": "W", "value": "2u"}
}))?;
rt.set_status("Ready")?;             // set status bar text
rt.info("something happened")?;      // log to host
rt.log("warn", "low battery")?;      // log with level
```

### Raw JSON-RPC

```rust
let value: Value = rt.request_json("custom/method", Some(json!({"key": "val"})))?;
```

## Widget types

Widgets are passed as `Vec<WidgetNode>` to `update_widgets`.

### Text
- `WidgetNode::Label("text".into())`
- `WidgetNode::Heading("title".into())`
- `WidgetNode::Code("let x = 1;".into())`
- `WidgetNode::RichText { text, color, bold, italic, size }`

### Actions
- `WidgetNode::Button { label, action }` — dispatches `action` string to `on_ui_action`
- `WidgetNode::LinkButton { label, action }`

### Input
- `WidgetNode::Toggle { label, value, action }` — sends bool
- `WidgetNode::RadioGroup { label, options, selected, action }` — sends index
- `WidgetNode::Dropdown { label, options, selected, action }` — sends index
- `WidgetNode::Slider { label, min, max, value, step, action }` — sends f64
- `WidgetNode::NumberInput { label, value, min, max, step, action }` — sends f64
- `WidgetNode::TextInput { label, value, placeholder, action }` — sends string
- `WidgetNode::ColorPicker { label, color, action }` — sends [r,g,b,a]

### Display
- `WidgetNode::ProgressBar { label, value, color }`
- `WidgetNode::KeyValue { entries: vec![["Key".into(), "Val".into()]] }`
- `WidgetNode::Table { headers, rows, action }` — optional `action` sends row index
- `WidgetNode::Alert { level: AlertLevel::Warn, message }` — Info/Warn/Error/Success
- `WidgetNode::Badge { text, color }`

### Layout
- `WidgetNode::Separator`
- `WidgetNode::Spacer(16.0)` — height in pixels
- `WidgetNode::Section { label, collapsed, children }` — collapsible
- `WidgetNode::Tabs { labels, selected, action, children }` — tabbed pane
- `WidgetNode::Horizontal { children }` — horizontal row
- `WidgetNode::Group { label, children }` — boxed group

### Media
- `WidgetNode::Image { path, width, action }` — PNG/SVG from a file path;
  optional `action` sends `[x, y]` relative click coords (0.0–1.0)
