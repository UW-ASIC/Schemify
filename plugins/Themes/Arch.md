# Themes Plugin Architecture

## Overview

`plugins/Themes` is a Python UI plugin that:

- Loads bundled theme JSON files from `plugins/Themes/themes/` (or installed runtime mirror).
- Loads optional user theme JSON files from `~/.config/Schemify/themes/`.
- Merges both sources with user themes overriding bundled themes by `name`.
- Renders a panel with theme buttons plus shape, wire width, and tab style presets.
- Sends selected theme payloads to host config key `themes.active_theme`.

The plugin entrypoint is `src/plugin.py` via `schemify_process`.

## Runtime Flow

1. `on_load`
   - Loads themes using `_load_all_themes()`.
   - Registers panel `themes`.

2. `on_draw`
   - Renders active theme and grouped theme buttons (`Sharp`, `Balanced`, `Rounded`, `Pill`).
   - Renders preset controls for shape, wire width, and tab style.

3. `on_event`
   - Accepts only `TAG_BUTTON_CLICKED`.
   - Maps widget id ranges to one of:
     - theme apply (`_apply_theme`)
     - shape preset (`corner_radius`)
     - wire preset (`wire_width`)
     - tab preset (`tab_shape`)
   - Applies config through `_set_active_theme(...)`.

## Core Components

- `ThemesPlugin`: plugin lifecycle, drawing, and event handling.
- `_iter_theme_paths(directory)`: deterministic theme file discovery.
- `_read_theme_file(path)`: guarded JSON parsing and schema sanity checks.
- `_load_all_themes()`: merge bundled + user themes.
- `_corner_category(theme)`: category classification by `corner_radius`.
- `_button_index(widget_id, base, size)`: range-safe button index decoding.

## Build and Deployment

- `build.zig` uses `addPythonPlugin(...)` to install `src/plugin.py`.
- `build.zig` also copies bundled theme JSON files into installed script directory:
  - `$HOME/.config/Schemify/SchemifyPython/scripts/Themes/themes/`

## Removed Dead Code

- Deleted `src/parse.zig`.
  - Not referenced by this plugin build or runtime path.
  - No in-plugin references found for `parse.zig`, `applyJson`, or `clamp8`.
