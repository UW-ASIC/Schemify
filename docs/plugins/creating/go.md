# Writing a Go Plugin (TinyGo)

Schemify provides a Go package (`tools/sdk/bindings/tinygo/schemify/`) that
wraps the ABI v6 message-passing protocol.  Implement the `Plugin` interface,
use a `*Writer` to emit UI commands, and export the `schemify_process` function
to give the host its entry point.  A single source file builds to both native
(`.so`) and WASM targets without build tags or cgo changes.

## 1. Why TinyGo?

Standard `go build -buildmode=c-shared` works but embeds a large Go runtime.
TinyGo produces smaller, more portable shared libraries and supports WASM
targets natively.  The `schemify` package is compatible with both standard Go
(cgo, native only) and TinyGo (native + WASM).

## 2. Prerequisites

- TinyGo 0.31 or later — https://tinygo.org/getting-started/install/
- clang (required by TinyGo for native `.so` builds; usually installed with TinyGo)
- `gopls` for IDE support (optional)
- Zig 0.14+ (only needed if using `zig build` to drive the build)

## 3. Project layout

```
my-go-plugin/
  main.go
  go.mod
  build.zig          ← optional; wraps tinygo for `zig build run`
  build.zig.zon      ← optional; needed only if using zig build
```

## 4. `go.mod`

```
module my-go-plugin

go 1.21

require github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify v0.0.0

// Inside the monorepo — local path override:
replace github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify => ../../../tools/sdk/bindings/tinygo/schemify
```

For a standalone project outside the monorepo, remove the `replace` directive
and point to the published module version (see section 8).

## 5. `main.go`

```go
// my-go-plugin — minimal Schemify TinyGo plugin (ABI v6).
package main

import schemify "github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify"

// MyPlugin is the plugin implementation.
type MyPlugin struct{}

func (p *MyPlugin) OnLoad(w *schemify.Writer) {
    w.RegisterPanel("my-plugin", "My Plugin", "myplugin", schemify.LayoutOverlay, 'm')
    w.SetStatus("My Go plugin loaded!")
}

func (p *MyPlugin) OnUnload(w *schemify.Writer) {
    w.SetStatus("My Go plugin unloaded")
}

func (p *MyPlugin) OnTick(dt float32, w *schemify.Writer) {}

func (p *MyPlugin) OnDraw(panelId uint16, w *schemify.Writer) {
    w.Label("Hello from Go!", 0)
    w.Label("Built with the TinyGo SDK.", 1)
}

func (p *MyPlugin) OnEvent(msg schemify.Msg, w *schemify.Writer) {}

var _plugin MyPlugin

//go:wasmexport schemify_process
//export schemify_process
func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
    return schemify.RunPlugin(&_plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
```

The two directives `//go:wasmexport` (WASM) and `//export` (native cgo) ensure
the symbol is visible regardless of target.  `schemify.RunPlugin` dispatches
incoming messages to the appropriate `Plugin` interface method.

## 6. Building with TinyGo directly

```bash
# Native shared library:
tinygo build -o libmy_go_plugin.so -buildmode=c-shared -target=linux/amd64 .

# WASM module:
tinygo build -o my_go_plugin.wasm -target=wasi .
```

Install the native library manually:

```bash
mkdir -p ~/.config/Schemify/MyGoPlugin
cp libmy_go_plugin.so ~/.config/Schemify/MyGoPlugin/
```

## 7. Building with `zig build` (optional)

Add a thin `build.zig` to drive TinyGo and install automatically:

**`build.zig.zon`**

```zig
.{
    .name    = .my_go_plugin,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .fingerprint = 0x<random_hex>,
    .dependencies = .{
        .schemify_sdk = .{ .path = "../../.." },
        // Standalone: replace with .url + .hash
    },
    .paths = .{ "build.zig", "build.zig.zon", "main.go", "go.mod" },
}
```

**`build.zig`**

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    // Runs `tinygo build` and copies the .so to zig-out/lib/
    helper.addGoPlugin(b, ".", "my_go_plugin");
    helper.addNativeAutoInstallRunStep(b, "MyGoPlugin", sdk_dep, "my-go-plugin");
}
```

| Build command | Result |
|---------------|--------|
| `tinygo build -o libmy_go_plugin.so -buildmode=c-shared -target=linux/amd64 .` | native `.so` |
| `zig build` | runs tinygo + copies to `zig-out/lib/` |
| `zig build run` | installs + launches Schemify |

## 8. Complete working example

The repo ships a ready-to-build example at `plugins/examples/go-hello/`:

```
plugins/examples/go-hello/
  main.go
  go.mod
  build.zig
  build.zig.zon
```

```bash
cd plugins/examples/go-hello
zig build run
# or:
tinygo build -o libgo_hello.so -buildmode=c-shared -target=linux/amd64 .
```

## 9. LSP / IDE setup

`gopls` works out of the box with `go.mod` — open the plugin directory in VS
Code, Neovim, or any LSP-capable editor.  TinyGo-specific builtins are resolved
when you have the TinyGo language server set up, but standard `gopls` covers
most completions and diagnostics.

## 10. Standalone git project

For a plugin in its own repository, remove the `replace` directive from
`go.mod` and reference the published module:

```
module my-go-plugin

go 1.21

require github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify v1.0.0
```

If you are also using `zig build`, update `build.zig.zon` to use a URL
dependency:

```zig
.schemify_sdk = .{
    .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
    .hash = "...",
},
```

Run `zig fetch --save=schemify_sdk <url>` to populate the hash.

## 11. Plugin API reference

The package lives at `tools/sdk/bindings/tinygo/schemify/plugin.go`.

### `Plugin` interface

```go
type Plugin interface {
    OnLoad(w *Writer)
    OnUnload(w *Writer)
    OnTick(dt float32, w *Writer)
    OnDraw(panelId uint16, w *Writer)
    OnEvent(msg Msg, w *Writer)
}
```

### `Writer` methods

| Method | Description |
|---|---|
| `RegisterPanel(id, title, vimCmd string, layout Layout, keybind byte)` | Register a panel |
| `SetStatus(text string)` | Set status bar text |
| `Log(level LogLevel, tag, msg string)` | Structured log |
| `Label(text string, id uint32)` | Text label |
| `Button(text string, id uint32)` | Button |
| `Separator(id uint32)` | Horizontal rule |
| `Slider(val, min, max float32, id uint32)` | Float slider |
| `Checkbox(checked bool, text string, id uint32)` | Labeled checkbox |
| `Progress(fraction float32, id uint32)` | Progress bar (0.0–1.0) |
| `BeginRow(id uint32)` / `EndRow(id uint32)` | Horizontal layout pair |

### Layout constants

| Constant | Position |
|----------|----------|
| `LayoutOverlay` | Floating overlay |
| `LayoutLeftSidebar` | Left panel |
| `LayoutRightSidebar` | Right panel |
| `LayoutBottomBar` | Bottom bar |

### Handling events

Incoming events arrive as a `Msg` struct in `OnEvent`:

```go
func (p *MyPlugin) OnEvent(msg schemify.Msg, w *schemify.Writer) {
    switch msg.Tag {
    case schemify.TagButtonClicked:
        if msg.WidgetId == 0 {
            w.SetStatus("Button clicked!")
        }
    case schemify.TagSliderChanged:
        p.value = msg.Val
    }
}
```

See `docs/plugins/api.md` for the full binary message protocol reference.
