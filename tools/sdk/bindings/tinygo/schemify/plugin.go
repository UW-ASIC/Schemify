// Package schemify provides Go/TinyGo bindings for the Schemify plugin SDK (ABI v6).
//
// A single file works for both native (.so) and WASM targets — no build tags,
// no cgo, no //go:wasmimport declarations.  Plugins communicate with the host
// through a binary message protocol over a pair of byte buffers.
//
// # WASM build
//
//	tinygo build -o myplugin.wasm -target=wasi .
//
// # Native shared library build
//
//	tinygo build -o libmyplugin.so -buildmode=c-shared -target=linux/amd64 .
//
// # Minimal plugin skeleton
//
//	package main
//
//	import schemify "github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify"
//
//	type MyPlugin struct{}
//
//	func (p *MyPlugin) OnLoad(w *schemify.Writer) {
//	    w.RegisterPanel("my-panel", "My Panel", "mypanel", schemify.LayoutRightSidebar, 0)
//	    w.SetStatus("My plugin loaded")
//	}
//	func (p *MyPlugin) OnUnload(w *schemify.Writer) { w.SetStatus("My plugin unloaded") }
//	func (p *MyPlugin) OnTick(dt float32, w *schemify.Writer) {}
//	func (p *MyPlugin) OnDraw(panelId uint16, w *schemify.Writer) {
//	    w.Label("Hello from Go!", 0)
//	}
//	func (p *MyPlugin) OnEvent(msg schemify.Msg, w *schemify.Writer) {}
//
//	var plugin MyPlugin
//
//	//go:wasmexport schemify_process
//	func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
//	    return schemify.RunPlugin(&plugin, inPtr, inLen, outPtr, outCap)
//	}
//
//	func main() {}
package schemify

import (
	"math"
	"unsafe"
)

// AbiVersion is the ABI version this package implements.
const AbiVersion = 6

// ── Tag constants ────────────────────────────────────────────────────────────

// Host → Plugin message tags (0x01–0x7F).
const (
	TagLoad              uint8 = 0x01
	TagUnload            uint8 = 0x02
	TagTick              uint8 = 0x03
	TagDrawPanel         uint8 = 0x04
	TagButtonClicked     uint8 = 0x05
	TagSliderChanged     uint8 = 0x06
	TagTextChanged       uint8 = 0x07
	TagCheckboxChanged   uint8 = 0x08
	TagCommand           uint8 = 0x09
	TagStateResponse     uint8 = 0x0A
	TagConfigResponse    uint8 = 0x0B
	TagSchematicChanged  uint8 = 0x0C
	TagSelectionChanged  uint8 = 0x0D
	TagSchematicSnapshot uint8 = 0x0E
	TagInstanceData      uint8 = 0x0F
	TagInstanceProp      uint8 = 0x10
	TagNetData           uint8 = 0x11
)

// Plugin → Host command tags (0x80–0x9F).
const (
	TagRegisterPanel   uint8 = 0x80
	TagSetStatus       uint8 = 0x81
	TagLog             uint8 = 0x82
	TagPushCommand     uint8 = 0x83
	TagSetState        uint8 = 0x84
	TagGetState        uint8 = 0x85
	TagSetConfig       uint8 = 0x86
	TagGetConfig       uint8 = 0x87
	TagRequestRefresh  uint8 = 0x88
	TagRegisterKeybind uint8 = 0x89
	TagPlaceDevice     uint8 = 0x8A
	TagAddWire         uint8 = 0x8B
	TagSetInstanceProp uint8 = 0x8C
	TagQueryInstances  uint8 = 0x8D
	TagQueryNets       uint8 = 0x8E
)

// Plugin → Host UI widget tags (0xA0–0xAB).
const (
	TagUiLabel            uint8 = 0xA0
	TagUiButton           uint8 = 0xA1
	TagUiSeparator        uint8 = 0xA2
	TagUiBeginRow         uint8 = 0xA3
	TagUiEndRow           uint8 = 0xA4
	TagUiSlider           uint8 = 0xA5
	TagUiCheckbox         uint8 = 0xA6
	TagUiProgress         uint8 = 0xA7
	TagUiPlot             uint8 = 0xA8
	TagUiImage            uint8 = 0xA9
	TagUiCollapsibleStart uint8 = 0xAA
	TagUiCollapsibleEnd   uint8 = 0xAB
)

// ── Layout constants ─────────────────────────────────────────────────────────

