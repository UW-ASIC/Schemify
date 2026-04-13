//! Shared types for the plugins module.
//!
//! Contains both the ABI v6 wire protocol types (formerly PluginIF) and
//! the runtime widget types.  All types are `pub` within the module but
//! should be treated as internal outside `src/plugins/`.  Only types
//! re-exported through `lib.zig` are part of the public surface.
//!
//! This file must NOT import named build-system modules (state, etc.)

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// ABI v6 Wire Protocol Types (formerly PluginIF)
// ═══════════════════════════════════════════════════════════════════════════

// -- Constants ----------------------------------------------------------------

pub const EXPORT_SYMBOL: [*:0]const u8 = "schemify_plugin";

/// Byte size of the fixed message header: [u8 tag][u16 payload_sz LE].
pub const HEADER_SZ: usize = 3;
/// Byte size of a wire-format u16 field (panel_id, string length prefix, etc.).
pub const U16_SZ: u16 = 2;
/// Byte size of a wire-format u32/i32/f32 field.
pub const U32_SZ: u16 = 4;

pub const ABI_VERSION: u32 = 6;

// -- Enums --------------------------------------------------------------------

/// Where a plugin panel is rendered in the host UI.
pub const PanelLayout = enum(u8) {
    overlay = 0,
    left_sidebar = 1,
    right_sidebar = 2,
    bottom_bar = 3,
};

pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };

// -- Panel types --------------------------------------------------------------

/// Panel registration data. Pass to Writer.registerPanel() during on_load.
/// No draw_fn -- drawing is done by writing Ui* messages during draw_panel.
///
/// Fields ordered by alignment: slices (2 * usize) first, then small scalars.
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

/// Every plugin must export a symbol named `schemify_plugin` of this type.
/// `abi_version` must equal `ABI_VERSION`; the host rejects plugins with a
/// different value rather than calling a potentially incompatible `process`.
///
/// extern struct -- field order fixed by ABI (no reordering).
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
pub const host_to_plugin_tag = blk: {
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

// -- Wire-format helpers (used by Reader and Writer) --------------------------

/// Clamp a slice length to u16 for the wire-format string prefix.
pub inline fn strLen(s: []const u8) u16 {
    return @intCast(@min(s.len, std.math.maxInt(u16)));
}

/// Read a [u16 len][N bytes] string from payload; advances *pos.
/// Returns a zero-copy slice into the original buffer.
pub fn readStr(payload: []const u8, pos: *usize) ?[]const u8 {
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
pub inline fn readPanelWidget(payload: []const u8) ?struct { panel_id: u16, widget_id: u32 } {
    if (payload.len < U16_SZ + U32_SZ) return null;
    return .{
        .panel_id = std.mem.readInt(u16, payload[0..2], .little),
        .widget_id = std.mem.readInt(u32, payload[2..6], .little),
    };
}

/// Parse a host->plugin payload into an InMsg for the given tag.
pub fn parsePayload(tag: Tag, payload: []const u8) ?InMsg {
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
            const pw = readPanelWidget(payload).?;
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
            if (payload.len < U16_SZ + U32_SZ + 1) return null;
            const pw = readPanelWidget(payload).?;
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

        else => return null,
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Runtime Widget Types
// ═══════════════════════════════════════════════════════════════════════════

pub const WidgetTag = enum(u8) {
    label,
    button,
    separator,
    begin_row,
    end_row,
    slider,
    checkbox,
    progress,
    collapsible_start,
    collapsible_end,
};

/// Widget kind for plugin-side declarative widget specs.
pub const WidgetKind = enum { slider, button, label, label_fmt, checkbox, separator, progress };

/// Flat widget record -- all variants share the same struct so MultiArrayList
/// can separate hot fields (tag, widget_id) from cold string/float data.
///
/// Fields ordered by alignment: slice (8-byte ptr+len) > f32 (4) > u32 (4) > enum(u8) (1) > bool (1).
pub const ParsedWidget = struct {
    str: []const u8 = &.{},
    val: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    widget_id: u32 = 0,
    tag: WidgetTag = .label,
    open: bool = false,
};

// -- Runtime constants --------------------------------------------------------

pub const INITIAL_OUT_BUF: usize = 4096;
pub const MAX_OUT_BUF: usize = 64 * 1024;
pub const MAX_EVENTS: usize = 64;
