# HTML Panels

Schemify renders plugin panel UI using a built-in HTML/CSS engine (litehtml). Plugins return HTML strings from `schemify_render` and receive interaction events via `schemify_on_html_event`.

---

## How It Works

1. Host calls `schemify_render(panel_id)` when a panel needs display
2. Plugin returns an HTML string (or NULL for no content)
3. Host parses the HTML, applies default stylesheet + theme CSS variables, renders via dvui
4. User interacts with an element -- host calls `schemify_on_html_event(panel_id, event_json)`
5. Plugin processes event, updates state, calls `host->request_refresh()` to trigger re-render

The host caches the parsed HTML document and only re-parses when the returned string changes (hash-based). Re-layout happens on panel width change.

---

## CSS Custom Properties

The host injects a stylesheet with variables that adapt to the active theme:

```css
:root {
    --bg: #1e1e2e;
    --fg: #cdd6f4;
    --accent: #89b4fa;
    --border: #45475a;
    --bg-alt: #313244;
    --success: #a6e3a1;
    --warning: #f9e2af;
    --error: #f38ba8;
}
```

Use these for theme-consistent UI:

```html
<div style="background: var(--bg-alt); border: 1px solid var(--border); padding: 8px;">
    <h3 style="color: var(--accent);">Results</h3>
    <p style="color: var(--fg);">Gain: 42 dB</p>
    <p style="color: var(--success);">All checks passed</p>
</div>
```

Variables update automatically on theme switch. No plugin code changes needed.

---

## Supported HTML Elements

| Element | Notes |
|---------|-------|
| `<div>` | Block container |
| `<span>` | Inline container |
| `<p>` | Paragraph |
| `<h1>` - `<h6>` | Headings |
| `<b>`, `<strong>` | Bold text |
| `<i>`, `<em>` | Italic text |
| `<br>` | Line break |
| `<hr>` | Horizontal rule |
| `<table>`, `<tr>`, `<td>`, `<th>` | Tables |
| `<ul>`, `<ol>`, `<li>` | Lists |
| `<pre>`, `<code>` | Monospace / code blocks |
| `<a href="...">` | Links (generates click event) |
| `<img src="data:...">` | Images (data URI only) |

---

## Interactive Elements

Seven element types generate events. All require an `id` attribute.

### Buttons

```html
<button id="run-sim">Run Simulation</button>
```
Event: `{"type": "click", "id": "run-sim", "tag": "button", "value": ""}`

### Text Inputs

```html
<input id="width" type="text" value="10u" placeholder="Width..."/>
```
Event (on blur or Enter): `{"type": "change", "id": "width", "tag": "input", "value": "10u"}`

### Checkboxes

```html
<input id="enable-bias" type="checkbox" checked/>
```
Event: `{"type": "change", "id": "enable-bias", "tag": "input", "value": "true"}`

### Select Dropdowns

```html
<select id="pdk">
    <option value="sky130">SKY130</option>
    <option value="gf180">GF180</option>
</select>
```
Event: `{"type": "change", "id": "pdk", "tag": "select", "value": "sky130"}`

### Textareas

```html
<textarea id="netlist" rows="6" placeholder="Paste netlist..."></textarea>
```
Event (on blur): `{"type": "change", "id": "netlist", "tag": "textarea", "value": "..."}`

### Links

```html
<a id="help-link" href="#">Help</a>
```
Event: `{"type": "click", "id": "help-link", "tag": "a", "value": ""}`

### Forms

```html
<form id="settings">
    <input id="vdd" type="text" value="1.8"/>
    <button type="submit">Apply</button>
</form>
```
Event: `{"type": "submit", "id": "settings", "tag": "form", "value": ""}`

Individual input changes still fire their own events.

---

## Event Handling via schemify_on_html_event

```c
void schemify_on_html_event(const char* panel_id, const char* event_json) {
    // Simple string matching (works for most cases)
    if (strstr(event_json, "\"id\":\"run-sim\"")) {
        host->set_status("Running simulation...");
        host->push_command("simulate");
    } else if (strstr(event_json, "\"id\":\"pdk\"")) {
        if (strstr(event_json, "\"value\":\"sky130\"")) {
            // handle sky130 selection
        }
    }
    host->request_refresh();
}
```