// PanelLayout values for RegisterPanel.
const (
	LayoutOverlay      uint8 = 0
	LayoutLeftSidebar  uint8 = 1
	LayoutRightSidebar uint8 = 2
	LayoutBottomBar    uint8 = 3
)

// ── Log level constants ──────────────────────────────────────────────────────

// Log level values for Log.
const (
	LogInfo uint8 = 0
	LogWarn uint8 = 1
	LogErr  uint8 = 2
)

// ── Message types (host → plugin) ────────────────────────────────────────────

// MsgTick carries the frame delta-time in seconds.
type MsgTick struct{ Dt float32 }

// MsgDrawPanel asks the plugin to emit UI widgets for the given panel.
type MsgDrawPanel struct{ PanelId uint16 }

// MsgButtonClicked notifies that a button widget was activated.
type MsgButtonClicked struct {
	PanelId  uint16
	WidgetId uint32
}

// MsgSliderChanged notifies that a slider value changed.
type MsgSliderChanged struct {
	PanelId  uint16
	WidgetId uint32
	Val      float32
}

// MsgTextChanged notifies that a text input changed.
type MsgTextChanged struct {
	PanelId  uint16
	WidgetId uint32
	Text     string
}

// MsgCheckboxChanged notifies that a checkbox state changed.
type MsgCheckboxChanged struct {
	PanelId  uint16
	WidgetId uint32
	Val      bool
}

// MsgCommand delivers a named command with an optional payload string.
type MsgCommand struct {
	Tag     string
	Payload string
}

// MsgStateResponse carries the result of a previous GetState call.
type MsgStateResponse struct {
	Key string
	Val string
}

// MsgConfigResponse carries the result of a previous GetConfig call.
type MsgConfigResponse struct {
	Key string
	Val string
}

// MsgSelectionChanged notifies that the schematic selection changed.
// InstanceIdx is -1 when nothing is selected.
type MsgSelectionChanged struct{ InstanceIdx int32 }

// MsgSchematicSnapshot is sent at the top of every Tick batch.
type MsgSchematicSnapshot struct {
	InstanceCount uint32
	WireCount     uint32
	NetCount      uint32
}

// MsgInstanceData carries details about one schematic instance.
type MsgInstanceData struct {
	Idx    uint32
	Name   string
	Symbol string
}

// MsgInstanceProp carries a single property for a schematic instance.
type MsgInstanceProp struct {
	Idx uint32
	Key string
	Val string
}

// MsgNetData carries details about one schematic net.
type MsgNetData struct {
	Idx  uint32
	Name string
}

// Msg is a decoded message from the host.
// Data holds one of the Msg* types listed above, or nil for empty payloads
// (TagLoad, TagUnload, TagSchematicChanged, TagRequestRefresh, etc.).
type Msg struct {
	Tag  uint8
	Data interface{}
}

// ── Reader ───────────────────────────────────────────────────────────────────

// Reader iterates over host→plugin messages in a flat byte buffer.
type Reader struct {
	buf []byte
	pos int
}

// NewReader creates a Reader over buf.  buf must remain valid for the
// lifetime of the Reader.
func NewReader(buf []byte) *Reader { return &Reader{buf: buf} }

