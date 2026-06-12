# plugin.toml Reference

## `[plugin]` — required

```toml
[plugin]
id = "my-plugin"            # lowercase, digits, hyphens. 3-64 chars.
name = "My Plugin"          # display name
version = "0.1.0"           # semver
description = "..."         # one-liner
entry = "cargo run --release"  # command to spawn the subprocess
```

`id` rules: `[a-z0-9][a-z0-9-]*[a-z0-9]`, 3 to 64 characters.

`entry` is split on whitespace and executed with the plugin directory as cwd.
For release builds, point it at the compiled binary:

```toml
entry = "bin/my-plugin"       # pre-built binary (used in tarballs)
entry = "python plugin.py"    # script-based plugin
entry = "cargo run --release"  # build-from-source (dev only)
```

## `[capabilities]` — optional

Declare what your plugin uses. The host AND-gates these with its own
capabilities during negotiation. Undeclared capabilities are blocked.

```toml
[capabilities]
panels = true       # register and update sidebar/bottom panels
commands = true     # register keybindable commands
overlays = false    # draw shapes on the schematic canvas
theme = false       # override theme tokens
optimizer = false   # query/drive optimizer instances
```

All default to `false`.

## `[[panels.panel]]` — optional, repeatable

Pre-declare panels. The plugin still calls `register_panel` at runtime.

```toml
[[panels.panel]]
name = "My Panel"
slot = "RightSidebar"    # Overlay | LeftSidebar | RightSidebar | BottomBar
priority = 10            # higher = shown first
```

## `[[commands.command]]` — optional, repeatable

Pre-declare commands.

```toml
[[commands.command]]
name = "do_thing"
description = "Does the thing"
keybind = "Ctrl+Shift+T"    # optional
```
