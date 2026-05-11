# Schemify Plugin System v2 — Design Sketch

## Philosophy

Give plugin creators **full control** over their domain while keeping the host safe.
Take the best from both VS Code (declarative manifest, provider pattern, structured contributions)
and Neovim (imperative power, direct buffer manipulation, composability).

The current system is a solid foundation — flat binary ABI, 7 language SDKs, crash isolation,
capability gating. This design evolves it rather than replacing it.

---

## 1. Declarative Manifest (`plugin.toml`)

**Problem:** Today, plugins imperatively register panels, commands, and keybinds at load time.
The host must load and execute every plugin just to know what it offers. This blocks lazy loading,
prevents showing UI contributions (menus, command palette entries) before a plugin is active,
and makes the marketplace registry a separate, manually-maintained artifact.

**Solution:** Every plugin ships a `plugin.toml` manifest. The host reads these without loading
the plugin binary. The current `registry.json` becomes auto-generated from manifests.

```toml
[plugin]
id = "ccreator"
name = "CCreator"
version = "1.2.0"
author = "UW-ASIC"
description = "Circuit creation, PDK switching, and gm/Id optimization"
license = "MIT"
abi = 9                          # minimum ABI version required
engine = ">=0.8.0"               # minimum Schemify version

[capabilities]
file_read_project = true
file_write_plugin_data = true
schematic_mutate = true
network = false
canvas_draw = true
menu_contribute = true
shell_exec = false               # spawn subprocesses (dangerous, user must approve)

# --- Static contributions (parsed without loading the plugin) ---

[[panels]]
id = "ccreator-main"
title = "CCreator"
layout = "right_sidebar"          # overlay | left_sidebar | right_sidebar | bottom_bar
icon = "assets/icon.png"
vim_command = "ccreator"
keybind = { key = "c", mods = ["ctrl", "shift"] }

[[panels]]
id = "ccreator-code"
title = "Code Editor"
layout = "bottom_bar"
vim_command = "ccreator-code"

[[commands]]
tag = "ccreator_embed"
name = "CCreator: Embed Circuit"
description = "Embed Python circuit generator into schematic"
keybind = { key = "e", mods = ["ctrl", "shift"] }

[[commands]]
tag = "ccreator_sync"
name = "CCreator: Sync from Schematic"
description = "Sync embedded Python from schematic PLUGIN block"

[[menus]]
location = "context.instance"     # right-click on instance
label = "Open in CCreator"
command = "ccreator_open_instance"
when = "selection.type == 'instance'"

[[menus]]
location = "menubar.tools"
label = "CCreator"
command = "ccreator_toggle_panel"

# Activation events — plugin binary loaded only when one of these fires.
[activation]
events = [
    "onCommand:ccreator_*",        # any command matching glob
    "onPanel:ccreator-*",          # user opens a declared panel
    "onFileType:*.chn_prim",       # file with matching extension opened
    "onStartup",                   # always load (escape hatch)
]

[build]
binary = "libccreator.so"
wasm = "ccreator.wasm"
```

**Key design choices:**
- `[capabilities]` — user reviews at install time (like Android permissions), replaces runtime assignment
- `[[commands]]` and `[[panels]]` — host renders these without loading the binary
- `[activation]` — true lazy loading; host shows greyed panel stubs / palette entries until triggered
- `[[menus]]` — context menus + menubar with optional `when` conditions
- `[build]` — declares binary locations, replaces path-guessing in PluginManager.zig

---

## 2. Activation & Lifecycle

### Current
```
dlopen → load → tick(60Hz) → draw_panel → events → unload → dlclose
```

### Proposed
```
    ┌──────────────────────────────────────────────────┐
    │              MANIFEST ONLY                       │
    │  Host reads plugin.toml at startup.              │
    │  Panels appear in sidebar (greyed/stub).         │
    │  Commands appear in palette.                     │
    │  Menus appear in context/menubar.                │
    │  Plugin binary is NOT loaded.                    │
    └────────────────────┬─────────────────────────────┘
                         │ activation event fires
                         ▼
    ┌──────────────────────────────────────────────────┐
    │              LOADING                             │
    │  dlopen + send `load` message.                   │
    │  Plugin confirms manifest panels/commands,       │
    │  can register additional dynamic ones.           │
    │  Plugin calls register_provider (new).           │
    └────────────────────┬─────────────────────────────┘
                         │
                         ▼
    ┌──────────────────────────────────────────────────┐
    │              ACTIVE                              │
    │  tick / draw / events as today.                  │
    │  Provider calls on demand.                       │
    │  Canvas drawing.                                 │
    └────────────────────┬─────────────────────────────┘
                         │ user disables / crash
                         ▼
    ┌──────────────────────────────────────────────────┐
    │              SUSPENDED / FAILED                  │
    │  No ticks, no draws, no providers.               │
    │  Static contributions remain visible (greyed).   │
    │  Can be reactivated.                             │
    └──────────────────────────────────────────────────┘
```

