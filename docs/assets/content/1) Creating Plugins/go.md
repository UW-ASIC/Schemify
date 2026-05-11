# Go Plugin Guide

Go plugins use TinyGo for compilation to both native shared libraries and WASM. The SDK is a single file (`schemify.go`) with no external dependencies.

> **Consider HTML first.** `w.HtmlLayout()` sends HTML directly to dvui for rendering. See [HTML Layout](html-layout).

---

## Setup

```
my-plugin/
  src/
    main.go
    go.mod
  schemify.go     <-- copy from tools/plugins/tinygo/schemify.go
  plugin.toml     <-- manifest (required for v9)
```

Copy the SDK:
```sh
cp tools/plugins/tinygo/schemify.go my-plugin/src/
```

`go.mod`:
```
module my-plugin

go 1.21
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
binary = "libmy_plugin.so"
```

---

## Minimal Plugin

```go
package main

import sp "schemify"

type MyPlugin struct {
    sliderVal float32
}

func (p *MyPlugin) OnLoad(w *sp.WriterBuf) {
    w.RegisterPanel("demo", "Demo", "demo", sp.LayoutLeftSidebar, 0)
    w.SetStatus("Plugin loaded")
    p.sliderVal = 50.0
}

func (p *MyPlugin) OnDrawPanel(panelId uint16, w *sp.WriterBuf) {
    w.Label("Resistance (kOhm)", 1)
    w.Slider(p.sliderVal, 0.0, 100.0, 2)
    w.Button("Apply", 3)
}

func (p *MyPlugin) OnSliderChanged(panelId uint16, widgetId uint32, val float32, w *sp.WriterBuf) {
    if widgetId == 2 {
        p.sliderVal = val
    }
}

func (p *MyPlugin) OnButtonClicked(panelId uint16, widgetId uint32, w *sp.WriterBuf) {
    if widgetId == 3 {
        w.SetStatus("Applied!")
    }
}

// Required interface methods (implement as needed)
func (p *MyPlugin) OnUnload(w *sp.WriterBuf)                   {}
func (p *MyPlugin) OnTick(dt float32, w *sp.WriterBuf)          {}
func (p *MyPlugin) OnPoll(w *sp.WriterBuf)                      {}
func (p *MyPlugin) OnCheckboxChanged(panelId uint16, widgetId uint32, val bool, w *sp.WriterBuf) {}
func (p *MyPlugin) OnTextChanged(panelId uint16, widgetId uint32, text []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnCommand(tag, payload []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnStateResponse(key, val []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnSelectionChanged(idx int32, w *sp.WriterBuf) {}
func (p *MyPlugin) OnSchematicChanged(w *sp.WriterBuf) {}
func (p *MyPlugin) OnInstanceData(idx uint32, name, symbol []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnHover(x, y int32, elemType uint8, elemIdx int32, name []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnKeyEvent(key, mods, action uint8, w *sp.WriterBuf) {}

// Provider callbacks (v9)
func (p *MyPlugin) OnProvideHoverInfo(wx, wy int32, etype uint8, eidx int32, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideCompletions(context, prefix []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideDiagnostics(path []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideActions(etype uint8, eidx int32, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideTooltip(etype uint8, eidx int32, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideDecoration(instanceIdx uint32, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideNetlistHook(format []byte, w *sp.WriterBuf) {}
func (p *MyPlugin) OnProvideValidation(w *sp.WriterBuf) {}

// Canvas events (v9)
func (p *MyPlugin) OnCanvasClick(wx, wy int32, button, mods uint8, w *sp.WriterBuf) {}
func (p *MyPlugin) OnCanvasDrag(wx, wy, dx, dy int32, button, mods uint8, w *sp.WriterBuf) {}
func (p *MyPlugin) OnCanvasScroll(wx, wy int32, dx, dy float32, w *sp.WriterBuf) {}

// IPC (v9)
func (p *MyPlugin) OnPluginMessage(sender, topic, payload []byte, w *sp.WriterBuf) {}

var plugin = &MyPlugin{}

//export schemify_process
func schemify_process(inPtr *byte, inLen uint32, outPtr *byte, outCap uint32) uint32 {
    return sp.Process(plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
```

---

## Using HTML Layout

```go
func (p *MyPlugin) OnDrawPanel(panelId uint16, w *sp.WriterBuf) {
    w.HtmlLayout(panelId, []byte(`
        <div style="padding: 8px;">
            <h3>Circuit Status</h3>
            <table>
                <tr><td>Instances</td><td>42</td></tr>
                <tr><td>Nets</td><td>18</td></tr>
                <tr><td>DRC</td><td>Clean</td></tr>
            </table>
            <button id="refresh">Refresh</button>
        </div>
    `))
}
```

