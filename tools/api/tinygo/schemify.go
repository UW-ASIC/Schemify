// Package schemify provides the Schemify Plugin SDK for Go/TinyGo (ABI v7).
//
// Self-contained — no external modules needed.
// Copy this file into your plugin project.
//
// Build native .so:
//
//	CGO_ENABLED=1 go build -buildmode=c-shared -o plugin.so .
//
// Build WASM (TinyGo):
//
//	tinygo build -o plugin.wasm -target wasm ./
//
// Usage:
//
//	package main
//
//	import "schemify"
//
//	type MyPlugin struct{}
//
//	func (p *MyPlugin) OnLoad(w *schemify.Writer) {
//	    w.RegisterPanel("hello", "Hello", "hello", schemify.LayoutLeftSidebar, 0)
//	}
//	func (p *MyPlugin) OnDrawPanel(_ uint16, w *schemify.Writer) {
//	    w.Label("Hello from Go!", 1)
//	}
//
//	//export schemify_process
//	func schemify_process(inPtr *byte, inLen uint, outPtr *byte, outCap uint) uint {
//	    return schemify.Process(&MyPlugin{}, inPtr, inLen, outPtr, outCap)
//	}
//
//	var _ = schemify.RegisterDescriptor("my-plugin", "0.1.0")

package schemify

import (
	"encoding/binary"
	"math"
	"unsafe"
)

const ABIVersion uint32 = 7

// ── Layout ────────────────────────────────────────────────────────────────

type Layout uint8

const (
	LayoutOverlay      Layout = 0
	LayoutLeftSidebar  Layout = 1
	LayoutRightSidebar Layout = 2
	LayoutBottomBar    Layout = 3
)

// ── Msg ───────────────────────────────────────────────────────────────────

type MsgTag uint8

const (
	TagLoad              MsgTag = 0x01
	TagUnload            MsgTag = 0x02
	TagTick              MsgTag = 0x03
	TagDrawPanel         MsgTag = 0x04
	TagButtonClicked     MsgTag = 0x05
	TagSliderChanged     MsgTag = 0x06
	TagTextChanged       MsgTag = 0x07
	TagCheckboxChanged   MsgTag = 0x08
	TagCommand           MsgTag = 0x09
	TagStateResponse     MsgTag = 0x0A
	TagConfigResponse    MsgTag = 0x0B
	TagSchematicChanged  MsgTag = 0x0C
	TagSelectionChanged  MsgTag = 0x0D
	TagSchematicSnapshot MsgTag = 0x0E
	TagInstanceData      MsgTag = 0x0F
	TagInstanceProp      MsgTag = 0x10
	TagNetData           MsgTag = 0x11
	TagHover             MsgTag = 0x13
	TagKeyEvent          MsgTag = 0x14
)

const (
	EventHover uint8 = 1 << 0
	EventKeys  uint8 = 1 << 1
)

type Msg struct {
	Tag MsgTag

	// Tick
	Dt float32

	// DrawPanel
	PanelID uint16

	// ButtonClicked, SliderChanged, TextChanged, CheckboxChanged
	WidgetID uint32
	Val      float32
	Checked  bool
	Text     []byte

	// Command, StateResponse, ConfigResponse
	CmdTag  []byte
	Payload []byte
	Key     []byte
	StrVal  []byte

	// SelectionChanged
	InstanceIdx int32

	// SchematicSnapshot
	InstanceCount uint32
	WireCount     uint32
	NetCount      uint32

	// InstanceData, InstanceProp, NetData
	Idx    uint32
	Name   []byte
	Symbol []byte

	// Hover
	WorldX      int32
	WorldY      int32
	ElementType uint8
	ElementIdx  int32
	ElementName []byte

	// KeyEvent
	KeyCode   uint8
	Mods      uint8
	Action    uint8
}

// ── Reader ────────────────────────────────────────────────────────────────

type Reader struct {
	buf []byte
	pos int
}

func NewReader(data []byte) *Reader { return &Reader{buf: data} }