**Activation events:**

| Event | Fires when |
|-------|-----------|
| `onStartup` | Schemify starts (current behavior, opt-in) |
| `onCommand:<glob>` | User invokes a matching command |
| `onPanel:<glob>` | User opens a matching panel |
| `onFileType:<glob>` | File with matching extension opened |
| `onSchematicOpen` | Any schematic is opened |
| `onSelection:<type>` | Selection changes to matching type |

---

## 3. Provider Pattern (Pull, not Push)

**Problem:** Plugins push UI every frame. They also push status, push commands, push everything.
This is wasteful for plugins that only need to respond to specific queries.

**Solution:** Plugins register **providers** — functions the host calls on demand. Complementary
to the push model (which stays for custom panels).

```
Host → Plugin (provider requests):
  0x16  provide_hover_info     [i32 wx][i32 wy][u8 type][i32 idx]
  0x17  provide_completions    [u16 ctx_len][ctx][u16 prefix_len][prefix]
  0x18  provide_diagnostics    [u16 path_len][path]
  0x19  provide_actions        [u8 type][i32 idx]       // context actions for selection
  0x1A  provide_tooltip        [u8 type][i32 idx]       // tooltip for instance/wire/net
  0x1B  provide_decoration     [u32 instance_idx]        // visual decoration
  0x1C  provide_netlist_hook   [u16 format_len][format]  // modify netlist before export
  0x1D  provide_validation     (none)                    // DRC/ERC checks

Plugin → Host (provider responses):
  0x97  hover_info_result      [u16 text_len][text]
  0x98  completion_result      [u16 label_len][label][u16 insert_len][insert][u16 detail_len][detail]
  0x99  diagnostic_result      [u8 severity][u16 msg_len][msg][i32 x][i32 y]
  0x9A  action_result          [u16 label_len][label][u16 cmd_len][command]
  0x9B  tooltip_result         [u16 text_len][text]
  0x9C  decoration_result      [u32 color_rgba][u8 style]
  0x9D  netlist_hook_result    [u32 len][modified_netlist]
  0x9E  validation_result      [u8 severity][u16 msg_len][msg][i32 x][i32 y][u16 fix_len][fix_cmd]
  0x9F  register_provider      [u16 name_len][provider_name]
```

**Usage:**
```python
class MyPlugin(Plugin):
    def on_load(self, w):
        w.register_provider("hover_info")
        w.register_provider("completions")
        w.register_provider("validation")

    def on_provide_hover_info(self, wx, wy, obj_type, idx, w):
        w.hover_info_result(f"Net: VDD\nFanout: 12\nCap: 2.3fF")

    def on_provide_validation(self, w):
        for issue in self.run_drc():
            w.validation_result(issue.level, issue.msg, issue.x, issue.y, issue.fix)
```

Multiple plugins can register the same provider. Host merges results.

---

## 4. Canvas Drawing API

**Problem:** Plugins cannot draw on the schematic canvas. No overlays, annotations, highlights,
routing guides, or simulation waveforms on-canvas.

**Solution:** Canvas primitives. New capability: `canvas_draw = true`.

```
Plugin → Host (canvas commands, 0xC0–0xCD):
  0xC0  canvas_clear_layer     [u8 layer_id]
  0xC1  canvas_line            [u8 layer][i32 x0][i32 y0][i32 x1][i32 y1][u32 color][f32 width]
  0xC2  canvas_rect            [u8 layer][i32 x][i32 y][i32 w][i32 h][u32 fill][u32 stroke][f32 sw]
  0xC3  canvas_circle          [u8 layer][i32 cx][i32 cy][i32 r][u32 fill][u32 stroke]
  0xC4  canvas_text            [u8 layer][i32 x][i32 y][u32 color][f32 size][u16 len][text]
  0xC5  canvas_polyline        [u8 layer][u32 color][f32 width][u16 n][i32 pairs...]
  0xC6  canvas_polygon         [u8 layer][u32 fill][u32 stroke][u16 n][i32 pairs...]
  0xC7  canvas_arc             [u8 layer][i32 cx][i32 cy][i32 r][f32 start][f32 end][u32 color][f32 w]
  0xC8  canvas_image           [u8 layer][i32 x][i32 y][i32 w][i32 h][u32 px_len][rgba...]
  0xC9  canvas_path            [u8 layer][u32 fill][u32 stroke][f32 sw][u16 cmd_len][svg_path_d]
  0xCA  canvas_begin_group     [u8 layer][u16 name_len][name]
  0xCB  canvas_end_group       [u8 layer]
  0xCC  canvas_set_transform   [u8 layer][f32 a][f32 b][f32 c][f32 d][f32 tx][f32 ty]
  0xCD  canvas_reset_transform [u8 layer]
```