Use Go's raw string literals (backticks) for HTML.

---

## Provider Pattern

```go
func (p *MyPlugin) OnLoad(w *sp.WriterBuf) {
    w.RegisterPanel("drc", "DRC", "drc", sp.LayoutRightSidebar, 0)
    w.RegisterProvider("hover_info")
    w.RegisterProvider("validation")
}

func (p *MyPlugin) OnProvideHoverInfo(wx, wy int32, etype uint8, eidx int32, w *sp.WriterBuf) {
    w.HoverInfoResult("Net: VDD\nFanout: 12")
}

func (p *MyPlugin) OnProvideValidation(w *sp.WriterBuf) {
    w.ValidationResult(1, "Missing connection", 100, 200, "fix_conn")
}
```

---

## Canvas Drawing

```go
func (p *MyPlugin) OnLoad(w *sp.WriterBuf) {
    w.RegisterPanel("annotate", "Annotate", "annotate", sp.LayoutLeftSidebar, 0)
    w.SubscribeEvents(0x04) // EVENT_CANVAS
}

func (p *MyPlugin) OnDrawPanel(panelId uint16, w *sp.WriterBuf) {
    // Layer 16 = first plugin overlay layer
    w.CanvasRect(16, 100, 200, 50, 30, 0xFF000040, 0xFF0000FF, 2.0)
    w.CanvasText(16, 105, 195, 0xFFFFFFFF, 12.0, "Critical Path")
    w.CanvasLine(16, 150, 230, 300, 230, 0xFF0000FF, 2.0)
}

func (p *MyPlugin) OnCanvasClick(wx, wy int32, button, mods uint8, w *sp.WriterBuf) {
    w.SetStatus("Canvas clicked")
}
```

---

## Schematic Mutation

```go
func (p *MyPlugin) generate(w *sp.WriterBuf) {
    w.BeginBatch()
    w.PlaceDevice("nmos", "M1", 100, 200)
    w.PlaceDevice("pmos", "M2", 100, 100)
    w.AddWire(120, 200, 120, 100)
    w.SetInstanceProp(0, "W", "1u")
    w.SetInstanceProp(0, "L", "180n")
    w.EndBatch()
}
```

---

## Inter-Plugin Communication

```go
// Publisher
func (p *MyPlugin) OnButtonClicked(panelId uint16, widgetId uint32, w *sp.WriterBuf) {
    if widgetId == 1 {
        w.PublishMessage("my_plugin.data_ready", []byte(`{"value": 42}`))
    }
}

// Subscriber
func (p *MyPlugin) OnPluginMessage(sender, topic, payload []byte, w *sp.WriterBuf) {
    if string(topic) == "my_plugin.data_ready" {
        // handle message
    }
}
```

---

## Build

### Native (.so)

```sh
tinygo build -o libmy_plugin.so -target=linux/amd64 -buildmode=c-shared ./src/
```

Or with standard Go (requires CGo):
```sh
go build -buildmode=c-shared -o libmy_plugin.so ./src/
```

### WASM

```sh
tinygo build -o my_plugin.wasm -target=wasi ./src/
```

---

## Install

```sh
mkdir -p ~/.config/Schemify/my-plugin
cp libmy_plugin.so ~/.config/Schemify/my-plugin/
cp plugin.toml ~/.config/Schemify/my-plugin/
```

---

## PluginHandler Interface

Go uses an interface — you must implement all methods:

```go
type PluginHandler interface {
    // Lifecycle
    OnLoad(w *WriterBuf)
    OnUnload(w *WriterBuf)
    OnTick(dt float32, w *WriterBuf)
    OnPoll(w *WriterBuf)

    // Panel UI
    OnDrawPanel(panelId uint16, w *WriterBuf)
    OnButtonClicked(panelId uint16, widgetId uint32, w *WriterBuf)
    OnSliderChanged(panelId uint16, widgetId uint32, val float32, w *WriterBuf)
    OnCheckboxChanged(panelId uint16, widgetId uint32, val bool, w *WriterBuf)
    OnTextChanged(panelId uint16, widgetId uint32, text []byte, w *WriterBuf)

    // Commands & state
    OnCommand(tag, payload []byte, w *WriterBuf)
    OnStateResponse(key, val []byte, w *WriterBuf)

    // Schematic events
    OnSelectionChanged(idx int32, w *WriterBuf)
    OnSchematicChanged(w *WriterBuf)
    OnInstanceData(idx uint32, name, symbol []byte, w *WriterBuf)
    OnHover(x, y int32, elemType uint8, elemIdx int32, name []byte, w *WriterBuf)
    OnKeyEvent(key, mods, action uint8, w *WriterBuf)

    // Provider callbacks (v9)
    OnProvideHoverInfo(wx, wy int32, etype uint8, eidx int32, w *WriterBuf)
    OnProvideCompletions(context, prefix []byte, w *WriterBuf)
    OnProvideDiagnostics(path []byte, w *WriterBuf)
    OnProvideActions(etype uint8, eidx int32, w *WriterBuf)
    OnProvideTooltip(etype uint8, eidx int32, w *WriterBuf)
    OnProvideDecoration(instanceIdx uint32, w *WriterBuf)
    OnProvideNetlistHook(format []byte, w *WriterBuf)
    OnProvideValidation(w *WriterBuf)

    // Canvas events (v9)
    OnCanvasClick(wx, wy int32, button, mods uint8, w *WriterBuf)
    OnCanvasDrag(wx, wy, dx, dy int32, button, mods uint8, w *WriterBuf)
    OnCanvasScroll(wx, wy int32, dx, dy float32, w *WriterBuf)

    // IPC (v9)
    OnPluginMessage(sender, topic, payload []byte, w *WriterBuf)
}
```

