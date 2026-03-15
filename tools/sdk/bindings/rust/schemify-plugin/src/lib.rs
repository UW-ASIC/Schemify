//! # Schemify Plugin SDK for Rust — ABI v6
//!
//! Provides safe(r) wrappers around the Schemify v6 message-passing ABI.
//!
//! ## Quick start
//!
//! ```rust,no_run
//! use schemify_plugin::{Plugin, Writer, InMsg, PanelDef, PanelLayout, LogLevel};
//!
//! #[derive(Default)]
//! struct MyPlugin {
//!     threshold: f32,
//! }
//!
//! impl Plugin for MyPlugin {
//!     fn on_load(&mut self, w: &mut Writer) {
//!         w.register_panel(&PanelDef {
//!             id: "my-panel",
//!             title: "My Panel",
//!             vim_cmd: "mypanel",
//!             layout: PanelLayout::Overlay,
//!             keybind: b'm',
//!         });
//!         w.set_status("My plugin loaded!");
//!     }
//!
//!     fn on_draw(&mut self, _panel_id: u16, w: &mut Writer) {
//!         w.label("Hello from Rust!", 0);
//!         w.slider(self.threshold, 0.0, 1.0, 1);
//!     }
//!
//!     fn on_event(&mut self, ev: InMsg, _w: &mut Writer) {
//!         if let InMsg::SliderChanged { widget_id: 1, val, .. } = ev {
//!             self.threshold = val;
//!         }
//!     }
//! }
//!
//! schemify_plugin::export_plugin!(MyPlugin, "my-plugin", "0.1.0");
//! ```
//!
//! The `export_plugin!` macro generates the `schemify_plugin` export symbol
//! and the `schemify_process` entry point.

// ── Enums ──────────────────────────────────────────────────────────────────

/// Panel position in the host UI.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelLayout {
    Overlay      = 0,
    LeftSidebar  = 1,
    RightSidebar = 2,
    BottomBar    = 3,
}

/// Log level for the [`Writer::log`] method.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogLevel {
    Info = 0,
    Warn = 1,
    Err  = 2,
}

// ── PanelDef ───────────────────────────────────────────────────────────────

/// Panel definition passed to [`Writer::register_panel`].
pub struct PanelDef<'a> {
    pub id:      &'a str,
    pub title:   &'a str,
    pub vim_cmd: &'a str,
    pub layout:  PanelLayout,
    pub keybind: u8,
}

// ── Wire-format tags ───────────────────────────────────────────────────────

// Host → plugin
const TAG_LOAD:               u8 = 0x01;
const TAG_UNLOAD:             u8 = 0x02;
const TAG_TICK:               u8 = 0x03;
const TAG_DRAW_PANEL:         u8 = 0x04;
const TAG_BUTTON_CLICKED:     u8 = 0x05;
const TAG_SLIDER_CHANGED:     u8 = 0x06;
const TAG_TEXT_CHANGED:       u8 = 0x07;
const TAG_CHECKBOX_CHANGED:   u8 = 0x08;
const TAG_COMMAND:            u8 = 0x09;
const TAG_STATE_RESPONSE:     u8 = 0x0A;
const TAG_CONFIG_RESPONSE:    u8 = 0x0B;
const TAG_SCHEMATIC_CHANGED:  u8 = 0x0C;
const TAG_SELECTION_CHANGED:  u8 = 0x0D;
const TAG_SCHEMATIC_SNAPSHOT: u8 = 0x0E;
const TAG_INSTANCE_DATA:      u8 = 0x0F;
const TAG_INSTANCE_PROP:      u8 = 0x10;
const TAG_NET_DATA:           u8 = 0x11;

