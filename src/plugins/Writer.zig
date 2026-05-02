//! Plugin -> host message encoder into a flat buffer.

const std = @import("std");
const types = @import("types.zig");

const Tag = types.Tag;
const U16_SZ = types.U16_SZ;
const U32_SZ = types.U32_SZ;
const strLen = types.strLen;

const Writer = @This();

buf: []u8,
pos: usize,
overflowed: bool,

pub fn init(buf: []u8) Writer {
    return .{ .buf = buf, .pos = 0, .overflowed = false };
}

// -- internal helpers ---------------------------------------------------------

inline fn reserve(self: *Writer, n: usize) bool {
    if (self.pos + n > self.buf.len) { self.overflowed = true; return false; }
    return true;
}

inline fn writeU8(self: *Writer, v: u8) void {
    if (!self.reserve(1)) return;
    self.buf[self.pos] = v;
    self.pos += 1;
}

inline fn writeU16Le(self: *Writer, v: u16) void {
    if (!self.reserve(U16_SZ)) return;
    std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
    self.pos += U16_SZ;
}

inline fn writeU32Le(self: *Writer, v: u32) void {
    if (!self.reserve(U32_SZ)) return;
    std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
    self.pos += U32_SZ;
}

inline fn writeI32Le(self: *Writer, v: i32) void {
    if (!self.reserve(U32_SZ)) return;
    std.mem.writeInt(i32, self.buf[self.pos..][0..4], v, .little);
    self.pos += U32_SZ;
}

inline fn writeF32Le(self: *Writer, v: f32) void { self.writeU32Le(@bitCast(v)); }

inline fn writeStrN(self: *Writer, s: []const u8, len: u16) void {
    self.writeU16Le(len);
    if (!self.reserve(len)) return;
    @memcpy(self.buf[self.pos .. self.pos + len], s[0..len]);
    self.pos += len;
}

inline fn writeStr(self: *Writer, s: []const u8) void { self.writeStrN(s, strLen(s)); }

fn writeF32Arr(self: *Writer, arr: []const f32) void {
    self.writeU32Le(@intCast(arr.len));
    for (arr) |v| self.writeF32Le(v);
}

fn writeU8Arr(self: *Writer, arr: []const u8) void {
    self.writeU32Le(@intCast(arr.len));
    if (!self.reserve(arr.len)) return;
    @memcpy(self.buf[self.pos .. self.pos + arr.len], arr);
    self.pos += arr.len;
}

inline fn writeHeader(self: *Writer, tag: Tag, payload_sz: u16) void {
    self.writeU8(@intFromEnum(tag));
    self.writeU16Le(payload_sz);
}

// -- string message helpers ---------------------------------------------------

inline fn oneStr(self: *Writer, tag: Tag, s: []const u8) void {
    const l = strLen(s);
    self.writeHeader(tag, U16_SZ + l);
    self.writeStrN(s, l);
}

inline fn twoStr(self: *Writer, tag: Tag, a: []const u8, b: []const u8) void {
    const al = strLen(a);
    const bl = strLen(b);
    self.writeHeader(tag, U16_SZ + al + U16_SZ + bl);
    self.writeStrN(a, al);
    self.writeStrN(b, bl);
}

inline fn threeStr(self: *Writer, tag: Tag, a: []const u8, b: []const u8, c: []const u8) void {
    const al = strLen(a);
    const bl = strLen(b);
    const cl = strLen(c);
    self.writeHeader(tag, U16_SZ + al + U16_SZ + bl + U16_SZ + cl);
    self.writeStrN(a, al);
    self.writeStrN(b, bl);
    self.writeStrN(c, cl);
}

inline fn keybindMsg(self: *Writer, tag: Tag, key: u8, mods: u8, cmd_tag: []const u8) void {
    const cl = strLen(cmd_tag);
    self.writeHeader(tag, 1 + 1 + U16_SZ + cl);
    self.writeU8(key);
    self.writeU8(mods);
    self.writeStrN(cmd_tag, cl);
}

inline fn uiTextId(self: *Writer, tag: Tag, text: []const u8, id: u32) void {
    const l = strLen(text);
    self.writeHeader(tag, U16_SZ + l + U32_SZ);
    self.writeStrN(text, l);
    self.writeU32Le(id);
}

inline fn uiIdOnly(self: *Writer, tag: Tag, id: u32) void {
    self.writeHeader(tag, U32_SZ);
    self.writeU32Le(id);
}