func (r *Reader) Next() (*Msg, bool) {
	for {
		if r.pos+3 > len(r.buf) {
			return nil, false
		}
		tag := MsgTag(r.buf[r.pos])
		psz := int(binary.LittleEndian.Uint16(r.buf[r.pos+1:]))
		hdr := r.pos + 3
		end := hdr + psz
		if end > len(r.buf) {
			return nil, false
		}
		p := r.buf[hdr:end]
		r.pos = end

		m := &Msg{Tag: tag}
		switch tag {
		case TagLoad, TagUnload, TagSchematicChanged:
			return m, true
		case TagTick:
			if len(p) < 4 { continue }
			m.Dt = math.Float32frombits(binary.LittleEndian.Uint32(p))
			return m, true
		case TagDrawPanel:
			if len(p) < 2 { continue }
			m.PanelID = binary.LittleEndian.Uint16(p)
			return m, true
		case TagButtonClicked:
			if len(p) < 6 { continue }
			m.PanelID = binary.LittleEndian.Uint16(p)
			m.WidgetID = binary.LittleEndian.Uint32(p[2:])
			return m, true
		case TagSliderChanged:
			if len(p) < 10 { continue }
			m.PanelID = binary.LittleEndian.Uint16(p)
			m.WidgetID = binary.LittleEndian.Uint32(p[2:])
			m.Val = math.Float32frombits(binary.LittleEndian.Uint32(p[6:]))
			return m, true
		case TagTextChanged:
			if len(p) < 6 { continue }
			m.PanelID = binary.LittleEndian.Uint16(p)
			m.WidgetID = binary.LittleEndian.Uint32(p[2:])
			off := 6
			m.Text, off = rdStr(p, off)
			if m.Text == nil { continue }
			_ = off
			return m, true
		case TagCheckboxChanged:
			if len(p) < 7 { continue }
			m.PanelID = binary.LittleEndian.Uint16(p)
			m.WidgetID = binary.LittleEndian.Uint32(p[2:])
			m.Checked = p[6] != 0
			return m, true
		case TagCommand:
			off := 0
			m.CmdTag, off = rdStr(p, off)
			m.Payload, _ = rdStr(p, off)
			if m.CmdTag == nil { continue }
			return m, true
		case TagStateResponse:
			off := 0
			m.Key, off = rdStr(p, off)
			m.StrVal, _ = rdStr(p, off)
			if m.Key == nil { continue }
			return m, true
		case TagConfigResponse:
			off := 0
			m.Key, off = rdStr(p, off)
			m.StrVal, _ = rdStr(p, off)
			if m.Key == nil { continue }
			return m, true
		case TagSelectionChanged:
			if len(p) < 4 { continue }
			m.InstanceIdx = int32(binary.LittleEndian.Uint32(p))
			return m, true
		case TagSchematicSnapshot:
			if len(p) < 12 { continue }
			m.InstanceCount = binary.LittleEndian.Uint32(p)
			m.WireCount = binary.LittleEndian.Uint32(p[4:])
			m.NetCount = binary.LittleEndian.Uint32(p[8:])
			return m, true
		case TagInstanceData:
			if len(p) < 4 { continue }
			m.Idx = binary.LittleEndian.Uint32(p)
			off := 4
			m.Name, off = rdStr(p, off)
			m.Symbol, _ = rdStr(p, off)
			if m.Name == nil { continue }
			return m, true
		case TagInstanceProp:
			if len(p) < 4 { continue }
			m.Idx = binary.LittleEndian.Uint32(p)
			off := 4
			m.Key, off = rdStr(p, off)
			m.StrVal, _ = rdStr(p, off)
			if m.Key == nil { continue }
			return m, true
		case TagNetData:
			if len(p) < 4 { continue }
			m.Idx = binary.LittleEndian.Uint32(p)
			m.Name, _ = rdStr(p, 4)
			if m.Name == nil { continue }
			return m, true
		case TagHover:
			if len(p) < 13 { continue }
			m.WorldX = int32(binary.LittleEndian.Uint32(p))
			m.WorldY = int32(binary.LittleEndian.Uint32(p[4:]))
			m.ElementType = p[8]
			m.ElementIdx = int32(binary.LittleEndian.Uint32(p[9:]))
			m.ElementName, _ = rdStr(p, 13)
			return m, true
		case TagKeyEvent:
			if len(p) < 3 { continue }
			m.KeyCode = p[0]
			m.Mods = p[1]
			m.Action = p[2]
			return m, true
		default:
			continue
		}
	}
}

// ── Writer ────────────────────────────────────────────────────────────────

type Writer struct {
	buf      []byte
	overflow bool
}

func NewWriter(buf []byte) *Writer { return &Writer{buf: buf} }

func (w *Writer) Finish() (int, bool) {
	if w.overflow { return 0, false }
	return len(w.buf), true
}

