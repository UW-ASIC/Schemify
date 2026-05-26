# SchemifyRS Plugin Examples

Plugins are **subprocess programs** that speak **JSON-RPC 2.0 over stdin/stdout** (newline-delimited).

Any language works. Write to stdout, read from stdin, handle JSON. That's it.

## Protocol Summary

```
Host -> Plugin:  stdin  (newline-delimited JSON)
Plugin -> Host:  stdout (newline-delimited JSON)
Plugin logs:     stderr (ignored by host, use for debug)
```

Every message is a single JSON object followed by `\n`. The host sends notifications and requests; the plugin sends notifications, requests, and responses.

## Lifecycle

1. Host spawns your `entry` command from `plugin.toml`
2. Host sends `lifecycle/initialize` notification with capabilities
3. Plugin registers panels, commands, overlays via notifications
4. Plugin receives state change notifications (`state/schematic_changed`, etc.)
5. Plugin can request data (`state/query_instances`, `state/query_nets`)
6. Host sends `lifecycle/shutdown` notification before stopping

## Directory Layout

```
my-plugin/
  plugin.toml      # required — manifest
  plugin.py         # or plugin.js, or compiled binary, etc.
```

## plugin.toml

```toml
[plugin]
id = "my-plugin"                    # machine name: [a-z0-9-], 3-64 chars
name = "My Plugin"                  # display name
version = "0.1.0"
description = "What it does"
entry = "python3 plugin.py"         # command to spawn (relative to plugin dir)
runtime = "subprocess"              # subprocess | wasm
api_version = 1

[capabilities]
panels = true                       # can register UI panels
commands = true                     # can register commands
overlays = false                    # can draw on canvas
theme = false                       # can override theme colors

[sandbox]
network = false
paths = [
    { path = "$PLUGIN_DIR", access = "read" },
]

[events]
listen = ["schematic_changed", "pre_save"]
```

## Examples

| Directory | Language | What it demonstrates |
|-----------|----------|----------------------|
| `python-hello/` | Python 3 | Minimal plugin — log, status bar, respond to lifecycle |
| `python-panel/` | Python 3 | Register a panel, query instances, draw overlays |
| `node-counter/` | Node.js | Register a command, maintain state, dispatch commands |
| `rust-linter/` | Rust | Compiled binary plugin, query nets, overlay markers |
| `bash-minimal/` | Bash | Absolute minimum viable plugin (~20 lines) |

## JSON-RPC Quick Reference

### Messages the host sends TO your plugin

#### Notifications (no response needed)

```jsonc
// Initialization — always sent first
{"jsonrpc":"2.0","method":"lifecycle/initialize","params":{
  "host_capabilities":{"api_version":"0.1.0","panels":true,"commands":true,
    "overlays":true,"theme":true,"query_instances":true,"query_nets":true},
  "plugin_name":"my-plugin"
}}

// Shutdown — always sent last
{"jsonrpc":"2.0","method":"lifecycle/shutdown"}

// State changes (only if subscribed via [events])
{"jsonrpc":"2.0","method":"state/schematic_changed"}
{"jsonrpc":"2.0","method":"state/selection_changed"}
{"jsonrpc":"2.0","method":"state/theme_changed","params":{
  "tokens":{"dark_mode":{"Bool":true},"accent":{"Color":[88,166,255,255]},"error":{"Color":[255,80,80,255]},...}
}}
```

#### Responses to your requests

```jsonc
// Success
{"jsonrpc":"2.0","id":1,"result":{...}}

// Error
{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"unknown method"}}
```

### Messages your plugin sends TO the host

#### Notifications (fire-and-forget)

