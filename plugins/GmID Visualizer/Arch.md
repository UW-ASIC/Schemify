# GmID Visualizer Architecture

## Purpose

`GmID Visualizer` is a Schemify overlay plugin that lets users pick a transistor model file, validate whether it looks like MOSFET or BJT data, run a sweep workflow, and open generated SVG plots.

## Runtime Components

- `src/plugin.py`
  - Schemify plugin entrypoint (`schemify_process`).
  - Owns UI state, panel rendering, and button event handling.
  - Launches the runner process and ingests `SVG:<path>` lines from stdout.
- `src/gmid_runner.py`
  - CLI worker invoked by `plugin.py`.
  - Generates deterministic SVG plot sets for MOSFET or BJT mode.
  - Prints produced files in machine-readable form: `SVG:/abs/or/rel/path.svg`.

## State Model (`plugin.py`)

Mutable UI state is held in a single `_State` dataclass:

- model selection: `selected_model_path`, `selected_model_kind`
- history/dropdown: `recent_models`, `dropdown_open`
- execution status: `status`, `status_msg`, `error_msg`
- outputs: `plots`

Status lifecycle:

- `idle`: waiting for user action
- `running`: sweep process in progress
- `done`: successful run with generated plots
- `err`: validation or execution failure

## Event Flow

1. `on_load` registers an overlay panel (`:gmid`, keybind `g`).
2. User actions in `on_event` dispatch by widget ID:
   - model toggle / browse
   - run sweep
   - pick from model history
   - open generated SVG
3. `on_draw` renders three logical sections:
   - model selector
   - validation/status
   - outputs list with open buttons

## Sweep Pipeline

1. Validate selected model/kind.
2. Ensure output directory exists: `~/.config/Schemify/GmIDVisualizer/figures`.
3. Run:

```bash
python3 src/gmid_runner.py --model-file <path> --kind <mosfet|bjt> --out-dir <dir>
```

4. Parse stdout lines beginning with `SVG:`.
5. Update state and redraw panel.

## Model Validation

`plugin.py` uses simple keyword heuristics over the model text:

- MOSFET hints (for example: `nmos`, `pmos`, `level=`)
- BJT hints (for example: `npn`, `pnp`, `bf=`)

If both are present, MOSFET wins (backward-compatible behavior).

## Packaging

`build.zig` packages only runtime-required sources:

- `src/plugin.py`
- `src/gmid_runner.py`

Historical exploratory scripts/docs were removed once reference checks showed they are not part of runtime.
