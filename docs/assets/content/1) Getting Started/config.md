# Config.toml Reference

Every Schemify project is rooted in a directory that contains a `Config.toml`. The file is optional — if it is missing, Schemify starts with sensible defaults.

## Full Example

```toml
name = "My Inverter"
pdk  = "sky130"

[paths]
chn    = ["top.chn"]
chn_tb = ["tb.chn_tb"]

[legacy_paths]
schematics = ["inv.sch"]
symbols    = ["inv.sym"]

[simulation]
spice_include_paths = ["/pdk/sky130/libs.tech/ngspice"]

[plugins]
enabled  = ["my-theme-plugin"]
disabled = []
```

## Keys

### Root

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | `"Untitled"` | Project display name. Shown in the window title. |
| `pdk`  | string | `null` | Active PDK (`"sky130"`, `"gf180"`, or any string). Used by synthesis. |

### `[paths]`

| Key | Type | Description |
|-----|------|-------------|
| `chn` | string[] | Native `.chn` schematics to open at startup. |
| `chn_tb` | string[] | Testbench `.chn_tb` schematics. |

### `[legacy_paths]`

| Key | Type | Description |
|-----|------|-------------|
| `schematics` | string[] | XSchem `.sch` files to import. |
| `symbols`    | string[] | XSchem `.sym` files to import. |

### `[simulation]`

| Key | Type | Description |
|-----|------|-------------|
| `spice_include_paths` | string[] | Directories added as `.include` lines in the generated netlist. |

### `[plugins]`

| Key | Type | Description |
|-----|------|-------------|
| `enabled`  | string[] | Plugin names to load at startup. |
| `disabled` | string[] | Plugin names to explicitly skip (overrides `enabled`). |

## Plugin Search Path

Plugins are installed to `~/.config/Schemify/<PluginName>/`. On startup, Schemify scans this directory for all installed plugins, then filters by the `enabled`/`disabled` lists in `Config.toml`.

## PDK Values

| Value | PDK |
|-------|-----|
| `"sky130"` | Google/SkyWater SKY130 |
| `"gf180"` | GlobalFoundries GF180MCU |
| `"ihp-sg13g2"` | IHP SG13G2 |

Any string is accepted — it is passed to synthesis tools as-is.
