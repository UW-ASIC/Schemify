const std = @import("std");

// -- Constants ----------------------------------------------------------------

pub const ABI_VERSION: u32 = 8;
pub const HEADER_SZ: usize = 3; // [u8 tag][u16 payload_sz LE]
pub const U16_SZ: u16 = 2;
pub const U32_SZ: u16 = 4;

pub const INITIAL_OUT_BUF: usize = 4096;
pub const MAX_OUT_BUF: usize = 64 * 1024;
pub const MAX_EVENTS: usize = 64;

pub const EXPORT_SYMBOL: [*:0]const u8 = "schemify_plugin";

// -- Enums --------------------------------------------------------------------

pub const PanelLayout = enum(u8) { overlay = 0, left_sidebar = 1, right_sidebar = 2, bottom_bar = 3 };
pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };

// -- Tag ----------------------------------------------------------------------

pub const Tag = enum(u8) {
    // host -> plugin (0x01-0x14)
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
    hover = 0x13,
    key_event = 0x14,
    // plugin -> host commands (0x80-0x8F)
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
    // plugin -> host event control (0x90-0x95)
    file_read_request = 0x90,
    file_write = 0x91,
    subscribe_events = 0x92,
    consume_event = 0x93,
    override_keybind = 0x94,
    html_layout = 0x95,
    // plugin -> host UI widgets (0xA0-0xAC)
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
    ui_tooltip = 0xAC,
    ui_text_input = 0xAD,
    ui_text_area = 0xAE,
    _,
};

/// Comptime lookup: true iff the tag flows host -> plugin.
pub const host_to_plugin_tag = blk: {
    var table = [_]bool{false} ** 256;
    for ([_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
    }) |t| table[t] = true;
    break :blk table;
};

// -- Structs ------------------------------------------------------------------

pub const PanelDef = struct {
    id: []const u8,
    title: []const u8,
    vim_cmd: []const u8,
    layout: PanelLayout,
    keybind: u8,
};

pub const ProcessFn = *const fn ([*]const u8, usize, [*]u8, usize) callconv(.c) usize;

pub const Descriptor = extern struct {
    abi_version: u32 = ABI_VERSION,
    name: [*:0]const u8,
    version_str: [*:0]const u8,
    process: ProcessFn,
};

// -- InMsg: host -> plugin tagged union ---------------------------------------

pub const InMsg = union(Tag) {
    // host -> plugin (real payloads)
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
    hover: struct { world_x: i32, world_y: i32, element_type: u8, element_idx: i32, element_name: []const u8 },
    key_event: struct { key: u8, mods: u8, action: u8 },
    // plugin -> host (void — should never appear as input)
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
    subscribe_events: void,
    consume_event: void,
    override_keybind: void,
    html_layout: void,
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
    ui_tooltip: void,
};

// -- Wire-format helpers ------------------------------------------------------

pub inline fn strLen(s: []const u8) u16 {
    return @intCast(@min(s.len, std.math.maxInt(u16)));
}

pub fn readStr(payload: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + U16_SZ > payload.len) return null;
    const len = std.mem.readInt(u16, payload[pos.*..][0..2], .little);
    pos.* += U16_SZ;
    if (pos.* + len > payload.len) return null;
    const s = payload[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

pub inline fn readPanelWidget(payload: []const u8) ?struct { panel_id: u16, widget_id: u32 } {
    if (payload.len < U16_SZ + U32_SZ) return null;
    return .{
        .panel_id = std.mem.readInt(u16, payload[0..2], .little),
        .widget_id = std.mem.readInt(u32, payload[2..6], .little),
    };
}

pub fn parsePayload(tag: Tag, payload: []const u8) ?InMsg {
    var p: usize = 0;
    switch (tag) {
        .load => return .{ .load = .{ .project_dir = readStr(payload, &p) orelse "" } },
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
            return .{ .slider_changed = .{ .panel_id = pw.panel_id, .widget_id = pw.widget_id, .val = @bitCast(std.mem.readInt(u32, payload[6..10], .little)) } };
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
            return .{ .checkbox_changed = .{ .panel_id = pw.panel_id, .widget_id = pw.widget_id, .val = payload[U16_SZ + U32_SZ] } };
        },
        .command => {
            const t = readStr(payload, &p) orelse return null;
            const pl = readStr(payload, &p) orelse return null;
            return .{ .command = .{ .tag = t, .payload = pl } };
        },
        .state_response, .config_response => {
            const key = readStr(payload, &p) orelse return null;
            const val = readStr(payload, &p) orelse return null;
            return if (tag == .state_response)
                .{ .state_response = .{ .key = key, .val = val } }
            else
                .{ .config_response = .{ .key = key, .val = val } };
        },
        .selection_changed => {
            if (payload.len < U32_SZ) return null;
            return .{ .selection_changed = .{ .instance_idx = std.mem.readInt(i32, payload[0..4], .little) } };
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
        .hover => {
            if (payload.len < U32_SZ * 2 + 1 + U32_SZ) return null;
            p = 13;
            return .{ .hover = .{
                .world_x = std.mem.readInt(i32, payload[0..4], .little),
                .world_y = std.mem.readInt(i32, payload[4..8], .little),
                .element_type = payload[8],
                .element_idx = std.mem.readInt(i32, payload[9..13], .little),
                .element_name = readStr(payload, &p) orelse "",
            } };
        },
        .key_event => {
            if (payload.len < 3) return null;
            return .{ .key_event = .{ .key = payload[0], .mods = payload[1], .action = payload[2] } };
        },
        else => return null,
    }
}

// -- Runtime widget types -----------------------------------------------------

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
    tooltip,
    text_input,
    text_area,
};

pub const ParsedWidget = struct {
    str: []const u8 = &.{},
    val: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    widget_id: u32 = 0,
    tag: WidgetTag = .label,
    open: bool = false,
};
