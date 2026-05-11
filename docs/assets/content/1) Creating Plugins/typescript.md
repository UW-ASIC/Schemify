# TypeScript Plugin Guide

TypeScript plugins run as subprocesses using the [Bun](https://bun.sh) runtime. The SDK is a single file (`lib.ts`) — no npm install needed.

> **Consider HTML first.** `w.html()` sends HTML directly to dvui for rendering. See [HTML Layout](html-layout).

---

## Setup

```
my-plugin/
  src/plugin.ts
  lib.ts            <-- copy from tools/plugins/js_w_bun/src/lib.ts
  plugin.toml       <-- manifest (required for v9)
  package.json
```

Copy the SDK:
```sh
cp tools/plugins/js_w_bun/src/lib.ts my-plugin/lib.ts
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

[[panels]]
id = "demo"
title = "Demo"
layout = "left_sidebar"
vim_command = "demo"

[activation]
events = ["onPanel:demo"]

[build]
binary = "src/plugin.ts"
```

---

## Minimal Plugin

```typescript
import { Plugin, Writer, Layout, run } from "./lib";

class MyPlugin extends Plugin {
    private sliderVal = 50.0;

    onLoad(w: Writer) {
        w.registerPanel("demo", "Demo", "demo", Layout.LeftSidebar);
        w.setStatus("Plugin loaded");
    }

    onDrawPanel(panelId: number, w: Writer) {
        w.label("Resistance (kOhm)", 1);
        w.slider(this.sliderVal, 0.0, 100.0, 2);
        w.button("Apply", 3);
    }

    onSliderChanged(panelId: number, widgetId: number, val: number, w: Writer) {
        if (widgetId === 2) this.sliderVal = val;
    }

    onButtonClicked(panelId: number, widgetId: number, w: Writer) {
        if (widgetId === 3) w.setStatus("Applied!");
    }
}

run(new MyPlugin());
```

---

## Using HTML Layout

```typescript
onDrawPanel(panelId: number, w: Writer) {
    w.html(panelId, `
        <div style="padding: 8px;">
            <h3>Analysis Dashboard</h3>
            <table style="width: 100%;">
                <tr><td>Gain</td><td>${this.gain} dB</td></tr>
                <tr><td>BW</td><td>${this.bandwidth} MHz</td></tr>
                <tr><td>PM</td><td>${this.phaseMargin} deg</td></tr>
            </table>
            <div style="display: flex; gap: 4px; margin-top: 8px;">
                <button id="rerun">Re-run</button>
                <button id="export">Export</button>
            </div>
        </div>
    `);
}
```

Template literals make HTML embedding natural in TypeScript.

---

## Provider Pattern

```typescript
class DRCPlugin extends Plugin {
    onLoad(w: Writer) {
        w.registerPanel("drc", "DRC", "drc", Layout.RightSidebar);
        w.registerProvider("hover_info");
        w.registerProvider("validation");
    }

    onProvideHoverInfo(wx: number, wy: number, etype: number,
                       eidx: number, w: Writer) {
        w.hoverInfoResult("Net: VDD\nFanout: 12");
    }

    onProvideValidation(w: Writer) {
        w.validationResult(1, "Missing connection", 100, 200, "fix_conn");
    }
}
```

---

## Canvas Drawing

```typescript
class AnnotationPlugin extends Plugin {
    onLoad(w: Writer) {
        w.registerPanel("annotate", "Annotate", "annotate", Layout.LeftSidebar);
        w.subscribeEvents(0x04); // EVENT_CANVAS
    }

    onDrawPanel(panelId: number, w: Writer) {
        // Layer 16 = first plugin overlay layer
        w.canvasRect(16, 100, 200, 50, 30, 0xFF000040, 0xFF0000FF, 2.0);
        w.canvasText(16, 105, 195, 0xFFFFFFFF, 12.0, "Critical Path");
        w.canvasLine(16, 150, 230, 300, 230, 0xFF0000FF, 2.0);
    }

    onCanvasClick(wx: number, wy: number, button: number,
                  mods: number, w: Writer) {
        w.setStatus("Canvas clicked");
    }
}
```

---

## Schematic Mutation

```typescript
generate(w: Writer) {
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

```typescript
// Publisher
onButtonClicked(panelId: number, widgetId: number, w: Writer) {
    if (widgetId === 1) {
        w.publishMessage("my_plugin.data_ready",
                        new TextEncoder().encode(JSON.stringify({value: 42})));
    }
}

// Subscriber
onPluginMessage(sender: string, topic: string, payload: Uint8Array, w: Writer) {
    if (topic === "my_plugin.data_ready") {
        const data = JSON.parse(new TextDecoder().decode(payload));
        // handle message
    }
}
```

---

## Build & Run

TypeScript plugins run as subprocesses — no compilation to `.so` needed:

```sh
bun run src/plugin.ts
```

Or build a standalone bundle:
```sh
bun build src/plugin.ts --outdir dist --target bun
```

---

## Install

```sh
mkdir -p ~/.config/Schemify/my-plugin
cp src/plugin.ts ~/.config/Schemify/my-plugin/
cp lib.ts ~/.config/Schemify/my-plugin/
cp plugin.toml ~/.config/Schemify/my-plugin/
```

---

## Plugin Base Class

```typescript
abstract class Plugin {
    // Lifecycle
    onLoad(w: Writer): void {}
    onUnload(w: Writer): void {}
    onTick(dt: number, w: Writer): void {}
    onPoll(w: Writer): void {}

    // Panel UI
    onDrawPanel(panelId: number, w: Writer): void {}
    onButtonClicked(panelId: number, widgetId: number, w: Writer): void {}
    onSliderChanged(panelId: number, widgetId: number, val: number, w: Writer): void {}
    onCheckboxChanged(panelId: number, widgetId: number, val: boolean, w: Writer): void {}
    onTextChanged(panelId: number, widgetId: number, text: string, w: Writer): void {}

    // Commands & state
    onCommand(tag: string, payload: string, w: Writer): void {}
    onStateResponse(key: string, val: string, w: Writer): void {}

    // Schematic events
    onSchematicChanged(w: Writer): void {}
    onSelectionChanged(idx: number, w: Writer): void {}
    onHover(x: number, y: number, elemType: number, elemIdx: number,
            name: string, w: Writer): void {}
    onKeyEvent(key: number, mods: number, action: number, w: Writer): void {}

    // Provider callbacks (v9)
    onProvideHoverInfo(wx: number, wy: number, etype: number,
                       eidx: number, w: Writer): void {}
    onProvideCompletions(context: string, prefix: string, w: Writer): void {}
    onProvideDiagnostics(path: string, w: Writer): void {}
    onProvideActions(etype: number, eidx: number, w: Writer): void {}
    onProvideTooltip(etype: number, eidx: number, w: Writer): void {}
    onProvideDecoration(instanceIdx: number, w: Writer): void {}
    onProvideNetlistHook(format: string, w: Writer): void {}
    onProvideValidation(w: Writer): void {}

    // Canvas events (v9)
    onCanvasClick(wx: number, wy: number, button: number,
                  mods: number, w: Writer): void {}
    onCanvasDrag(wx: number, wy: number, dx: number, dy: number,
                 button: number, mods: number, w: Writer): void {}
    onCanvasScroll(wx: number, wy: number, dx: number, dy: number,
                   w: Writer): void {}

    // IPC (v9)
    onPluginMessage(sender: string, topic: string, payload: Uint8Array,
                    w: Writer): void {}
}
```

---

## Writer Methods

```typescript
// Commands
w.registerPanel("id", "Title", "vim_cmd", Layout.LeftSidebar);
w.setStatus("message");
w.pushCommand("zoom_fit", "");
w.getState("key");
w.setState("key", "value");
w.getConfig("plugin_id", "key");
w.setConfig("plugin_id", "key", "value");
w.registerCommand("id", "Display Name", "Description");
w.subscribeEvents(7);  // 1=hover, 2=keys, 4=canvas
w.consumeEvent();
w.yieldPending();
w.html(panelId, "<h1>Hello</h1>");
w.log(level, "tag", "message");

// Widgets
w.label("text", 1);
w.button("text", 2);
w.separator(3);
w.slider(val, min, max, 4);
w.checkbox(val, "text", 5);
w.progress(0.75, 6);
w.textInput("hint", "text", 7);
w.textArea("hint", "text", 8);
w.beginRow(9);
w.endRow(9);
w.collapsibleStart("label", true, 10);
w.collapsibleEnd(10);
w.tooltip("hover text", 11);
w.dropdown("Option A\nOption B\nOption C", 0, 12);
w.table("Name\tValue", "R1\t10k\nR2\t20k", 13);
w.tabBar("Tab 1\nTab 2\nTab 3", 0, 14);

// Provider responses (v9)
w.registerProvider("hover_info");
w.hoverInfoResult("Net: VDD\nFanout: 12");
w.completionResult("label", "insert_text", "detail");
w.diagnosticResult(severity, "msg", x, y);
w.actionResult("label", "command");
w.tooltipResult("text");
w.decorationResult(color, style);
w.validationResult(severity, "msg", x, y, "fix_cmd");

// Canvas drawing (v9)
w.canvasClearLayer(16);
w.canvasLine(16, x0, y0, x1, y1, color, width);
w.canvasRect(16, x, y, w, h, fill, stroke, strokeWidth);
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
w.publishMessage("topic", payload);
```

---

## Subprocess Protocol

TypeScript plugins communicate with the host via stdin/stdout binary frames:

```
Host -> Plugin: [u32 in_len LE][in_bytes...]
Plugin -> Host: [u32 out_len LE][out_bytes...]
```

The `run()` function handles this loop automatically. You don't need to deal with the binary protocol directly.

---

## Tips

- Requires [Bun](https://bun.sh) runtime (Node.js is not supported due to stdin handling differences)
- The subprocess is started by the host — don't worry about process management
- TypeScript plugins can use any npm packages available to Bun
- Widget IDs must be unique per panel and stable across frames
- Template literals with `${...}` interpolation are the cleanest way to generate dynamic HTML
- `beginBatch()`/`endBatch()` wraps multiple mutations into a single undo step
- Provider registration should be done in `onLoad()`