---

## Complete Example: Counter Plugin

```c
#include "lib.h"
#include <stdio.h>

SCHEMIFY_PLUGIN("counter", "1.0.0")

static const SchemifyHost* host;
static int counter = 0;
static char html_buf[2048];

void schemify_activate(const SchemifyHost* h) {
    host = h;
    host->register_panel(
        "{\"id\":\"counter\",\"title\":\"Counter\",\"layout\":\"right_sidebar\"}");
}

const char* schemify_render(const char* panel_id) {
    snprintf(html_buf, sizeof(html_buf),
        "<div style='padding: 12px;'>"
        "  <h2 style='color: var(--accent);'>Counter</h2>"
        "  <p style='font-size: 24px; text-align: center;'>%d</p>"
        "  <div style='display: flex; gap: 8px;'>"
        "    <button id='dec'>-</button>"
        "    <button id='inc'>+</button>"
        "    <button id='reset'>Reset</button>"
        "  </div>"
        "</div>",
        counter);
    return html_buf;
}

void schemify_on_html_event(const char* panel_id, const char* event_json) {
    if (strstr(event_json, "\"id\":\"inc\""))       counter++;
    else if (strstr(event_json, "\"id\":\"dec\""))  counter--;
    else if (strstr(event_json, "\"id\":\"reset\"")) counter = 0;
    host->request_refresh();
}
```

---

## Supported CSS Properties

| Property | Example | Notes |
|----------|---------|-------|
| `padding` | `padding: 8px;` | Shorthand and individual sides |
| `margin` | `margin: 4px 8px;` | Shorthand and individual sides |
| `width`, `height` | `width: 100%;` | px, %, auto |
| `color` | `color: var(--fg);` | Hex, named, CSS variables |
| `background-color` | `background-color: #333;` | Also `background` shorthand |
| `font-size` | `font-size: 14px;` | px only |
| `font-family` | `font-family: monospace;` | Two fonts: proportional and monospace |
| `font-weight` | `font-weight: bold;` | normal, bold (>=600 = bold) |
| `font-style` | `font-style: italic;` | normal, italic |
| `text-align` | `text-align: center;` | left, center, right |
| `border` | `border: 1px solid var(--border);` | Shorthand |
| `border-radius` | `border-radius: 4px;` | |
| `display` | `display: flex;` | block, flex, inline, none |
| `flex-direction` | `flex-direction: column;` | row, column |
| `gap` | `gap: 8px;` | For flex containers |
| `overflow` | `overflow: hidden;` | Panel-level scrolling only |
| `white-space` | `white-space: pre;` | For preserving formatting |

---

## Images

Only **data URIs** are supported. No external URLs, no file://, no SVG.

```html
<img src="data:image/png;base64,iVBORw0KGgo..." style="width: 100px;"/>
```

Supported formats: PNG, JPEG (base64 encoded).

---

## Limitations

- **No JavaScript.** `<script>` and `<iframe>` tags are stripped.
- **No external URLs.** Images must be inline data URIs.
- **No SVG.** Only raster images (PNG, JPEG).
- **256KB max HTML size.** Output exceeding this is truncated.
- **No CSS `overflow: scroll` on inner elements.** Panel-level scrolling only.
- **Elements without `id` cannot generate events.** Always assign an `id` to interactive elements.
- **Two-font model.** Only proportional and monospace families are available. CSS font-family selects between them.

---

## Tips

- **Use CSS variables.** They adapt to theme changes automatically.
- **Use `<table>` for data grids.** Tables render cleanly with automatic column sizing.
- **Use `<pre>` for code/logs.** Monospace text preserves formatting.
- **Call `request_refresh()` after state changes.** The host only re-renders when asked.
- **Use a static buffer for dynamic HTML.** The host copies immediately; one buffer works.
- **Start simple.** Begin with a `<p>` and build up complexity incrementally.
