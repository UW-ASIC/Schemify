// Schemify Plugin SDK — Go demo
//
// Registers four panels and draws a widget gallery on every OnDrawPanel call.
//
// Build native: make        (from parent dir)
// Build WASM:   make wasm   (requires tinygo)
package main

import (
	"schemify"
)

type GoDemo struct {
	sliderVal   float32
	checkboxVal bool
	tickCount   uint32
}

func (p *GoDemo) OnLoad(w *schemify.WriterBuf) {
	w.RegisterPanel("go-demo-overlay", "Properties", "gdprop", schemify.LayoutOverlay, 0)
	w.RegisterPanel("go-demo-left", "Components", "gdcomp", schemify.LayoutLeftSidebar, 0)
	w.RegisterPanel("go-demo-right", "Design Stats", "gdstats", schemify.LayoutRightSidebar, 0)
	w.RegisterPanel("go-demo-bottom", "Status", "gdstatus", schemify.LayoutBottomBar, 0)
	w.SetStatus("Go Demo loaded")
}

func (p *GoDemo) OnUnload(w *schemify.WriterBuf) {}

func (p *GoDemo) OnTick(dt float32, w *schemify.WriterBuf) {
	p.tickCount++
}

func (p *GoDemo) OnDrawPanel(panelID uint16, w *schemify.WriterBuf) {
	_ = panelID
	p.drawWidgets(w)
}

func (p *GoDemo) OnButtonClicked(_ uint16, _ uint32, _ *schemify.WriterBuf) {}

func (p *GoDemo) OnSliderChanged(_ uint16, widgetID uint32, val float32, _ *schemify.WriterBuf) {
	if widgetID == 3 {
		p.sliderVal = val
	}
}

func (p *GoDemo) OnCheckboxChanged(_ uint16, widgetID uint32, val bool, _ *schemify.WriterBuf) {
	if widgetID == 4 {
		p.checkboxVal = val
	}
}

func (p *GoDemo) OnCommand(_, _ []byte, _ *schemify.WriterBuf)        {}
func (p *GoDemo) OnStateResponse(_, _ []byte, _ *schemify.WriterBuf)  {}
func (p *GoDemo) OnSelectionChanged(_ int32, _ *schemify.WriterBuf)   {}
func (p *GoDemo) OnSchematicChanged(_ *schemify.WriterBuf)            {}
func (p *GoDemo) OnInstanceData(_ uint32, _, _ []byte, _ *schemify.WriterBuf)           {}
func (p *GoDemo) OnHover(_, _ int32, _ uint8, _ int32, _ []byte, _ *schemify.WriterBuf) {}
func (p *GoDemo) OnKeyEvent(_, _, _ uint8, _ *schemify.WriterBuf)                       {}

func (p *GoDemo) drawWidgets(w *schemify.WriterBuf) {
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

var plugin = GoDemo{sliderVal: 0.5, checkboxVal: true}

//export schemify_process
func schemify_process(inPtr *byte, inLen uint, outPtr *byte, outCap uint) uint {
	return schemify.Process(&plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
