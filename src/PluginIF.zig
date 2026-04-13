//! Plugin Interface — ABI v6 (message-passing protocol).

const std = @import("std");
const utility = @import("utility");
pub const Vfs = utility.Vfs;
pub const platform = utility.platform;

pub const EXPORT_SYMBOL: [*:0]const u8 = "schemify_plugin";

/// Byte size of the fixed message header: [u8 tag][u16 payload_sz LE].
pub const HEADER_SZ: usize = 3;
/// Byte size of a wire-format u16 field (panel_id, string length prefix, etc.).
pub const U16_SZ: u16 = 2;
/// Byte size of a wire-format u32/i32/f32 field.
pub const U32_SZ: u16 = 4;

// -- Panel types --------------------------------------------------------------

/// Where a plugin panel is rendered in the host UI.
pub const PanelLayout = enum(u8) {
    overlay = 0,
    left_sidebar = 1,
    right_sidebar = 2,
    bottom_bar = 3,
};

pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };

/// Widget kind for plugin-side declarative widget specs.
pub const WidgetKind = enum { slider, button, label, label_fmt, checkbox, separator, progress };

// -- PanelDef -----------------------------------------------------------------

/// Panel registration data. Pass to Writer.registerPanel() during on_load.
/// No draw_fn -- drawing is done by writing Ui* messages during draw_panel.
pub const PanelDef = struct {
    id: []const u8,
    title: []const u8,
    vim_cmd: []const u8,
    layout: PanelLayout,
    keybind: u8,
};

// -- Descriptor ---------------------------------------------------------------

/// ABI entry-point function type.
///
/// in_ptr / in_len:   host->plugin message batch (read-only, valid for call duration)
/// out_ptr / out_cap: plugin->host message buffer (write)
/// returns:           bytes written, OR std.math.maxInt(usize) if out_cap was too small
///                    (host doubles buffer and retries)
pub const ProcessFn = *const fn (
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize;

pub const ABI_VERSION: u32 = 6;

/// Every plugin must export a symbol named `schemify_plugin` of this type.
/// `abi_version` must equal `ABI_VERSION`; the host rejects plugins with a
/// different value rather than calling a potentially incompatible `process`.
pub const Descriptor = extern struct {
    abi_version: u32 = ABI_VERSION,
    name: [*:0]const u8,
    version_str: [*:0]const u8,
    process: ProcessFn,
};

// -- Message tag enum ---------------------------------------------------------

pub const Tag = enum(u8) {
    // host->plugin (0x01-0x12)
    load = 0x01,
    unload = 0x02,
    tick = 0x03,
    draw_panel = 0x04,
    button_clicked = 0x05,
    slider_changed = 0x06,
    text_changed = 0x07,
    checkbox_changed = 0x08,
    command = 0x09,
    state_response = 0x0A,
    config_response = 0x0B,
    schematic_changed = 0x0C,
    selection_changed = 0x0D,
    schematic_snapshot = 0x0E,
    instance_data = 0x0F,
    instance_prop = 0x10,
    net_data = 0x11,
    file_response = 0x12,
    // plugin->host commands (0x80-0x8F)
    register_panel = 0x80,
    set_status = 0x81,
    log = 0x82,
    push_command = 0x83,
    set_state = 0x84,
    get_state = 0x85,
    set_config = 0x86,
    get_config = 0x87,
    request_refresh = 0x88,
    register_keybind = 0x89,
    place_device = 0x8A,
    add_wire = 0x8B,
    set_instance_prop = 0x8C,
    query_instances = 0x8D,
    query_nets = 0x8E,
    register_command = 0x8F,
    // plugin->host file I/O (0x90-0x91)
    file_read_request = 0x90,
    file_write = 0x91,
    // plugin->host UI widgets (0xA0-0xAB)
    ui_label = 0xA0,
    ui_button = 0xA1,
    ui_separator = 0xA2,
    ui_begin_row = 0xA3,
    ui_end_row = 0xA4,
    ui_slider = 0xA5,
    ui_checkbox = 0xA6,
    ui_progress = 0xA7,
    ui_plot = 0xA8,
    ui_image = 0xA9,
    ui_collapsible_start = 0xAA,
    ui_collapsible_end = 0xAB,
    _,
};

/// Comptime lookup table: true iff the tag flows host->plugin.
/// Checked by Reader.next() to skip output-direction tags gracefully.
const host_to_plugin_tag = blk: {
    var table = [_]bool{false} ** 256;
    const host_tags = [_]Tag{
        .load,              .unload,             .tick,
        .draw_panel,        .button_clicked,     .slider_changed,
        .text_changed,      .checkbox_changed,   .command,
        .state_response,    .config_response,    .schematic_changed,
        .selection_changed, .schematic_snapshot, .instance_data,
        .instance_prop,     .net_data,           .file_response,
    };
    for (host_tags) |t| table[@intFromEnum(t)] = true;
    break :blk table;
};

// -- InMsg: host->plugin tagged union -----------------------------------------

pub const InMsg = union(Tag) {
    // host->plugin -- real payloads
    load: struct { project_dir: []const u8 },
    unload: void,
    tick: struct { dt: f32 },
    draw_panel: struct { panel_id: u16 },
    button_clicked: struct { panel_id: u16, widget_id: u32 },
    slider_changed: struct { panel_id: u16, widget_id: u32, val: f32 },
    text_changed: struct { panel_id: u16, widget_id: u32, text: []const u8 },
    checkbox_changed: struct { panel_id: u16, widget_id: u32, val: u8 },
    command: struct { tag: []const u8, payload: []const u8 },
    state_response: struct { key: []const u8, val: []const u8 },
    config_response: struct { key: []const u8, val: []const u8 },
    schematic_changed: void,
    selection_changed: struct { instance_idx: i32 },
    schematic_snapshot: struct { instance_count: u32, wire_count: u32, net_count: u32 },
    instance_data: struct { idx: u32, name: []const u8, symbol: []const u8 },
    instance_prop: struct { idx: u32, key: []const u8, val: []const u8 },
    net_data: struct { idx: u32, name: []const u8 },
    file_response: struct { path: []const u8, data: []const u8 },
    // plugin->host tags -- should not appear as input; treated as unknown (skipped)
    register_panel: void,
    set_status: void,
    log: void,
    push_command: void,
    set_state: void,
    get_state: void,
    set_config: void,
    get_config: void,
    request_refresh: void,
    register_keybind: void,
    place_device: void,
    add_wire: void,
    set_instance_prop: void,
    query_instances: void,
    query_nets: void,
    register_command: void,
    file_read_request: void,
    file_write: void,
    ui_label: void,
    ui_button: void,
    ui_separator: void,
    ui_begin_row: void,
    ui_end_row: void,
    ui_slider: void,
    ui_checkbox: void,
    ui_progress: void,
    ui_plot: void,
    ui_image: void,
    ui_collapsible_start: void,
    ui_collapsible_end: void,
};

// -- Reader -------------------------------------------------------------------

pub const Reader = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf, .pos = 0 };
    }

    /// Returns the next host->plugin message, or null at end of buffer.
    /// Skips unknown / plugin->host tags transparently.
    /// Returns null on malformed input (truncated header or payload).
    pub fn next(self: *Reader) ?InMsg {
        while (true) {
            if (self.pos + HEADER_SZ > self.buf.len) return null;

            const tag_byte = self.buf[self.pos];
            const payload_sz = std.mem.readInt(u16, self.buf[self.pos + 1 ..][0..2], .little);
            self.pos += HEADER_SZ;

            if (self.pos + payload_sz > self.buf.len) return null;

            const payload = self.buf[self.pos .. self.pos + payload_sz];
            const tag_enum = std.meta.intToEnum(Tag, tag_byte) catch {
                self.pos += payload_sz;
                continue;
            };

            if (!host_to_plugin_tag[@intFromEnum(tag_enum)]) {
                self.pos += payload_sz;
                continue;
            }

            const msg = parsePayload(tag_enum, payload) orelse return null;
            self.pos += payload_sz;
            return msg;
        }
    }
};