// Next decodes the next message into msg and advances the read position.
// Returns false when the buffer is exhausted.  Unknown tags are skipped
// transparently so forward-compatibility is maintained automatically.
func (r *Reader) Next(msg *Msg) bool {
	if r.pos+3 > len(r.buf) {
		return false
	}
	tag := r.buf[r.pos]
	payloadSz := int(r.buf[r.pos+1]) | int(r.buf[r.pos+2])<<8
	r.pos += 3

	end := r.pos + payloadSz
	if end > len(r.buf) {
		return false
	}
	payload := r.buf[r.pos:end]

	msg.Tag = tag
	msg.Data = nil

	switch tag {
	case TagLoad, TagUnload, TagSchematicChanged:
		// no payload

	case TagTick:
		if len(payload) >= 4 {
			msg.Data = MsgTick{Dt: math.Float32frombits(
				uint32(payload[0]) | uint32(payload[1])<<8 |
					uint32(payload[2])<<16 | uint32(payload[3])<<24,
			)}
		}

	case TagDrawPanel:
		if len(payload) >= 2 {
			msg.Data = MsgDrawPanel{PanelId: uint16(payload[0]) | uint16(payload[1])<<8}
		}

	case TagButtonClicked:
		if len(payload) >= 6 {
			msg.Data = MsgButtonClicked{
				PanelId:  uint16(payload[0]) | uint16(payload[1])<<8,
				WidgetId: uint32(payload[2]) | uint32(payload[3])<<8 | uint32(payload[4])<<16 | uint32(payload[5])<<24,
			}
		}

	case TagSliderChanged:
		if len(payload) >= 10 {
			msg.Data = MsgSliderChanged{
				PanelId:  uint16(payload[0]) | uint16(payload[1])<<8,
				WidgetId: uint32(payload[2]) | uint32(payload[3])<<8 | uint32(payload[4])<<16 | uint32(payload[5])<<24,
				Val: math.Float32frombits(
					uint32(payload[6]) | uint32(payload[7])<<8 |
						uint32(payload[8])<<16 | uint32(payload[9])<<24,
				),
			}
		}

	case TagTextChanged:
		if len(payload) >= 6 {
			panelId := uint16(payload[0]) | uint16(payload[1])<<8
			widgetId := uint32(payload[2]) | uint32(payload[3])<<8 | uint32(payload[4])<<16 | uint32(payload[5])<<24
			text, _ := readStr(payload[6:])
			msg.Data = MsgTextChanged{PanelId: panelId, WidgetId: widgetId, Text: text}
		}

	case TagCheckboxChanged:
		if len(payload) >= 7 {
			msg.Data = MsgCheckboxChanged{
				PanelId:  uint16(payload[0]) | uint16(payload[1])<<8,
				WidgetId: uint32(payload[2]) | uint32(payload[3])<<8 | uint32(payload[4])<<16 | uint32(payload[5])<<24,
				Val:      payload[6] != 0,
			}
		}

	case TagCommand:
		tag2, rest := readStr(payload)
		pl, _ := readStr(rest)
		msg.Data = MsgCommand{Tag: tag2, Payload: pl}

	case TagStateResponse:
		key, rest := readStr(payload)
		val, _ := readStr(rest)
		msg.Data = MsgStateResponse{Key: key, Val: val}

	case TagConfigResponse:
		key, rest := readStr(payload)
		val, _ := readStr(rest)
		msg.Data = MsgConfigResponse{Key: key, Val: val}

	case TagSelectionChanged:
		if len(payload) >= 4 {
			v := uint32(payload[0]) | uint32(payload[1])<<8 | uint32(payload[2])<<16 | uint32(payload[3])<<24
			msg.Data = MsgSelectionChanged{InstanceIdx: int32(v)}
		}

	case TagSchematicSnapshot:
		if len(payload) >= 12 {
			msg.Data = MsgSchematicSnapshot{
				InstanceCount: uint32(payload[0]) | uint32(payload[1])<<8 | uint32(payload[2])<<16 | uint32(payload[3])<<24,
				WireCount:     uint32(payload[4]) | uint32(payload[5])<<8 | uint32(payload[6])<<16 | uint32(payload[7])<<24,
				NetCount:      uint32(payload[8]) | uint32(payload[9])<<8 | uint32(payload[10])<<16 | uint32(payload[11])<<24,
			}
		}

	case TagInstanceData:
		if len(payload) >= 4 {
			idx := uint32(payload[0]) | uint32(payload[1])<<8 | uint32(payload[2])<<16 | uint32(payload[3])<<24
			name, rest := readStr(payload[4:])
			symbol, _ := readStr(rest)
			msg.Data = MsgInstanceData{Idx: idx, Name: name, Symbol: symbol}
		}

	case TagInstanceProp:
		if len(payload) >= 4 {
			idx := uint32(payload[0]) | uint32(payload[1])<<8 | uint32(payload[2])<<16 | uint32(payload[3])<<24
			key, rest := readStr(payload[4:])
			val, _ := readStr(rest)
			msg.Data = MsgInstanceProp{Idx: idx, Key: key, Val: val}
		}

	case TagNetData:
		if len(payload) >= 4 {
			idx := uint32(payload[0]) | uint32(payload[1])<<8 | uint32(payload[2])<<16 | uint32(payload[3])<<24
			name, _ := readStr(payload[4:])
			msg.Data = MsgNetData{Idx: idx, Name: name}
		}

	default:
		// Unknown tag — skip transparently for forward compatibility.
	}

	r.pos = end
	return true
}

// readStr decodes a u16le-prefixed string from buf and returns the string
// and the remaining bytes.  Returns ("", nil) if buf is too short.
func readStr(buf []byte) (string, []byte) {
	if len(buf) < 2 {
		return "", nil
	}
	n := int(buf[0]) | int(buf[1])<<8
	if len(buf) < 2+n {
		return "", buf[2:]
	}
	return string(buf[2 : 2+n]), buf[2+n:]
}

