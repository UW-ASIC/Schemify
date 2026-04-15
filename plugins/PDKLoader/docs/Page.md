### PDKLoader Plugin

Manages PDK (Process Design Kit) installations for Schemify projects using [Volare](https://github.com/efabless/volare).

Works standalone and as a required companion to the **EasyImport** plugin.

#### Setup

Install Volare (one of):

```sh
pip install volare
python3 -m pip install volare
```

PDKLoader auto-detects `volare` in PATH or as `python3 -m volare`.

#### Panel  (`K` keybind / vim `:pdk`)

| Control | Description |
|---------|-------------|
| **Re-detect** | Re-probe Volare availability |
| **PDK toggle** | Cycle between supported PDKs |
| **Fetch PDK** | Download the selected PDK via Volare into `~/.volare/` |
| **Apply pdk to Config.toml** | Write `pdk = "<name>"` into the open project's Config.toml |

> **Note:** "Fetch PDK" is synchronous. Downloading a PDK (several GB on first install)
> blocks the UI. Subsequent fetches check a local cache and are fast.

#### Supported PDKs

| Config.toml value | Volare family | Description |
|-------------------|---------------|-------------|
| `sky130A`         | `sky130`      | SkyWater 130 nm open PDK |
| `gf180mcu`        | `gf180mcu`    | GlobalFoundries 180 nm MCU PDK |

#### Integration with EasyImport

PDKLoader is a `requires` dependency in EasyImport's `plugin.toml`.

Typical workflow:

1. **PDKLoader** — Fetch sky130A → installed to `~/.volare/sky130A/`
2. **PDKLoader** — Apply → `pdk = "sky130A"` written to `Config.toml`
3. **EasyImport** — Set project directory to the PDK's xschem library root
   e.g. `~/.volare/sky130A/libs.ref/sky130_fd_pr/xschem/`
4. **EasyImport** — Convert → `.sym` files become `.chn_prim` primitives
5. EasyImport updates `Config.toml` `chn_prim` paths with the converted files

#### How It Works

- Probes `volare --version` then `python3 -m volare --version` on load
- Runs `volare fetch --pdk <family>` to install into `~/.volare/`
- Locates `Config.toml` by walking up the directory tree from the active document
- Reads and rewrites the `pdk =` line (or inserts it after `name =`)