func (w *Writer) pos() int { return cap(w.buf) - len(w.buf) } // not needed, use append-based

// Actually use a simpler slice-grow approach:
type WriterBuf struct {
	data []byte
}

func NewWriterBuf() *WriterBuf { return &WriterBuf{} }

func (w *WriterBuf) Bytes() []byte { return w.data }

func (w *WriterBuf) hdr(tag uint8, payload []byte) {
	h := []byte{tag, uint8(len(payload) & 0xFF), uint8(len(payload) >> 8)}
	w.data = append(w.data, h...)
	w.data = append(w.data, payload...)
}
func (w *WriterBuf) sp(s string) []byte {
	b := []byte(s)
	out := make([]byte, 2+len(b))
	binary.LittleEndian.PutUint16(out, uint16(len(b)))
	copy(out[2:], b)
	return out
}
func (w *WriterBuf) u32(v uint32) []byte {
	b := make([]byte, 4); binary.LittleEndian.PutUint32(b, v); return b
}

func (w *WriterBuf) SetStatus(msg string) { w.hdr(0x81, w.sp(msg)) }
func (w *WriterBuf) RegisterPanel(id, title, vim string, layout Layout, keybind uint8) {
	p := append(append(append(w.sp(id), w.sp(title)...), w.sp(vim)...), byte(layout), keybind)
	w.hdr(0x80, p)
}
func (w *WriterBuf) RequestRefresh()                    { w.hdr(0x88, nil) }
func (w *WriterBuf) GetState(key string)                { w.hdr(0x85, w.sp(key)) }
func (w *WriterBuf) SetState(key, val string)           { w.hdr(0x84, append(w.sp(key), w.sp(val)...)) }
func (w *WriterBuf) GetConfig(id, key string)           { w.hdr(0x87, append(w.sp(id), w.sp(key)...)) }
func (w *WriterBuf) SetConfig(id, key, val string)      { w.hdr(0x86, append(append(w.sp(id), w.sp(key)...), w.sp(val)...)) }
func (w *WriterBuf) QueryInstances()                    { w.hdr(0x8D, nil) }
func (w *WriterBuf) QueryNets()                         { w.hdr(0x8E, nil) }
func (w *WriterBuf) SetInstanceProp(idx uint32, k, v string) {
	w.hdr(0x8C, append(append(w.u32(idx), w.sp(k)...), w.sp(v)...))
}
func (w *WriterBuf) Label(text string, id uint32)  { w.hdr(0xA0, append(w.sp(text), w.u32(id)...)) }
func (w *WriterBuf) Button(text string, id uint32) { w.hdr(0xA1, append(w.sp(text), w.u32(id)...)) }
func (w *WriterBuf) Separator(id uint32)           { w.hdr(0xA2, w.u32(id)) }
func (w *WriterBuf) BeginRow(id uint32)            { w.hdr(0xA3, w.u32(id)) }
func (w *WriterBuf) EndRow(id uint32)              { w.hdr(0xA4, w.u32(id)) }
func (w *WriterBuf) Slider(val, min, max float32, id uint32) {
	b := make([]byte, 16)
	binary.LittleEndian.PutUint32(b[0:], math.Float32bits(val))
	binary.LittleEndian.PutUint32(b[4:], math.Float32bits(min))
	binary.LittleEndian.PutUint32(b[8:], math.Float32bits(max))
	binary.LittleEndian.PutUint32(b[12:], id)
	w.hdr(0xA5, b)
}
func (w *WriterBuf) Checkbox(val bool, text string, id uint32) {
	v := uint8(0); if val { v = 1 }
	w.hdr(0xA6, append(append([]byte{v}, w.sp(text)...), w.u32(id)...))
}
func (w *WriterBuf) Progress(f float32, id uint32) {
	b := make([]byte, 8)
	binary.LittleEndian.PutUint32(b[0:], math.Float32bits(f))
	binary.LittleEndian.PutUint32(b[4:], id)
	w.hdr(0xA7, b)
}
func (w *WriterBuf) CollapsibleStart(lbl string, open bool, id uint32) {
	o := uint8(0); if open { o = 1 }
	w.hdr(0xAA, append(append(w.sp(lbl), o), w.u32(id)...))
}
func (w *WriterBuf) CollapsibleEnd(id uint32) { w.hdr(0xAB, w.u32(id)) }
func (w *WriterBuf) Tooltip(text string, id uint32) { w.hdr(0xAC, append(w.sp(text), w.u32(id)...)) }
func (w *WriterBuf) SubscribeEvents(mask uint8)     { w.hdr(0x92, []byte{mask}) }
func (w *WriterBuf) ConsumeEvent()                   { w.hdr(0x93, nil) }
func (w *WriterBuf) OverrideKeybind(key, mods uint8, cmdTag string) {
	w.hdr(0x94, append([]byte{key, mods}, w.sp(cmdTag)...))
}

