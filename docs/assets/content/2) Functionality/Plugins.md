# Plugins

Extend Schemify with plugins written in C, C++, Python, Zig, Rust, Go, or compiled to WebAssembly.

---

## What Plugins Can Do

- **Add sidebar panels** with interactive HTML-based UI (buttons, inputs, dropdowns, tables)
- **Register commands** accessible from the command bar (`:`) and the Plugins menu
- **React to events** — selection changes, schematic edits, file loads, key presses
- **Query the schematic** — read instances, nets, wires, properties
- **Draw on the canvas** — overlay graphics on any of 9 drawing layers
- **Communicate with other plugins** via publish/subscribe IPC

---

## The Marketplace

Open the marketplace from **Plugins > Marketplace** or press **F6** then navigate to the marketplace panel.

### Browsing

- A search bar at the top filters plugins by name, description, author, or tags
- Each plugin card shows: name, version, author, description, and install status
- Installed plugins show an "Uninstall" button; available plugins show "Install"

### Installing

Click **Install** on a plugin card. Schemify downloads the plugin to `~/.config/schemify/plugins/<PluginName>/` and activates it.

### Uninstalling

Click **Uninstall** on an installed plugin card. The plugin directory is removed and the plugin is deactivated.

---

## Trust and Security

Schemify uses a tiered security model based on plugin format.

### WASM Plugins — Auto-approved

WASM plugins run in a sandboxed runtime (wasm3). They can only call host-provided functions. No file system access, no network, no arbitrary code execution. These are approved automatically on install.

### Native Plugins (.so) — Trust on First Use (TOFU)

Native plugins have full system access. Before loading a native plugin for the first time, Schemify:

1. Inspects the ELF binary for dangerous imports (`dlopen`, `system`, `exec*`, `fork`, `popen`, `socket`)
2. Shows a trust prompt listing what the plugin imports
3. Waits for your approval

Once approved, Schemify stores a SHA-256 hash of the binary in `~/.config/schemify/trusted_plugins.json`. If the plugin binary changes (e.g., after an update), you are prompted again.

### Python/Go Plugins

These bundle full language runtimes and get a one-time "full system access" warning.

---

## Plugin Panels

Plugins can register sidebar panels. These appear as toggleable entries in the **Plugins** menu.

### Toggling Panels

- **Plugins menu** — click a plugin name to show/hide its panel
- **Keybinds** — plugins can declare a keybind in their manifest (e.g., pressing `c` opens CCreator)
- **Command bar** — type the plugin's vim command (e.g., `:ccreator`)

### Panel Rendering

Plugin panels render HTML/CSS. The host converts this to native UI elements. Plugins can use:

- Standard HTML elements (div, span, h1-h6, p, ul, ol, table)
- Interactive elements (button, input, select, textarea, checkbox)
- CSS variables for theme-aware styling (colors auto-adapt to light/dark mode)

---

## Plugin Discovery

Schemify searches three locations (highest priority first):

| Location | Purpose |
| --- | --- |
| `<project>/.schemify/plugins/` | Project-local overrides (development) |
| `~/.config/schemify/plugins/` | User-installed (marketplace or manual) |
| `<app>/plugins/` | Bundled with the application |

If the same plugin name exists in multiple locations, the highest-priority one wins.

---

## Plugin Data Storage

Each plugin gets a dedicated data directory:

```
~/.local/share/schemify/plugins/<plugin_name>/
```

- On macOS: `~/Library/Application Support/Schemify/plugins/<plugin_name>/`
- On Windows: `%APPDATA%\Schemify\plugins\<plugin_name>\`

Plugins store configuration, caches, and persistent state here. The directory is created on first use.

---

## Manual Installation

1. Download or clone the plugin into `~/.config/schemify/plugins/<PluginName>/`
2. Ensure the directory contains a `plugin.toml` manifest file
3. Restart Schemify or run **Plugins > Reload Plugins**

### Manifest Example

Every plugin requires a `plugin.toml`:

```toml
[plugin]
name = "MyPlugin"
version = "1.0.0"
description = "Does something useful"
author = "Your Name"
api = 1
binary = "myplugin.so"

[activation]
events = ["on_startup"]

[[panels]]
id = "myplugin_main"
title = "My Plugin"
layout = "right_sidebar"
keybind = "p"
```

---

## Plugin Blocks in Files

Plugins can embed persistent data in `.chn` schematic files using `PLUGIN` blocks:

```
PLUGIN CCreator
  circuit_class = my_circuit
  generator: |
    def generate(circuit):
        circuit.add_mosfet("M1", w=500e-9)
```

These blocks survive save/load cycles and are only visible to the declaring plugin.

---

## Reloading Plugins

- **Plugins > Reload Plugins** — rescans all plugin directories and reloads
- **F6** — refreshes plugin state
- **`:pluginsreload`** — command bar equivalent

---

## Troubleshooting

### Plugin does not appear

- Verify the plugin directory contains a valid `plugin.toml` with `api = 1`
- Check that the `binary` field points to an existing file (`.so`, `.wasm`, or Python script)
- Run **Plugins > Reload Plugins** after adding new plugins
- Check the log output for load errors (visible in terminal when running from CLI)

### Trust prompt keeps appearing

The plugin binary has changed since you last approved it. This is expected after updates. Re-approve to continue using it.

### Panel is blank or shows "loading..."

- The plugin's `schemify_render` function may be returning empty HTML
- Check that the plugin activated correctly (look for errors in the status bar)
- Try **Plugins > Reload Plugins** to force re-activation

### Plugin crashes Schemify

Native plugins run in the same process. A segfault in a native plugin will crash Schemify. Consider using the WASM version of the plugin if available, or report the issue to the plugin author.

WASM plugins cannot crash Schemify — they are sandboxed and terminated gracefully on error.

---

## Creating Plugins

See the **Creating Plugins** documentation section for developer guides covering each supported language, the HTML panel system, canvas drawing, and the full host API reference.