// -- Wire-format decode helpers (private) -------------------------------------

/// Read a [u16 len][N bytes] string from payload; advances *pos.
/// Returns a zero-copy slice into the original buffer.
fn readStr(payload: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + U16_SZ > payload.len) return null;
    const len = std.mem.readInt(u16, payload[pos.*..][0..2], .little);
    pos.* += U16_SZ;
    if (pos.* + len > payload.len) return null;
    const s = payload[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

/// Read u16(panel_id) + u32(widget_id) from the start of a payload.
/// Returns null if payload is too short.
inline fn readPanelWidget(payload: []const u8) ?struct { panel_id: u16, widget_id: u32 } {
    if (payload.len < U16_SZ + U32_SZ) return null;
    return .{
        .panel_id = std.mem.readInt(u16, payload[0..2], .little),
        .widget_id = std.mem.readInt(u32, payload[2..6], .little),
    };
}

/// Parse a host->plugin payload into an InMsg for the given tag.
fn parsePayload(tag: Tag, payload: []const u8) ?InMsg {
    var p: usize = 0;

    switch (tag) {
        .load => {
            const dir = readStr(payload, &p) orelse "";
            return .{ .load = .{ .project_dir = dir } };
        },
        .unload => return .{ .unload = {} },
        .schematic_changed => return .{ .schematic_changed = {} },

        .tick => {
            if (payload.len < U32_SZ) return null;
            return .{ .tick = .{ .dt = @bitCast(std.mem.readInt(u32, payload[0..4], .little)) } };
        },

        .draw_panel => {
            if (payload.len < U16_SZ) return null;
            return .{ .draw_panel = .{ .panel_id = std.mem.readInt(u16, payload[0..2], .little) } };
        },

        .button_clicked => {
            const pw = readPanelWidget(payload) orelse return null;
            return .{ .button_clicked = .{ .panel_id = pw.panel_id, .widget_id = pw.widget_id } };
        },

        .slider_changed => {
            if (payload.len < U16_SZ + U32_SZ + U32_SZ) return null;
            const pw = readPanelWidget(payload).?; // length already checked above
            const val: f32 = @bitCast(std.mem.readInt(u32, payload[6..10], .little));
            return .{ .slider_changed = .{ .panel_id = pw.panel_id, .widget_id = pw.widget_id, .val = val } };
        },

        .text_changed => {
            const pw = readPanelWidget(payload) orelse return null;
            p = U16_SZ + U32_SZ;
            const text = readStr(payload, &p) orelse return null;
            return .{ .text_changed = .{ .panel_id = pw.panel_id, .widget_id = pw.widget_id, .text = text } };
        },

        .checkbox_changed => {
            // u16(panel_id) + u32(widget_id) + u8(val)
            if (payload.len < U16_SZ + U32_SZ + 1) return null;
            const pw = readPanelWidget(payload).?; // length already checked above
            return .{ .checkbox_changed = .{
                .panel_id = pw.panel_id,
                .widget_id = pw.widget_id,
                .val = payload[U16_SZ + U32_SZ],
            } };
        },

        .command => {
            const tag_str = readStr(payload, &p) orelse return null;
            const cmd_payload = readStr(payload, &p) orelse return null;
            return .{ .command = .{ .tag = tag_str, .payload = cmd_payload } };
        },

        // Two-string key/val responses share identical parsing.
        .state_response, .config_response => {
            const key = readStr(payload, &p) orelse return null;
            const val = readStr(payload, &p) orelse return null;
            return switch (tag) {
                .state_response => .{ .state_response = .{ .key = key, .val = val } },
                .config_response => .{ .config_response = .{ .key = key, .val = val } },
                else => unreachable,
            };
        },

        .selection_changed => {
            if (payload.len < U32_SZ) return null;
            return .{ .selection_changed = .{
                .instance_idx = std.mem.readInt(i32, payload[0..4], .little),
            } };
        },

        .schematic_snapshot => {
            if (payload.len < U32_SZ * 3) return null;
            return .{ .schematic_snapshot = .{
                .instance_count = std.mem.readInt(u32, payload[0..4], .little),
                .wire_count = std.mem.readInt(u32, payload[4..8], .little),
                .net_count = std.mem.readInt(u32, payload[8..12], .little),
            } };
        },

        .instance_data => {
            if (payload.len < U32_SZ) return null;
            const idx = std.mem.readInt(u32, payload[0..4], .little);
            p = U32_SZ;
            const name = readStr(payload, &p) orelse return null;
            const symbol = readStr(payload, &p) orelse return null;
            return .{ .instance_data = .{ .idx = idx, .name = name, .symbol = symbol } };
        },

        .instance_prop => {
            if (payload.len < U32_SZ) return null;
            const idx = std.mem.readInt(u32, payload[0..4], .little);
            p = U32_SZ;
            const key = readStr(payload, &p) orelse return null;
            const val = readStr(payload, &p) orelse return null;
            return .{ .instance_prop = .{ .idx = idx, .key = key, .val = val } };
        },

        .net_data => {
            if (payload.len < U32_SZ) return null;
            const idx = std.mem.readInt(u32, payload[0..4], .little);
            p = U32_SZ;
            const name = readStr(payload, &p) orelse return null;
            return .{ .net_data = .{ .idx = idx, .name = name } };
        },

        .file_response => {
            const path = readStr(payload, &p) orelse return null;
            if (p + U32_SZ > payload.len) return null;
            const count = std.mem.readInt(u32, payload[p..][0..4], .little);
            p += U32_SZ;
            if (p + count > payload.len) return null;
            return .{ .file_response = .{ .path = path, .data = payload[p .. p + count] } };
        },

        // plugin->host tags -- already filtered before calling parsePayload
        else => return null,
    }
}

// -- Writer -------------------------------------------------------------------

pub const Writer = struct {
    buf: []u8,
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

    // -- internal helpers -----------------------------------------------------

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
    /// Accepts a pre-computed clamped length to avoid calling strLen twice.
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

    // -- plugin->host commands ------------------------------------------------

    /// Register a panel with the host.
    /// payload = str(id) + str(title) + str(vim_cmd) + u8(layout) + u8(keybind)
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

    // -- Single-string commands: payload = str(arg) ---------------------------

    /// Set the host status bar text.
    pub fn setStatus(self: *Writer, msg: []const u8) void {
        const l = strLen(msg);
        self.writeHeader(.set_status, U16_SZ + l);
        self.writeStrN(msg, l);
    }

    /// Request the host to read a file; content arrives as file_response next tick.
    pub fn fileReadRequest(self: *Writer, path: []const u8) void {
        const l = strLen(path);
        self.writeHeader(.file_read_request, U16_SZ + l);
        self.writeStrN(path, l);
    }

    /// Request a state value; reply arrives as state_response next tick.
    pub fn getState(self: *Writer, key: []const u8) void {
        const l = strLen(key);
        self.writeHeader(.get_state, U16_SZ + l);
        self.writeStrN(key, l);
    }

    // -- Two-string commands --------------------------------------------------

    /// Push a command into the host command queue. payload = str(tag) + str(payload)
    pub fn pushCommand(self: *Writer, tag: []const u8, payload: []const u8) void {
        const tl = strLen(tag);
        const pl = strLen(payload);
        self.writeHeader(.push_command, U16_SZ + tl + U16_SZ + pl);
        self.writeStrN(tag, tl);
        self.writeStrN(payload, pl);
    }

    /// Store a key/value in plugin persistent state. payload = str(key) + str(val)
    pub fn setState(self: *Writer, key: []const u8, val: []const u8) void {
        const kl = strLen(key);
        const vl = strLen(val);
        self.writeHeader(.set_state, U16_SZ + kl + U16_SZ + vl);
        self.writeStrN(key, kl);
        self.writeStrN(val, vl);
    }

    /// Request a config value; reply arrives as config_response next tick.
    /// payload = str(plugin_id) + str(key)
    pub fn getConfig(self: *Writer, plugin_id: []const u8, key: []const u8) void {
        const il = strLen(plugin_id);
        const kl = strLen(key);
        self.writeHeader(.get_config, U16_SZ + il + U16_SZ + kl);
        self.writeStrN(plugin_id, il);
        self.writeStrN(key, kl);
    }

    // -- Zero-arg commands (header only, no payload) --------------------------

    /// Request the host to repaint on the next frame.
    pub fn requestRefresh(self: *Writer) void {
        self.writeHeader(.request_refresh, 0);
    }
    /// Request instance data; replies arrive as instance_data messages next tick.
    pub fn queryInstances(self: *Writer) void {
        self.writeHeader(.query_instances, 0);
    }
    /// Request net data; replies arrive as net_data messages next tick.
    pub fn queryNets(self: *Writer) void {
        self.writeHeader(.query_nets, 0);
    }

    // -- Log message ----------------------------------------------------------

    /// Emit a log message. payload = u8(level) + str(tag) + str(msg)
    pub fn log(self: *Writer, level: LogLevel, tag: []const u8, msg: []const u8) void {
        const tl = strLen(tag);
        const ml = strLen(msg);
        self.writeHeader(.log, 1 + U16_SZ + tl + U16_SZ + ml);
        self.writeU8(@intFromEnum(level));
        self.writeStrN(tag, tl);
        self.writeStrN(msg, ml);
    }

    // -- Three-string commands ------------------------------------------------

    /// Write a TOML-backed per-plugin config value.
    /// payload = str(plugin_id) + str(key) + str(val)
    pub fn setConfig(self: *Writer, plugin_id: []const u8, key: []const u8, val: []const u8) void {
        const il = strLen(plugin_id);
        const kl = strLen(key);
        const vl = strLen(val);
        self.writeHeader(.set_config, U16_SZ + il + U16_SZ + kl + U16_SZ + vl);
        self.writeStrN(plugin_id, il);
        self.writeStrN(key, kl);
        self.writeStrN(val, vl);
    }

    /// Register a named command in the host command palette.
    /// payload = str(id) + str(display_name) + str(description)
    pub fn registerCommand(self: *Writer, id: []const u8, display_name: []const u8, description: []const u8) void {
        const il = strLen(id);
        const dl = strLen(display_name);
        const el = strLen(description);
        self.writeHeader(.register_command, U16_SZ + il + U16_SZ + dl + U16_SZ + el);
        self.writeStrN(id, il);
        self.writeStrN(display_name, dl);
        self.writeStrN(description, el);
    }

    // -- Schematic-mutation commands ------------------------------------------

    /// Register a keybind that fires a plugin command tag when pressed.
    /// payload = u8(key) + u8(mods) + str(cmd_tag)
    pub fn registerKeybind(self: *Writer, key: u8, mods: u8, cmd_tag: []const u8) void {
        const cl = strLen(cmd_tag);
        self.writeHeader(.register_keybind, 1 + 1 + U16_SZ + cl);
        self.writeU8(key);
        self.writeU8(mods);
        self.writeStrN(cmd_tag, cl);
    }

    /// Place a device in the active schematic.
    /// payload = str(sym) + str(name) + i32(x) + i32(y)
    pub fn placeDevice(self: *Writer, sym: []const u8, name: []const u8, x: i32, y: i32) void {
        const sl = strLen(sym);
        const nl = strLen(name);
        self.writeHeader(.place_device, U16_SZ + sl + U16_SZ + nl + U32_SZ + U32_SZ);
        self.writeStrN(sym, sl);
        self.writeStrN(name, nl);
        self.writeI32Le(x);
        self.writeI32Le(y);
    }

    /// Add a wire segment. payload = i32(x0) + i32(y0) + i32(x1) + i32(y1)
    pub fn addWire(self: *Writer, x0: i32, y0: i32, x1: i32, y1: i32) void {
        self.writeHeader(.add_wire, U32_SZ * 4);
        self.writeI32Le(x0);
        self.writeI32Le(y0);
        self.writeI32Le(x1);
        self.writeI32Le(y1);
    }

    /// Set a property on a schematic instance.
    /// payload = u32(idx) + str(key) + str(val)
    pub fn setInstanceProp(self: *Writer, idx: u32, key: []const u8, val: []const u8) void {
        const kl = strLen(key);
        const vl = strLen(val);
        self.writeHeader(.set_instance_prop, U32_SZ + U16_SZ + kl + U16_SZ + vl);
        self.writeU32Le(idx);
        self.writeStrN(key, kl);
        self.writeStrN(val, vl);
    }

    // -- File write -----------------------------------------------------------

    /// Write bytes to a file on the host filesystem.
    /// payload = str(path) + u8arr(data)
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

    // -- plugin->host UI widgets ----------------------------------------------

    /// Render a text label. payload = str(text) + u32(id)
    pub fn label(self: *Writer, text: []const u8, id: u32) void {
        const l = strLen(text);
        self.writeHeader(.ui_label, U16_SZ + l + U32_SZ);
        self.writeStrN(text, l);
        self.writeU32Le(id);
    }

    /// Render a button. payload = str(text) + u32(id)
    pub fn button(self: *Writer, text: []const u8, id: u32) void {
        const l = strLen(text);
        self.writeHeader(.ui_button, U16_SZ + l + U32_SZ);
        self.writeStrN(text, l);
        self.writeU32Le(id);
    }

    // id-only widgets: header(tag, U32_SZ) + u32(id)

    /// Render a horizontal separator rule.
    pub fn separator(self: *Writer, id: u32) void {
        self.writeHeader(.ui_separator, U32_SZ);
        self.writeU32Le(id);
    }

    /// Begin a horizontal row layout.
    pub fn beginRow(self: *Writer, id: u32) void {
        self.writeHeader(.ui_begin_row, U32_SZ);
        self.writeU32Le(id);
    }

    /// End the horizontal row started with beginRow(id).
    pub fn endRow(self: *Writer, id: u32) void {
        self.writeHeader(.ui_end_row, U32_SZ);
        self.writeU32Le(id);
    }

    /// End a collapsible section.
    pub fn collapsibleEnd(self: *Writer, id: u32) void {
        self.writeHeader(.ui_collapsible_end, U32_SZ);
        self.writeU32Le(id);
    }

    /// Horizontal slider. payload = f32(val) + f32(min) + f32(max) + u32(id)
    pub fn slider(self: *Writer, val: f32, min: f32, max: f32, id: u32) void {
        self.writeHeader(.ui_slider, U32_SZ * 4);
        self.writeF32Le(val);
        self.writeF32Le(min);
        self.writeF32Le(max);
        self.writeU32Le(id);
    }

    /// Checkbox with label. payload = u8(val) + str(text) + u32(id)
    pub fn checkbox(self: *Writer, val: bool, text: []const u8, id: u32) void {
        const l = strLen(text);
        self.writeHeader(.ui_checkbox, 1 + U16_SZ + l + U32_SZ);
        self.writeU8(if (val) 1 else 0);
        self.writeStrN(text, l);
        self.writeU32Le(id);
    }

    /// Progress bar (fraction 0.0-1.0). payload = f32(fraction) + u32(id)
    pub fn progress(self: *Writer, fraction: f32, id: u32) void {
        self.writeHeader(.ui_progress, U32_SZ * 2);
        self.writeF32Le(fraction);
        self.writeU32Le(id);
    }

    /// 2D line chart. payload = str(title) + f32arr(xs) + f32arr(ys) + u32(id)
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

    /// Render a bitmap image (RGBA8). payload = u32(w) + u32(h) + u8arr(pixels) + u32(id)
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

    /// Begin a collapsible section. payload = str(label) + u8(open) + u32(id)
    pub fn collapsibleStart(self: *Writer, label_text: []const u8, open: bool, id: u32) void {
        const l = strLen(label_text);
        self.writeHeader(.ui_collapsible_start, U16_SZ + l + 1 + U32_SZ);
        self.writeStrN(label_text, l);
        self.writeU8(if (open) 1 else 0);
        self.writeU32Le(id);
    }
};

// -- Wire-format encode helper (private) --------------------------------------

/// Clamp a slice length to u16 for the wire-format string prefix.
inline fn strLen(s: []const u8) u16 {
    return @intCast(@min(s.len, std.math.maxInt(u16)));
}

// -- Comptime plugin framework ------------------------------------------------
//
// Plugin authors define a State struct and a PluginSpec (panels + widget bindings).
// The framework generates widget IDs, draw_panel dispatch, event routing, and the
// full schemify_process body.
//
// Usage:
//
//   const std = @import("std");
//   const P = @import("PluginIF").Framework;
//
//   const State = struct { gain: f32 = 0.5, count: u32 = 0 };
//   var state = State{};
//
//   const MyPlugin = P.define(State, &state, .{
//       .name    = "Demo",
//       .version = "1.0.0",
//       .panels  = &.{
//           P.panel("demo", "Demo Panel", "demo", .right_sidebar, 'D', &.{
//               P.slider("Gain", "gain", 0, 1),
//               P.label_fmt("Count: {d}", "count"),
//               P.button("Reset", State, onReset),
//               P.separator(),
//           }),
//       },
//   });
//
//   fn onReset(s: *State) void { s.count = 0; }
//
//   comptime { MyPlugin.export_plugin(); }
//
// Widget IDs are assigned as `panel_index * 256 + widget_index` (comptime).

pub const Framework = struct {

    // -- Widget descriptor ----------------------------------------------------

    /// Comptime widget specification. All string fields are comptime constants.
    pub const WidgetSpec = union(WidgetKind) {
        /// Horizontal slider bound to a f32 field.
        slider: struct {
            label: [:0]const u8,
            /// Field name in the State struct (comptime, resolved with @field).
            field: [:0]const u8,
            min: f32,
            max: f32,
        },
        /// Clickable button with a handler fn(*State) void.
        button: struct {
            label: [:0]const u8,
            handler: *const fn (*anyopaque) void,
        },
        /// Static label (text known at comptime).
        label: struct { text: [:0]const u8 },
        /// Dynamic label: std.fmt.bufPrint(fmt, .{@field(state, field)}).
        label_fmt: struct {
            fmt: [:0]const u8,
            /// Field name in the State struct.
            field: [:0]const u8,
        },
        /// Checkbox bound to a bool field; optional change handler.
        checkbox: struct {
            label: [:0]const u8,
            field: [:0]const u8,
            handler: ?*const fn (*anyopaque, bool) void = null,
        },
        /// Horizontal separator rule (no event).
        separator: struct {},
        /// Progress bar bound to a f32 field (0.0-1.0).
        progress: struct { field: [:0]const u8 },
    };

    // -- Type-erasure wrappers ------------------------------------------------

    /// Wrap a typed handler `fn(*S) void` into a type-erased `fn(*anyopaque) void`.
    fn wrapHandler(comptime S: type, comptime h: fn (*S) void) *const fn (*anyopaque) void {
        return &struct {
            fn call(p: *anyopaque) void {
                h(@alignCast(@ptrCast(p)));
            }
        }.call;
    }

    /// Wrap a typed checkbox handler `fn(*S, bool) void` into type-erased form.
    fn wrapCheckboxHandler(comptime S: type, comptime h: fn (*S, bool) void) *const fn (*anyopaque, bool) void {
        return &struct {
            fn call(p: *anyopaque, v: bool) void {
                h(@alignCast(@ptrCast(p)), v);
            }
        }.call;
    }

    /// Wrap a typed `fn(*S, *Writer) void` into type-erased form.
    /// Used for draw_fn, on_load, and on_unload-with-writer hooks.
    pub fn wrapWriterHook(comptime S: type, comptime h: fn (*S, *Writer) void) *const fn (*anyopaque, *Writer) void {
        return &struct {
            fn call(p: *anyopaque, w: *Writer) void {
                h(@alignCast(@ptrCast(p)), w);
            }
        }.call;
    }

    /// Alias kept for callers that used the previous name.
    pub const wrapDrawFn = wrapWriterHook;

    /// Wrap a typed `fn(*S) void` for on_unload (no Writer).
    /// Delegates to wrapHandler since the signatures are identical.
    pub fn wrapUnloadHook(comptime S: type, comptime h: fn (*S) void) *const fn (*anyopaque) void {
        return wrapHandler(S, h);
    }

    /// Wrap a typed on_button hook `fn(*S, u32, *Writer) void`.
    pub fn wrapOnButton(comptime S: type, comptime h: fn (*S, u32, *Writer) void) *const fn (*anyopaque, u32, *Writer) void {
        return &struct {
            fn call(p: *anyopaque, wid: u32, w: *Writer) void {
                h(@alignCast(@ptrCast(p)), wid, w);
            }
        }.call;
    }

    /// Wrap a typed on_tick hook `fn(*S, f32) void`.
    pub fn wrapTickHook(comptime S: type, comptime h: fn (*S, f32) void) *const fn (*anyopaque, f32) void {
        return &struct {
            fn call(p: *anyopaque, dt: f32) void {
                h(@alignCast(@ptrCast(p)), dt);
            }
        }.call;
    }

    /// Wrap a typed on_command hook `fn(*S, []const u8, []const u8, *Writer) void`.
    pub fn wrapCommandHook(comptime S: type, comptime h: fn (*S, []const u8, []const u8, *Writer) void) *const fn (*anyopaque, []const u8, []const u8, *Writer) void {
        return &struct {
            fn call(p: *anyopaque, tag: []const u8, payload: []const u8, w: *Writer) void {
                h(@alignCast(@ptrCast(p)), tag, payload, w);
            }
        }.call;
    }

    // -- Widget constructor helpers -------------------------------------------

    pub fn slider(comptime lbl: [:0]const u8, comptime field: [:0]const u8, comptime min: f32, comptime max: f32) WidgetSpec {
        return .{ .slider = .{ .label = lbl, .field = field, .min = min, .max = max } };
    }

    pub fn button(comptime lbl: [:0]const u8, comptime S: type, comptime handler: fn (*S) void) WidgetSpec {
        return .{ .button = .{ .label = lbl, .handler = wrapHandler(S, handler) } };
    }

    pub fn label(comptime text: [:0]const u8) WidgetSpec {
        return .{ .label = .{ .text = text } };
    }

    pub fn label_fmt(comptime fmt: [:0]const u8, comptime field: [:0]const u8) WidgetSpec {
        return .{ .label_fmt = .{ .fmt = fmt, .field = field } };
    }

    pub fn checkbox(comptime lbl: [:0]const u8, comptime field: [:0]const u8) WidgetSpec {
        return .{ .checkbox = .{ .label = lbl, .field = field, .handler = null } };
    }

    pub fn checkboxCb(comptime lbl: [:0]const u8, comptime field: [:0]const u8, comptime S: type, comptime handler: fn (*S, bool) void) WidgetSpec {
        return .{ .checkbox = .{ .label = lbl, .field = field, .handler = wrapCheckboxHandler(S, handler) } };
    }

    pub fn separator() WidgetSpec {
        return .{ .separator = .{} };
    }

    pub fn progress(comptime field: [:0]const u8) WidgetSpec {
        return .{ .progress = .{ .field = field } };
    }

    // -- Panel descriptor -----------------------------------------------------

    pub const PanelSpec = struct {
        id: [:0]const u8,
        title: [:0]const u8,
        vim_cmd: [:0]const u8,
        layout: PanelLayout,
        keybind: u8,
        widgets: []const WidgetSpec = &.{},
        /// If set, called instead of the static widget list for draw_panel.
        draw_fn: ?*const fn (*anyopaque, *Writer) void = null,
        /// Optional hook called on .load (after registerPanel).
        on_load: ?*const fn (*anyopaque, *Writer) void = null,
        /// Optional hook called on .unload.
        on_unload: ?*const fn (*anyopaque) void = null,
        /// Optional catch-all for button_clicked not matched by static widgets.
        on_button: ?*const fn (*anyopaque, u32, *Writer) void = null,
    };

    pub fn panel(
        comptime id: [:0]const u8,
        comptime title: [:0]const u8,
        comptime vim_cmd: [:0]const u8,
        comptime layout: PanelLayout,
        comptime keybind: u8,
        comptime widgets: []const WidgetSpec,
    ) PanelSpec {
        return .{ .id = id, .title = title, .vim_cmd = vim_cmd, .layout = layout, .keybind = keybind, .widgets = widgets };
    }

    // -- Plugin descriptor ----------------------------------------------------

    pub const PluginSpec = struct {
        name: [:0]const u8,
        version: [:0]const u8,
        panels: []const PanelSpec,
        /// Optional hook called on .load (before per-panel on_load hooks).
        on_load: ?*const fn (*anyopaque, *Writer) void = null,
        /// Optional hook called on .unload.
        on_unload: ?*const fn (*anyopaque, *Writer) void = null,
        /// Optional hook called on .tick.
        on_tick: ?*const fn (*anyopaque, f32) void = null,
        /// Optional hook called on .command.
        on_command: ?*const fn (*anyopaque, []const u8, []const u8, *Writer) void = null,
    };

    // -- define() -- generates the process fn and export_plugin ---------------

    /// Generate a plugin type for the given State type, state pointer, and spec.
    ///
    /// The returned type exposes:
    ///   `process`       -- the ABI v6 process function (can be used directly)
    ///   `export_plugin` -- call inside `comptime {}` to export the two symbols
    pub fn define(comptime State: type, comptime state_ptr: *State, comptime spec: PluginSpec) type {
        return struct {
            const g_state_ptr: *anyopaque = state_ptr;

            pub fn process(
                in_ptr: [*]const u8,
                in_len: usize,
                out_ptr: [*]u8,
                out_cap: usize,
            ) callconv(.c) usize {
                var r = Reader.init(in_ptr[0..in_len]);
                var w = Writer.init(out_ptr[0..out_cap]);

                while (r.next()) |msg| switch (msg) {
                    .load => {
                        inline for (spec.panels) |p| {
                            w.registerPanel(.{
                                .id = p.id,
                                .title = p.title,
                                .vim_cmd = p.vim_cmd,
                                .layout = p.layout,
                                .keybind = p.keybind,
                            });
                            if (p.on_load) |h| h(g_state_ptr, &w);
                        }
                        if (spec.on_load) |h| h(g_state_ptr, &w);
                    },

                    .unload => {
                        if (spec.on_unload) |h| h(g_state_ptr, &w);
                        inline for (spec.panels) |p| {
                            if (p.on_unload) |h| h(g_state_ptr);
                        }
                    },

                    .tick => |ev| {
                        if (spec.on_tick) |h| h(g_state_ptr, ev.dt);
                    },

                    .draw_panel => |ev| {
                        inline for (spec.panels, 0..) |p, pi| {
                            if (ev.panel_id == pi) {
                                if (p.draw_fn) |df| {
                                    df(g_state_ptr, &w);
                                } else {
                                    inline for (p.widgets, 0..) |widget, wi| {
                                        const wid: u32 = pi * 256 + wi;
                                        switch (widget) {
                                            .slider => |s| {
                                                w.label(s.label, wid);
                                                w.slider(@field(state_ptr.*, s.field), s.min, s.max, wid + 128);
                                            },
                                            .button => |b| w.button(b.label, wid),
                                            .label => |l| w.label(l.text, wid),
                                            .label_fmt => |lf| {
                                                var buf: [256]u8 = undefined;
                                                const text = std.fmt.bufPrint(&buf, lf.fmt, .{@field(state_ptr.*, lf.field)}) catch lf.fmt;
                                                w.label(text, wid);
                                            },
                                            .checkbox => |cb| w.checkbox(@field(state_ptr.*, cb.field), cb.label, wid),
                                            .separator => w.separator(wid),
                                            .progress => |pr| w.progress(@field(state_ptr.*, pr.field), wid),
                                        }
                                    }
                                }
                            }
                        }
                    },

                    .button_clicked => |ev| {
                        inline for (spec.panels, 0..) |p, pi| {
                            if (p.on_button) |h| h(g_state_ptr, ev.widget_id, &w);
                            inline for (p.widgets, 0..) |widget, wi| {
                                if (ev.widget_id == pi * 256 + wi) {
                                    switch (widget) {
                                        .button => |b| b.handler(g_state_ptr),
                                        else => {},
                                    }
                                }
                            }
                        }
                    },

                    .slider_changed => |ev| {
                        inline for (spec.panels, 0..) |p, pi| {
                            inline for (p.widgets, 0..) |widget, wi| {
                                if (ev.widget_id == pi * 256 + wi + 128) {
                                    switch (widget) {
                                        .slider => |s| @field(state_ptr.*, s.field) = ev.val,
                                        else => {},
                                    }
                                }
                            }
                        }
                    },

                    .checkbox_changed => |ev| {
                        inline for (spec.panels, 0..) |p, pi| {
                            inline for (p.widgets, 0..) |widget, wi| {
                                if (ev.widget_id == pi * 256 + wi) {
                                    switch (widget) {
                                        .checkbox => |cb| {
                                            const v = ev.val != 0;
                                            @field(state_ptr.*, cb.field) = v;
                                            if (cb.handler) |h| h(g_state_ptr, v);
                                        },
                                        else => {},
                                    }
                                }
                            }
                        }
                    },

                    .command => |ev| {
                        if (spec.on_command) |h| h(g_state_ptr, ev.tag, ev.payload, &w);
                    },

                    else => {},
                };

                return if (w.overflow()) std.math.maxInt(usize) else w.pos;
            }

            /// Module-level descriptor; `@export` needs a stable address.
            const descriptor: Descriptor = .{
                .abi_version = ABI_VERSION,
                .name = spec.name.ptr,
                .version_str = spec.version.ptr,
                .process = &process,
            };

            pub fn export_plugin() void {
                @export(&process, .{ .name = "schemify_process", .linkage = .strong });
                @export(&descriptor, .{ .name = "schemify_plugin", .linkage = .strong });
            }
        };
    }
};

// -- Size tests ---------------------------------------------------------------

test "Expose struct size for Descriptor" {
    const print = @import("std").debug.print;
    print("Descriptor: {d}B\n", .{@sizeOf(Descriptor)});
}

test "Expose struct size for Reader" {
    const print = @import("std").debug.print;
    print("Reader: {d}B\n", .{@sizeOf(Reader)});
}

test "Expose struct size for Writer" {
    const print = @import("std").debug.print;
    print("Writer: {d}B\n", .{@sizeOf(Writer)});
}