// -- plugin -> host commands --------------------------------------------------

pub fn registerPanel(self: *Writer, def: types.PanelDef) void {
    const il = strLen(def.id);
    const tl = strLen(def.title);
    const vl = strLen(def.vim_cmd);
    self.writeHeader(.register_panel, @intCast(U16_SZ + il + U16_SZ + tl + U16_SZ + vl + 1 + 1));
    self.writeStrN(def.id, il);
    self.writeStrN(def.title, tl);
    self.writeStrN(def.vim_cmd, vl);
    self.writeU8(@intFromEnum(def.layout));
    self.writeU8(def.keybind);
}

pub fn setStatus(self: *Writer, msg: []const u8) void { self.oneStr(.set_status, msg); }
pub fn fileReadRequest(self: *Writer, path: []const u8) void { self.oneStr(.file_read_request, path); }
pub fn getState(self: *Writer, key: []const u8) void { self.oneStr(.get_state, key); }
pub fn setState(self: *Writer, key: []const u8, val: []const u8) void { self.twoStr(.set_state, key, val); }
pub fn pushCommand(self: *Writer, tag: []const u8, payload: []const u8) void { self.twoStr(.push_command, tag, payload); }
pub fn getConfig(self: *Writer, plugin_id: []const u8, key: []const u8) void { self.twoStr(.get_config, plugin_id, key); }
pub fn setConfig(self: *Writer, plugin_id: []const u8, key: []const u8, val: []const u8) void { self.threeStr(.set_config, plugin_id, key, val); }
pub fn registerCommand(self: *Writer, id: []const u8, display_name: []const u8, description: []const u8) void { self.threeStr(.register_command, id, display_name, description); }

pub fn requestRefresh(self: *Writer) void { self.writeHeader(.request_refresh, 0); }
pub fn queryInstances(self: *Writer) void { self.writeHeader(.query_instances, 0); }
pub fn queryNets(self: *Writer) void { self.writeHeader(.query_nets, 0); }
pub fn consumeEvent(self: *Writer) void { self.writeHeader(.consume_event, 0); }

pub fn subscribeEvents(self: *Writer, mask: u8) void { self.writeHeader(.subscribe_events, 1); self.writeU8(mask); }
pub fn registerKeybind(self: *Writer, key: u8, mods: u8, cmd_tag: []const u8) void { self.keybindMsg(.register_keybind, key, mods, cmd_tag); }
pub fn overrideKeybind(self: *Writer, key: u8, mods: u8, cmd_tag: []const u8) void { self.keybindMsg(.override_keybind, key, mods, cmd_tag); }

pub fn log(self: *Writer, level: types.LogLevel, tag: []const u8, msg: []const u8) void {
    const tl = strLen(tag); const ml = strLen(msg);
    self.writeHeader(.log, 1 + U16_SZ + tl + U16_SZ + ml);
    self.writeU8(@intFromEnum(level)); self.writeStrN(tag, tl); self.writeStrN(msg, ml);
}

pub fn placeDevice(self: *Writer, sym: []const u8, name: []const u8, x: i32, y: i32) void {
    const sl = strLen(sym); const nl = strLen(name);
    self.writeHeader(.place_device, U16_SZ + sl + U16_SZ + nl + U32_SZ + U32_SZ);
    self.writeStrN(sym, sl); self.writeStrN(name, nl); self.writeI32Le(x); self.writeI32Le(y);
}

pub fn addWire(self: *Writer, x0: i32, y0: i32, x1: i32, y1: i32) void {
    self.writeHeader(.add_wire, U32_SZ * 4);
    self.writeI32Le(x0); self.writeI32Le(y0); self.writeI32Le(x1); self.writeI32Le(y1);
}

pub fn setInstanceProp(self: *Writer, idx: u32, key: []const u8, val: []const u8) void {
    const kl = strLen(key); const vl = strLen(val);
    self.writeHeader(.set_instance_prop, U32_SZ + U16_SZ + kl + U16_SZ + vl);
    self.writeU32Le(idx); self.writeStrN(key, kl); self.writeStrN(val, vl);
}

pub fn fileWrite(self: *Writer, path: []const u8, data: []const u8) void {
    const pl = strLen(path);
    const raw: usize = U16_SZ + pl + U32_SZ + data.len;
    if (raw > std.math.maxInt(u16)) { self.overflowed = true; return; }
    self.writeHeader(.file_write, @intCast(raw)); self.writeStrN(path, pl); self.writeU8Arr(data);
}

