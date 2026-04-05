//! Message writer -- encodes plugin->host binary messages into a flat buffer.

const std = @import("std");
const types = @import("types.zig");

const Tag = types.Tag;
const PanelDef = types.PanelDef;
const LogLevel = types.LogLevel;
const U16_SZ = types.U16_SZ;
const U32_SZ = types.U32_SZ;
const strLen = types.strLen;

const Writer = @This();

/// Output buffer (caller-owned).
buf: []u8,
/// Current write position within `buf`.
pos: usize,
/// Set to true if any write was dropped due to buffer overflow.
overflowed: bool,

pub fn init(buf: []u8) Writer {
    return .{ .buf = buf, .pos = 0, .overflowed = false };
}

/// Returns true if any write was dropped due to buffer overflow.
pub inline fn overflow(self: Writer) bool {
    return self.overflowed;
}

// -- internal helpers ---------------------------------------------------------

inline fn reserve(self: *Writer, n: usize) bool {
    if (self.pos + n > self.buf.len) {
        self.overflowed = true;
        return false;
    }
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

inline fn writeF32Le(self: *Writer, v: f32) void {
    self.writeU32Le(@bitCast(v));
}

/// Write a string as [u16 len_clamped][N bytes].
inline fn writeStrN(self: *Writer, s: []const u8, len: u16) void {
    self.writeU16Le(len);
    if (!self.reserve(len)) return;
    @memcpy(self.buf[self.pos .. self.pos + len], s[0..len]);
    self.pos += len;
}

/// Write a string as [u16 len][N bytes] (computes length internally).
inline fn writeStr(self: *Writer, s: []const u8) void {
    self.writeStrN(s, strLen(s));
}

/// Write a f32 array as [u32 count][count * 4 bytes].
fn writeF32Arr(self: *Writer, arr: []const f32) void {
    self.writeU32Le(@intCast(arr.len));
    for (arr) |v| self.writeF32Le(v);
}

/// Write a u8 array as [u32 count][count bytes].
fn writeU8Arr(self: *Writer, arr: []const u8) void {
    self.writeU32Le(@intCast(arr.len));
    if (!self.reserve(arr.len)) return;
    @memcpy(self.buf[self.pos .. self.pos + arr.len], arr);
    self.pos += arr.len;
}

/// Write the 3-byte message header: [tag u8][payload_sz u16 LE].
inline fn writeHeader(self: *Writer, tag: Tag, payload_sz: u16) void {
    self.writeU8(@intFromEnum(tag));
    self.writeU16Le(payload_sz);
}

// -- plugin->host commands ----------------------------------------------------

/// Register a panel with the host.
pub fn registerPanel(self: *Writer, def: PanelDef) void {
    const id_len = strLen(def.id);
    const title_len = strLen(def.title);
    const vim_len = strLen(def.vim_cmd);
    const sz: u16 = @intCast(U16_SZ + id_len + U16_SZ + title_len + U16_SZ + vim_len + 1 + 1);
    self.writeHeader(.register_panel, sz);
    self.writeStrN(def.id, id_len);
    self.writeStrN(def.title, title_len);
    self.writeStrN(def.vim_cmd, vim_len);
    self.writeU8(@intFromEnum(def.layout));
    self.writeU8(def.keybind);
}

pub fn setStatus(self: *Writer, msg: []const u8) void {
    const l = strLen(msg);
    self.writeHeader(.set_status, U16_SZ + l);
    self.writeStrN(msg, l);
}

pub fn fileReadRequest(self: *Writer, path: []const u8) void {
    const l = strLen(path);
    self.writeHeader(.file_read_request, U16_SZ + l);
    self.writeStrN(path, l);
}

pub fn getState(self: *Writer, key: []const u8) void {
    const l = strLen(key);
    self.writeHeader(.get_state, U16_SZ + l);
    self.writeStrN(key, l);
}

pub fn pushCommand(self: *Writer, tag: []const u8, payload: []const u8) void {
    const tl = strLen(tag);
    const pl = strLen(payload);
    self.writeHeader(.push_command, U16_SZ + tl + U16_SZ + pl);
    self.writeStrN(tag, tl);
    self.writeStrN(payload, pl);
}

pub fn setState(self: *Writer, key: []const u8, val: []const u8) void {
    const kl = strLen(key);
    const vl = strLen(val);
    self.writeHeader(.set_state, U16_SZ + kl + U16_SZ + vl);
    self.writeStrN(key, kl);
    self.writeStrN(val, vl);
}

pub fn getConfig(self: *Writer, plugin_id: []const u8, key: []const u8) void {
    const il = strLen(plugin_id);
    const kl = strLen(key);
    self.writeHeader(.get_config, U16_SZ + il + U16_SZ + kl);
    self.writeStrN(plugin_id, il);
    self.writeStrN(key, kl);
}

pub fn requestRefresh(self: *Writer) void {
    self.writeHeader(.request_refresh, 0);
}

pub fn queryInstances(self: *Writer) void {
    self.writeHeader(.query_instances, 0);
}

pub fn queryNets(self: *Writer) void {
    self.writeHeader(.query_nets, 0);
}

pub fn log(self: *Writer, level: LogLevel, tag: []const u8, msg: []const u8) void {
    const tl = strLen(tag);
    const ml = strLen(msg);
    self.writeHeader(.log, 1 + U16_SZ + tl + U16_SZ + ml);
    self.writeU8(@intFromEnum(level));
    self.writeStrN(tag, tl);
    self.writeStrN(msg, ml);
}

pub fn setConfig(self: *Writer, plugin_id: []const u8, key: []const u8, val: []const u8) void {
    const il = strLen(plugin_id);
    const kl = strLen(key);
    const vl = strLen(val);
    self.writeHeader(.set_config, U16_SZ + il + U16_SZ + kl + U16_SZ + vl);
    self.writeStrN(plugin_id, il);
    self.writeStrN(key, kl);
    self.writeStrN(val, vl);
}

pub fn registerCommand(self: *Writer, id: []const u8, display_name: []const u8, description: []const u8) void {
    const il = strLen(id);
    const dl = strLen(display_name);
    const el = strLen(description);
    self.writeHeader(.register_command, U16_SZ + il + U16_SZ + dl + U16_SZ + el);
    self.writeStrN(id, il);
    self.writeStrN(display_name, dl);
    self.writeStrN(description, el);
}

pub fn registerKeybind(self: *Writer, key: u8, mods: u8, cmd_tag: []const u8) void {
    const cl = strLen(cmd_tag);
    self.writeHeader(.register_keybind, 1 + 1 + U16_SZ + cl);
    self.writeU8(key);
    self.writeU8(mods);
    self.writeStrN(cmd_tag, cl);
}

pub fn placeDevice(self: *Writer, sym: []const u8, name: []const u8, x: i32, y: i32) void {
    const sl = strLen(sym);
    const nl = strLen(name);
    self.writeHeader(.place_device, U16_SZ + sl + U16_SZ + nl + U32_SZ + U32_SZ);
    self.writeStrN(sym, sl);
    self.writeStrN(name, nl);
    self.writeI32Le(x);
    self.writeI32Le(y);
}

pub fn addWire(self: *Writer, x0: i32, y0: i32, x1: i32, y1: i32) void {
    self.writeHeader(.add_wire, U32_SZ * 4);
    self.writeI32Le(x0);
    self.writeI32Le(y0);
    self.writeI32Le(x1);
    self.writeI32Le(y1);
}

pub fn setInstanceProp(self: *Writer, idx: u32, key: []const u8, val: []const u8) void {
    const kl = strLen(key);
    const vl = strLen(val);
    self.writeHeader(.set_instance_prop, U32_SZ + U16_SZ + kl + U16_SZ + vl);
    self.writeU32Le(idx);
    self.writeStrN(key, kl);
    self.writeStrN(val, vl);
}

pub fn fileWrite(self: *Writer, path: []const u8, data: []const u8) void {
    const pl = strLen(path);
    const raw_sz: usize = U16_SZ + pl + U32_SZ + data.len;
    if (raw_sz > std.math.maxInt(u16)) {
        self.overflowed = true;
        return;
    }
    self.writeHeader(.file_write, @intCast(raw_sz));
    self.writeStrN(path, pl);
    self.writeU8Arr(data);
}

// -- plugin->host UI widgets --------------------------------------------------

pub fn label(self: *Writer, text: []const u8, id: u32) void {
    const l = strLen(text);
    self.writeHeader(.ui_label, U16_SZ + l + U32_SZ);
    self.writeStrN(text, l);
    self.writeU32Le(id);
}

pub fn button(self: *Writer, text: []const u8, id: u32) void {
    const l = strLen(text);
    self.writeHeader(.ui_button, U16_SZ + l + U32_SZ);
    self.writeStrN(text, l);
    self.writeU32Le(id);
}

pub fn separator(self: *Writer, id: u32) void {
    self.writeHeader(.ui_separator, U32_SZ);
    self.writeU32Le(id);
}

pub fn beginRow(self: *Writer, id: u32) void {
    self.writeHeader(.ui_begin_row, U32_SZ);
    self.writeU32Le(id);
}

pub fn endRow(self: *Writer, id: u32) void {
    self.writeHeader(.ui_end_row, U32_SZ);
    self.writeU32Le(id);
}

pub fn collapsibleEnd(self: *Writer, id: u32) void {
    self.writeHeader(.ui_collapsible_end, U32_SZ);
    self.writeU32Le(id);
}

pub fn slider(self: *Writer, val: f32, min: f32, max: f32, id: u32) void {
    self.writeHeader(.ui_slider, U32_SZ * 4);
    self.writeF32Le(val);
    self.writeF32Le(min);
    self.writeF32Le(max);
    self.writeU32Le(id);
}

pub fn checkbox(self: *Writer, val: bool, text: []const u8, id: u32) void {
    const l = strLen(text);
    self.writeHeader(.ui_checkbox, 1 + U16_SZ + l + U32_SZ);
    self.writeU8(if (val) 1 else 0);
    self.writeStrN(text, l);
    self.writeU32Le(id);
}

pub fn progress(self: *Writer, fraction: f32, id: u32) void {
    self.writeHeader(.ui_progress, U32_SZ * 2);
    self.writeF32Le(fraction);
    self.writeU32Le(id);
}

pub fn plot(self: *Writer, title: []const u8, xs: []const f32, ys: []const f32, id: u32) void {
    const tl = strLen(title);
    const raw_sz: usize = U16_SZ + tl + U32_SZ + xs.len * U32_SZ + U32_SZ + ys.len * U32_SZ + U32_SZ;
    if (raw_sz > std.math.maxInt(u16)) {
        self.overflowed = true;
        return;
    }
    self.writeHeader(.ui_plot, @intCast(raw_sz));
    self.writeStrN(title, tl);
    self.writeF32Arr(xs);
    self.writeF32Arr(ys);
    self.writeU32Le(id);
}

pub fn image(self: *Writer, pixels: []const u8, w: u32, h: u32, id: u32) void {
    const raw_sz: usize = U32_SZ + U32_SZ + U32_SZ + pixels.len + U32_SZ;
    if (raw_sz > std.math.maxInt(u16)) {
        self.overflowed = true;
        return;
    }
    self.writeHeader(.ui_image, @intCast(raw_sz));
    self.writeU32Le(w);
    self.writeU32Le(h);
    self.writeU8Arr(pixels);
    self.writeU32Le(id);
}

pub fn collapsibleStart(self: *Writer, label_text: []const u8, open: bool, id: u32) void {
    const l = strLen(label_text);
    self.writeHeader(.ui_collapsible_start, U16_SZ + l + 1 + U32_SZ);
    self.writeStrN(label_text, l);
    self.writeU8(if (open) 1 else 0);
    self.writeU32Le(id);
}
