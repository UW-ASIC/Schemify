# HTML Layout Guide

Schemify's dvui fork ([HTML2DVUI](https://github.com/OmarSiwy/HTML2DVUI)) renders HTML and CSS directly inside plugin panels. This is the **recommended approach** for any plugin that needs more than a few sliders and buttons.

---

## Why HTML?

| Approach | Effort | Flexibility | Best for |
|----------|--------|-------------|----------|
| Widget protocol | Low | Limited to ~14 widget types | Simple parameter panels |
| **HTML layout** | **Low** | **Arbitrary layout** | **Everything else** |

With `html()` you get:
- Tables, grids, nested divs
- Styled text (bold, italic, colors, fonts)
- Buttons with IDs (trigger `button_clicked`)
- Forms, lists, headings
- No need to learn the binary widget protocol

---

## Basic Usage

Every SDK has an `html()` method. Call it during `draw_panel` instead of emitting individual widgets.

### Python

```python
def on_draw_panel(self, panel_id, w):
    w.html(panel_id, """
        <div style="padding: 8px;">
            <h3>MOSFET Parameters</h3>
            <table style="width: 100%;">
                <tr><td>W</td><td>10u</td></tr>
                <tr><td>L</td><td>180n</td></tr>
                <tr><td>gm/Id</td><td>15 V^-1</td></tr>
            </table>
            <hr/>
            <button id="optimize">Optimize</button>
            <button id="export">Export Netlist</button>
        </div>
    """)
```

### Zig

```zig
.draw_panel => |ev| {
    w.html(ev.panel_id,
        \\<div style="padding: 8px;">
        \\  <h3>Design Stats</h3>
        \\  <p>Instances: 42</p>
        \\  <p>Nets: 18</p>
        \\  <button id="refresh">Refresh</button>
        \\</div>
    );
},
```

### C

```c
case SP_TAG_DRAW_PANEL: {
    const char* html =
        "<div style='padding: 8px;'>"
        "  <h3>Status</h3>"
        "  <p>All checks <b>passed</b>.</p>"
        "  <button id='recheck'>Re-check</button>"
        "</div>";
    sp_write_html(&w, panel_id, html, strlen(html));
    break;
}
```

### Rust

```rust
fn on_draw_panel(&mut self, panel_id: u16, w: &mut Writer) {
    w.html(panel_id, b"<div><h3>Results</h3><p>Gain: 42 dB</p></div>");
}
```

### TypeScript

```typescript
onDrawPanel(panelId: number, w: Writer) {
    w.html(panelId, `
        <div style="padding: 8px;">
            <h3>Waveform Viewer</h3>
            <p>Click a net to plot.</p>
        </div>
    `);
}
```

### Go

```go
func (p *MyPlugin) OnDrawPanel(panelId uint16, w *sp.WriterBuf) {
    w.Html(panelId, []byte(`<div><h3>Go Plugin</h3><p>Running.</p></div>`))
}
```

---

## Supported HTML Elements

The dvui HTML renderer supports a practical subset of HTML:

| Element | Notes |
|---------|-------|
| `<div>` | Block container, supports `style` |
| `<span>` | Inline container |
| `<p>` | Paragraph |
| `<h1>` - `<h6>` | Headings |
| `<b>`, `<strong>` | Bold text |
| `<i>`, `<em>` | Italic text |
| `<br>` | Line break |
| `<hr>` | Horizontal rule |
| `<table>`, `<tr>`, `<td>`, `<th>` | Tables |
| `<ul>`, `<ol>`, `<li>` | Lists |
| `<button id="...">` | Clickable button (fires `button_clicked`) |
| `<input>` | Text input fields |
| `<a href="...">` | Links |
| `<pre>`, `<code>` | Monospace/code blocks |
| `<img src="...">` | Images (data: URIs supported) |

---

## Supported CSS Properties

Inline `style` attributes support these properties:

| Property | Example |
|----------|---------|
| `padding`, `margin` | `padding: 8px;` |
| `width`, `height` | `width: 100%;` |
| `color` | `color: #ff0000;` |
| `background-color` | `background-color: #333;` |
| `font-size` | `font-size: 14px;` |
| `font-family` | `font-family: monospace;` |
| `font-weight` | `font-weight: bold;` |
| `text-align` | `text-align: center;` |
| `border` | `border: 1px solid #ccc;` |
| `display` | `display: flex;` |
| `flex-direction` | `flex-direction: row;` |
| `gap` | `gap: 4px;` |

---

## Mixing HTML and Widgets

You can mix HTML layout with widget protocol calls in the same `draw_panel` response. Widgets are rendered in the order they're emitted. Use HTML for complex layout sections and widgets for interactive controls that need the built-in event system.

```python
def on_draw_panel(self, panel_id, w):
    # HTML section for layout
    w.html(panel_id, """
        <div style="padding: 8px;">
            <h3>Parameters</h3>
        </div>
    """)
    # Widget protocol for interactive slider
    w.slider(self.value, 0.0, 100.0, 1)
    w.button("Apply", 2)
```

---

## Button Events from HTML

Buttons in HTML with an `id` attribute fire `button_clicked` events. The `widget_id` is derived from the button's position in the HTML.

```python
w.html(panel_id, '<button id="run_sim">Run</button>')

def on_button_clicked(self, panel_id, widget_id, w):
    # Handle the button click
    w.push_command("reload_from_disk", "")
```

---

## Tips

- **Keep HTML simple.** The renderer handles a practical subset, not the full browser spec. Stick to basic layout.
- **Use inline styles.** There's no `<style>` block or external CSS — put styles directly on elements.
- **Prefer `<table>` for data grids.** It renders cleanly and handles alignment automatically.
- **Use `<pre>` for code/logs.** Monospace text preserves formatting.
- **Test incrementally.** Start with a simple `<p>` and build up.
