# Plugin Examples Design

**Date:** 2026-04-12
**Topic:** Recreate `plugins/examples/` with per-language UI showcase plugins
**Status:** Approved

---

## Background

All example plugins in `plugins/examples/` were accidentally deleted. The VitePress docs site at `docs/plugins/` references these paths throughout the language guides and quick-start, making those links broken. Phase 2 of the project roadmap calls for making the SDK documentation easier to use — functional examples are the primary missing piece.

---

## Goal

Recreate `plugins/examples/` with six working example plugins (one per supported language) that together demonstrate all four panel layout types. Each example must compile, install, and run against a local Schemify build.

---

## Approach: "UI Showcase" Plugin per Language

Each example implements the same conceptual plugin — a minimal "schematic assistant" — in its target language. Sharing a concept across all six makes it easy to compare language syntax directly. Each plugin registers four panels covering every layout type the ABI supports.

### The Four Panels

| Panel | Layout | Role | Widgets demonstrated |
|---|---|---|---|
| A | `overlay` (0) | Properties popup | label, slider, checkbox, button |
| B | `left_sidebar` (1) | Component browser | collapsible sections, label, separator, button |
| C | `right_sidebar` (2) | Design stats | label, progress, separator, button |
| D | `bottom_bar` (3) | Status strip | label, separator, button (compact row) |

Each panel is self-contained: all state is local to the plugin, drawn fresh each `draw_panel` call. A tick counter is maintained to demonstrate `tick` lifecycle.

---

## File Layout

```
plugins/examples/
├── zig-demo/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/main.zig
├── c-demo/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/plugin.c
├── cpp-demo/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/plugin.cpp
├── rust-demo/
│   ├── build.zig
│   ├── build.zig.zon
│   ├── Cargo.toml
│   └── src/lib.rs
├── go-demo/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/plugin.go
└── python-demo/
    ├── build.zig
    ├── build.zig.zon
    └── plugin.py
```

---

## Build Integration

Every example's `build.zig` uses `build_plugin_helper` with the appropriate language helper:

```zig
// zig-demo/build.zig
const helper = @import("build_plugin_helper");
pub fn build(b: *std.Build) void {
    const opt = helper.setup(b);
    const lib = helper.addNativePluginLibrary(b, opt, "zig-demo", "src/main.zig");
    helper.addNativeAutoInstallRunStep(b, lib, "zig-demo");
}
```

- C: `addCPlugin`
- C++: `addCppPlugin`
- Rust: `addRustPlugin`
- Go: `addGoPlugin`
- Python: `addPythonPlugin`

`zig build run` in any example directory installs the plugin to `~/.config/Schemify/<name>/` and launches Schemify. All four panels become visible immediately.

Each `build.zig.zon` references `build_plugin_helper` via relative path (`../../../tools/sdk/build_plugin_helper.zig`) so examples work from the repo without any separate install step.

---

## Plugin Implementation Details

### Descriptor
Each plugin exports a `SchemifyDescriptor` (or language-equivalent) with:
- `abi_version = 6`
- `name = "<lang>-demo"`
- `version_str = "0.1.0"`
- `process` = entry point function

### Panels registered on `load`
```
panel_id=1  title="Properties"       layout=overlay
panel_id=2  title="Components"       layout=left_sidebar
panel_id=3  title="Design Stats"     layout=right_sidebar
panel_id=4  title="Status"           layout=bottom_bar
```

### Tick
Increment an internal counter; no output required (demonstrates that tick is called every frame and plugins can maintain state without emitting anything).

### draw_panel per panel
- **Panel 1 (overlay):** `label("Selected: R1")`, `slider("Value", 0.47)`, `checkbox("Show in netlist", true)`, `button("Apply")`
- **Panel 2 (left_sidebar):** `collapsibleStart("Resistors", true)`, three `label` entries, `collapsibleEnd`, `separator`, `button("Place")`
- **Panel 3 (right_sidebar):** `label("Nets: 12")`, `separator`, `label("Components: 8")`, `progress("DRC", 0.75)`, `button("Run DRC")`
- **Panel 4 (bottom_bar):** `beginRow`, `label("Nets: 12")`, `separator`, `label("Components: 8")`, `button("Simulate")`, `endRow`

### Event handling
Button click events (`button_clicked`) are logged or no-op — examples are demonstration-only, not wired to real schematic state.

---

## Docs Fixes (alongside examples)

Two small corrections to the existing docs:

1. **`docs/plugins/creating/quick-start.md`** — fix `.path = "../../"` → `"../../.."` (wrong depth, should reach repo root from `plugins/examples/<lang>-demo/`)

2. **`docs/plugins/api.md`** — `Descriptor` is missing `abi_version: u32` as its first field. The C header `schemify_plugin.h` has it; the Zig docs do not.

---

## Verification

- `zig build` succeeds in each of the six example directories
- `zig build run` installs and launches with all four panels visible
- No external dependencies beyond what `build_plugin_helper` already pulls
- Docs links from language guides resolve to real files

---

## Out of Scope

- WASM variants (`.wasm` build targets) — each example focuses on native `.so`; WASM build is already covered by `wasm.md` separately
- Actual schematic integration (reading/writing schematic state) — examples are UI demonstration only
- Publishing to the plugin marketplace — covered by `publishing.md`
