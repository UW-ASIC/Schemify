# PDKLoader Architecture

## Purpose

`EasyPDKLoader` is a native Schemify plugin that discovers installed PDK variants,
shows them in a sidebar panel, lets users clone/enable versions through `volare`,
and converts XSchem assets into Schemify CHN files.

Primary source files:

- `src/main.zig`: plugin UI state, widget handling, user actions
- `src/volare.zig`: filesystem discovery, `volare` process calls, XSchem -> CHN conversion

## Module Boundaries

### `src/main.zig` (UI/controller)

- Owns in-memory plugin state (`State` and `PdkSlot` array)
- Draws right-sidebar panel rows for each known PDK variant
- Routes button clicks by widget-id offset
- Calls into `volare.zig` for all external side effects:
  - discovery (`discover`)
  - clone/enable (`clone`, `listRemoteVersions`, `saveSelectedVersion`)
  - conversion (`convertToSchemify`, `chnOutDir`)

### `src/volare.zig` (domain/services)

- Defines `PdkVariant` and known variant list
- Discovers PDK roots from standard locations
- Reads version metadata and probes for XSchem/SPICE assets
- Executes `volare` subprocess commands (`enable`, `ls-remote`)
- Converts `libs.tech/xschem` `.sch`/`.sym` files to CHN outputs
- Maintains persisted selected versions in:
  - `~/.config/Schemify/pdks/selected_versions`

## Runtime Data Flow

1. Plugin load (`onLoad` in `main.zig`)
   - Initializes slots with known variant names
   - Runs discovery (`volare.discover`)
   - Applies persisted version selections (`loadSelectedVersion`)

2. Panel render (`drawPanel` / `drawSlot`)
   - Shows one row per known variant
   - Displays status badge (`missing`, `found`, `converting`, `converted`)
   - Shows actions: `Clone`, `Convert`, `Versions+/-`, `Use`, `Reload list`

3. User actions (`onButton`)
   - `Refresh`: re-run discovery
   - `Clone`: run `volare enable <variant>`, then re-scan
   - `Convert`: derive output dir and run XSchem -> CHN conversion
   - `Versions+`: lazy-load remote versions (`volare ls-remote`)
   - `Use`: persist chosen version and try `volare enable --pdk-family ...`

4. Conversion (`convertToSchemify` in `volare.zig`)
   - Pass 1: classify stems by file presence (`.sch`, `.sym`)
   - Pass 2: convert files and write:
     - `.chn` for component schematics (`.sch` with matching `.sym`)
     - `.chn_tb` for standalone schematics
     - `.chn_prim` for symbols
   - Emit `registry.dat` in output directory

## Storage and External Dependencies

- Discovery paths checked in order per variant:
  1. `~/.volare/<variant>`
  2. `$PDK_ROOT/<variant>`
  3. `$PDK/<variant>`
  4. `/usr/share/pdk/<variant>`
  5. `/opt/pdk/<variant>`
- Output CHN root:
  - `~/.config/Schemify/pdks/<variant>/`
- External tools:
  - `volare` in `PATH` for clone/enable/version listing

## Interface and Stability Notes

- Plugin-facing interface remains unchanged:
  - name: `EasyPDKLoader`
  - panel id/title/vim command/keybind unchanged
  - button behavior and status messaging semantics preserved
- Internal refactors favor shared helpers for:
  - fixed-buffer string writes
  - status formatting
  - widget offset constants and routing