// Plugin → host — commands
const TAG_REGISTER_PANEL:   u8 = 0x80;
const TAG_SET_STATUS:       u8 = 0x81;
const TAG_LOG:              u8 = 0x82;
const TAG_PUSH_COMMAND:     u8 = 0x83;
const TAG_SET_STATE:        u8 = 0x84;
const TAG_GET_STATE:        u8 = 0x85;
const TAG_SET_CONFIG:       u8 = 0x86;
const TAG_GET_CONFIG:       u8 = 0x87;
const TAG_REQUEST_REFRESH:  u8 = 0x88;
const TAG_REGISTER_KEYBIND: u8 = 0x89;
const TAG_PLACE_DEVICE:     u8 = 0x8A;
const TAG_ADD_WIRE:         u8 = 0x8B;
const TAG_SET_INSTANCE_PROP:u8 = 0x8C;
const TAG_QUERY_INSTANCES:  u8 = 0x8D;
const TAG_QUERY_NETS:       u8 = 0x8E;

// Plugin → host — UI widgets
const TAG_UI_LABEL:             u8 = 0xA0;
const TAG_UI_BUTTON:            u8 = 0xA1;
const TAG_UI_SEPARATOR:         u8 = 0xA2;
const TAG_UI_BEGIN_ROW:         u8 = 0xA3;
const TAG_UI_END_ROW:           u8 = 0xA4;
const TAG_UI_SLIDER:            u8 = 0xA5;
const TAG_UI_CHECKBOX:          u8 = 0xA6;
const TAG_UI_PROGRESS:          u8 = 0xA7;
const TAG_UI_PLOT:              u8 = 0xA8;
const TAG_UI_IMAGE:             u8 = 0xA9;
const TAG_UI_COLLAPSIBLE_START: u8 = 0xAA;
const TAG_UI_COLLAPSIBLE_END:   u8 = 0xAB;

// ── InMsg ──────────────────────────────────────────────────────────────────

