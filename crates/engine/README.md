# schemify_engine

CLI binary and application entry point. When invoked with no arguments it launches the GUI; with a subcommand it runs headlessly.

## Files

### `main.rs` — CLI interface

**Usage:**
```
schemify [OPTIONS] [FILE] [COMMAND]
```

81 CLI commands organized into categories, each mapping 1:1 to a core `Command` variant:

| Category | Commands |
|----------|----------|
| View | `zoom-in`, `zoom-out`, `zoom-fit`, `zoom-reset`, `toggle-grid`, `toggle-fullscreen`, `toggle-color-scheme` |
| File | `file-new`, `file-open`, `file-save`, `file-save-as`, `new-tab`, `close-tab`, `switch-tab`, `reload` |
| Selection | `select-all`, `select-none`, `invert-selection` |
| Clipboard | `copy`, `cut`, `paste` |
| Tool | `set-tool <name>` (select, wire, move, pan, line, rect, polygon, arc, circle, text) |
| Transform | `rotate-cw`, `rotate-ccw`, `flip-h`, `flip-v`, `nudge-*`, `align-to-grid` |
| Placement | `place-device`, `add-wire`, `add-line`, `add-rect`, `add-circle`, `add-arc`, `add-text` |
| Properties | `set-instance-prop`, `rename-instance`, `rename-net`, `set-spice-code`, `set-documentation`, `set-wire-color` |
| Simulation | `run-sim`, `set-stimulus-lang`, `set-sim-backend`, `gen-stimulus`, `show-stimulus`, `export-netlist` |
| Import | `import-spice` |
| Plugin | `plugin install/uninstall/list` |

**Control flow:**
1. No command → `run_gui()` (launches display crate).
2. `plugin <subcmd>` → routes to `plugin_cli`.
3. `gen-stimulus` / `show-stimulus` → special handlers that load a schematic and generate/display stimulus files.
4. Everything else → `run_cli()` which creates an `App`, optionally loads a file, dispatches the command, and optionally saves.

**How to add a new CLI command:**
1. Add a `CliCommand` variant with `#[command]` attributes.
2. Add the mapping in `to_command()` to convert it to a core `Command`.
3. If it needs special handling (like `gen-stimulus`), add a branch in `main()`.

### `plugin_cli.rs` — Plugin management

Three subcommands:

| Command | What it does |
|---------|-------------|
| `plugin install <source>` | Install from `github:owner/repo` or `--from-file path.tar.gz`. Downloads, extracts, validates manifest, moves to plugin dir, updates lock file. |
| `plugin uninstall <id>` | Removes plugin directory and lock entry. `--keep-data` preserves data. |
| `plugin list` | Prints table of installed plugins (ID, version, scope, source). |

**Action system:** Both install and uninstall produce a `Vec<PluginAction>` plan, then `execute_actions()` runs them in order. Actions include: `DownloadTarball`, `Extract`, `ValidateManifest`, `MoveDir`, `UpdateLock`, `RemoveLockEntry`, `RemoveDir`, `Notify`.

Downloads use `curl` with exponential-backoff retry (up to 3 attempts).
