//! Theme + Palette — color computation, plugin overrides, and color math.
//! Combines the old Theme.zig and Palette.zig into a single file.

const std = @import("std");
const dvui = @import("dvui");
const Color = dvui.Color;

// ── Plugin overrides (written by Themes plugin via SET_CONFIG) ───────────────

pub var current_overrides: ThemeOverrides = .{};

pub const ThemeOverrides = struct {
    canvas_bg: ?[3]u8 = null,
    grid_dot: ?[4]u8 = null,
    wire: ?[3]u8 = null,
    wire_selected: ?[3]u8 = null,
    wire_endpoint: ?[3]u8 = null,
    instance_body: ?[3]u8 = null,
    instance_pin: ?[3]u8 = null,
    symbol_line: ?[3]u8 = null,
    wire_preview: ?[4]u8 = null,
    sidebar_bg: ?[3]u8 = null,
    bottombar_bg: ?[3]u8 = null,
    corner_radius: ?f32 = null,
    border_width: ?f32 = null,
    button_padding_h: ?f32 = null,
    button_padding_v: ?f32 = null,
    wire_width: ?f32 = null,
    grid_dot_size: ?f32 = null,
    tab_shape: ?u8 = null,
};

// ── Shape / spacing getters ──────────────────────────────────────────────────

pub fn getCornerRadius() f32 { return current_overrides.corner_radius orelse 4.0; }
pub fn getBorderWidth() f32 { return current_overrides.border_width orelse 1.0; }
pub fn getButtonPaddingH() f32 { return current_overrides.button_padding_h orelse 6.0; }
pub fn getButtonPaddingV() f32 { return current_overrides.button_padding_v orelse 3.0; }
pub fn getWireWidth() f32 { return current_overrides.wire_width orelse 1.0; }
pub fn getGridDotSize() f32 { return current_overrides.grid_dot_size orelse 1.0; }
pub fn getTabShape() u8 { return current_overrides.tab_shape orelse 1; }

// ── Chrome color getters (consumed by panels, respects plugin overrides) ─────

pub fn getSidebarBg() Color {
    if (current_overrides.sidebar_bg) |rgb| return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    return .{ .r = 28, .g = 30, .b = 38, .a = 255 }; // #1c1e26
}
pub fn getBottomBarBg() Color {
    if (current_overrides.bottombar_bg) |rgb| return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    return .{ .r = 28, .g = 30, .b = 38, .a = 255 }; // #1c1e26
}

// ── Palette ──────────────────────────────────────────────────────────────────

pub const Palette = struct {
    canvas_bg: Color,
    grid_dot: Color,
    wire: Color,
    wire_sel: Color,
    wire_endpoint: Color,
    inst_body: Color,
    inst_sel: Color,
    inst_pin: Color,
    symbol_line: Color,
    symbol_pin: Color,
    wire_preview: Color,
    origin: Color,

    pub fn fromDvui(t: dvui.Theme) Palette {
        const focus = t.focus;
        const hl = t.highlight.fill orelse t.focus;
        const ctrl = t.control.fill orelse t.fill;
        const win_bg = t.window.fill orelse t.fill;

        const canvas_bg = if (t.dark) Color{ .r = 15, .g = 17, .b = 23, .a = 255 } else colorScale(win_bg, 240);
        const grid_dot = withAlpha(colorScale(t.border, if (t.dark) 110 else 160), if (t.dark) 90 else 160);
        const wire = if (t.dark) blend(focus, .{ .r = 100, .g = 190, .b = 245, .a = 255 }, 100) else blend(focus, .{ .r = 0, .g = 40, .b = 120, .a = 255 }, 40);
        const wire_sel = if (t.dark) blend(hl, .{ .r = 245, .g = 170, .b = 70, .a = 255 }, 130) else blend(hl, .{ .r = 200, .g = 90, .b = 0, .a = 255 }, 90);
        const wire_endpoint = blend(focus, .{ .r = 80, .g = 220, .b = 150, .a = 255 }, 80);
        const inst_body = blend(ctrl, wire, 50);
        const inst_pin = blend(t.text, .{ .r = 240, .g = 220, .b = 100, .a = 255 }, 80);
        const symbol_line = colorScale(t.text, 220);
        const symbol_pin = blend(focus, .{ .r = 240, .g = 210, .b = 90, .a = 255 }, 90);
        const wire_preview = withAlpha(blend(hl, .{ .r = 100, .g = 230, .b = 140, .a = 255 }, 80), 170);
        const origin = withAlpha(t.border, if (t.dark) 160 else 150);

        var result = Palette{
            .canvas_bg = canvas_bg, .grid_dot = grid_dot, .wire = wire, .wire_sel = wire_sel,
            .wire_endpoint = wire_endpoint, .inst_body = inst_body, .inst_sel = wire_sel,
            .inst_pin = inst_pin, .symbol_line = symbol_line, .symbol_pin = symbol_pin,
            .wire_preview = wire_preview, .origin = origin,
        };

        // Apply plugin overrides
        const ov = &current_overrides;
        inline for (.{
            .{ "canvas_bg", "canvas_bg" }, .{ "wire", "wire" }, .{ "wire_endpoint", "wire_endpoint" },
            .{ "instance_body", "inst_body" }, .{ "instance_pin", "inst_pin" }, .{ "symbol_line", "symbol_line" },
        }) |pair| {
            if (@field(ov, pair[0])) |rgb| @field(result, pair[1]) = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        }
        if (ov.grid_dot) |rgba| result.grid_dot = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.wire_preview) |rgba| result.wire_preview = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.wire_selected) |rgb| { result.wire_sel = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 }; result.inst_sel = result.wire_sel; }

        return result;
    }
};