```jsonc
// Register a panel
{"jsonrpc":"2.0","method":"panels/register","params":{
  "name":"My Panel","slot":"RightSidebar","priority":10,"default_visible":true
}}

// Register a command
{"jsonrpc":"2.0","method":"commands/register","params":{
  "name":"do_thing","description":"Does a thing","keybind":"Ctrl+Shift+T"
}}

// Update a canvas overlay
{"jsonrpc":"2.0","method":"overlay/update","params":{
  "name":"my_overlay","z_order":5,"visible":true,
  "shapes":[
    {"Line":{"x0":0,"y0":0,"x1":100,"y1":100,"color":[255,0,0,255],"width":2}},
    {"Circle":{"cx":50,"cy":50,"radius":10,"stroke":[0,255,0,255],"fill":null,"width":1}},
    {"Rect":{"x":10,"y":10,"w":80,"h":40,"stroke":[0,0,255,255],"fill":[0,0,255,40],"width":1}},
    {"Text":{"x":20,"y":30,"content":"hello","color":[255,255,255,255],"size":14}},
    {"Marker":{"x":50,"y":50,"kind":"Error","color":[255,0,0,255]}}
  ]
}}

// Override theme colors
{"jsonrpc":"2.0","method":"theme/override","params":{
  "priority":5,"overrides":{"accent":{"Color":[255,0,128,255]}}
}}

// Dispatch a schematic command
{"jsonrpc":"2.0","method":"commands/dispatch","params":{"action":"zoom_in"}}

// Set status bar message
{"jsonrpc":"2.0","method":"host/set_status","params":{"message":"Processing..."}}

// Log (appears in host logs, not UI)
{"jsonrpc":"2.0","method":"host/log","params":{"level":"info","message":"started"}}
```

#### Requests (expect a response back)

```jsonc
// Query all instances in the schematic
{"jsonrpc":"2.0","id":1,"method":"state/query_instances"}

// Query all nets
{"jsonrpc":"2.0","id":2,"method":"state/query_nets"}

// Query current resolved theme tokens
{"jsonrpc":"2.0","id":3,"method":"state/query_theme"}
```

### Overlay Shapes

| Shape | Fields |
|-------|--------|
| `Line` | `x0, y0, x1, y1, color: [r,g,b,a], width` |
| `Circle` | `cx, cy, radius, stroke: [r,g,b,a], fill: [r,g,b,a]\|null, width` |
| `Rect` | `x, y, w, h, stroke, fill, width` |
| `Text` | `x, y, content, color, size` |
| `Marker` | `x, y, kind: "Error"\|"Warning"\|"Info"\|"Pin", color` |

### Panel Slots

`LeftSidebar`, `RightSidebar`, `BottomBar`, `Toolbar`, `MenuBar`, `CanvasOverlay`, `StatusBar`

### Widget Trees (panel content)

Push a widget tree to populate your registered panel:

```jsonc
{"jsonrpc":"2.0","method":"panels/update_widgets","params":{
  "panel":"My Panel",
  "widgets":[
    {"Heading": "Status"},
    {"Label": "All good"},
    {"Button": {"label": "Run", "action": "run_check"}},
    {"Toggle": {"label": "Auto-run", "value": true, "action": "set_auto"}},
    {"Separator": null},
    {"Alert": {"level": "info", "message": "3 nets checked"}},
    {"Badge": {"text": "OK", "color": "success"}},
    {"ProgressBar": {"value": 0.75, "color": "accent"}}
  ]
}}
```

### ThemeColor

Color fields in widgets (`Badge.color`, `ProgressBar.color`, `RichText.color`) accept either:
- **Literal RGBA**: `[255, 0, 128, 255]`
- **Theme token reference**: `"accent"`, `"error"`, `"warning"`, `"success"`, `"text_primary"`

Token references resolve against the host's active theme, so your plugin UI automatically adapts to dark/light mode and user customizations.

Available tokens: `bg_primary`, `bg_secondary`, `bg_panel`, `text_primary`, `text_dim`, `accent`, `border`, `error`, `warning`, `success`, `canvas_bg`, `grid_color`, `wire_default`, `wire_selected`, `pin_color`, `symbol_stroke`, `symbol_fill`, `label_color`.

### Error Codes (standard JSON-RPC)

| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
