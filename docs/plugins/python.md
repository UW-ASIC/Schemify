# Writing a Python Plugin

Python plugins are pure `.py` files — no compilation, no Zig wrapper. The
`schemify` SDK package handles the binary message protocol between your script
and the Schemify host. Subclass `schemify.Plugin`, override the lifecycle
methods, and expose a `schemify_process` function.

Python plugins run natively only. WASM is not supported.

## 1. Prerequisites

- Python 3.10 or later
- The `schemify` SDK package on `PYTHONPATH` (see section 5)
- `pip` for dependency management
- `pylsp` or `pyright` for IDE support (optional)

## 2. Quick start

Create `plugin.py`:

```python
import schemify

class MyPlugin(schemify.Plugin):
    def on_load(self, w: schemify.Writer):
        w.register_panel('my-panel', 'My Panel', 'mypanel', schemify.LAYOUT_OVERLAY, 0)
        w.set_status('My plugin loaded')

    def on_draw(self, panel_id: int, w: schemify.Writer):
        w.label('Hello from Python!', id=0)
        w.button('Click me', id=1)

    def on_tick(self, dt: float, w: schemify.Writer):
        pass

    def on_event(self, msg: dict, w: schemify.Writer):
        if msg['tag'] == schemify.TAG_BUTTON_CLICKED and msg['widget_id'] == 1:
            w.set_status('Clicked!')

_plugin = MyPlugin()

def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
```

Deploy manually:

```bash
SCRIPTS="$HOME/.config/Schemify/SchemifyPython/scripts/my-plugin"
mkdir -p "$SCRIPTS"
cp plugin.py "$SCRIPTS/"
```

Launch Schemify; the script is loaded on startup.

## 3. File structure

A minimal plugin is a single `.py` file. A plugin with a build step looks like:

```
my-python-plugin/
  plugin.py
  requirements.txt     # optional pip dependencies
  build.zig            # optional; deploys via `zig build run`
  build.zig.zon        # optional; needed only if using zig build
```

## 4. `build.zig` for deployment

Add `build.zig` to deploy the plugin automatically with `zig build run`.

**`build.zig.zon`**

```zig
.{
    .name    = .my_python_plugin,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .fingerprint = 0x<random_hex>,
    .dependencies = .{
        .schemify_sdk = .{ .path = "../../.." },
        // Standalone project: replace with .url + .hash (see section 6)
    },
    .paths = .{ "build.zig", "build.zig.zon", "plugin.py" },
}
```

**`build.zig`**

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addPythonPlugin(
        b,
        "my-python-plugin",   // plugin directory name under scripts/
        sdk_dep,
        &.{"plugin.py"},      // source files to copy
        null,                 // pass "requirements.txt" to run pip install
        "my-python-plugin",   // label shown in build output
    );
}
```

```bash
zig build run   # runs pip install (if requirements given), copies files, launches Schemify
```

`addPythonPlugin` copies the listed files to
`~/.config/Schemify/SchemifyPython/scripts/<plugin_dir_name>/` and, if a
`requirements` file is provided, runs `pip install -r <requirements>` first.

## 5. LSP setup

Add the SDK bindings directory to `PYTHONPATH` so `pylsp` or `pyright` resolves
imports:

```bash
export PYTHONPATH="/path/to/Schemify/tools/sdk/bindings/python:$PYTHONPATH"
```

For VS Code, add to `.vscode/settings.json`:

```json
{
  "python.analysis.extraPaths": [
    "/path/to/Schemify/tools/sdk/bindings/python"
  ]
}
```

No special language server configuration is required beyond setting the path.

## 6. Standalone git project

For a plugin in its own repository, replace the `.path` entry in
`build.zig.zon` with a URL dependency:

```zig
.schemify_sdk = .{
    .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
    .hash = "...",
},
```

Run `zig fetch --save=schemify_sdk <url>` to populate the hash. You can also
skip `build.zig` entirely and deploy the script manually (section 2).

## 7. API reference

The SDK lives at `tools/sdk/bindings/python/schemify/__init__.py`.

### `Plugin` base class

```python
class Plugin:
    def on_load(self, w: Writer) -> None: ...
    def on_unload(self, w: Writer) -> None: ...
    def on_tick(self, dt: float, w: Writer) -> None: ...
    def on_draw(self, panel_id: int, w: Writer) -> None: ...
    def on_event(self, msg: dict, w: Writer) -> None: ...
