// go-hello — minimal TinyGo plugin example for Schemify (ABI v6).
//
// Build (native .so):
//
//	tinygo build -o libgo_hello.so -buildmode=c-shared -target=linux/amd64 .
//
// Or via the Zig wrapper:
//
//	zig build
package main

import schemify "github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify"

// GoHello is the plugin implementation.
type GoHello struct{}

func (p *GoHello) OnLoad(w *schemify.Writer) {
	w.RegisterPanel("go-hello", "Go Hello", "ghello", schemify.LayoutOverlay, 'g')
	w.SetStatus("Go Hello plugin loaded")
}

func (p *GoHello) OnUnload(w *schemify.Writer) {
	w.SetStatus("Go Hello plugin unloaded")
}

func (p *GoHello) OnTick(dt float32, w *schemify.Writer) {}

func (p *GoHello) OnDraw(panelId uint16, w *schemify.Writer) {
	w.Label("Hello from Go!", 0)
	w.Label("Built with the TinyGo SDK.", 1)
}

func (p *GoHello) OnEvent(msg schemify.Msg, w *schemify.Writer) {}

var _plugin GoHello

//go:wasmexport schemify_process
//export schemify_process
func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
	return schemify.RunPlugin(&_plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
