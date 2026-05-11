# Python Plugin Guide

Python plugins run via an embedded CPython interpreter inside a shared library. A C bridge (`bridge.c`) exports the 11 C ABI functions and delegates to a Python `Plugin` subclass.

---

## How It Works

```
bridge.c (compiled to .so with embedded CPython)
    |
    +--> imports your plugin.py module
    +--> finds Plugin subclass instance
    +--> delegates schemify_activate -> plugin.activate()
    +--> delegates schemify_render   -> plugin.render()
    +--> delegates schemify_on_*     -> plugin.on_*()
```

The bridge handles all C ABI concerns (string encoding, memory management, GIL). You write pure Python.

---

## Setup

```
my-plugin/
  src/plugin.py      <-- your plugin code
  src/lib.py         <-- copy from tools/plugins/python/src/lib.py
  bridge.c           <-- copy from tools/plugins/python/bridge.c
  plugin.toml
  Makefile
```

Copy the SDK files:
```sh
mkdir -p my-plugin/src
cp tools/plugins/python/src/lib.py my-plugin/src/
cp tools/plugins/python/bridge.c my-plugin/
cp tools/plugins/python/Makefile my-plugin/
```

---

## Complete Working Example

### plugin.toml

```toml
[plugin]
name = "Task Tracker"
version = "1.0.0"
author = "Your Name"
description = "Track design tasks"
api = 1

[activation]
events = ["on_startup"]

[[panels]]
id = "tasks"
title = "Tasks"
layout = "right_sidebar"
keybind = "t"
vim_cmd = "tasks"

[build]
binary = "tasks.so"
```

### src/plugin.py

```python
"""Task tracker plugin for Schemify."""
from __future__ import annotations
import json
from lib import Plugin, host

PANEL_ID = "tasks"


class TaskTracker(Plugin):
    def __init__(self):
        self.tasks: list[dict] = []
        self.next_id = 1

    def activate(self) -> None:
        host.log("info", "Task Tracker activated")
        host.register_panel(json.dumps({
            "id": PANEL_ID,
            "title": "Tasks",
            "layout": "right_sidebar"
        }))
        # Load saved tasks
        self._load_state()

    def deactivate(self) -> None:
        self._save_state()

    def render(self, panel_id: str) -> str | None:
        if panel_id != PANEL_ID:
            return None

        task_rows = ""
        for t in self.tasks:
            checked = " checked" if t["done"] else ""
            task_rows += (
                f'<div style="display: flex; gap: 8px; align-items: center;">'
                f'  <input id="chk-{t["id"]}" type="checkbox"{checked}/>'
                f'  <span style="color: var(--fg);">{t["text"]}</span>'
                f'  <button id="del-{t["id"]}">x</button>'
                f'</div>'
            )

        return (
            f'<div style="padding: 12px; display: flex; flex-direction: column; gap: 8px;">'
            f'  <h2 style="color: var(--accent);">Tasks</h2>'
            f'  <div style="display: flex; gap: 8px;">'
            f'    <input id="new-task" type="text" placeholder="New task..."/>'
            f'    <button id="add-btn">Add</button>'
            f'  </div>'
            f'  <hr/>'
            f'  {task_rows}'
            f'  <p style="color: var(--fg);">'
            f'    {sum(1 for t in self.tasks if t["done"])}/{len(self.tasks)} done'
            f'  </p>'
            f'</div>'
        )

    def on_html_event(self, panel_id: str, event_json: str) -> None:
        try:
            ev = json.loads(event_json)
        except json.JSONDecodeError:
            return

        eid = ev.get("id", "")
        etype = ev.get("type", "")

        if eid == "add-btn" and etype == "click":
            # In practice, you'd get the input value from a change event
            self.tasks.append({"id": self.next_id, "text": f"Task {self.next_id}", "done": False})
            self.next_id += 1
        elif eid == "new-task" and etype == "change":
            # User typed and submitted (Enter/blur)
            text = ev.get("value", "").strip()
            if text:
                self.tasks.append({"id": self.next_id, "text": text, "done": False})
                self.next_id += 1
        elif eid.startswith("chk-"):
            task_id = int(eid.split("-")[1])
            for t in self.tasks:
                if t["id"] == task_id:
                    t["done"] = not t["done"]
                    break
        elif eid.startswith("del-"):
            task_id = int(eid.split("-")[1])
            self.tasks = [t for t in self.tasks if t["id"] != task_id]

        self._save_state()
        host.request_refresh()

    def _load_state(self) -> None:
        data_dir = host.plugin_data_dir()
        if not data_dir:
            return
        content = host.read_file(f"{data_dir}/tasks.json")
        if content:
            try:
                state = json.loads(content)
                self.tasks = state.get("tasks", [])
                self.next_id = state.get("next_id", 1)
            except json.JSONDecodeError:
                pass

    def _save_state(self) -> None:
        data_dir = host.plugin_data_dir()
        if not data_dir:
            return
        state = json.dumps({"tasks": self.tasks, "next_id": self.next_id})
        host.write_file(f"{data_dir}/tasks.json", state)


# The bridge finds this instance automatically
plugin = TaskTracker()
```

