# Using dvui from Any Language

Schemify's GUI is built on [dvui](https://github.com/OmarSiwy/HTML2DVUI), a Zig immediate-mode UI library. The plugin system exposes dvui's rendering capabilities through two paths:

1. **HTML Layout** (recommended) — send HTML strings, dvui renders them
2. **Widget Protocol** — emit individual widget tags that map directly to dvui calls

This guide covers both and how to use them effectively from any language.

---

## What is dvui?

dvui is an immediate-mode GUI library for Zig with a retained-mode layout engine. Schemify's fork (HTML2DVUI) adds an HTML/CSS rendering path — you write HTML, dvui parses and lays it out using its native widget primitives.

This means:
- Your HTML `<button>` becomes a dvui button
- Your `<table>` becomes a dvui grid layout
- Your `style="padding: 8px"` maps to dvui layout parameters
- No browser, no webview, no JavaScript — it's all native rendering

---

## Path 1: HTML Layout (Any Language)

The `html(panel_id, html_string)` method sends raw HTML to dvui's HTML renderer. Available in every SDK.

### When to Use HTML

- You need tables, grids, or nested layouts
- You want styled text (headings, bold, colors)
- Your UI is mostly informational (displaying results, status, logs)
- You want to iterate quickly on layout without recompiling

### Example: Simulation Results Panel

```python
class SimResults(Plugin):
    def __init__(self):
        self.results = {}

    def on_draw_panel(self, panel_id, w):
        rows = "".join(
            f"<tr><td>{k}</td><td>{v}</td></tr>"
            for k, v in self.results.items()
        )
        w.html(panel_id, f"""
            <div style="padding: 8px;">
                <h3>Simulation Results</h3>
                <table style="width: 100%; border: 1px solid #555;">
                    <tr style="font-weight: bold;">
                        <td>Parameter</td><td>Value</td>
                    </tr>
                    {rows}
                </table>
                <div style="margin-top: 8px; display: flex; gap: 4px;">
                    <button id="rerun">Re-run</button>
                    <button id="export">Export CSV</button>
                </div>
            </div>
        """)
```

---

## Path 2: Widget Protocol (Any Language)

The widget protocol maps 1:1 to dvui widget calls. Each widget is a single message in the output buffer.

### When to Use Widgets

- Simple parameter panels (a few sliders, checkboxes, buttons)
- You need real-time interactive controls (slider values update every frame)
- You want the smallest possible output size
- Your panel has < 10 controls

### Example: Parameter Panel

```python
def on_draw_panel(self, panel_id, w):
    w.label("Width (um)", 0)
    w.slider(self.width, 0.1, 100.0, 1)
    w.label("Length (nm)", 2)
    w.slider(self.length, 45.0, 1000.0, 3)
    w.checkbox(self.include_parasitics, "Include parasitics", 4)
    w.separator(5)
    w.button("Apply", 6)
```

### Widget to dvui Mapping

| Plugin Widget | dvui Function | Notes |
|---------------|---------------|-------|
| `label` | `dvui.label()` | Static text |
| `button` | `dvui.button()` | Click fires `button_clicked` |
| `slider` | `dvui.slider()` | Continuous float value |
| `checkbox` | `dvui.checkbox()` | Boolean toggle |
| `textInput` | `dvui.textEntry()` | Single-line input |
| `textArea` | `dvui.textEntry({multiline})` | Multi-line, 32KB buffer |
| `progress` | `dvui.progressBar()` | 0.0 - 1.0 fraction |
| `separator` | `dvui.separator()` | Horizontal line |
| `beginRow/endRow` | `dvui.horizontalLayout()` | Horizontal grouping |
| `collapsibleStart/End` | `dvui.collapsible()` | Foldable section |

---

## Path 3: Mixing Both

You can emit HTML and widgets in the same draw call. They render in order:

```zig
.draw_panel => |ev| {
    // HTML section for complex layout
    w.html(ev.panel_id,
        \\<div style="padding: 8px;">
        \\  <h3>Device Properties</h3>
        \\  <table>
        \\    <tr><td>Type</td><td>NMOS</td></tr>
        \\    <tr><td>Model</td><td>sky130_fd_pr__nfet_01v8</td></tr>
        \\  </table>
        \\</div>
    );
    // Interactive controls via widgets
    w.label("W (um)", 1);
    w.slider(width_val, 0.1, 100.0, 2);
    w.label("L (nm)", 3);
    w.slider(length_val, 45.0, 1000.0, 4);
    w.button("Apply", 5);
},
```

---

## dvui Concepts for Plugin Authors

### Immediate Mode

dvui is immediate-mode: you redraw the entire panel every frame. There's no retained widget tree. Your `on_draw_panel` is called ~60 times/second, and you emit the current UI state each time.

This means:
- No "add widget" / "remove widget" — just emit what you want now
- State lives in your plugin, not in the UI framework
- Changing the UI is as simple as changing what you emit

### Layout

dvui uses a constraint-based layout engine:
- Widgets fill available width by default
- `beginRow`/`endRow` creates horizontal layouts
- Collapsibles provide vertical sections
- HTML `<div style="display: flex">` maps to dvui's flex layout

### Widget IDs

Every widget needs a unique ID (u32) within its panel. The host uses IDs to route events back:
- `button_clicked(panel_id=0, widget_id=5)` means button with id=5 was clicked
- `slider_changed(panel_id=0, widget_id=2, val=0.75)` means slider 2 moved

Keep IDs stable across frames — changing IDs causes visual glitches.

### Theme Integration

dvui widgets automatically match Schemify's current theme (dark/light). HTML elements inherit the theme's font and colors. You don't need to handle theming manually.

---

## Language-Specific Notes

### Zig

Zig plugins can use dvui directly if linked against the host's dvui module. This is an advanced pattern — most Zig plugins should use the SDK's Writer methods or HTML layout instead.

### Python / TypeScript

These run as subprocesses. They have zero access to dvui's Zig API. Use the Writer's widget methods or `html()` exclusively.

### C / C++ / Rust / Go

These compile to `.so` shared libraries loaded into the host process. They could theoretically call dvui functions directly, but the ABI is unstable and not supported. Use the SDK's binary protocol.

---

## Recommendations

| Scenario | Approach |
|----------|----------|
| Parameter panel (< 5 controls) | Widget protocol |
| Data display (tables, results) | HTML layout |
| Complex form with layout | HTML layout |
| Code editor | `textArea` widget |
| Dashboard with mixed content | HTML + widgets |
| Waveform viewer | HTML for labels, `plot` widget for data |