/// A decoded host→plugin message.
#[derive(Debug)]
pub enum InMsg<'a> {
    Load,
    Unload,
    Tick               { dt: f32 },
    DrawPanel          { panel_id: u16 },
    ButtonClicked      { panel_id: u16, widget_id: u32 },
    SliderChanged      { panel_id: u16, widget_id: u32, val: f32 },
    TextChanged        { panel_id: u16, widget_id: u32, text: &'a str },
    CheckboxChanged    { panel_id: u16, widget_id: u32, val: bool },
    Command            { tag: &'a str, payload: &'a str },
    StateResponse      { key: &'a str, val: &'a str },
    ConfigResponse     { key: &'a str, val: &'a str },
    SchematicChanged,
    SelectionChanged   { instance_idx: i32 },
    SchematicSnapshot  { instance_count: u32, wire_count: u32, net_count: u32 },
    InstanceData       { idx: u32, name: &'a str, symbol: &'a str },
    InstanceProp       { idx: u32, key: &'a str, val: &'a str },
    NetData            { idx: u32, name: &'a str },
}

// ── Reader ─────────────────────────────────────────────────────────────────

/// Iterates over host→plugin messages in a flat binary buffer.
///
/// Unknown tags are silently skipped. Returns `None` at end of buffer or on
/// malformed input.
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    // ── low-level read helpers ──────────────────────────────────────────────

    fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    fn read_u8(&mut self) -> Option<u8> {
        if self.remaining() < 1 { return None; }
        let v = self.buf[self.pos];
        self.pos += 1;
        Some(v)
    }

    fn read_u16le(&mut self) -> Option<u16> {
        if self.remaining() < 2 { return None; }
        let lo = self.buf[self.pos] as u16;
        let hi = self.buf[self.pos + 1] as u16;
        self.pos += 2;
        Some(lo | (hi << 8))
    }

    fn read_u32le(&mut self) -> Option<u32> {
        if self.remaining() < 4 { return None; }
        let b0 = self.buf[self.pos]     as u32;
        let b1 = self.buf[self.pos + 1] as u32;
        let b2 = self.buf[self.pos + 2] as u32;
        let b3 = self.buf[self.pos + 3] as u32;
        self.pos += 4;
        Some(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }

    fn read_i32le(&mut self) -> Option<i32> {
        self.read_u32le().map(|v| v as i32)
    }

    fn read_f32le(&mut self) -> Option<f32> {
        self.read_u32le().map(f32::from_bits)
    }

    /// Read a u16-length-prefixed UTF-8 string from the current position.
    /// Returns a `&str` borrowing from the original buffer.
    fn read_str(&mut self) -> Option<&'a str> {
        let len = self.read_u16le()? as usize;
        if self.remaining() < len { return None; }
        let bytes = &self.buf[self.pos..self.pos + len];
        self.pos += len;
        std::str::from_utf8(bytes).ok()
    }

    /// Skip exactly `n` bytes from the current position.
    fn skip(&mut self, n: usize) -> bool {
        if self.remaining() < n { return false; }
        self.pos += n;
        true
    }

    // ── decode one framed message ───────────────────────────────────────────

    fn decode_next(&mut self) -> Option<InMsg<'a>> {
        loop {
            let tag      = self.read_u8()?;
            let payload_sz = self.read_u16le()? as usize;

            // Snapshot position so we can skip the whole payload if unknown.
            let payload_start = self.pos;

            let msg = match tag {
                TAG_LOAD    => Some(InMsg::Load),
                TAG_UNLOAD  => Some(InMsg::Unload),

                TAG_TICK => {
                    let dt = self.read_f32le()?;
                    Some(InMsg::Tick { dt })
                }

                TAG_DRAW_PANEL => {
                    let panel_id = self.read_u16le()?;
                    Some(InMsg::DrawPanel { panel_id })
                }

                TAG_BUTTON_CLICKED => {
                    let panel_id  = self.read_u16le()?;
                    let widget_id = self.read_u32le()?;
                    Some(InMsg::ButtonClicked { panel_id, widget_id })
                }

                TAG_SLIDER_CHANGED => {
                    let panel_id  = self.read_u16le()?;
                    let widget_id = self.read_u32le()?;
                    let val       = self.read_f32le()?;
                    Some(InMsg::SliderChanged { panel_id, widget_id, val })
                }

                TAG_TEXT_CHANGED => {
                    let panel_id  = self.read_u16le()?;
                    let widget_id = self.read_u32le()?;
                    let text      = self.read_str()?;
                    Some(InMsg::TextChanged { panel_id, widget_id, text })
                }

                TAG_CHECKBOX_CHANGED => {
                    let panel_id  = self.read_u16le()?;
                    let widget_id = self.read_u32le()?;
                    let val_u8    = self.read_u8()?;
                    Some(InMsg::CheckboxChanged { panel_id, widget_id, val: val_u8 != 0 })
                }

                TAG_COMMAND => {
                    let tag_str  = self.read_str()?;
                    let payload  = self.read_str()?;
                    Some(InMsg::Command { tag: tag_str, payload })
                }

                TAG_STATE_RESPONSE => {
                    let key = self.read_str()?;
                    let val = self.read_str()?;
                    Some(InMsg::StateResponse { key, val })
                }

                TAG_CONFIG_RESPONSE => {
                    let key = self.read_str()?;
                    let val = self.read_str()?;
                    Some(InMsg::ConfigResponse { key, val })
                }

                TAG_SCHEMATIC_CHANGED  => Some(InMsg::SchematicChanged),

                TAG_SELECTION_CHANGED => {
                    let instance_idx = self.read_i32le()?;
                    Some(InMsg::SelectionChanged { instance_idx })
                }

                TAG_SCHEMATIC_SNAPSHOT => {
                    let instance_count = self.read_u32le()?;
                    let wire_count     = self.read_u32le()?;
                    let net_count      = self.read_u32le()?;
                    Some(InMsg::SchematicSnapshot { instance_count, wire_count, net_count })
                }

                TAG_INSTANCE_DATA => {
                    let idx    = self.read_u32le()?;
                    let name   = self.read_str()?;
                    let symbol = self.read_str()?;
                    Some(InMsg::InstanceData { idx, name, symbol })
                }

                TAG_INSTANCE_PROP => {
                    let idx = self.read_u32le()?;
                    let key = self.read_str()?;
                    let val = self.read_str()?;
                    Some(InMsg::InstanceProp { idx, key, val })
                }

                TAG_NET_DATA => {
                    let idx  = self.read_u32le()?;
                    let name = self.read_str()?;
                    Some(InMsg::NetData { idx, name })
                }

                _ => {
                    // Unknown tag — skip payload and try the next message.
                    if !self.skip(payload_sz) { return None; }
                    continue;
                }
            };

            // Advance past any remaining payload bytes so the reader stays
            // in sync even if we under-read (e.g., future optional fields).
            let consumed = self.pos - payload_start;
            if consumed < payload_sz {
                let leftover = payload_sz - consumed;
                if !self.skip(leftover) { return None; }
            }

            return msg;
        }
    }
}