/// NEW in v8: send an HTML layout for a panel. [u16 panel_id][u16 len][html bytes]
pub fn htmlLayout(self: *Writer, panel_id: u16, html: []const u8) void {
    const hl = strLen(html);
    self.writeHeader(.html_layout, U16_SZ + U16_SZ + hl); self.writeU16Le(panel_id); self.writeStrN(html, hl);
}

// -- plugin -> host UI widgets ------------------------------------------------

pub fn label(self: *Writer, text: []const u8, id: u32) void { self.uiTextId(.ui_label, text, id); }
pub fn button(self: *Writer, text: []const u8, id: u32) void { self.uiTextId(.ui_button, text, id); }
pub fn tooltip(self: *Writer, text: []const u8, id: u32) void { self.uiTextId(.ui_tooltip, text, id); }
pub fn separator(self: *Writer, id: u32) void { self.uiIdOnly(.ui_separator, id); }
pub fn beginRow(self: *Writer, id: u32) void { self.uiIdOnly(.ui_begin_row, id); }
pub fn endRow(self: *Writer, id: u32) void { self.uiIdOnly(.ui_end_row, id); }
pub fn collapsibleEnd(self: *Writer, id: u32) void { self.uiIdOnly(.ui_collapsible_end, id); }

pub fn slider(self: *Writer, val: f32, min: f32, max: f32, id: u32) void {
    self.writeHeader(.ui_slider, U32_SZ * 4);
    self.writeF32Le(val); self.writeF32Le(min); self.writeF32Le(max); self.writeU32Le(id);
}

pub fn checkbox(self: *Writer, val: bool, text: []const u8, id: u32) void {
    const l = strLen(text);
    self.writeHeader(.ui_checkbox, 1 + U16_SZ + l + U32_SZ);
    self.writeU8(if (val) 1 else 0); self.writeStrN(text, l); self.writeU32Le(id);
}

pub fn progress(self: *Writer, fraction: f32, id: u32) void {
    self.writeHeader(.ui_progress, U32_SZ * 2); self.writeF32Le(fraction); self.writeU32Le(id);
}

pub fn plot(self: *Writer, title: []const u8, xs: []const f32, ys: []const f32, id: u32) void {
    const tl = strLen(title);
    const raw: usize = U16_SZ + tl + U32_SZ + xs.len * U32_SZ + U32_SZ + ys.len * U32_SZ + U32_SZ;
    if (raw > std.math.maxInt(u16)) { self.overflowed = true; return; }
    self.writeHeader(.ui_plot, @intCast(raw));
    self.writeStrN(title, tl); self.writeF32Arr(xs); self.writeF32Arr(ys); self.writeU32Le(id);
}

pub fn image(self: *Writer, pixels: []const u8, w: u32, h: u32, id: u32) void {
    const raw: usize = U32_SZ * 3 + pixels.len + U32_SZ;
    if (raw > std.math.maxInt(u16)) { self.overflowed = true; return; }
    self.writeHeader(.ui_image, @intCast(raw));
    self.writeU32Le(w); self.writeU32Le(h); self.writeU8Arr(pixels); self.writeU32Le(id);
}

pub fn textInput(self: *Writer, hint: []const u8, text: []const u8, id: u32) void {
    const hl = strLen(hint);
    const tl = strLen(text);
    self.writeHeader(.ui_text_input, U16_SZ + hl + U16_SZ + tl + U32_SZ);
    self.writeStrN(hint, hl);
    self.writeStrN(text, tl);
    self.writeU32Le(id);
}

pub fn textArea(self: *Writer, hint: []const u8, text: []const u8, id: u32) void {
    const hl = strLen(hint);
    const tl = strLen(text);
    self.writeHeader(.ui_text_area, U16_SZ + hl + U16_SZ + tl + U32_SZ);
    self.writeStrN(hint, hl);
    self.writeStrN(text, tl);
    self.writeU32Le(id);
}

pub fn collapsibleStart(self: *Writer, label_text: []const u8, open: bool, id: u32) void {
    const l = strLen(label_text);
    self.writeHeader(.ui_collapsible_start, U16_SZ + l + 1 + U32_SZ);
    self.writeStrN(label_text, l); self.writeU8(if (open) 1 else 0); self.writeU32Le(id);
}