// ── Writer ───────────────────────────────────────────────────────────────────

// Writer serialises plugin→host messages into a caller-supplied byte slice.
// All writes are bounds-checked; if the buffer is too small the overflow flag
// is set and no further writes are performed — the caller should return
// ^uintptr(0) to signal the host to retry with a larger buffer.
type Writer struct {
	buf      []byte
	pos      int
	overflow bool
}

// NewWriter creates a Writer that serialises into buf.
func NewWriter(buf []byte) *Writer { return &Writer{buf: buf} }

// Overflow reports whether any write was dropped due to insufficient buffer capacity.
func (w *Writer) Overflow() bool { return w.overflow }

// Pos returns the number of bytes written so far.
func (w *Writer) Pos() int { return w.pos }

// ── low-level write helpers ──────────────────────────────────────────────────

func (w *Writer) reserve(n int) bool {
	if w.overflow || w.pos+n > len(w.buf) {
		w.overflow = true
		return false
	}
	return true
}

func (w *Writer) writeU8(v uint8) {
	if !w.reserve(1) {
		return
	}
	w.buf[w.pos] = v
	w.pos++
}

func (w *Writer) writeU16le(v uint16) {
	if !w.reserve(2) {
		return
	}
	w.buf[w.pos] = uint8(v)
	w.buf[w.pos+1] = uint8(v >> 8)
	w.pos += 2
}

func (w *Writer) writeU32le(v uint32) {
	if !w.reserve(4) {
		return
	}
	w.buf[w.pos] = uint8(v)
	w.buf[w.pos+1] = uint8(v >> 8)
	w.buf[w.pos+2] = uint8(v >> 16)
	w.buf[w.pos+3] = uint8(v >> 24)
	w.pos += 4
}

func (w *Writer) writeI32le(v int32) {
	w.writeU32le(uint32(v))
}

func (w *Writer) writeF32le(v float32) {
	w.writeU32le(math.Float32bits(v))
}

// writeStr encodes s as [u16le len][bytes].
func (w *Writer) writeStr(s string) {
	n := len(s)
	w.writeU16le(uint16(n))
	if n == 0 || !w.reserve(n) {
		return
	}
	copy(w.buf[w.pos:], s)
	w.pos += n
}

// writeF32Arr encodes arr as [u32le count][f32le × count].
func (w *Writer) writeF32Arr(arr []float32) {
	w.writeU32le(uint32(len(arr)))
	for _, v := range arr {
		w.writeF32le(v)
	}
}

// writeU8Arr encodes arr as [u32le count][bytes].
func (w *Writer) writeU8Arr(arr []byte) {
	w.writeU32le(uint32(len(arr)))
	n := len(arr)
	if n == 0 || !w.reserve(n) {
		return
	}
	copy(w.buf[w.pos:], arr)
	w.pos += n
}

// msg writes a complete framed message: [u8 tag][u16le payload_sz][payload].
// payloadFn writes the payload bytes; the payload_sz field is patched
// afterward with the actual byte count written.
func (w *Writer) msg(tag uint8, payloadFn func()) {
	if w.overflow {
		return
	}
	// Write header with placeholder payload_sz = 0.
	headerPos := w.pos
	w.writeU8(tag)
	w.writeU16le(0) // placeholder
	if w.overflow {
		return
	}
	payloadStart := w.pos
	payloadFn()
	if w.overflow {
		// Restore position to before the header so the buffer is clean.
		w.pos = headerPos
		return
	}
	// Patch payload_sz.
	payloadSz := uint16(w.pos - payloadStart)
	w.buf[headerPos+1] = uint8(payloadSz)
	w.buf[headerPos+2] = uint8(payloadSz >> 8)
}

// ── Public command methods ───────────────────────────────────────────────────

// RegisterPanel asks the host to register a UI panel.
// id is the internal panel identifier, title is the display name,
// vimCmd is the command name for keyboard navigation, layout is one of the
// Layout* constants, and keybind is an ASCII character (0 = none).
func (w *Writer) RegisterPanel(id, title, vimCmd string, layout, keybind uint8) {
	w.msg(TagRegisterPanel, func() {
		w.writeStr(id)
		w.writeStr(title)
		w.writeStr(vimCmd)
		w.writeU8(layout)
		w.writeU8(keybind)
	})
}

// SetStatus updates the status-bar text in the host UI.
func (w *Writer) SetStatus(msg string) {
	w.msg(TagSetStatus, func() { w.writeStr(msg) })
}