impl<'a> Iterator for Reader<'a> {
    type Item = InMsg<'a>;

    fn next(&mut self) -> Option<InMsg<'a>> {
        self.decode_next()
    }
}

// ── Writer ─────────────────────────────────────────────────────────────────

/// Writes plugin→host messages into a caller-supplied byte buffer.
///
/// If a write would exceed `cap`, the message is silently dropped and
/// `overflow()` returns `true` for the remainder of the frame.  The host
/// will double the buffer and retry when it sees the overflow sentinel.
pub struct Writer {
    buf:      *mut u8,
    cap:      usize,
    pos:      usize,
    overflow: bool,
}

impl Writer {
    /// Create a `Writer` that writes into `buf[0..cap]`.
    ///
    /// # Safety
    /// `buf` must be valid and writable for at least `cap` bytes for the
    /// lifetime of this `Writer`.
    pub unsafe fn new(buf: *mut u8, cap: usize) -> Self {
        Writer { buf, cap, pos: 0, overflow: false }
    }

    /// Returns `true` if any write was dropped due to buffer overflow.
    pub fn overflow(&self) -> bool { self.overflow }

    /// Returns the number of bytes written so far.
    pub fn pos(&self) -> usize { self.pos }

    // ── low-level write helpers ─────────────────────────────────────────────

    fn write_byte(&mut self, b: u8) {
        if self.overflow { return; }
        if self.pos >= self.cap { self.overflow = true; return; }
        unsafe { self.buf.add(self.pos).write(b); }
        self.pos += 1;
    }

    fn write_u16le(&mut self, v: u16) {
        self.write_byte((v & 0xFF) as u8);
        self.write_byte((v >> 8)   as u8);
    }

    fn write_u32le(&mut self, v: u32) {
        self.write_byte( (v        & 0xFF) as u8);
        self.write_byte(((v >>  8) & 0xFF) as u8);
        self.write_byte(((v >> 16) & 0xFF) as u8);
        self.write_byte( (v >> 24)         as u8);
    }

    fn write_i32le(&mut self, v: i32) {
        self.write_u32le(v as u32);
    }

    fn write_f32le(&mut self, v: f32) {
        self.write_u32le(v.to_bits());
    }

    /// Write a u16-length-prefixed UTF-8 string.
    fn write_str(&mut self, s: &str) {
        let len = s.len().min(0xFFFF) as u16;
        self.write_u16le(len);
        for b in s.as_bytes().iter().take(len as usize) {
            self.write_byte(*b);
        }
    }

    /// Write a u32-count-prefixed array of f32 values.
    fn write_f32arr(&mut self, arr: &[f32]) {
        self.write_u32le(arr.len() as u32);
        for v in arr {
            self.write_f32le(*v);
        }
    }

    /// Write a u32-count-prefixed byte array.
    fn write_u8arr(&mut self, arr: &[u8]) {
        self.write_u32le(arr.len() as u32);
        for b in arr {
            self.write_byte(*b);
        }
    }

    /// Write the 3-byte message header (tag + payload size).
    /// Returns the position of the payload_sz field so the caller can patch it.
    fn write_header(&mut self, tag: u8, payload_sz: u16) {
        self.write_byte(tag);
        self.write_u16le(payload_sz);
    }

    // ── Framed-payload helper ───────────────────────────────────────────────
    //
    // For variable-length messages we write the header with a dummy size,
    // record the start of the payload, write the payload, then patch the size.
    // If overflow occurred we rewind `pos` to before the header.

    fn begin_msg(&mut self, tag: u8) -> usize {
        let start = self.pos;
        self.write_byte(tag);
        self.write_u16le(0); // placeholder
        start
    }