**Layers** (drawn in order):
```
0-15:    Host reserved (grid, wires, devices, labels, selection)
16-127:  Plugin overlays (above schematic content)
128-255: Plugin underlays (below schematic, above grid)
```

**Canvas events** (opt-in via `subscribe_events`):
```
Host → Plugin:
  0x1E  canvas_click   [i32 wx][i32 wy][u8 button][u8 mods]
  0x1F  canvas_drag    [i32 wx][i32 wy][i32 dx][i32 dy][u8 button][u8 mods]
  0x20  canvas_scroll  [i32 wx][i32 wy][f32 dx][f32 dy]
```

**Use cases:**
- Highlight critical path (rect overlay on instances)
- Draw simulation waveforms on-canvas
- Custom routing guide (line following cursor)
- Measurement ruler tool
- Annotation/markup layer
- DRC violation markers

---

## 5. Extended Capabilities

Evolve from 5-bit packed struct to u32:

```zig
pub const Capability = packed struct(u32) {
    // Existing
    file_read_project: bool,
    file_read_plugin_data: bool,
    file_write_plugin_data: bool,
    schematic_mutate: bool,
    network: bool,

    // New
    canvas_draw: bool,
    menu_contribute: bool,
    shell_exec: bool,            // spawn child processes
    clipboard_read: bool,
    clipboard_write: bool,
    file_write_project: bool,    // write files in project dir
    file_read_anywhere: bool,    // read any file (PDK paths, etc.)
    register_provider: bool,
    intercept_save: bool,        // hook into save pipeline
    intercept_export: bool,      // hook into export/netlist pipeline
    workspace_events: bool,      // file open/close/change events

    _reserved: u16 = 0,
};
```

**Permission prompt at install:**
```
Plugin "CCreator" requests:
  [x] Read project files
  [x] Write plugin data
  [x] Modify schematic
  [x] Draw on canvas
  [x] Contribute to menus
  [x] Spawn processes (for simulation)
  [ ] Network access

  [Allow Selected]  [Allow All]  [Deny]
```

---

## 6. Schematic Mutation API (Expanded)

**Problem:** Current mutation is limited to `place_device`, `add_wire`, `set_instance_prop`.

**Solution:**

```
Plugin → Host (0xD0–0xEE):

  # Instance CRUD
  0xD0  delete_instance         [u32 idx]
  0xD1  move_instance           [u32 idx][i32 dx][i32 dy]
  0xD2  rotate_instance         [u32 idx][u8 rotation]
  0xD3  mirror_instance         [u32 idx][u8 axis]
  0xD4  duplicate_instance      [u32 idx][i32 dx][i32 dy]
  0xD5  rename_instance         [u32 idx][u16 len][name]
  0xD6  set_instance_symbol     [u32 idx][u16 len][symbol]
  0xD7  get_instance_props      [u32 idx]  → triggers instance_prop msgs
  0xD8  delete_instance_prop    [u32 idx][u16 len][key]

  # Wire CRUD
  0xD9  delete_wire             [u32 idx]
  0xDA  move_wire               [u32 idx][i32 dx][i32 dy]
  0xDB  split_wire              [u32 idx][i32 x][i32 y]
  0xDC  merge_wires             [u32 a][u32 b]

  # Net manipulation
  0xDD  rename_net              [u32 idx][u16 len][name]
  0xDE  query_net_connections   [u32 idx]

  # Batch (single undo step)
  0xDF  begin_batch             (none)
  0xE0  end_batch               (none)
  0xE1  undo                    (none)
  0xE2  redo                    (none)

  # Selection
  0xE3  select_instances        [u16 count][u32 indices...]
  0xE4  select_wires            [u16 count][u32 indices...]
  0xE5  select_area             [i32 x][i32 y][i32 w][i32 h]
  0xE6  clear_selection         (none)

  # Clipboard
  0xE7  copy_selection          (none)
  0xE8  paste                   [i32 x][i32 y]
  0xE9  cut_selection           (none)

  # Query
  0xEA  query_instance_at       [i32 x][i32 y]       // hit test
  0xEB  query_wire_at           [i32 x][i32 y]
  0xEC  query_bounding_box      (none)                // schematic extents
  0xED  query_viewport          (none)                // visible area
  0xEE  query_instance_pins     [u32 idx]             // pin names + positions
```