// Log emits a log message.  level is one of the Log* constants.
func (w *Writer) Log(level uint8, tag, message string) {
	w.msg(TagLog, func() {
		w.writeU8(level)
		w.writeStr(tag)
		w.writeStr(message)
	})
}

// PushCommand pushes a named command into the host command queue.
func (w *Writer) PushCommand(tag, payload string) {
	w.msg(TagPushCommand, func() {
		w.writeStr(tag)
		w.writeStr(payload)
	})
}

// SetState stores a persistent key/value pair for this plugin.
func (w *Writer) SetState(key, val string) {
	w.msg(TagSetState, func() {
		w.writeStr(key)
		w.writeStr(val)
	})
}

// GetState requests the value for key; the host replies with a StateResponse
// message in the next tick's input batch.
func (w *Writer) GetState(key string) {
	w.msg(TagGetState, func() { w.writeStr(key) })
}

// SetConfig stores a config value.  pluginId identifies the owning plugin.
func (w *Writer) SetConfig(pluginId, key, val string) {
	w.msg(TagSetConfig, func() {
		w.writeStr(pluginId)
		w.writeStr(key)
		w.writeStr(val)
	})
}

// GetConfig requests a config value; the host replies with a ConfigResponse
// message in the next tick's input batch.
func (w *Writer) GetConfig(pluginId, key string) {
	w.msg(TagGetConfig, func() {
		w.writeStr(pluginId)
		w.writeStr(key)
	})
}

// RequestRefresh asks the host to repaint the UI on the next frame.
func (w *Writer) RequestRefresh() {
	w.msg(TagRequestRefresh, func() {})
}

// RegisterKeybind registers a global keybind that fires a command.
// key is the ASCII code, mods is a bitmask of modifier keys, cmdTag is
// the command tag that will be delivered as a Command message.
func (w *Writer) RegisterKeybind(key, mods uint8, cmdTag string) {
	w.msg(TagRegisterKeybind, func() {
		w.writeU8(key)
		w.writeU8(mods)
		w.writeStr(cmdTag)
	})
}

// PlaceDevice asks the host to insert a device into the active schematic.
func (w *Writer) PlaceDevice(sym, name string, x, y int32) {
	w.msg(TagPlaceDevice, func() {
		w.writeStr(sym)
		w.writeStr(name)
		w.writeI32le(x)
		w.writeI32le(y)
	})
}

// AddWire asks the host to add a wire segment to the active schematic.
func (w *Writer) AddWire(x0, y0, x1, y1 int32) {
	w.msg(TagAddWire, func() {
		w.writeI32le(x0)
		w.writeI32le(y0)
		w.writeI32le(x1)
		w.writeI32le(y1)
	})
}

// SetInstanceProp sets a property on an existing schematic instance.
func (w *Writer) SetInstanceProp(idx uint32, key, val string) {
	w.msg(TagSetInstanceProp, func() {
		w.writeU32le(idx)
		w.writeStr(key)
		w.writeStr(val)
	})
}

// QueryInstances requests full instance data; the host delivers a batch of
// InstanceData messages in the next tick's input.
func (w *Writer) QueryInstances() {
	w.msg(TagQueryInstances, func() {})
}

// QueryNets requests net data; the host delivers a batch of NetData messages
// in the next tick's input.
func (w *Writer) QueryNets() {
	w.msg(TagQueryNets, func() {})
}

// ── UI widget methods ────────────────────────────────────────────────────────

// Label emits a static text label widget.
func (w *Writer) Label(text string, id uint32) {
	w.msg(TagUiLabel, func() {
		w.writeStr(text)
		w.writeU32le(id)
	})
}

// Button emits a clickable button widget.
// The host delivers a ButtonClicked message when the user activates it.
func (w *Writer) Button(text string, id uint32) {
	w.msg(TagUiButton, func() {
		w.writeStr(text)
		w.writeU32le(id)
	})
}

// Separator emits a horizontal separator rule.
func (w *Writer) Separator(id uint32) {
	w.msg(TagUiSeparator, func() { w.writeU32le(id) })
}

// BeginRow begins a horizontal row layout container.  Must be paired with EndRow.
func (w *Writer) BeginRow(id uint32) {
	w.msg(TagUiBeginRow, func() { w.writeU32le(id) })
}

// EndRow ends the current horizontal row layout container.
func (w *Writer) EndRow(id uint32) {
	w.msg(TagUiEndRow, func() { w.writeU32le(id) })
}