    fn end_msg(&mut self, start: usize) {
        if self.overflow { return; }
        let payload_start = start + 3;
        let payload_sz    = (self.pos - payload_start) as u16;
        // Patch the size field in-place.
        unsafe {
            self.buf.add(start + 1).write((payload_sz & 0xFF) as u8);
            self.buf.add(start + 2).write((payload_sz >> 8)   as u8);
        }
    }

    // ── Commands ────────────────────────────────────────────────────────────

    /// Register a UI panel with the host.
    pub fn register_panel(&mut self, def: &PanelDef) {
        let start = self.begin_msg(TAG_REGISTER_PANEL);
        self.write_str(def.id);
        self.write_str(def.title);
        self.write_str(def.vim_cmd);
        self.write_byte(def.layout as u8);
        self.write_byte(def.keybind);
        self.end_msg(start);
    }

    /// Set the host status bar text.
    pub fn set_status(&mut self, msg: &str) {
        let start = self.begin_msg(TAG_SET_STATUS);
        self.write_str(msg);
        self.end_msg(start);
    }

    /// Emit a log message at the given level.
    pub fn log(&mut self, level: LogLevel, tag: &str, msg: &str) {
        let start = self.begin_msg(TAG_LOG);
        self.write_byte(level as u8);
        self.write_str(tag);
        self.write_str(msg);
        self.end_msg(start);
    }

    /// Push a named command into the host command queue.
    pub fn push_command(&mut self, tag: &str, payload: &str) {
        let start = self.begin_msg(TAG_PUSH_COMMAND);
        self.write_str(tag);
        self.write_str(payload);
        self.end_msg(start);
    }

    /// Persist a key/value pair in plugin state storage.
    pub fn set_state(&mut self, key: &str, val: &str) {
        let start = self.begin_msg(TAG_SET_STATE);
        self.write_str(key);
        self.write_str(val);
        self.end_msg(start);
    }

    /// Request the value for `key` from plugin state storage.
    /// The response arrives as [`InMsg::StateResponse`] next tick.
    pub fn get_state(&mut self, key: &str) {
        let start = self.begin_msg(TAG_GET_STATE);
        self.write_str(key);
        self.end_msg(start);
    }

    /// Persist a configuration value for a plugin.
    pub fn set_config(&mut self, plugin_id: &str, key: &str, val: &str) {
        let start = self.begin_msg(TAG_SET_CONFIG);
        self.write_str(plugin_id);
        self.write_str(key);
        self.write_str(val);
        self.end_msg(start);
    }

    /// Request a configuration value. Response arrives as [`InMsg::ConfigResponse`].
    pub fn get_config(&mut self, plugin_id: &str, key: &str) {
        let start = self.begin_msg(TAG_GET_CONFIG);
        self.write_str(plugin_id);
        self.write_str(key);
        self.end_msg(start);
    }

    /// Ask the host to repaint the UI on the next frame.
    pub fn request_refresh(&mut self) {
        self.write_header(TAG_REQUEST_REFRESH, 0);
    }

    /// Register a keyboard shortcut that fires a command tag when pressed.
    /// `mods` bitmask: bit0 = Ctrl, bit1 = Shift, bit2 = Alt.
    pub fn register_keybind(&mut self, key: u8, mods: u8, cmd_tag: &str) {
        let start = self.begin_msg(TAG_REGISTER_KEYBIND);
        self.write_byte(key);
        self.write_byte(mods);
        self.write_str(cmd_tag);
        self.end_msg(start);
    }

    /// Place a schematic device instance.
    pub fn place_device(&mut self, sym: &str, name: &str, x: i32, y: i32) {
        let start = self.begin_msg(TAG_PLACE_DEVICE);
        self.write_str(sym);
        self.write_str(name);
        self.write_i32le(x);
        self.write_i32le(y);
        self.end_msg(start);
    }

    /// Add a wire segment to the schematic.
    pub fn add_wire(&mut self, x0: i32, y0: i32, x1: i32, y1: i32) {
        let start = self.begin_msg(TAG_ADD_WIRE);
        self.write_i32le(x0);
        self.write_i32le(y0);
        self.write_i32le(x1);
        self.write_i32le(y1);
        self.end_msg(start);
    }

