// Schemify Plugin SDK — Go demo
//
// Registers four panels and draws a widget gallery on every OnDraw call.
//
// Build:  zig build        (invokes tinygo build -buildmode=c-shared internally)
// Run:    zig build run
package main

import (
	schemify "github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify"
)

// GoDemo holds per-frame state updated via slider/checkbox events.
type GoDemo struct {
	sliderVal   float32
	checkboxVal bool
	tickCount   uint32
}

func (p *GoDemo) OnLoad(w *schemify.Writer) {
	w.RegisterPanel("go-demo-overlay", "Properties",   "gdprop",   schemify.LayoutOverlay,      0)
	w.RegisterPanel("go-demo-left",    "Components",   "gdcomp",   schemify.LayoutLeftSidebar,  0)
	w.RegisterPanel("go-demo-right",   "Design Stats", "gdstats",  schemify.LayoutRightSidebar, 0)
	w.RegisterPanel("go-demo-bottom",  "Status",       "gdstatus", schemify.LayoutBottomBar,    0)
	w.SetStatus("Go Demo loaded")
}

func (p *GoDemo) OnUnload(w *schemify.Writer) {}

func (p *GoDemo) OnTick(dt float32, w *schemify.Writer) {
	p.tickCount++
}

func (p *GoDemo) OnDraw(panelId uint16, w *schemify.Writer) {
	// panelId identifies which panel to draw; switch on it when the host
	// assigns distinct IDs per registration. Currently always 0.
	_ = panelId
	p.drawWidgets(w)
}

func (p *GoDemo) OnEvent(msg schemify.Msg, w *schemify.Writer) {
	switch d := msg.Data.(type) {
	case schemify.MsgSliderChanged:
		if d.WidgetId == 3 {
			p.sliderVal = d.Val
		}
	case schemify.MsgCheckboxChanged:
		if d.WidgetId == 4 {
			p.checkboxVal = d.Val
		}
	}
}

func (p *GoDemo) drawWidgets(w *schemify.Writer) {
	w.Label("Selected: R1", 0)
	w.Separator(1)
	w.Label("Value (kOhm)", 2)
	w.Slider(p.sliderVal, 0.0, 100.0, 3)
	w.Checkbox(p.checkboxVal, "Show in netlist", 4)
	w.Button("Apply", 5)
	w.Separator(6)
	w.CollapsibleStart("Component Browser", true, 7)
	w.Label("  Resistors: R1, R2, R3", 8)
	w.Label("  Capacitors: C1", 9)
	w.Label("  Transistors: M1, M2", 10)
	w.CollapsibleEnd(7)
	w.Separator(11)
	w.Label("Design Stats", 12)
	w.Progress(0.75, 13)
	w.BeginRow(14)
	w.Label("Nets: 12", 15)
	w.Label("Comps: 8", 16)
	w.Button("Simulate", 17)
	w.EndRow(14)
}

var plugin GoDemo = GoDemo{sliderVal: 0.5, checkboxVal: true}

//export schemify_process
func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
	return schemify.RunPlugin(&plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
