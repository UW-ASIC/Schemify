# API Reference (Plugin API v1)

Complete reference for all export functions, the host function pointer table, sub-tables, and data formats.

---

## Plugin Export Functions

C ABI symbols exported by a plugin. Resolved via `dlsym` (native) or WASM export table.

### schemify_activate (REQUIRED)

```c
void schemify_activate(const SchemifyHost* host);
```

Called once when the plugin is loaded. Store the `host` pointer for later use. Register panels, commands, keybinds, and providers here.

- `host` -- pointer to the host function table, valid for the plugin's lifetime

---

### schemify_deactivate

```c
void schemify_deactivate(void);
```

Called when the plugin is being unloaded. Clean up resources (open files, allocated memory).

---

### schemify_render

```c
const char* schemify_render(const char* panel_id);
```

Called when the host needs to display a plugin panel. Return an HTML string or NULL for no content.

- `panel_id` -- null-terminated string identifying which panel to render
- **Returns:** HTML string owned by the plugin. Valid until the next `schemify_*` call. NULL means no content.

---

### schemify_on_html_event

```c
void schemify_on_html_event(const char* panel_id, const char* event_json);
```

Called when the user interacts with an HTML element that has an `id` attribute.

- `panel_id` -- which panel the event originated from
- `event_json` -- JSON string (see [Event JSON Format](#html-event-json))

---

### schemify_on_command

```c
void schemify_on_command(const char* name, const char* args);
```

Called when a command registered by this plugin is invoked.

- `name` -- the command name as registered
- `args` -- JSON string with arguments (may be `""` for no args)

---

### schemify_on_schematic_changed

```c
void schemify_on_schematic_changed(void);
```

Called after the schematic data model is modified (instance placed, wire drawn, property changed).

---

### schemify_on_selection_changed

```c
void schemify_on_selection_changed(const char* selection_json);
```

Called when the user's selection changes.

```json
{"instances": ["M1", "M2"], "wires": [3, 7], "nets": ["VDD"]}
```

---

### schemify_on_key_event

```c
void schemify_on_key_event(const char* key_json);
```

Called for keybinds registered by this plugin.

```json
{"key": "r", "mods": ["ctrl", "shift"], "action": "press"}
```

Valid modifiers: `"ctrl"`, `"shift"`, `"alt"`, `"super"`
Valid actions: `"press"`, `"release"`

---

### schemify_on_hover

```c
void schemify_on_hover(const char* hover_json);
```

Called when the cursor hovers over schematic elements.

```json
{"x": 150.0, "y": 200.0, "instances": ["M1"], "nets": ["net0"], "wires": [2]}
```

---

### schemify_provide

```c
const char* schemify_provide(const char* provider_type, const char* context_json);
```

Called when the host queries a registered provider.

- `provider_type` -- type registered via `register_provider` (e.g., `"hover_info"`, `"validation"`)
- `context_json` -- query context (provider-type-specific)
- **Returns:** JSON result string owned by plugin. NULL means no result.

---

### schemify_on_message

```c
void schemify_on_message(const char* sender, const char* topic, const char* payload);
```

Called when another plugin publishes a message to a subscribed topic.

- `sender` -- plugin ID of the sender
- `topic` -- message topic string
- `payload` -- JSON payload string

---

## Metadata Exports

Three metadata symbols checked at load time:

```c
const uint32_t schemify_api_version;    // Must be 1
const char*    schemify_plugin_name;    // Plugin name
const char*    schemify_plugin_version; // Semver string
```

The C SDK provides a convenience macro:
```c
SCHEMIFY_PLUGIN("my-plugin", "1.0.0")
```

---

## SchemifyHost Struct

The full function pointer table passed to `schemify_activate`:

```c
typedef struct SchemifyHost {
    /* Core */
    void            (*log)(const char* level, const char* msg);
    void            (*set_status)(const char* msg);
    schemify_bool   (*push_command)(const char* cmd);
    void            (*request_refresh)(void);

    /* Files */
    const char*     (*read_file)(const char* path);
    schemify_bool   (*write_file)(const char* path, const char* data);
    const char*     (*project_dir)(void);
    const char*     (*plugin_data_dir)(void);

    /* Registration */
    void            (*register_panel)(const char* panel_json);
    void            (*unregister_panel)(const char* panel_id);
    void            (*register_command)(const char* cmd_json);
    void            (*register_keybind)(const char* keybind_json);
    void            (*register_provider)(const char* provider_type);

    /* IPC */
    void            (*publish)(const char* topic, const char* payload);

    /* Sub-tables */
    const SchemifyCanvas*    canvas;
    const SchemifySchematic* schematic;
} SchemifyHost;
```

**16 core functions + 2 sub-table pointers.** Boolean return/parameter type is `int` (not `_Bool`) for cross-language ABI stability. Defined as `typedef int schemify_bool;`.

---

### Core Functions (4)

| Function | Signature | Description | Thread-safe |
|----------|-----------|-------------|-------------|
| `log` | `void (const char* level, const char* msg)` | Log to the Schemify log panel. Levels: `"debug"`, `"info"`, `"warn"`, `"error"` | Yes (queued) |
| `set_status` | `void (const char* msg)` | Set the status bar text | Yes (queued) |
| `push_command` | `schemify_bool (const char* cmd)` | Execute a Schemify command by name. Returns 1 if found. | Yes (queued) |
| `request_refresh` | `void (void)` | Request re-render of this plugin's panels on next frame | Yes (queued) |

### File Functions (4)

| Function | Signature | Description | Thread-safe |
|----------|-----------|-------------|-------------|
| `read_file` | `const char* (const char* path)` | Read file contents. Returns NULL on failure. | Yes (OS handles) |
| `write_file` | `schemify_bool (const char* path, const char* data)` | Write data to file. Returns 1 on success. | Yes (OS handles) |
| `project_dir` | `const char* (void)` | Current project directory. NULL if no project open. | Yes (immutable) |
| `plugin_data_dir` | `const char* (void)` | Plugin's persistent data dir. Auto-created on first call. | Yes (immutable) |

### Registration Functions (5)

| Function | Signature | Description | Thread-safe |
|----------|-----------|-------------|-------------|
| `register_panel` | `void (const char* panel_json)` | Register a panel (see format below) | Yes (queued) |
| `unregister_panel` | `void (const char* panel_id)` | Remove a registered panel | Yes (queued) |
| `register_command` | `void (const char* cmd_json)` | Register a command | Yes (queued) |
| `register_keybind` | `void (const char* keybind_json)` | Register a keybind | Yes (queued) |
| `register_provider` | `void (const char* provider_type)` | Register as a data provider | Yes (queued) |

### IPC Function (1)

| Function | Signature | Description | Thread-safe |
|----------|-----------|-------------|-------------|
| `publish` | `void (const char* topic, const char* payload)` | Publish to IPC bus | Yes (queued) |

---

## Registration JSON Formats

### register_panel

```json
{"id": "my-panel", "title": "My Panel", "layout": "right_sidebar"}
```

Valid `layout` values: `"left_sidebar"`, `"right_sidebar"`, `"bottom"`, `"floating"`

### register_command

```json
{"name": "my_plugin.do_thing", "description": "Does the thing"}
```

### register_keybind

```json
{"key": "r", "mods": ["ctrl"], "command": "my_plugin.do_thing"}
```

### register_provider

Plain string (not JSON): `"hover_info"`, `"completions"`, `"diagnostics"`, `"actions"`, `"tooltip"`, `"decoration"`, `"netlist_hook"`, `"validation"`

---

## SchemifyCanvas Sub-table

Drawing primitives for the schematic canvas overlay. Access via `host->canvas`.

```c
typedef struct SchemifyCanvas {
    void (*clear_layer)(int layer);
    void (*line)(float x1, float y1, float x2, float y2,
                 uint32_t color, float width);
    void (*rect)(float x, float y, float w, float h,
                 uint32_t color, schemify_bool filled);
    void (*circle)(float cx, float cy, float r,
                   uint32_t color, schemify_bool filled);
    void (*text)(float x, float y, const char* text,
                 uint32_t color, float size);
    void (*polyline)(const float* points, int count,
                     uint32_t color, float width);
    void (*polygon)(const float* points, int count,
                    uint32_t color, schemify_bool filled);
    void (*arc)(float cx, float cy, float r, float start_angle, float end_angle,
                uint32_t color, float width);
    void (*image)(float x, float y, float w, float h, const char* data_uri);
} SchemifyCanvas;
```

| Function | Description |
|----------|-------------|
| `clear_layer(layer)` | Clear all drawings on the specified layer |
| `line(x1,y1,x2,y2,color,width)` | Draw a line segment |
| `rect(x,y,w,h,color,filled)` | Draw a rectangle (outline or filled) |
| `circle(cx,cy,r,color,filled)` | Draw a circle (outline or filled) |
| `text(x,y,text,color,size)` | Draw text at a position |
| `polyline(points,count,color,width)` | Draw connected line segments |
| `polygon(points,count,color,filled)` | Draw a closed polygon |
| `arc(cx,cy,r,start,end,color,width)` | Draw a circular arc (angles in radians) |
| `image(x,y,w,h,data_uri)` | Draw an image from a data URI |

**Color format:** 32-bit RGBA (`0xRRGGBBAA`). Example: `0xFF0000FF` = opaque red.

**Coordinates:** Schematic-space (not screen pixels). The host transforms to screen coordinates.

**Points array:** For `polyline` and `polygon`, points are interleaved `[x0, y0, x1, y1, ...]`. `count` is the number of points (array length / 2).

**Layers:** 0-15 reserved for host. Plugins use 16-127 (overlays above schematic) or 128-255 (underlays below schematic, above grid).

All canvas calls are thread-safe (queued into a per-plugin draw command list, replayed on main thread).

---

## SchemifySchematic Sub-table

Query and modify the schematic data model. Access via `host->schematic`.

```c
typedef struct SchemifySchematic {
    const char* (*instances)(void);
    const char* (*nets)(void);
    const char* (*wires)(void);
    const char* (*selection)(void);
    const char* (*instance)(const char* id);
    const char* (*net)(const char* id);
    const char* (*config)(const char* key);
    void        (*set_config)(const char* key, const char* value);
} SchemifySchematic;
```

| Function | Returns | Description |
|----------|---------|-------------|
| `instances()` | JSON array | All instances (id, kind, position) |
| `nets()` | JSON array | All net names |
| `wires()` | JSON array | All wire segments |
| `selection()` | JSON object | Current selection state |
| `instance(id)` | JSON object | Full details for one instance |
| `net(id)` | JSON object | Full details for one net |
| `config(key)` | String | Read a schematic config value |
| `set_config(key, value)` | void | Write a schematic config value |

All read functions are thread-safe (read from snapshot). `set_config` is thread-safe (queued).

**Instance JSON (`instance(id)`):**
```json
{
  "id": "M1",
  "kind": "nmos",
  "x": 100, "y": 200,
  "rotation": 0,
  "mirror": false,
  "properties": {"W": "10u", "L": "180n", "nf": "1"}
}
```

**Net JSON (`net(id)`):**
```json
{
  "name": "VDD",
  "pins": [
    {"instance": "M1", "pin": "D"},
    {"instance": "M2", "pin": "S"}
  ]
}
```

---

## HTML Event JSON

Sent to `schemify_on_html_event`:

```json
{"type": "click", "id": "run-btn", "tag": "button", "value": ""}
{"type": "change", "id": "width-input", "tag": "input", "value": "10u"}
{"type": "change", "id": "pdk-select", "tag": "select", "value": "sky130"}
{"type": "change", "id": "my-checkbox", "tag": "input", "value": "true"}
{"type": "submit", "id": "settings-form", "tag": "form", "value": ""}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"click"` for buttons/links, `"change"` for inputs/selects, `"submit"` for forms |
| `id` | string | The HTML element's `id` attribute |
| `tag` | string | The HTML tag name in lowercase |
| `value` | string | Current value for inputs/selects; empty string for buttons/forms |

Elements without an `id` attribute cannot generate events.

---

## Memory Conventions

### Plugin-owned strings

Strings returned by plugin exports (`schemify_render`, `schemify_provide`) are owned by the plugin. The host copies immediately. The plugin must keep the pointer valid until the next `schemify_*` call.

Common patterns:
- Return a string literal (always valid)
- Return a pointer to a static buffer that gets overwritten each call
- Return a heap allocation freed on the next call

### Host-owned strings

Strings returned by host functions (`read_file`, `project_dir`, `plugin_data_dir`, schematic queries) are owned by the host. Valid until the next call to the **same** host function from the **same** plugin.

### Null safety

- All `const char*` parameters from the host are guaranteed non-NULL
- Plugin return values may be NULL (meaning "no result")
- Host function pointers may be NULL if the capability is unavailable (check before calling, or use SDK wrappers)

---

## API Version

Current version: **1**. The host checks `schemify_api_version` at load time. Plugins built against API v1 are guaranteed forward-compatible within the v1 series.