    /// Set a property on a schematic instance.
    pub fn set_instance_prop(&mut self, idx: u32, key: &str, val: &str) {
        let start = self.begin_msg(TAG_SET_INSTANCE_PROP);
        self.write_u32le(idx);
        self.write_str(key);
        self.write_str(val);
        self.end_msg(start);
    }

    /// Request full instance data for all instances.
    /// Responses arrive as [`InMsg::InstanceData`] / [`InMsg::InstanceProp`] next tick.
    pub fn query_instances(&mut self) {
        self.write_header(TAG_QUERY_INSTANCES, 0);
    }

    /// Request net data for all nets.
    /// Responses arrive as [`InMsg::NetData`] next tick.
    pub fn query_nets(&mut self) {
        self.write_header(TAG_QUERY_NETS, 0);
    }

    // ── UI widgets ──────────────────────────────────────────────────────────

    /// Render a text label.
    pub fn label(&mut self, text: &str, id: u32) {
        let start = self.begin_msg(TAG_UI_LABEL);
        self.write_str(text);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render a clickable button.
    pub fn button(&mut self, text: &str, id: u32) {
        let start = self.begin_msg(TAG_UI_BUTTON);
        self.write_str(text);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render a horizontal separator rule.
    pub fn separator(&mut self, id: u32) {
        let start = self.begin_msg(TAG_UI_SEPARATOR);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Begin a horizontal row layout. Pair with [`end_row`](Writer::end_row).
    pub fn begin_row(&mut self, id: u32) {
        let start = self.begin_msg(TAG_UI_BEGIN_ROW);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// End a horizontal row started with [`begin_row`](Writer::begin_row).
    pub fn end_row(&mut self, id: u32) {
        let start = self.begin_msg(TAG_UI_END_ROW);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render a horizontal slider.
    pub fn slider(&mut self, val: f32, min: f32, max: f32, id: u32) {
        let start = self.begin_msg(TAG_UI_SLIDER);
        self.write_f32le(val);
        self.write_f32le(min);
        self.write_f32le(max);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render a checkbox with a label.
    pub fn checkbox(&mut self, val: bool, text: &str, id: u32) {
        let start = self.begin_msg(TAG_UI_CHECKBOX);
        self.write_byte(val as u8);
        self.write_str(text);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render a progress bar (`fraction` in 0.0–1.0).
    pub fn progress(&mut self, fraction: f32, id: u32) {
        let start = self.begin_msg(TAG_UI_PROGRESS);
        self.write_f32le(fraction);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render a 2D line chart.
    pub fn plot(&mut self, title: &str, xs: &[f32], ys: &[f32], id: u32) {
        let start = self.begin_msg(TAG_UI_PLOT);
        self.write_str(title);
        self.write_f32arr(xs);
        self.write_f32arr(ys);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Render an RGBA8 bitmap of `width × height` pixels.
    pub fn image(&mut self, pixels: &[u8], width: u32, height: u32, id: u32) {
        let start = self.begin_msg(TAG_UI_IMAGE);
        self.write_u32le(width);
        self.write_u32le(height);
        self.write_u8arr(pixels);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// Begin a collapsible section.
    /// `open` is the current open/closed state as last tracked by the host.
    pub fn collapsible_start(&mut self, label: &str, open: bool, id: u32) {
        let start = self.begin_msg(TAG_UI_COLLAPSIBLE_START);
        self.write_str(label);
        self.write_byte(open as u8);
        self.write_u32le(id);
        self.end_msg(start);
    }

    /// End a collapsible section started with
    /// [`collapsible_start`](Writer::collapsible_start).
    pub fn collapsible_end(&mut self, id: u32) {
        let start = self.begin_msg(TAG_UI_COLLAPSIBLE_END);
        self.write_u32le(id);
        self.end_msg(start);
    }
}

// ── Descriptor ─────────────────────────────────────────────────────────────

/// Function signature for the single plugin entry point.
pub type ProcessFn = unsafe extern "C" fn(
    in_ptr:  *const u8, in_len:  usize,
    out_ptr: *mut u8,   out_cap: usize,
) -> usize;

pub const ABI_VERSION: u32 = 6;

/// The export symbol every plugin must provide.
#[repr(C)]
pub struct Descriptor {
    pub abi_version: u32,
    pub name:        *const u8,
    pub version_str: *const u8,
    pub process:     ProcessFn,
}

// SAFETY: `Descriptor` holds only fn pointers and `'static` string literals.
unsafe impl Sync for Descriptor {}

// ── Plugin trait ────────────────────────────────────────────────────────────

/// Implement this trait to define a Schemify v6 plugin.
///
/// Use [`export_plugin!`] to wire it into the required C-ABI exports.
pub trait Plugin: Default {
    /// Called when the host loads the plugin.
    /// Register panels, keybinds, and initial status here.
    fn on_load(&mut self, w: &mut Writer);

    /// Called just before the plugin is unloaded.  Default: no-op.
    fn on_unload(&mut self, w: &mut Writer) { let _ = w; }

    /// Called every frame with the elapsed time in seconds.  Default: no-op.
    fn on_tick(&mut self, dt: f32, w: &mut Writer) { let _ = (dt, w); }

    /// Called when the host requests the plugin to draw a panel.
    /// Write UI widget messages to `w`.  Default: no-op.
    fn on_draw(&mut self, panel_id: u16, w: &mut Writer) { let _ = (panel_id, w); }

    /// Called for all other incoming messages.  Default: no-op.
    fn on_event(&mut self, ev: InMsg, w: &mut Writer) { let _ = (ev, w); }
}

// ── export_plugin! macro ────────────────────────────────────────────────────

/// Generate all C-ABI boilerplate for a Schemify v6 plugin.
///
/// # Usage
///
/// ```rust,no_run
/// schemify_plugin::export_plugin!(MyPlugin, "my-plugin", "0.1.0");
/// ```
///
/// This expands to:
/// - A `static mut _PLUGIN_INSTANCE` that holds the plugin state.
/// - The `schemify_process` `extern "C"` function.
/// - The `schemify_plugin` export symbol (a [`Descriptor`]).
///
/// `MyPlugin` must implement [`Plugin`] and [`Default`].
///
/// # Safety
///
/// The generated `static mut _PLUGIN_INSTANCE` is sound under the host's
/// guarantee that `schemify_process` is never called concurrently or
/// re-entrantly.
#[macro_export]
macro_rules! export_plugin {
    ($plugin_ty:ty, $name:expr, $version:expr) => {
        static mut _PLUGIN_INSTANCE: Option<$plugin_ty> = None;

        #[no_mangle]
        pub unsafe extern "C" fn schemify_process(
            in_ptr:  *const u8, in_len:  usize,
            out_ptr: *mut u8,   out_cap: usize,
        ) -> usize {
            // Initialise on first call.
            if _PLUGIN_INSTANCE.is_none() {
                _PLUGIN_INSTANCE = Some(<$plugin_ty as Default>::default());
            }
            let plugin = _PLUGIN_INSTANCE.as_mut().unwrap();

            let in_buf = std::slice::from_raw_parts(in_ptr, in_len);
            let mut w  = $crate::Writer::new(out_ptr, out_cap);

            for msg in $crate::Reader::new(in_buf) {
                match msg {
                    $crate::InMsg::Load                        => plugin.on_load(&mut w),
                    $crate::InMsg::Unload                      => plugin.on_unload(&mut w),
                    $crate::InMsg::Tick { dt }                 => plugin.on_tick(dt, &mut w),
                    $crate::InMsg::DrawPanel { panel_id }      => plugin.on_draw(panel_id, &mut w),
                    other                                      => plugin.on_event(other, &mut w),
                }
            }

            if w.overflow() { usize::MAX } else { w.pos() }
        }

        #[no_mangle]
        #[used]
        pub static schemify_plugin: $crate::Descriptor = $crate::Descriptor {
            abi_version: $crate::ABI_VERSION,
            name:        concat!($name, "\0").as_ptr(),
            version_str: concat!($version, "\0").as_ptr(),
            process:     schemify_process,
        };
    };
}
