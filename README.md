## Schemify

Lighter, Faster, More Featureful Schematic Editor with easier support for development and plugin creation.

### Development

**Requires Zig 0.15+.** Use the Nix dev shell (provides Zig 0.15.2):

```bash
nix-shell shell.nix   # enter once, then use zig freely
zig build             # must run inside nix-shell
```

Without nix-shell, `zig build` will fail with a version error if your system Zig is older than 0.15.

#### Native (SDL3)

```bash
zig build                        # compile
zig build run                    # launch GUI

zig build run -- --open examples/inverter   # open example (reads Config.toml)
zig build run -- --open examples/diff_amp  # open diff_amp example

zig build run -- --cli help      # CLI mode

zig build test                   # run all tests
zig build -Doptimize=ReleaseFast # release build
```

`--open <project_dir>` loads the project's `Config.toml` and opens the first schematic (`.shn` in `paths.shn`, else `.sch` in `legacy_paths.schematics`).

#### Web (WASM)

```bash
zig build -Dbackend=web          # compile → zig-out/bin/{n1schem.wasm,web.js,index.html}
zig build -Dbackend=web run_local  # compile + serve at http://localhost:8080
```

`run_local` starts `python3 -m http.server 8080` in `zig-out/bin/`. Press Ctrl-C to stop.

### Benefits over XSchem

- Plugin support
  - Volare < PDK Management
    - GM/ID > Schematic Editor
    - Resimulates and then updates the sizing
  - ThemeSwitcher
  - Picture to Schematic...
    - ...
- Use a web viewer...
  - Github workflwos...
- Different File structure
  - XSchem
    - schematic ()
    - symbol ()
  - Schemify
    - .chn_sym (.sym < primitives) > volare .lib file for ngspice
    - .chn (.sch and .sym) < top-level components l
    - .chn_tb (.sch only)
- Digital Interface is better
  - inline (embedded) or linked...
  - inline or linked...
  - .sym is automatically created!
  - LSP built in... (HRT (slang-server))
- Xyce support too
  - Xyce >>>>>>>> ngspice

- Atomic Semi needs this, (web) layout editor, (web) schhematic editor
- < Open-Source Silicon Meeting

### TODO:

- Waveform Viewer device...
- Python drop-in replacement behavior for blocks
