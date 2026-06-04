# Plugins

Schemify has an extensible plugin system. Write plugins in any language -- Python, JavaScript, Rust, Bash -- as long as they speak JSON-RPC 2.0 over stdin/stdout.

## Plugin Architecture

```
Schemify ◄──── JSON-RPC 2.0 (stdin/stdout) ────► Plugin Process
```

Plugins run as separate processes. Schemify spawns them, sends requests, and receives responses. Plugins can also be compiled to WebAssembly and loaded directly (requires the `wasm` feature).

## What Plugins Can Do

| Capability | Description |
|---|---|
| **Panels** | Add custom UI panels to sidebars, bottom bar, toolbar, or status bar |
| **Commands** | Register new commands with optional keybindings |
| **Overlays** | Draw shapes on the canvas (lines, circles, markers, text) |
| **Theme** | Customize the color theme |
| **Queries** | Read schematic data (instances, nets, properties) |
| **Mutations** | Dispatch commands to modify the schematic |

## UI Slots

Plugins can place panels in these locations:

- `LeftSidebar`
- `RightSidebar`
- `BottomBar`
- `Toolbar`
- `MenuBar`
- `CanvasOverlay`
- `StatusBar`

## Plugin Manifest

Every plugin needs a `plugin.toml` file:

```toml
[plugin]
id = "my-plugin"
name = "My Plugin"
version = "0.1.0"
description = "Adds custom functionality"
entry = "python3 main.py"
runtime = "subprocess"

[capabilities]
panels = true
commands = true
overlays = false

[sandbox]
network = false
paths = ["."]

[events]
subscribe = ["schematic_changed", "pre_save"]
```

### Fields

- **id** -- unique plugin identifier
- **entry** -- the shell command to spawn the plugin
- **runtime** -- `subprocess` (default) or `wasm`
- **capabilities** -- what the plugin can do
- **sandbox** -- security restrictions (network access, filesystem paths)
- **events** -- which schematic events the plugin subscribes to

## Writing a Plugin

### Python Example

```python
import sys
import json

def handle_request(request):
    method = request.get("method")
    
    if method == "initialize":
        return {
            "panels": [{
                "id": "my-panel",
                "title": "My Panel",
                "slot": "RightSidebar",
                "widgets": [
                    {"type": "label", "text": "Hello from my plugin!"},
                    {"type": "button", "label": "Click me", "action": "do_thing"}
                ]
            }]
        }
    
    if method == "action":
        action = request["params"]["action"]
        if action == "do_thing":
            return {"dispatch": {"command": "SelectAll"}}
    
    return {}

for line in sys.stdin:
    request = json.loads(line)
    response = handle_request(request)
    result = {"jsonrpc": "2.0", "id": request["id"], "result": response}
    print(json.dumps(result), flush=True)
```

### Bash Example

Even a shell script can be a plugin:

```bash
#!/bin/bash
while IFS= read -r line; do
    method=$(echo "$line" | jq -r '.method')
    id=$(echo "$line" | jq -r '.id')
    
    if [ "$method" = "initialize" ]; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"name\":\"bash-plugin\"}}"
    fi
done
```

## Included Examples

The `plugins/examples/` directory includes working plugins:

| Plugin | Language | Description |
|---|---|---|
| `python-hello` | Python | Minimal plugin demonstrating initialization |
| `python-panel` | Python | Plugin with a sidebar panel and widgets |
| `node-counter` | Node.js | Event-counting plugin |
| `rust-linter` | Rust | Schematic linting rules |
| `bash-minimal` | Bash | Bare-minimum plugin in shell script |

## Managing Plugins

- Press **F6** to refresh/reload all plugins
- Plugin errors appear in the bottom panel
- Plugins are discovered from the project's `plugins/` directory

## Widget Types

Panels support 30+ widget types including:

- `label`, `button`, `text_input`, `checkbox`, `slider`
- `dropdown`, `color_picker`, `progress_bar`
- `table`, `tree`, `tabs`, `collapsible`
- `separator`, `spacer`, `image`