// ── Color math ───────────────────────────────────────────────────────────────

pub inline fn blend(a: Color, b: Color, w: u8) Color {
    const fw: u32 = w;
    const fa: u32 = 255 - fw;
    return .{
        .r = @intCast((a.r * fa + b.r * fw) / 255),
        .g = @intCast((a.g * fa + b.g * fw) / 255),
        .b = @intCast((a.b * fa + b.b * fw) / 255),
        .a = 255,
    };
}

pub inline fn colorScale(col: Color, fac: u32) Color {
    return .{
        .r = @intCast(@min(255, @as(u32, col.r) * fac / 255)),
        .g = @intCast(@min(255, @as(u32, col.g) * fac / 255)),
        .b = @intCast(@min(255, @as(u32, col.b) * fac / 255)),
        .a = col.a,
    };
}

pub inline fn withAlpha(col: Color, a: u8) Color {
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
}

// ── Runtime JSON config ──────────────────────────────────────────────────────

pub fn applyJson(alloc: std.mem.Allocator, json_str: []const u8) void {
    const Schema = struct {
        canvas_bg: ?[3]i64 = null, grid_dot: ?[4]i64 = null,
        wire: ?[3]i64 = null, wire_selected: ?[3]i64 = null, wire_endpoint: ?[3]i64 = null,
        instance_body: ?[3]i64 = null, instance_pin: ?[3]i64 = null, symbol_line: ?[3]i64 = null,
        wire_preview: ?[4]i64 = null, sidebar_bg: ?[3]i64 = null, bottombar_bg: ?[3]i64 = null,
        corner_radius: ?f64 = null, border_width: ?f64 = null,
        button_padding_h: ?f64 = null, button_padding_v: ?f64 = null,
        wire_width: ?f64 = null, grid_dot_size: ?f64 = null, tab_shape: ?i64 = null,
    };
    const parsed = std.json.parseFromSlice(Schema, alloc, json_str, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    current_overrides = .{};
    const v = &parsed.value;
    const ov = &current_overrides;

    inline for (.{
        .{ "canvas_bg", "canvas_bg" }, .{ "wire", "wire" }, .{ "wire_selected", "wire_selected" },
        .{ "wire_endpoint", "wire_endpoint" }, .{ "instance_body", "instance_body" },
        .{ "instance_pin", "instance_pin" }, .{ "symbol_line", "symbol_line" },
        .{ "sidebar_bg", "sidebar_bg" }, .{ "bottombar_bg", "bottombar_bg" },
    }) |pair| {
        if (@field(v, pair[0])) |a| @field(ov, pair[1]) = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    }
    inline for (.{ .{ "grid_dot", "grid_dot" }, .{ "wire_preview", "wire_preview" } }) |pair| {
        if (@field(v, pair[0])) |a| @field(ov, pair[1]) = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]), clamp8(a[3]) };
    }
    inline for (.{ "corner_radius", "border_width", "button_padding_h", "button_padding_v", "wire_width", "grid_dot_size" }) |name| {
        if (@field(v, name)) |f_val| @field(ov, name) = @floatCast(f_val);
    }
    if (v.tab_shape) |n| ov.tab_shape = @intCast(std.math.clamp(n, 0, 4));
}

fn clamp8(x: i64) u8 { return @intCast(std.math.clamp(x, 0, 255)); }
