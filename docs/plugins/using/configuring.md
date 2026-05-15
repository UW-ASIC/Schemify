# Configuring Plugins

Schemify has two levels of plugin configuration: **user-level** (applies to every
project you open) and **project-level** (scoped to a single project directory).
Both use the same `[plugins]` TOML syntax; the host merges them at startup.

## User-level config

`~/.config/Schemify/plugins.toml`

```toml
[plugins]
enabled  = ["EasyImport", "PDKLoader"]
disabled = []
```

Use this for plugins you always want available — themes, personal utilities,
PDK loaders that aren't tied to a specific project.

## Project-level config

`<project-root>/Config.toml`

```toml
[plugins]
enabled  = ["SpiceRunner", "MyTeamPlugin"]
disabled = ["EasyImport"]
```

Use this for plugins that make sense only in one project — simulation helpers,
team-specific tools, or a plugin that conflicts with the project's workflow.
Check this file into version control so collaborators get the same setup.

## How the two levels are merged

At startup Schemify combines both lists in this order:

1. Project-level `enabled` entries are collected first.
2. User-level `enabled` entries are appended after.
3. Any plugin whose name appears in **either** `disabled` list is removed from
   the final set.

```
Project enabled:  [SpiceRunner, MyTeamPlugin]
User enabled:     [EasyImport, PDKLoader]
Project disabled: [EasyImport]

Final loaded:     [SpiceRunner, MyTeamPlugin, PDKLoader]
                                        ↑ EasyImport removed by project disabled
```

The `disabled` key is the correct way to suppress a user-level plugin for a
specific project — there is no need to edit your global config.

## Quick reference

| What you want | Where to put it |
|---|---|
| Plugin for all projects | `~/.config/Schemify/plugins.toml` → `enabled` |
| Plugin for one project only | `Config.toml` → `enabled` |
| Suppress a global plugin in one project | `Config.toml` → `disabled` |
| Permanently remove a global plugin | `~/.config/Schemify/plugins.toml` → remove from `enabled` |

::: tip Plugin binary location
The config only controls which plugins are **activated**. The binary (`.so` /
`.dylib` / `.wasm`) must already be installed in
`~/.config/Schemify/<PluginName>/`. See [Installing Plugins](./installing) for
how to get the binary in place first.
:::