**Batch operations** are critical — CCreator generating an entire circuit wraps in
`begin_batch`/`end_batch` so Ctrl+Z undoes the whole thing:

```python
def generate_circuit(self, w):
    w.begin_batch()
    for dev in self.circuit.devices:
        w.place_device(dev.symbol, dev.name, dev.x, dev.y)
    for wire in self.circuit.wires:
        w.add_wire(wire.x0, wire.y0, wire.x1, wire.y1)
    w.end_batch()
```

---

## 7. Inter-Plugin Communication

**Problem:** Plugins are isolated silos.

**Solution:** Topic-based message bus.

```
Plugin → Host:
  0xEF  publish_message   [u16 topic_len][topic][u32 payload_len][payload]

Host → Plugin:
  0x21  plugin_message    [u16 sender_len][sender][u16 topic_len][topic][u32 payload_len][payload]
```

**Manifest declaration:**
```toml
[messages]
publishes = ["ccreator.circuit_generated", "ccreator.pdk_switched"]
subscribes = ["theme.changed", "simulator.result"]
```

```python
# Publisher
w.publish_message("ccreator.circuit_generated", json.dumps({"instances": 42}))

# Subscriber
def on_plugin_message(self, sender, topic, payload, w):
    if topic == "ccreator.circuit_generated":
        self.invalidate_cache()
```

---

## 8. Configuration Schema

**Problem:** `set_config`/`get_config` uses opaque strings. No validation, no UI, no discoverability.

**Solution:** Declare schema in manifest. Host auto-generates settings UI.

```toml
[[config]]
key = "auto_embed"
type = "bool"
default = true
title = "Auto-embed on save"
description = "Automatically embed Python generator when saving"

[[config]]
key = "pdk"
type = "enum"
options = ["sky130", "gf180", "asap7"]
default = "sky130"
title = "Default PDK"

[[config]]
key = "optimization_iterations"
type = "int"
min = 10
max = 1000
default = 100
title = "Optimization iterations"

[[config]]
key = "simulator_path"
type = "path"
default = ""
title = "Simulator binary"
```

---

## 9. Extension Points (Plugin-extends-Plugin)

```toml
# CCreator declares an extension point
[[extension_points]]
id = "ccreator.device_generator"
description = "Register a custom device generator"
schema = { name = "string", category = "string", generate = "command_tag" }

# Third-party plugin extends it
[extends]
"ccreator.device_generator" = [
    { name = "Custom DAC", category = "Converters", generate = "my_plugin_gen_dac" }
]
```

When CCreator loads, it queries the host for all contributions to its extension points.

---

## 10. SDK Ergonomics

### Pain points today
1. Manual widget ID management (magic numbers everywhere)
2. SDK discovery via fragile relative paths
3. No type safety for config values
4. Verbose event routing (`if widget_id == 3: ...`)

### Immediate-mode wrapper (SDK-level, no ABI change)

```python
class MyPlugin(Plugin):
    def on_draw_panel(self, panel_id, ui):
        ui.label("Settings")
        ui.separator()

        with ui.collapsible("Advanced"):
            self.vol = ui.slider("Volume", self.vol, 0.0, 1.0)
            self.mute = ui.checkbox("Mute", self.mute)

        with ui.row():
            if ui.button("Apply"):
                self.apply()
            if ui.button("Reset"):
                self.reset()

        self.pdk = ui.dropdown("PDK", ["sky130", "gf180"], self.pdk)

        with ui.tabs(["Design", "Simulation", "Code"]) as tab:
            if tab == 0:
                self.draw_design(ui)
            elif tab == 1:
                self.draw_simulation(ui)
            elif tab == 2:
                self.draw_code(ui)
```

This wrapper lives entirely in the SDK:
- Auto-assigns widget IDs sequentially per draw call
- Buffers click/change events from previous frame
- `ui.button()` returns `True` if clicked since last draw
- `ui.slider()` returns current value (updated from host events)
- Context managers (`with ui.row()`, `with ui.collapsible()`) handle begin/end pairing
- No ABI changes needed — pure SDK sugar

