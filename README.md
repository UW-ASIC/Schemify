## Schemify

<p align="center">
  <img src="assets/banner.svg" alt="Schemify — Analog Schematic Editor" width="100%"/>
</p>

A fast, vim-first analog schematic editor with gold-class import, AI-native design, and a plugin ecosystem.

### Features

- **Vim-first keybindings** — modal editing, command-line (`:place`, `:wire`, `:save`, etc.)
- **Gold-class import** — XSchem, Cadence Virtuoso (CDL/Spectre), SPICE netlists
- **PDK-aware** — Sky130, GF180MCU, IHP SG13G2 with automatic device remapping
- **MCP server** — Claude Code, Cursor, Continue.dev connect natively for AI-assisted design
- **gm/Id optimizer** — built-in analog sizing via gm/Id methodology
- **PySpice simulation** — ngspice, Xyce, Spectre backends via Python bridge
- **Plugin system** — native (.so) and WASM plugins, JSON in / HTML out
- **Cross-platform** — Linux, macOS, Windows (native); browser (WASM)

### Development

**Requires Zig 0.15+ and Python 3.10+.** Use the Nix dev shell:

```bash
nix develop              # enter dev shell (Zig 0.15.2 + deps)
zig build                # build native
zig build run            # launch GUI
zig build test           # run all tests
zig build test_plugins   # plugin test suite
```

Without the dev shell, `zig build` will fail if your system Zig is older than 0.15.

#### Build variants

```bash
zig build                          # debug build
zig build -Doptimize=ReleaseFast   # release build
zig build -Dbackend=web            # WASM build
zig build -Dbackend=web run_local  # WASM + local server (localhost:8080)
```

#### CLI mode

```bash
schemify --help
schemify --cmd file.chn :place nmos4
schemify --batch file.chn < commands.txt
schemify --netlist file.chn
schemify --export-svg file.chn
schemify --commands                # list all commands
```

### Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| Zig 0.15.2 | Build system + language | Yes |
| Python 3.10+ | Plugins, simulation, PDK management | Yes |
| PySpice | Simulation backend (ngspice/Xyce/Spectre) | For simulation |
| raylib | Native rendering backend | Bundled |
| dvui | GUI framework | Bundled |

```bash
pip install pyspice  # optional: enables simulation
```

### Architecture

```
src/
├── core/           # Schematic data model, file I/O
├── gui/            # dvui-based GUI (app frame, canvas, panels, dialogs)
├── commands/       # Command system (parser, dispatch, 16 handler modules)
├── plugins/        # Plugin host (native + WASM loading, async execution)
├── external/       # Import backends (XSchem, Virtuoso, SPICE)
├── optimizer/      # gm/Id MOSFET sizing optimizer
├── simulation/     # PySpice bridge (subprocess-based)
├── settings/       # Core settings (theme.json, keybinds.json)
├── agent/          # MCP server (tools, resources, prompts, diagnostics)
└── cli.zig         # CLI subcommands
```

### MCP Server (AI Integration)

Schemify exposes an MCP server on a Unix socket. Any MCP-compatible client connects instantly:

```json
{
  "mcpServers": {
    "schemify": {
      "transport": "unix",
      "path": "$XDG_RUNTIME_DIR/schemify.sock"
    }
  }
}
```

**Tools:** `place_component`, `add_wire`, `create_from_topology`, `validate_circuit`, `check_connectivity`, `drc_check`, `generate_netlist`, `simulate`, `execute_command`

**Resources:** `schemify://instances`, `schemify://nets`, `schemify://wires`, `schemify://skills/core`

**Prompts:** `design_amplifier`, `import_xschem`, `optimize_sizing`, `design_current_mirror`, `analyze_circuit`, `create_testbench`, `explain_circuit`

### Plugins

| Plugin | Description |
|--------|-------------|
| CCreator | Circuit templates, behavioral modeling, generation |
| PDKSwitcher | PDK management (CIEL + LambdaPDK) |
| GitBlame | Git blame annotations on schematic elements |
| GmIDVisualizer | Interactive gm/Id design space plots |

Install plugins via CLI or marketplace:
```bash
schemify --plugin-install https://github.com/user/plugin.git
schemify --plugin-list
schemify --plugin-remove plugin-name
```

### Examples

Six example schematics ship in `examples/schematics/`:
- `inverter.chn` — CMOS inverter
- `diff_pair.chn` — Differential pair
- `current_mirror.chn` — NMOS current mirror
- `bandgap.chn` — Bandgap voltage reference
- `ring_oscillator.chn` — 3-stage ring oscillator
- `opamp.chn` — Two-stage Miller OTA

### Settings

Settings live in `~/.config/Schemify/`:
- `theme.json` — colors, sizing, tab style
- `keybinds.json` — key-to-command mappings (vim-first defaults)
- `themes/` — user-installed theme presets

Access via Help → Settings in the GUI, or edit JSON directly.

### License

MIT
