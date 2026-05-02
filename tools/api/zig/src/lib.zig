//! Schemify Plugin SDK — Zig (ABI v6)
//!
//! Self-contained — no build.zig.zon needed.
//! Copy this file alongside your plugin and import it by path.
//!
//! Usage:
//!
//!   const sp = @import("schemify.zig");
//!
//!   fn process(in: []const u8, out: []u8) usize {
//!       var r = sp.Reader.init(in);
//!       var w = sp.Writer.init(out);
//!       while (r.next()) |msg| {
//!           switch (msg) {
//!               .load => w.registerPanel("hello", "Hello", "hello", .left_sidebar, 0),
//!               .draw_panel => w.label("Hello from Zig!", 1),
//!               else => {},
//!           }
//!       }
//!       return w.finish() catch ~@as(usize, 0);
//!   }
//!
//!   export const schemify_plugin = sp.descriptor("my-plugin", "0.1.0", process);

pub const ABI_VERSION: u32 = 8;

// ── Layout ────────────────────────────────────────────────────────────────

pub const Layout = enum(u8) {
    overlay       = 0,
    left_sidebar  = 1,
    right_sidebar = 2,
    bottom_bar    = 3,
};

// ── Incoming messages ─────────────────────────────────────────────────────

pub const Msg = union(enum) {
    load,
    unload,
    tick:               f32,
    draw_panel:         u16,
    button_clicked:     struct { panel_id: u16, widget_id: u32 },
    slider_changed:     struct { panel_id: u16, widget_id: u32, val: f32 },
    text_changed:       struct { panel_id: u16, widget_id: u32, text: []const u8 },
    checkbox_changed:   struct { panel_id: u16, widget_id: u32, val: bool },
    command:            struct { tag: []const u8, payload: []const u8 },
    state_response:     struct { key: []const u8, val: []const u8 },
    config_response:    struct { key: []const u8, val: []const u8 },
    schematic_changed,
    selection_changed:  i32,
    schematic_snapshot: struct { instance_count: u32, wire_count: u32, net_count: u32 },
    instance_data:      struct { idx: u32, name: []const u8, symbol: []const u8 },
    instance_prop:      struct { idx: u32, key: []const u8, val: []const u8 },
    net_data:           struct { idx: u32, name: []const u8 },
    file_response:      struct { path: []const u8, data: []const u8 },
    hover:              struct { world_x: i32, world_y: i32, element_type: u8, element_idx: i32, element_name: []const u8 },
    key_event:          struct { key: u8, mods: u8, action: u8 },
};

pub const EVENT_HOVER: u8 = 1 << 0;
pub const EVENT_KEYS: u8 = 1 << 1;