### Named events (alternative to widget ID matching)

```python
class MyPlugin(Plugin):
    def on_draw_panel(self, panel_id, ui):
        ui.slider("volume", self.vol, 0, 1)
        ui.button("apply")

    def on_event(self, name, value, ui):
        match name:
            case "volume": self.vol = value
            case "apply":  self.do_apply()
```

---

## 11. Subprocess Plugins (Formalized)

### Current state
Python plugins already run out-of-process via `bridge.c`. TypeScript/Bun uses subprocess mode.

### Formalize in manifest

```toml
[plugin]
runtime = "subprocess"
command = "python3 plugin.py"
# or
runtime = "native"
binary = "libfoo.so"
# or
runtime = "hybrid"
native_binary = "libfast.so"       # canvas drawing, hot path
subprocess = "python3 optimizer.py" # heavy computation
```

**Benefits:**
- Any language with stdin/stdout can be a plugin
- Full process isolation (no crash guard needed)
- Can be sandboxed (seccomp/landlock on Linux)

**Tradeoff:** ~1ms vs ~1μs per message. Fine for panels/providers/commands, not for per-frame canvas.

---

## 12. File Type Associations

```toml
[[file_types]]
id = "spice-netlist"
extensions = [".spice", ".sp", ".cir"]
icon = "assets/spice-icon.png"

[[file_types]]
id = "chn-primitive"
extensions = [".chn_prim"]
```

Enables: custom editors, syntax validation, export formats, import filters.

---

## 13. Tag Allocation Map (ABI v9)

```
Host → Plugin:
  0x01–0x15  Existing (load, tick, draw, events, poll)
  0x16–0x1D  Provider requests
  0x1E–0x20  Canvas events
  0x21       Inter-plugin message
  0x22–0x3F  Reserved

Plugin → Host:
  0x80–0x8F  Existing commands
  0x90–0x96  Existing event control
  0x97–0x9F  Provider responses + register_provider
  0xA0–0xB1  Existing UI widgets
  0xB2–0xBF  Future widgets
  0xC0–0xCD  Canvas drawing
  0xCE–0xCF  Future canvas
  0xD0–0xEF  Schematic mutation + query + IPC
  0xF0–0xFF  Reserved
```

---

## 14. Migration Path (v8 → v9)

Each phase is independently shippable. Existing plugins keep working throughout.

### Phase 1: Manifest + Lazy Loading
- Add `plugin.toml` parsing (Schemify already has a TOML parser)
- Support `[activation]` events for true lazy loading
- Keep all existing tags working
- `register_panel`/`register_command` still honored (backwards compat)
- Auto-generate `registry.json` from manifests

### Phase 2: Providers + Canvas
- Add provider tags (0x16–0x1D, 0x97–0x9F)
- Add canvas drawing tags (0xC0–0xCD)
- Add canvas event tags (0x1E–0x20)
- Extend capability bits to u32

### Phase 3: Extended Mutation + IPC
- Expanded schematic mutation tags (0xD0–0xEE)
- Inter-plugin message bus (0xEF, 0x21)
- Batch/undo grouping

### Phase 4: SDK Ergonomics
- Immediate-mode wrappers in each SDK
- Auto widget IDs
- Config schema → settings UI generation
- Extension points

---

## Summary: What Plugin Creators Get

| Capability | Current (v8) | Proposed (v9) |
|-----------|-------------|--------------|
| Panel UI | 17 widget types, push every frame | Same + immediate-mode wrapper, auto IDs |
| Canvas drawing | None | Full 2D primitives, overlay/underlay layers |
| Schematic mutation | 3 commands | Full CRUD + batch undo + selection + clipboard |
| Lazy loading | Partial (flag) | True lazy via activation events + manifest |
| Commands | Imperative register | Declarative manifest + runtime register |
| Menus | None | Context menus + menubar contributions |
| Providers | None | Hover, completions, diagnostics, validation, netlist hooks |
| Inter-plugin | None | Topic pub/sub message bus |
| Configuration | Opaque strings | Typed schema + auto-generated settings UI |
| File I/O | Read project + plugin data | + Write project, read anywhere (gated) |
| Canvas interaction | None | Click, drag, scroll in schematic space |
| Extension points | None | Plugin-extends-plugin API |
| Process control | None | shell_exec capability |
| Subprocess | Informal (Python bridge) | Formal runtime mode in manifest |
