# C++ Plugin Guide

The C++ SDK wraps the C header with RAII classes, `std::variant` messages, and a virtual `Plugin` base class. Requires C++17.

> **Consider HTML first.** For complex UIs, `w.html()` lets you send HTML directly to dvui without composing widgets manually. See [HTML Layout](html-layout).

---

## Setup

```
my-plugin/
  src/plugin.cpp
  inc/
    lib.h          <-- copy from tools/plugins/cpp/inc/lib.h
    schemify_c.h   <-- copy from tools/plugins/c/inc/lib.h
  plugin.toml      <-- manifest (required for v9)
  Makefile
```

The C++ header includes the C header. You need both:
```sh
cp tools/plugins/cpp/inc/lib.h my-plugin/inc/
cp tools/plugins/c/inc/lib.h my-plugin/inc/schemify_c.h
```

Or use the provided Makefile:
```sh
make -f tools/plugins/cpp/Makefile PLUGIN_SRC=src/plugin.cpp PLUGIN_NAME=my_plugin
```

---

## Plugin Manifest

```toml
[plugin]
id = "my-plugin"
name = "My Plugin"
version = "0.1.0"
author = "Your Name"
description = "A demo plugin"
abi = 9

[capabilities]
file_read_project = true
canvas_draw = true

[[panels]]
id = "demo"
title = "Demo Panel"
layout = "left_sidebar"
vim_command = "demo"

[activation]
events = ["onPanel:demo"]

[build]
binary = "libmy_plugin.so"
```

---

## Minimal Plugin

```cpp
#include "lib.h"

class MyPlugin : public schemify::Plugin {
public:
    void on_load(schemify::Writer& w) override {
        w.registerPanel("demo", "Demo Panel", "demo",
                        schemify::Layout::LeftSidebar, 0);
    }

    void on_draw_panel(uint16_t panel_id, schemify::Writer& w) override {
        w.label("Hello from C++!", 1);
        w.slider(value_, 0.0f, 100.0f, 2);
        w.button("Apply", 3);
    }

    void on_slider_changed(uint16_t panel_id, uint32_t widget_id,
                           float val, schemify::Writer& w) override {
        if (widget_id == 2) value_ = val;
    }

    void on_button_clicked(uint16_t panel_id, uint32_t widget_id,
                           schemify::Writer& w) override {
        if (widget_id == 3) {
            w.setStatus("Applied!");
        }
    }

private:
    float value_ = 50.0f;
};

SCHEMIFY_PLUGIN_CPP("my-plugin", "0.1.0", MyPlugin)
```

---

## Using HTML Layout

```cpp
void on_draw_panel(uint16_t panel_id, schemify::Writer& w) override {
    w.html(panel_id, R"(
        <div style="padding: 8px;">
            <h3>Analysis Results</h3>
            <table>
                <tr><td>DC Gain</td><td>42 dB</td></tr>
                <tr><td>UGB</td><td>1.2 MHz</td></tr>
                <tr><td>Phase Margin</td><td>62 deg</td></tr>
            </table>
            <button id="rerun">Re-run Analysis</button>
        </div>
    )");
}
```

C++ raw string literals (`R"(...)"`) make HTML embedding clean.

---

## Provider Pattern

```cpp
class DRCPlugin : public schemify::Plugin {
public:
    void on_load(schemify::Writer& w) override {
        w.registerPanel("drc", "DRC", "drc",
                        schemify::Layout::RightSidebar, 0);
        w.registerProvider("hover_info");
        w.registerProvider("validation");
    }

    void on_provide_hover_info(int32_t wx, int32_t wy, uint8_t etype,
                               int32_t eidx, schemify::Writer& w) override {
        w.hoverInfoResult("Net: VDD\nFanout: 12");
    }

    void on_provide_validation(schemify::Writer& w) override {
        w.validationResult(1, "Missing bulk connection", 100, 200, "fix_bulk");
    }
};
```

---

## Canvas Drawing

