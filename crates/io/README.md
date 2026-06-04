# schemify_io

File I/O, configuration parsing, plugin lock management, and platform path resolution. Handles reading/writing the `.chn` schematic format, stimulus file generation, and an in-memory virtual filesystem for WASM.

## Files

### `reader.rs` — CHN file parser

State-machine parser that reads `.chn` files line by line into a `Schematic`. Section headers switch the parser state:

| Section | What it parses |
|---------|---------------|
| `pins` | Pin declarations with name, direction, optional position and width. |
| `params` | Key-value symbol parameters. |
| `instances` | Component instances with position, rotation, flip, and properties. Supports `.parameters{...}` blocks. |
| `type_table` | Bulk instance creation from a columnar table format. |
| `wires` | Wire segments with optional bus flag, color, and net name. |
| `drawing` | Geometric shapes: line, rect, circle, arc, text, polygon. |
| `code_block` | Raw SPICE code. |
| `plugin` | Plugin key-value blocks with multiline support. |
| `pyspice` | PySpice source code. |
| `documentation` | LaTeX/Markdown documentation text. |
| `generate` | Parameter expansion loops (`generate i: range 0..3`). |

**How to add a new file section:**
1. Add a variant to the `Section` enum.
2. Add a section header pattern in the main parse loop.
3. Write a `parse_your_section()` function.
4. Add the corresponding writer in `writer.rs`.

### `writer.rs` — CHN file writer

`write_chn()` serializes a `Schematic` back to `.chn` format. Writes sections in order: metadata, pins, params, instances, wires, drawing, code block, plugin blocks, pyspice, documentation.

Properties are filtered: metadata keys (`description`, `type`, `spice_body`, `include`, analysis/measure prefixes) and structural keys (`x`, `y`, `rot`, `flip`, `sym`, `name`) are excluded from the property block. Instances with 4+ custom properties use the `.parameters{...}` block format.

### `config.rs` — Project configuration

Parses `Config.toml` from the project root:

```toml
[project]
name = "my-project"
pdk = "sky130"

[paths]
schematics = ["src/*.chn"]
primitives = ["lib/*.chn_prim"]
testbenches = ["tb/*.chn_tb"]

[simulation]
spice_include_paths = ["models/"]

[plugins]
enabled = ["rust-linter"]
disabled = []
```

Supports glob expansion in path arrays.

### `stimulus.rs` — Stimulus file generation

Generates companion stimulus files (`.spice` or `.py`) for testbenches. A marker line separates auto-generated boilerplate from user-editable code. When regenerating, user code below the marker is preserved.

| Function | Output |
|----------|--------|
| `write_spice_stimulus()` | SPICE stimulus with netlist header + user section. |
| `write_py_stimulus()` | PySpice script with netlist as triple-quoted string + user section. |
| `generate_stimulus()` | High-level: picks format by `StimulusLang`, preserves existing user code. |
| `stimulus_path()` | Derives stimulus path from testbench path (`.spice` or `_stim.py`). |

### `lock.rs` — Plugin lock file

TOML-based lock file tracking installed plugins. Each `LockEntry` has: id, version, source, sha256 hash, location (global/project).

### `paths.rs` — Platform paths

| Function | Returns |
|----------|---------|
| `global_plugins_dir()` | `$XDG_DATA_HOME/schemify/plugins` (or platform equivalent) |
| `cache_dir()` | `$XDG_CACHE_HOME/schemify/cache` |
| `config_dir()` | `$XDG_CONFIG_HOME/schemify` |
| `lock_file_path()` | `config_dir()/plugin-lock.toml` |

### `virtual_fs.rs` — In-memory filesystem (WASM)

`VirtualFs` — a `HashMap<String, String>` pretending to be a filesystem. Supports insert, read, list by directory prefix, and list by extension. Used as a drop-in FS abstraction when native file access is unavailable.
