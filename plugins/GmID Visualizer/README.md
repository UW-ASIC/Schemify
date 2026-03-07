# GmID Visualizer Plugin

Overlay panel plugin for Schemify that:
- lets you pick a model file (`.spice`, `.model`, `.lib`, etc.),
- validates it as MOSFET or BJT format,
- runs a Gm/Id sweep workflow, and
- writes SVG plots to the plugin figures directory.

Run from this directory:

```bash
zig build run
```

Panel controls:
- `Model` button: opens a dropdown-like list of previously selected models.
- `Browse...`: pick and validate a model file.
- `Run`: executes the sweep and lists generated SVGs.