// ── Reader ────────────────────────────────────────────────────────────────

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader { return .{ .buf = buf }; }

    pub fn next(self: *Reader) ?Msg {
        while (true) {
            if (self.pos + 3 > self.buf.len) return null;
            const tag         = self.buf[self.pos];
            const payload_sz  = rdU16(self.buf[self.pos + 1 ..]);
            const hdr_end     = self.pos + 3;
            const payload_end = hdr_end + payload_sz;
            if (payload_end > self.buf.len) return null;
            const p   = self.buf[hdr_end..payload_end];
            self.pos  = payload_end;

            switch (tag) {
                0x01 => return .load,
                0x02 => return .unload,
                0x03 => { if (p.len < 4) continue; return .{ .tick = rdF32(p) }; },
                0x04 => { if (p.len < 2) continue; return .{ .draw_panel = rdU16(p) }; },
                0x05 => {
                    if (p.len < 6) continue;
                    return .{ .button_clicked = .{ .panel_id = rdU16(p), .widget_id = rdU32(p[2..]) } };
                },
                0x06 => {
                    if (p.len < 10) continue;
                    return .{ .slider_changed = .{ .panel_id = rdU16(p), .widget_id = rdU32(p[2..]), .val = rdF32(p[6..]) } };
                },
                0x07 => {
                    if (p.len < 6) continue;
                    var off: usize = 6;
                    const text = rdStr(p, &off) orelse continue;
                    return .{ .text_changed = .{ .panel_id = rdU16(p), .widget_id = rdU32(p[2..]), .text = text } };
                },
                0x08 => {
                    if (p.len < 7) continue;
                    return .{ .checkbox_changed = .{ .panel_id = rdU16(p), .widget_id = rdU32(p[2..]), .val = p[6] != 0 } };
                },
                0x09 => {
                    var off: usize = 0;
                    const t  = rdStr(p, &off) orelse continue;
                    const pl = rdStr(p, &off) orelse continue;
                    return .{ .command = .{ .tag = t, .payload = pl } };
                },
                0x0A => {
                    var off: usize = 0;
                    const k = rdStr(p, &off) orelse continue;
                    const v = rdStr(p, &off) orelse continue;
                    return .{ .state_response = .{ .key = k, .val = v } };
                },
                0x0B => {
                    var off: usize = 0;
                    const k = rdStr(p, &off) orelse continue;
                    const v = rdStr(p, &off) orelse continue;
                    return .{ .config_response = .{ .key = k, .val = v } };
                },
                0x0C => return .schematic_changed,
                0x0D => { if (p.len < 4) continue; return .{ .selection_changed = rdI32(p) }; },
                0x0E => {
                    if (p.len < 12) continue;
                    return .{ .schematic_snapshot = .{
                        .instance_count = rdU32(p),
                        .wire_count     = rdU32(p[4..]),
                        .net_count      = rdU32(p[8..]),
                    }};
                },
                0x0F => {
                    if (p.len < 4) continue;
                    var off: usize = 4;
                    const n = rdStr(p, &off) orelse continue;
                    const s = rdStr(p, &off) orelse continue;
                    return .{ .instance_data = .{ .idx = rdU32(p), .name = n, .symbol = s } };
                },
                0x10 => {
                    if (p.len < 4) continue;
                    var off: usize = 4;
                    const k = rdStr(p, &off) orelse continue;
                    const v = rdStr(p, &off) orelse continue;
                    return .{ .instance_prop = .{ .idx = rdU32(p), .key = k, .val = v } };
                },
                0x11 => {
                    if (p.len < 4) continue;
                    var off: usize = 4;
                    const n = rdStr(p, &off) orelse continue;
                    return .{ .net_data = .{ .idx = rdU32(p), .name = n } };
                },
                0x12 => {
                    var off: usize = 0;
                    const path = rdStr(p, &off) orelse continue;
                    if (off + 4 > p.len) continue;
                    const count: usize = rdU32(p[off..]);
                    off += 4;
                    if (off + count > p.len) continue;
                    return .{ .file_response = .{ .path = path, .data = p[off..off + count] } };
                },
                0x13 => {
                    if (p.len < 13) continue;
                    var off: usize = 13;
                    const ename = rdStr(p, &off) orelse "";
                    return .{ .hover = .{
                        .world_x = rdI32(p), .world_y = rdI32(p[4..]),
                        .element_type = p[8], .element_idx = rdI32(p[9..]),
                        .element_name = ename,
                    }};
                },
                0x14 => {
                    if (p.len < 3) continue;
                    return .{ .key_event = .{ .key = p[0], .mods = p[1], .action = p[2] } };
                },
                else => continue,
            }
        }
    }

    fn rdU16(b: []const u8) u16 { return @as(u16, b[0]) | (@as(u16, b[1]) << 8); }
    fn rdU32(b: []const u8) u32 {
        return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
    }
    fn rdI32(b: []const u8) i32 { return @bitCast(rdU32(b)); }
    fn rdF32(b: []const u8) f32 { return @bitCast(rdU32(b)); }
    fn rdStr(b: []const u8, off: *usize) ?[]const u8 {
        if (off.* + 2 > b.len) return null;
        const slen: usize = rdU16(b[off.*..]);
        off.* += 2;
        if (off.* + slen > b.len) return null;
        const s = b[off.*..][0..slen];
        off.* += slen;
        return s;
    }
};

