# Command Line

Using the command bar (`:` mode) and the CLI for headless operation.

---

## Command Bar

Press **:** (colon) to enter command mode. Type a command and press **Enter**. Press **Escape** to cancel.

### Available Commands

#### File

| Command | Description |
| --- | --- |
| `:save` | Save current file |
| `:saveas <path>` | Save to a new path |
| `:open <path>` | Open a file |
| `:quit` | Close the application |

#### Editing

| Command | Description |
| --- | --- |
| `:set-prop <key> <value>` | Set property on selected instance |
| `:rename <name>` | Rename selected instance |
| `:rename-net <name>` | Rename selected wire's net |

#### Netlisting

| Command | Description |
| --- | --- |
| `:netlist` | Generate hierarchical netlist |
| `:netlist-flat` | Generate flat netlist |
| `:netlist-top-only` | Generate top-level netlist |
| `:print-netlist` | Print netlist to console |
| `:export-verilog` | Export Verilog netlist |

#### View

| Command | Description |
| --- | --- |
| `:zoom-fit` | Zoom to fit all |
| `:zoom-in` | Zoom in |
| `:zoom-out` | Zoom out |
| `:toggle-grid` | Toggle grid |
| `:toggle-crosshair` | Toggle crosshair |
| `:snap <value>` | Set snap size |

#### Design Checks

| Command | Description |
| --- | --- |
| `:check-duplicate-names` | Find duplicate instance names |
| `:auto-rename-duplicates` | Fix duplicate names |
| `:check-dangling-nets` | Find unconnected nets |
| `:check-overlapping-instances` | Find stacked instances |
| `:check-pin-mismatch` | Check port/net discrepancies |
| `:run-all-checks` | Run all checks |

#### Info

| Command | Description |
| --- | --- |
| `:list-instances` | List all instances |
| `:list-wires` | List all wires |
| `:info` | Show document info |
| `:select-instance <name>` | Select instance by name |
| `:select-wire <index>` | Select wire by index |

---

## CLI (Headless Mode)

Schemify can run without a GUI for scripting and automation.

### Single Command

```bash
schemify --cmd myschematic.chn set-prop M1 W 500n
```

Runs one command on the file and auto-saves.

### Batch Mode

```bash
echo "set-prop M1 W 500n
set-prop M1 L 180n
print-netlist" | schemify --batch myschematic.chn
```

Reads commands from stdin, executes each one, and auto-saves on exit.

### List Commands

```bash
schemify --commands
```

Prints all available commands.

### Netlist Generation

```bash
schemify --cmd myschematic.chn print-netlist > output.spice
```

---

## Command Naming

Commands accept multiple naming styles:

- **snake_case**: `set_prop`, `zoom_fit`
- **kebab-case**: `set-prop`, `zoom-fit`
- **Short aliases**: as listed above

The parser auto-converts between naming conventions.