---

## Plugin Class Structure

Subclass `Plugin` from the SDK and override methods you need:

```python
from lib import Plugin, host

class MyPlugin(Plugin):
    def activate(self) -> None: ...
    def deactivate(self) -> None: ...
    def render(self, panel_id: str) -> str | None: ...
    def on_html_event(self, panel_id: str, event_json: str) -> None: ...
    def on_command(self, name: str, args: str) -> None: ...
    def on_schematic_changed(self) -> None: ...
    def on_selection_changed(self, selection_json: str) -> None: ...
    def on_key_event(self, key_json: str) -> None: ...
    def on_hover(self, hover_json: str) -> None: ...
    def provide(self, provider_type: str, context_json: str) -> str | None: ...
    def on_message(self, sender: str, topic: str, payload: str) -> None: ...
```

Only `activate` needs to do something meaningful. All others have safe no-op defaults.

---

## The `host` Object

The SDK exposes a global `host` singleton with Python-friendly wrappers:

```python
from lib import host

# Core
host.log("info", "Hello from Python")
host.set_status("Processing...")
host.push_command("save")
host.request_refresh()

# Files
content = host.read_file("/path/to/file.txt")  # returns str or None
host.write_file("/path/to/file.txt", "data")   # returns bool
project = host.project_dir()                    # returns str
data_dir = host.plugin_data_dir()               # returns str

# Registration (JSON strings)
host.register_panel('{"id":"x","title":"X","layout":"right_sidebar"}')
host.unregister_panel("x")
host.register_command('{"name":"x.run","description":"Run X"}')
host.register_keybind('{"key":"r","mods":["ctrl"],"command":"x.run"}')
host.register_provider("hover_info")

# IPC
host.publish("my_plugin.data_ready", '{"value": 42}')

# Canvas drawing
host.canvas.clear_layer(16)
host.canvas.line(0, 0, 100, 100, 0xFF0000FF, 2.0)
host.canvas.rect(50, 50, 80, 40, 0x00FF00FF, filled=True)
host.canvas.circle(200, 200, 30, 0x0000FFFF, filled=False)
host.canvas.text(10, 10, "Annotation", 0xFFFFFFFF, 14.0)

# Schematic queries (return JSON strings)
instances_json = host.schematic.instances()
nets_json = host.schematic.nets()
m1_json = host.schematic.instance("M1")
host.schematic.set_config("sim.temp", "27")
```

---

## State Management

Python's GC handles memory. Use instance attributes for state:

```python
class MyPlugin(Plugin):
    def __init__(self):
        self.data = {}
        self.counter = 0

    def render(self, panel_id: str) -> str:
        return f"<p>Count: {self.counter}</p>"

    def on_html_event(self, panel_id: str, event_json: str) -> None:
        self.counter += 1
        host.request_refresh()
```

For persistent state, use `host.plugin_data_dir()` + `host.read_file()`/`host.write_file()`.

---

## Build

### Using the SDK Makefile

```sh
make -f Makefile PLUGIN_NAME=tasks PLUGIN_MODULE=plugin
```

### Manual build

```sh
cc -shared -fPIC -O2 \
    -DPLUGIN_NAME='"tasks"' \
    -DPLUGIN_VERSION='"1.0.0"' \
    -DPLUGIN_MODULE='"plugin"' \
    $(python3-config --cflags --embed) \
    -o tasks.so bridge.c \
    $(python3-config --ldflags --embed) -ldl
```

The bridge uses `dladdr` to find its own directory and prepends it (and `src/`) to `sys.path`.

---

## Install

```sh
mkdir -p ~/.config/schemify/plugins/tasks
cp tasks.so plugin.toml ~/.config/schemify/plugins/tasks/
cp src/plugin.py src/lib.py ~/.config/schemify/plugins/tasks/src/
```

Or for development, symlink your project directory:
```sh
ln -s /path/to/my-plugin ~/.config/schemify/plugins/tasks
```

---

## Provider Pattern

```python
class MyProvider(Plugin):
    def activate(self) -> None:
        host.register_provider("hover_info")
        host.register_provider("validation")

    def provide(self, provider_type: str, context_json: str) -> str | None:
        if provider_type == "hover_info":
            ctx = json.loads(context_json)
            return json.dumps({"text": f"Net: VDD\nFanout: 12"})
        elif provider_type == "validation":
            return json.dumps({"issues": []})
        return None
```

---

## Tips

- The C bridge holds the GIL -- your Python code is single-threaded within each `schemify_*` call.
- `bridge.c` finds your Plugin instance by scanning module-level variables for `isinstance(x, Plugin)`.
- The SDK file must be importable as `lib` from the same directory as your plugin module.
- Use `json.dumps()` for constructing registration JSON -- avoids quoting errors.
- Strings returned from `render()` are copied by the bridge immediately. Python GC owns lifetime.
- The plugin module name defaults to `"plugin"` (configurable via `-DPLUGIN_MODULE`).
- Requires Python 3.10+ (f-strings, type union syntax).