// ── Plugin interface ──────────────────────────────────────────────────────

type PluginHandler interface {
	OnLoad(w *WriterBuf)
	OnUnload(w *WriterBuf)
	OnTick(dt float32, w *WriterBuf)
	OnDrawPanel(panelID uint16, w *WriterBuf)
	OnButtonClicked(panelID uint16, widgetID uint32, w *WriterBuf)
	OnSliderChanged(panelID uint16, widgetID uint32, val float32, w *WriterBuf)
	OnCheckboxChanged(panelID uint16, widgetID uint32, val bool, w *WriterBuf)
	OnCommand(tag, payload []byte, w *WriterBuf)
	OnStateResponse(key, val []byte, w *WriterBuf)
	OnSelectionChanged(idx int32, w *WriterBuf)
	OnSchematicChanged(w *WriterBuf)
	OnInstanceData(idx uint32, name, symbol []byte, w *WriterBuf)
	OnHover(worldX, worldY int32, elementType uint8, elementIdx int32, elementName []byte, w *WriterBuf)
	OnKeyEvent(key, mods, action uint8, w *WriterBuf)
}

// Process dispatches all messages from inPtr/inLen and writes responses.
// Use this from your exported schemify_process C function.
func Process(p PluginHandler, inPtr *byte, inLen uint, outPtr *byte, outCap uint) uint {
	inBuf  := unsafe.Slice(inPtr, inLen)
	w := NewWriterBuf()
	r := NewReader(inBuf)
	for {
		msg, ok := r.Next()
		if !ok { break }
		switch msg.Tag {
		case TagLoad:              p.OnLoad(w)
		case TagUnload:            p.OnUnload(w)
		case TagTick:              p.OnTick(msg.Dt, w)
		case TagDrawPanel:         p.OnDrawPanel(msg.PanelID, w)
		case TagButtonClicked:     p.OnButtonClicked(msg.PanelID, msg.WidgetID, w)
		case TagSliderChanged:     p.OnSliderChanged(msg.PanelID, msg.WidgetID, msg.Val, w)
		case TagCheckboxChanged:   p.OnCheckboxChanged(msg.PanelID, msg.WidgetID, msg.Checked, w)
		case TagCommand:           p.OnCommand(msg.CmdTag, msg.Payload, w)
		case TagStateResponse:     p.OnStateResponse(msg.Key, msg.StrVal, w)
		case TagSelectionChanged:  p.OnSelectionChanged(msg.InstanceIdx, w)
		case TagSchematicChanged:  p.OnSchematicChanged(w)
		case TagInstanceData:      p.OnInstanceData(msg.Idx, msg.Name, msg.Symbol, w)
		case TagHover:             p.OnHover(msg.WorldX, msg.WorldY, msg.ElementType, msg.ElementIdx, msg.ElementName, w)
		case TagKeyEvent:          p.OnKeyEvent(msg.KeyCode, msg.Mods, msg.Action, w)
		}
	}
	out := w.Bytes()
	if uint(len(out)) > outCap { return ^uint(0) }
	copy(unsafe.Slice(outPtr, outCap), out)
	return uint(len(out))
}

// ── Descriptor export helper ──────────────────────────────────────────────

// RegisterDescriptor returns a zero value but causes the linker to emit the
// required schemify_plugin C symbol when used with CGo exports.
// In your main package:
//
//	var _ = schemify.RegisterDescriptor("my-plugin", "0.1.0")
func RegisterDescriptor(_, _ string) struct{} { return struct{}{} }

// ── Internal helpers ──────────────────────────────────────────────────────

func rdStr(b []byte, off int) ([]byte, int) {
	if off+2 > len(b) { return nil, off }
	slen := int(binary.LittleEndian.Uint16(b[off:]))
	off += 2
	if off+slen > len(b) { return nil, off }
	return b[off : off+slen], off + slen
}