---

## Writer Methods

```go
// Commands
w.RegisterPanel("id", "Title", "vim_cmd", sp.LayoutLeftSidebar, 0)
w.SetStatus("message")
w.PushCommand("zoom_fit", "")
w.GetState("key")
w.SetState("key", "value")
w.GetConfig("plugin_id", "key")
w.SetConfig("plugin_id", "key", "value")
w.RegisterCommand("id", "Display Name", "Description")
w.SubscribeEvents(7)  // 1=hover, 2=keys, 4=canvas
w.ConsumeEvent()
w.YieldPending()
w.HtmlLayout(panelId, []byte("<h1>Hello</h1>"))
w.Log(level, "tag", "message")

// Widgets
w.Label("text", 1)
w.Button("text", 2)
w.Separator(3)
w.Slider(val, min, max, 4)
w.Checkbox(val, "text", 5)
w.Progress(0.75, 6)
w.TextInput("hint", "text", 7)
w.TextArea("hint", "text", 8)
w.BeginRow(9)
w.EndRow(9)
w.CollapsibleStart("label", true, 10)
w.CollapsibleEnd(10)
w.Tooltip("hover text", 11)
w.Dropdown("Option A\nOption B\nOption C", 0, 12)
w.Table("Name\tValue", "R1\t10k\nR2\t20k", 13)
w.TabBar("Tab 1\nTab 2\nTab 3", 0, 14)

// Provider responses (v9)
w.RegisterProvider("hover_info")
w.HoverInfoResult("Net: VDD\nFanout: 12")
w.CompletionResult("label", "insert_text", "detail")
w.DiagnosticResult(severity, "msg", x, y)
w.ActionResult("label", "command")
w.TooltipResult("text")
w.DecorationResult(color, style)
w.ValidationResult(severity, "msg", x, y, "fix_cmd")

// Canvas drawing (v9)
w.CanvasClearLayer(16)
w.CanvasLine(16, x0, y0, x1, y1, color, width)
w.CanvasRect(16, x, y, w, h, fill, stroke, strokeWidth)
w.CanvasCircle(16, cx, cy, r, fill, stroke)
w.CanvasText(16, x, y, color, size, "text")
w.CanvasBeginGroup(16, "name")
w.CanvasEndGroup(16)
w.CanvasSetTransform(16, a, b, c, d, tx, ty)
w.CanvasResetTransform(16)

// Schematic mutation (v9)
w.BeginBatch()
w.EndBatch()
w.DeleteInstance(idx)
w.MoveInstance(idx, dx, dy)
w.RotateInstance(idx, rotation)
w.MirrorInstance(idx, axis)
w.DuplicateInstance(idx, dx, dy)
w.RenameInstance(idx, "name")
w.DeleteWire(idx)
w.MoveWire(idx, dx, dy)
w.MergeWires(a, b)
w.RenameNet(idx, "VDD")
w.Undo()
w.Redo()
w.ClearSelection()
w.CopySelection()
w.Paste(x, y)
w.CutSelection()
w.QueryInstanceAt(x, y)
w.QueryBoundingBox()

// IPC (v9)
w.PublishMessage("topic", payload)
```

---

## Tips

- TinyGo produces much smaller `.so`/`.wasm` files than standard Go
- The `PluginHandler` interface requires all methods — use empty implementations for events you don't need
- The `//export schemify_process` comment is required for CGo to create the C export
- `func main() {}` must exist but can be empty
- Widget IDs must be unique per panel and stable across frames
- Use raw string literals (backticks) for HTML layout strings
- `BeginBatch()`/`EndBatch()` wraps multiple mutations into a single undo step
- Provider registration should be done in `OnLoad()`