```cpp
class AnnotationPlugin : public schemify::Plugin {
public:
    void on_load(schemify::Writer& w) override {
        w.registerPanel("annotate", "Annotate", "annotate",
                        schemify::Layout::LeftSidebar, 0);
        w.subscribeEvents(0x04); // EVENT_CANVAS
    }

    void on_draw_panel(uint16_t panel_id, schemify::Writer& w) override {
        // Layer 16 = first plugin overlay layer
        w.canvasRect(16, 100, 200, 50, 30, 0xFF000040, 0xFF0000FF, 2.0f);
        w.canvasText(16, 105, 195, 0xFFFFFFFF, 12.0f, "Critical Path");
        w.canvasLine(16, 150, 230, 300, 230, 0xFF0000FF, 2.0f);
    }

    void on_canvas_click(int32_t wx, int32_t wy, uint8_t button,
                         uint8_t mods, schemify::Writer& w) override {
        w.setStatus("Canvas clicked");
    }
};
```

---

## Schematic Mutation

```cpp
void generate(schemify::Writer& w) {
    w.beginBatch();  // single undo step
    w.placeDevice("nmos", "M1", 100, 200);
    w.placeDevice("pmos", "M2", 100, 100);
    w.addWire(120, 200, 120, 100);
    w.setInstanceProp(0, "W", "1u");
    w.setInstanceProp(0, "L", "180n");
    w.endBatch();
}
```

---

## Inter-Plugin Communication

```cpp
// Publisher
void on_button_clicked(uint16_t, uint32_t wid, schemify::Writer& w) override {
    if (wid == 1) {
        std::string data = R"({"value": 42})";
        w.publishMessage("my_plugin.data_ready",
                        reinterpret_cast<const uint8_t*>(data.data()),
                        data.size());
    }
}

// Subscriber
void on_plugin_message(std::string_view sender, std::string_view topic,
                       const uint8_t* payload, size_t len,
                       schemify::Writer& w) override {
    if (topic == "my_plugin.data_ready") {
        // handle message
    }
}
```

---

## Build

```sh
make -f tools/plugins/cpp/Makefile \
    PLUGIN_SRC=src/plugin.cpp \
    PLUGIN_NAME=my_plugin
```

Manual:
```sh
c++ -std=c++17 -shared -fPIC -O2 -o libmy_plugin.so src/plugin.cpp \
    -Iinc -Itools/plugins/c/inc
```

---

## Install

```sh
mkdir -p ~/.config/Schemify/my-plugin
cp libmy_plugin.so ~/.config/Schemify/my-plugin/
cp plugin.toml ~/.config/Schemify/my-plugin/
```

---

## Plugin Base Class

```cpp
class Plugin {
public:
    // Lifecycle
    virtual void on_load(Writer& w) {}
    virtual void on_unload(Writer& w) {}
    virtual void on_tick(float dt, Writer& w) {}
    virtual void on_poll(Writer& w) {}

    // Panel UI
    virtual void on_draw_panel(uint16_t panel_id, Writer& w) {}
    virtual void on_button_clicked(uint16_t panel_id, uint32_t widget_id, Writer& w) {}
    virtual void on_slider_changed(uint16_t panel_id, uint32_t widget_id, float val, Writer& w) {}
    virtual void on_checkbox_changed(uint16_t panel_id, uint32_t widget_id, bool val, Writer& w) {}
    virtual void on_text_changed(uint16_t panel_id, uint32_t widget_id,
                                 std::string_view text, Writer& w) {}

    // Commands & state
    virtual void on_command(std::string_view tag, std::string_view payload, Writer& w) {}
    virtual void on_state_response(std::string_view key, std::string_view val, Writer& w) {}

    // Schematic events
    virtual void on_schematic_changed(Writer& w) {}
    virtual void on_selection_changed(int32_t idx, Writer& w) {}
    virtual void on_hover(int32_t x, int32_t y, uint8_t elem_type, int32_t elem_idx,
                          std::string_view name, Writer& w) {}
    virtual void on_key_event(uint8_t key, uint8_t mods, uint8_t action, Writer& w) {}

    // Provider callbacks (v9)
    virtual void on_provide_hover_info(int32_t wx, int32_t wy, uint8_t etype,
                                       int32_t eidx, Writer& w) {}
    virtual void on_provide_completions(std::string_view context,
                                        std::string_view prefix, Writer& w) {}
    virtual void on_provide_diagnostics(std::string_view path, Writer& w) {}
    virtual void on_provide_actions(uint8_t etype, int32_t eidx, Writer& w) {}
    virtual void on_provide_tooltip(uint8_t etype, int32_t eidx, Writer& w) {}
    virtual void on_provide_decoration(uint32_t instance_idx, Writer& w) {}
    virtual void on_provide_netlist_hook(std::string_view format, Writer& w) {}
    virtual void on_provide_validation(Writer& w) {}

    // Canvas events (v9)
    virtual void on_canvas_click(int32_t wx, int32_t wy, uint8_t button,
                                 uint8_t mods, Writer& w) {}
    virtual void on_canvas_drag(int32_t wx, int32_t wy, int32_t dx, int32_t dy,
                                uint8_t button, uint8_t mods, Writer& w) {}
    virtual void on_canvas_scroll(int32_t wx, int32_t wy, float dx, float dy, Writer& w) {}

    // IPC (v9)
    virtual void on_plugin_message(std::string_view sender, std::string_view topic,
                                   const uint8_t* payload, size_t len, Writer& w) {}
};
```