// ── Writer ────────────────────────────────────────────────────────────────

pub const Writer = struct {
    buf:      []u8,
    pos:      usize = 0,
    overflow: bool  = false,

    pub fn init(buf: []u8) Writer { return .{ .buf = buf }; }

    pub fn finish(self: *const Writer) error{Overflow}!usize {
        if (self.overflow) return error.Overflow;
        return self.pos;
    }

    // ── Commands ──────────────────────────────────────────────────────────

    pub fn setStatus(self: *Writer, msg: []const u8) void {
        const p: u16 = @intCast(2 + msg.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x81, p); self.str(msg);
    }
    pub fn log(self: *Writer, level: u8, tag: []const u8, msg: []const u8) void {
        const p: u16 = @intCast(1 + 2 + tag.len + 2 + msg.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x82, p); self.b(level); self.str(tag); self.str(msg);
    }
    pub fn registerPanel(self: *Writer, id: []const u8, title: []const u8,
                         vim: []const u8, layout: Layout, keybind: u8) void {
        const p: u16 = @intCast(2 + id.len + 2 + title.len + 2 + vim.len + 1 + 1);
        if (!self.room(3 + p)) return;
        self.hdr(0x80, p); self.str(id); self.str(title); self.str(vim);
        self.b(@intFromEnum(layout)); self.b(keybind);
    }
    pub fn requestRefresh(self: *Writer) void { if (self.room(3)) self.hdr(0x88, 0); }
    pub fn getState(self: *Writer, key: []const u8) void {
        const p: u16 = @intCast(2 + key.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x85, p); self.str(key);
    }
    pub fn setState(self: *Writer, key: []const u8, val: []const u8) void {
        const p: u16 = @intCast(2 + key.len + 2 + val.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x84, p); self.str(key); self.str(val);
    }
    pub fn getConfig(self: *Writer, plugin_id: []const u8, key: []const u8) void {
        const p: u16 = @intCast(2 + plugin_id.len + 2 + key.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x87, p); self.str(plugin_id); self.str(key);
    }
    pub fn setConfig(self: *Writer, plugin_id: []const u8, key: []const u8, val: []const u8) void {
        const p: u16 = @intCast(2 + plugin_id.len + 2 + key.len + 2 + val.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x86, p); self.str(plugin_id); self.str(key); self.str(val);
    }
    pub fn queryInstances(self: *Writer) void { if (self.room(3)) self.hdr(0x8D, 0); }
    pub fn queryNets(self: *Writer)      void { if (self.room(3)) self.hdr(0x8E, 0); }
    pub fn placeDevice(self: *Writer, sym: []const u8, name: []const u8, x: i32, y: i32) void {
        const p: u16 = @intCast(2 + sym.len + 2 + name.len + 4 + 4);
        if (!self.room(3 + p)) return;
        self.hdr(0x8A, p); self.str(sym); self.str(name); self.i32w(x); self.i32w(y);
    }
    pub fn addWire(self: *Writer, x0: i32, y0: i32, x1: i32, y1: i32) void {
        if (!self.room(3 + 16)) return;
        self.hdr(0x8B, 16); self.i32w(x0); self.i32w(y0); self.i32w(x1); self.i32w(y1);
    }
    pub fn setInstanceProp(self: *Writer, idx: u32, key: []const u8, val: []const u8) void {
        const p: u16 = @intCast(4 + 2 + key.len + 2 + val.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x8C, p); self.u32w(idx); self.str(key); self.str(val);
    }

    // ── UI widgets ────────────────────────────────────────────────────────

    pub fn label(self: *Writer, text: []const u8, id: u32) void {
        const p: u16 = @intCast(2 + text.len + 4);
        if (!self.room(3 + p)) return;
        self.hdr(0xA0, p); self.str(text); self.u32w(id);
    }
    pub fn button(self: *Writer, text: []const u8, id: u32) void {
        const p: u16 = @intCast(2 + text.len + 4);
        if (!self.room(3 + p)) return;
        self.hdr(0xA1, p); self.str(text); self.u32w(id);
    }
    pub fn separator(self: *Writer, id: u32) void { if (self.room(7)) { self.hdr(0xA2, 4); self.u32w(id); } }
    pub fn beginRow(self: *Writer, id: u32) void  { if (self.room(7)) { self.hdr(0xA3, 4); self.u32w(id); } }
    pub fn endRow(self: *Writer, id: u32) void    { if (self.room(7)) { self.hdr(0xA4, 4); self.u32w(id); } }
    pub fn slider(self: *Writer, val: f32, min: f32, max: f32, id: u32) void {
        if (!self.room(3 + 16)) return;
        self.hdr(0xA5, 16); self.f32w(val); self.f32w(min); self.f32w(max); self.u32w(id);
    }
    pub fn checkbox(self: *Writer, val: bool, text: []const u8, id: u32) void {
        const p: u16 = @intCast(1 + 2 + text.len + 4);
        if (!self.room(3 + p)) return;
        self.hdr(0xA6, p); self.b(if (val) 1 else 0); self.str(text); self.u32w(id);
    }
    pub fn progress(self: *Writer, fraction: f32, id: u32) void {
        if (!self.room(3 + 8)) return;
        self.hdr(0xA7, 8); self.f32w(fraction); self.u32w(id);
    }
    pub fn collapsibleStart(self: *Writer, lbl: []const u8, open: bool, id: u32) void {
        const p: u16 = @intCast(2 + lbl.len + 1 + 4);
        if (!self.room(3 + p)) return;
        self.hdr(0xAA, p); self.str(lbl); self.b(if (open) 1 else 0); self.u32w(id);
    }
    pub fn collapsibleEnd(self: *Writer, id: u32) void {
        if (self.room(7)) { self.hdr(0xAB, 4); self.u32w(id); }
    }
    pub fn plot(self: *Writer, title: []const u8, xs: []const f32, ys: []const f32, id: u32) void {
        const raw_sz: usize = 2 + title.len + 4 + xs.len * 4 + 4 + ys.len * 4 + 4;
        if (raw_sz > 0xFFFF) { self.overflow = true; return; }
        const p: u16 = @intCast(raw_sz);
        if (!self.room(3 + p)) return;
        self.hdr(0xA8, p); self.str(title);
        self.u32w(@intCast(xs.len));
        for (xs) |v| self.f32w(v);
        self.u32w(@intCast(ys.len));
        for (ys) |v| self.f32w(v);
        self.u32w(id);
    }
    pub fn image(self: *Writer, pixels: []const u8, w_px: u32, h_px: u32, id: u32) void {
        const raw_sz: usize = 4 + 4 + 4 + pixels.len + 4;
        if (raw_sz > 0xFFFF) { self.overflow = true; return; }
        const p: u16 = @intCast(raw_sz);
        if (!self.room(3 + p)) return;
        self.hdr(0xA9, p); self.u32w(w_px); self.u32w(h_px);
        self.u32w(@intCast(pixels.len));
        @memcpy(self.buf[self.pos..][0..pixels.len], pixels);
        self.pos += pixels.len;
        self.u32w(id);
    }
    pub fn pushCommand(self: *Writer, tag: []const u8, payload: []const u8) void {
        const p: u16 = @intCast(2 + tag.len + 2 + payload.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x83, p); self.str(tag); self.str(payload);
    }
    pub fn fileReadRequest(self: *Writer, path: []const u8) void {
        const p: u16 = @intCast(2 + path.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x90, p); self.str(path);
    }
    pub fn fileWrite(self: *Writer, path: []const u8, data: []const u8) void {
        const raw_sz: usize = 2 + path.len + 4 + data.len;
        if (raw_sz > 0xFFFF) { self.overflow = true; return; }
        const p: u16 = @intCast(raw_sz);
        if (!self.room(3 + p)) return;
        self.hdr(0x91, p); self.str(path);
        self.u32w(@intCast(data.len));
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
    pub fn registerCommand(self: *Writer, id: []const u8, display_name: []const u8, description: []const u8) void {
        const p: u16 = @intCast(2 + id.len + 2 + display_name.len + 2 + description.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x8F, p); self.str(id); self.str(display_name); self.str(description);
    }
    pub fn subscribeEvents(self: *Writer, event_mask: u8) void {
        if (!self.room(4)) return;
        self.hdr(0x92, 1); self.b(event_mask);
    }
    pub fn consumeEvent(self: *Writer) void { if (self.room(3)) self.hdr(0x93, 0); }
    pub fn overrideKeybind(self: *Writer, key: u8, mods: u8, cmd_tag: []const u8) void {
        const p: u16 = @intCast(1 + 1 + 2 + cmd_tag.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x94, p); self.b(key); self.b(mods); self.str(cmd_tag);
    }
    pub fn tooltip(self: *Writer, text: []const u8, id: u32) void {
        const p: u16 = @intCast(2 + text.len + 4);
        if (!self.room(3 + p)) return;
        self.hdr(0xAC, p); self.str(text); self.u32w(id);
    }
    pub fn registerKeybind(self: *Writer, key: u8, mods: u8, cmd_tag: []const u8) void {
        const p: u16 = @intCast(1 + 1 + 2 + cmd_tag.len);
        if (!self.room(3 + p)) return;
        self.hdr(0x89, p); self.b(key); self.b(mods); self.str(cmd_tag);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    fn room(self: *Writer, need: usize) bool {
        if (self.overflow or self.pos + need > self.buf.len) { self.overflow = true; return false; }
        return true;
    }
    fn hdr(self: *Writer, tag: u8, p: u16) void {
        self.buf[self.pos]     = tag;
        self.buf[self.pos + 1] = @truncate(p);
        self.buf[self.pos + 2] = @truncate(p >> 8);
        self.pos += 3;
    }
    fn b(self: *Writer, v: u8) void    { self.buf[self.pos] = v; self.pos += 1; }
    fn u32w(self: *Writer, v: u32) void {
        self.buf[self.pos]     = @truncate(v);
        self.buf[self.pos + 1] = @truncate(v >> 8);
        self.buf[self.pos + 2] = @truncate(v >> 16);
        self.buf[self.pos + 3] = @truncate(v >> 24);
        self.pos += 4;
    }
    fn i32w(self: *Writer, v: i32) void { self.u32w(@bitCast(v)); }
    fn f32w(self: *Writer, v: f32) void { self.u32w(@bitCast(v)); }
    fn str(self: *Writer, s: []const u8) void {
        self.buf[self.pos]     = @truncate(s.len);
        self.buf[self.pos + 1] = @truncate(s.len >> 8);
        self.pos += 2;
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }
};

// ── Plugin descriptor ─────────────────────────────────────────────────────

pub const ProcessFn = *const fn (
    in_ptr:  [*]const u8, in_len:  usize,
    out_ptr: [*]u8,       out_cap: usize,
) callconv(.c) usize;

pub const Descriptor = extern struct {
    abi_version: u32,
    name:        [*:0]const u8,
    version_str: [*:0]const u8,
    process:     ProcessFn,
};

/// Build the `schemify_plugin` export value.
///
/// `proc` must have the signature: `fn(in: []const u8, out: []u8) usize`
/// Return `w.finish() catch ~@as(usize,0)` from your process fn.
pub fn descriptor(
    comptime name: [:0]const u8,
    comptime ver:  [:0]const u8,
    comptime proc: fn (in: []const u8, out: []u8) usize,
) Descriptor {
    const S = struct {
        fn call(ip: [*]const u8, il: usize, op: [*]u8, oc: usize) callconv(.c) usize {
            return proc(ip[0..il], op[0..oc]);
        }
    };
    return .{ .abi_version = ABI_VERSION, .name = name, .version_str = ver, .process = S.call };
}
