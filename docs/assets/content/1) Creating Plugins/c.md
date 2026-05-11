# C Plugin Guide

The C SDK is a single header file (`lib.h`) -- copy it into your project and compile. No dependencies, no package manager, C99 compatible.

---

## Setup

```
my-plugin/
  src/plugin.c
  inc/lib.h        <-- copy from tools/plugins/c/inc/lib.h
  plugin.toml
  Makefile
```

Copy the header:
```sh
cp tools/plugins/c/inc/lib.h my-plugin/inc/
```

---

## Complete Working Example

This plugin registers a panel, renders HTML with interactive elements, and handles events.

### plugin.toml

```toml
[plugin]
name = "My Counter"
version = "1.0.0"
author = "Your Name"
description = "A simple counter plugin"
api = 1

[activation]
events = ["on_startup"]

[[panels]]
id = "counter"
title = "Counter"
layout = "right_sidebar"
keybind = "n"
vim_cmd = "counter"

[build]
binary = "counter.so"
```

### src/plugin.c

```c
#include "lib.h"
#include <stdio.h>
#include <string.h>

SCHEMIFY_PLUGIN("counter", "1.0.0")

static const SchemifyHost* host;
static int count = 0;
static char html[2048];

void schemify_activate(const SchemifyHost* h) {
    host = h;
    host->log("info", "Counter plugin activated");
    host->register_panel(
        "{\"id\":\"counter\",\"title\":\"Counter\",\"layout\":\"right_sidebar\"}");
}

void schemify_deactivate(void) {
    /* Nothing to clean up */
}

const char* schemify_render(const char* panel_id) {
    if (strcmp(panel_id, "counter") != 0) return NULL;

    snprintf(html, sizeof(html),
        "<div style='padding: 12px;'>"
        "  <h2 style='color: var(--accent);'>Counter</h2>"
        "  <p style='font-size: 32px; text-align: center; "
        "     color: var(--fg);'>%d</p>"
        "  <div style='display: flex; gap: 8px;'>"
        "    <button id='dec'>-</button>"
        "    <button id='inc'>+</button>"
        "    <button id='reset'>Reset</button>"
        "  </div>"
        "  <hr/>"
        "  <div>"
        "    <label style='color: var(--fg);'>Step size:</label>"
        "    <input id='step' type='text' value='1'/>"
        "  </div>"
        "</div>",
        count);
    return html;
}

void schemify_on_html_event(const char* panel_id, const char* event_json) {
    if (strstr(event_json, "\"id\":\"inc\"")) {
        count++;
    } else if (strstr(event_json, "\"id\":\"dec\"")) {
        count--;
    } else if (strstr(event_json, "\"id\":\"reset\"")) {
        count = 0;
    }
    /* Step size input changes could be parsed from the "value" field */
    host->request_refresh();
}

void schemify_on_command(const char* name, const char* args) {
    if (strcmp(name, "counter.reset") == 0) {
        count = 0;
        host->request_refresh();
    }
}
```

---

## Build

### Makefile

```makefile
CC      ?= cc
CFLAGS  = -std=c99 -O2 -Wall -Wextra -fPIC
LDFLAGS = -shared
TARGET  = counter.so

all: $(TARGET)

$(TARGET): src/plugin.c
	$(CC) $(CFLAGS) $(LDFLAGS) -Iinc -o $@ $<

clean:
	rm -f $(TARGET)
```

### Manual compilation

```sh
cc -std=c99 -shared -fPIC -O2 -Iinc -o counter.so src/plugin.c
```

### Cross-compile to WASM

```sh
clang --target=wasm32 -O2 -nostdlib \
    -Wl,--no-entry -Wl,--export-dynamic -Wl,--allow-undefined \
    -Iinc -o counter.wasm src/plugin.c
```

---

## Install

```sh
mkdir -p ~/.config/schemify/plugins/counter
cp counter.so plugin.toml ~/.config/schemify/plugins/counter/
```

Launch Schemify -- the plugin appears in the sidebar.

---

## The Activate/Render/Event Pattern

Every C plugin follows this pattern:

1. **Activate**: Store the host pointer. Register panels, commands, keybinds.
2. **Render**: Return HTML string for the requested panel_id. Use a static buffer.
3. **Event**: Parse the event JSON, update internal state, call `request_refresh()`.

```c
// 1. Store host, register
void schemify_activate(const SchemifyHost* h) {
    host = h;
    host->register_panel("{\"id\":\"x\",\"title\":\"X\",\"layout\":\"right_sidebar\"}");
}

// 2. Return HTML (static buffer pattern)
const char* schemify_render(const char* panel_id) {
    snprintf(buf, sizeof(buf), "<p>Value: %d</p>", state);
    return buf;
}

// 3. Handle events, update state
void schemify_on_html_event(const char* panel_id, const char* ev) {
    if (strstr(ev, "\"id\":\"btn\"")) { /* update state */ }
    host->request_refresh();
}
```

---

## Using the Host API

### Canvas Drawing

```c
void draw_highlight(void) {
    if (!host->canvas) return;
    host->canvas->clear_layer(16);
    host->canvas->rect(100, 200, 50, 30, 0xFF000080, SCHEMIFY_FALSE);
    host->canvas->text(105, 195, "Critical", 0xFF0000FF, 12.0f);
    host->canvas->line(100, 230, 300, 230, 0x00FF00FF, 2.0f);
}
```

### Schematic Queries

```c
void show_instances(void) {
    if (!host->schematic) return;
    const char* json = host->schematic->instances();
    /* json is a JSON array: [{"id":"M1","kind":"nmos",...}, ...] */
    host->log("info", json);
}
```

### File I/O

```c
void save_state(void) {
    const char* dir = host->plugin_data_dir();
    char path[512];
    snprintf(path, sizeof(path), "%s/state.json", dir);
    host->write_file(path, "{\"count\": 42}");
}
```

### Commands and IPC

```c
void schemify_activate(const SchemifyHost* h) {
    host = h;
    host->register_command(
        "{\"name\":\"counter.reset\",\"description\":\"Reset counter\"}");
    host->register_keybind(
        "{\"key\":\"0\",\"mods\":[\"ctrl\"],\"command\":\"counter.reset\"}");
}
```

---

## Convenience Macros

The SDK header provides macros that use a global `_schemify_host` pointer (set via `SCHEMIFY_ACTIVATE_STORE_HOST`):

```c
void schemify_activate(const SchemifyHost* h) {
    SCHEMIFY_ACTIVATE_STORE_HOST(h);  /* sets _schemify_host = h */
    schemify_log("info", "Activated");
    schemify_reg_panel("{\"id\":\"x\",\"title\":\"X\",\"layout\":\"right_sidebar\"}");
}

const char* schemify_render(const char* panel_id) {
    const char* instances = schemify_instances();
    /* ... */
}
```

Define `SCHEMIFY_NO_CONVENIENCE` before including `lib.h` to disable these macros.

---

## Tips

- Use `snprintf` with a static buffer for `schemify_render` -- the host copies immediately.
- The `SCHEMIFY_PLUGIN` macro exports API version + name + version symbols.
- All host function pointers in sub-tables may be NULL -- check before calling.
- For JSON parsing, `strstr` works for simple cases. For complex parsing, bring a JSON library (cJSON, yyjson).
- `schemify_bool` is `int` (not `_Bool`) for ABI stability. Use `SCHEMIFY_TRUE`/`SCHEMIFY_FALSE`.