// Slider emits a slider widget.  The host delivers a SliderChanged message
// when the user moves it.
func (w *Writer) Slider(val, min, max float32, id uint32) {
	w.msg(TagUiSlider, func() {
		w.writeF32le(val)
		w.writeF32le(min)
		w.writeF32le(max)
		w.writeU32le(id)
	})
}

// Checkbox emits a checkbox widget.  The host delivers a CheckboxChanged
// message when the user toggles it.
func (w *Writer) Checkbox(val bool, text string, id uint32) {
	w.msg(TagUiCheckbox, func() {
		var v uint8
		if val {
			v = 1
		}
		w.writeU8(v)
		w.writeStr(text)
		w.writeU32le(id)
	})
}

// Progress emits a progress bar widget.  fraction should be in [0.0, 1.0].
func (w *Writer) Progress(fraction float32, id uint32) {
	w.msg(TagUiProgress, func() {
		w.writeF32le(fraction)
		w.writeU32le(id)
	})
}

// Plot emits a 2-D line plot widget.  xs and ys must have the same length.
func (w *Writer) Plot(title string, xs, ys []float32, id uint32) {
	w.msg(TagUiPlot, func() {
		w.writeStr(title)
		w.writeF32Arr(xs)
		w.writeF32Arr(ys)
		w.writeU32le(id)
	})
}

// Image emits a raw RGBA image widget.
// pixels must be width × height × 4 bytes (RGBA, row-major).
func (w *Writer) Image(pixels []byte, width, height uint32, id uint32) {
	w.msg(TagUiImage, func() {
		w.writeU32le(width)
		w.writeU32le(height)
		w.writeU8Arr(pixels)
		w.writeU32le(id)
	})
}

// CollapsibleStart emits the start of a collapsible section.
// open is the current expanded state as last tracked by the host.
func (w *Writer) CollapsibleStart(label string, open bool, id uint32) {
	w.msg(TagUiCollapsibleStart, func() {
		w.writeStr(label)
		var v uint8
		if open {
			v = 1
		}
		w.writeU8(v)
		w.writeU32le(id)
	})
}

// CollapsibleEnd emits the end marker for a collapsible section.
func (w *Writer) CollapsibleEnd(id uint32) {
	w.msg(TagUiCollapsibleEnd, func() { w.writeU32le(id) })
}

// ── Plugin interface and RunPlugin ───────────────────────────────────────────

// Plugin is the interface that plugin types must implement.
//
// OnLoad is called once when the plugin is first loaded; the plugin should
// register its panels here.
//
// OnUnload is called once before the plugin is removed.
//
// OnTick is called every frame with the elapsed time in seconds.
//
// OnDraw is called when the host wants the plugin to emit UI widgets for the
// named panel.
//
// OnEvent is called for all other host messages (button clicks, slider changes,
// state/config responses, schematic events, etc.).
type Plugin interface {
	OnLoad(w *Writer)
	OnUnload(w *Writer)
	OnTick(dt float32, w *Writer)
	OnDraw(panelId uint16, w *Writer)
	OnEvent(msg Msg, w *Writer)
}

// RunPlugin is the bridge between the raw ABI entry point and the Plugin interface.
//
// Call this from the exported schemify_process function:
//
//	//go:wasmexport schemify_process        (WASM target)
//	//export schemify_process               (native cgo target)
//	func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
//	    return schemify.RunPlugin(&myPlugin, inPtr, inLen, outPtr, outCap)
//	}
//
// Returns the number of bytes written to the output buffer, or ^uintptr(0)
// if the output buffer was too small (host will double it and retry).
func RunPlugin(p Plugin, inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
	in := unsafe.Slice(inPtr, inLen)
	out := unsafe.Slice(outPtr, outCap)
	r := NewReader(in)
	w := NewWriter(out)
	var m Msg
	for r.Next(&m) {
		switch m.Tag {
		case TagLoad:
			p.OnLoad(w)
		case TagUnload:
			p.OnUnload(w)
		case TagTick:
			dt := float32(0)
			if t, ok := m.Data.(MsgTick); ok {
				dt = t.Dt
			}
			p.OnTick(dt, w)
		case TagDrawPanel:
			panelId := uint16(0)
			if d, ok := m.Data.(MsgDrawPanel); ok {
				panelId = d.PanelId
			}
			p.OnDraw(panelId, w)
		default:
			p.OnEvent(m, w)
		}
	}
	if w.Overflow() {
		return ^uintptr(0)
	}
	return uintptr(w.Pos())
}