---

## Writer Methods

```cpp
// Commands
w.registerPanel("id", "title", "vim_cmd", Layout::LeftSidebar, keybind);
w.setStatus("msg");
w.pushCommand("cmd", "payload");
w.getState("key");
w.setState("key", "value");
w.getConfig("plugin_id", "key");
w.setConfig("plugin_id", "key", "value");
w.registerCommand("id", "Display Name", "Description");
w.subscribeEvents(mask);  // 1=hover, 2=keys, 4=canvas
w.consumeEvent();
w.yieldPending();
w.html(panel_id, "html");
w.log(level, "tag", "message");

// Widgets
w.label("text", id);
w.button("text", id);
w.slider(val, min, max, id);
w.checkbox(val, "text", id);
w.textInput("hint", "text", id);
w.textArea("hint", "text", id);
w.progress(fraction, id);
w.separator(id);
w.beginRow(id);
w.endRow(id);
w.collapsibleStart("label", open, id);
w.collapsibleEnd(id);
w.dropdown("Option A\nOption B\nOption C", 0, id);
w.table("Name\tValue", "R1\t10k\nR2\t20k", id);
w.tabBar("Tab 1\nTab 2\nTab 3", 0, id);

// Provider responses (v9)
w.registerProvider("hover_info");
w.hoverInfoResult("text");
w.completionResult("label", "insert_text", "detail");
w.diagnosticResult(severity, "msg", x, y);
w.actionResult("label", "command");
w.tooltipResult("text");
w.decorationResult(color, style);
w.validationResult(severity, "msg", x, y, "fix_cmd");

// Canvas drawing (v9)
w.canvasClearLayer(16);
w.canvasLine(16, x0, y0, x1, y1, color, width);
w.canvasRect(16, x, y, w, h, fill, stroke, stroke_width);
w.canvasCircle(16, cx, cy, r, fill, stroke);
w.canvasText(16, x, y, color, size, "text");
w.canvasBeginGroup(16, "name");
w.canvasEndGroup(16);
w.canvasSetTransform(16, a, b, c, d, tx, ty);
w.canvasResetTransform(16);

// Schematic mutation (v9)
w.beginBatch();
w.endBatch();
w.deleteInstance(idx);
w.moveInstance(idx, dx, dy);
w.rotateInstance(idx, rotation);
w.mirrorInstance(idx, axis);
w.duplicateInstance(idx, dx, dy);
w.renameInstance(idx, "name");
w.deleteWire(idx);
w.moveWire(idx, dx, dy);
w.mergeWires(a, b);
w.renameNet(idx, "VDD");
w.undo();
w.redo();
w.clearSelection();
w.copySelection();
w.paste(x, y);
w.cutSelection();
w.queryInstanceAt(x, y);
w.queryBoundingBox();

// IPC (v9)
w.publishMessage("topic", payload, payload_len);
```

---

## Tips

- `std::string_view` is used for all string parameters — zero-copy from the message buffer
- RTTI and exceptions can be disabled for smaller `.so` files (the SDK doesn't use them)
- The `SCHEMIFY_PLUGIN_CPP` macro handles static initialization and the C export
- `beginBatch()`/`endBatch()` wraps multiple mutations into a single undo step
- Provider registration should be done in `on_load()`