```

### `Writer` methods

#### Plugin lifecycle and host commands

| Method | Description |
|---|---|
| `register_panel(id, title, vim_cmd, layout, keybind)` | Register a panel |
| `set_status(text)` | Set status bar text |
| `log(level, tag, msg)` | Structured log message |
| `log_info(tag, msg)` | Shorthand for `log(LOG_INFO, ...)` |
| `log_warn(tag, msg)` | Shorthand for `log(LOG_WARN, ...)` |
| `log_err(tag, msg)` | Shorthand for `log(LOG_ERR, ...)` |
| `push_command(tag, payload)` | Send a named command to the host |
| `set_state(key, val)` | Persist a string value in host state |
| `get_state(key)` | Request a state value (arrives as `TAG_STATE_RESPONSE`) |
| `set_config(plugin_id, key, val)` | Write a config entry |
| `get_config(plugin_id, key)` | Read a config entry (arrives as `TAG_CONFIG_RESPONSE`) |
| `request_refresh()` | Ask for an immediate redraw |
| `register_keybind(key, mods, cmd_tag)` | Register a global keybind |
| `place_device(sym, name, x, y)` | Place a schematic device |
| `add_wire(x0, y0, x1, y1)` | Add a wire segment |
| `set_instance_prop(idx, key, val)` | Set a property on an instance |
| `query_instances()` | Request all instances (arrive as `TAG_INSTANCE_DATA`) |
| `query_nets()` | Request all nets (arrive as `TAG_NET_DATA`) |

#### UI widgets

| Method | Description |
|---|---|
| `label(text, id)` | Text label |
| `button(text, id)` | Button |
| `separator(id)` | Horizontal rule |
| `begin_row(id)` / `end_row(id)` | Horizontal layout group |
| `slider(val, min, max, id)` | Float slider |
| `checkbox(val, text, id)` | Labeled checkbox |
| `progress(fraction, id)` | Progress bar (0.0–1.0) |
| `plot(title, xs, ys, id)` | Line plot |
| `image(pixels, w, h, id)` | Raw RGBA image |
| `collapsible_start(label, open, id)` / `collapsible_end(id)` | Collapsible section |

### Layout constants

```python
schemify.LAYOUT_OVERLAY        # 0
schemify.LAYOUT_LEFT_SIDEBAR   # 1
schemify.LAYOUT_RIGHT_SIDEBAR  # 2
schemify.LAYOUT_BOTTOM_BAR     # 3
```

### Incoming message tags

Used in `msg['tag']` inside `on_event`:

```python
from schemify import (
    # Host → plugin lifecycle
    TAG_LOAD, TAG_UNLOAD, TAG_TICK, TAG_DRAW_PANEL,
    # Widget interactions
    TAG_BUTTON_CLICKED, TAG_SLIDER_CHANGED,
    TAG_TEXT_CHANGED, TAG_CHECKBOX_CHANGED,
    # Host responses and events
    TAG_COMMAND, TAG_STATE_RESPONSE, TAG_CONFIG_RESPONSE,
    TAG_SCHEMATIC_CHANGED, TAG_SELECTION_CHANGED,
    TAG_SCHEMATIC_SNAPSHOT,
    # Schematic data responses
    TAG_INSTANCE_DATA, TAG_INSTANCE_PROP, TAG_NET_DATA,
)
```

## 8. Using scientific libraries

Because Python plugins run in a regular CPython process, you can import any
library directly — no IPC or subprocess needed.

```python
import schemify
import numpy as np
import scipy.signal as sig

class AnalysisPlugin(schemify.Plugin):
    def on_load(self, w: schemify.Writer):
        w.register_panel('analysis', 'Signal Analysis', 'sig',
                         schemify.LAYOUT_RIGHT_SIDEBAR, 0)

    def on_draw(self, panel_id: int, w: schemify.Writer):
        xs = np.linspace(0, 2 * np.pi, 256)
        ys = np.sin(xs)
        w.plot('Sine wave', xs.tolist(), ys.tolist(), id=0)

_plugin = AnalysisPlugin()

def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
```

Declare dependencies in `requirements.txt`:

```
numpy>=1.24
scipy>=1.11
torch>=2.0
```

Pass the filename to `addPythonPlugin` to have `zig build` install them
automatically:

```zig
helper.addPythonPlugin(b, "analysis", sdk_dep,
    &.{"plugin.py"},
    "requirements.txt",
    "analysis");
```

## 9. WASM

Python plugins are not supported on the WASM target. The WASM backend loads
compiled `.wasm` modules only. Use Zig, C, or Rust if you need a plugin that
runs in the browser.
