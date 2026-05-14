//! Theme + Palette — color computation, plugin overrides, and color math.
//! Combines the old Theme.zig and Palette.zig into a single file.

const std = @import("std");
const dvui = @import("dvui");
pub const Color = dvui.Color;

// ── Plugin overrides (written by Themes plugin via SET_CONFIG) ───────────────

pub var current_overrides: ThemeOverrides = .{};

pub const ThemeOverrides = struct {
    // Canvas colors
    canvas_bg: ?[3]u8 = null,
    grid_dot: ?[4]u8 = null,
    wire: ?[3]u8 = null,
    wire_selected: ?[3]u8 = null,
    wire_endpoint: ?[3]u8 = null,
    instance_body: ?[3]u8 = null,
    instance_pin: ?[3]u8 = null,
    symbol_line: ?[3]u8 = null,
    symbol_pin: ?[3]u8 = null,
    wire_preview: ?[4]u8 = null,
    origin: ?[4]u8 = null,
    // Chrome colors
    sidebar_bg: ?[3]u8 = null,
    bottombar_bg: ?[3]u8 = null,
    toolbar_bg: ?[3]u8 = null,
    tabbar_bg: ?[3]u8 = null,
    tab_active_bg: ?[3]u8 = null,
    statusbar_bg: ?[3]u8 = null,
    text_primary: ?[3]u8 = null,
    text_secondary: ?[3]u8 = null,
    accent: ?[3]u8 = null,
    separator: ?[3]u8 = null,
    hover_bg: ?[3]u8 = null,
    // Shape / spacing
    corner_radius: ?f32 = null,
    border_width: ?f32 = null,
    button_padding_h: ?f32 = null,
    button_padding_v: ?f32 = null,
    wire_width: ?f32 = null,
    grid_dot_size: ?f32 = null,
    tab_shape: ?u8 = null,
    toolbar_height: ?f32 = null,
    tabbar_height: ?f32 = null,
    statusbar_height: ?f32 = null,
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

pub fn chromeToolbarBg() Color { return rgb3(current_overrides.toolbar_bg, 35, 38, 48); }
pub fn chromeTabbarBg() Color { return rgb3(current_overrides.tabbar_bg, 22, 24, 30); }
pub fn chromeTabActiveBg() Color { return rgb3(current_overrides.tab_active_bg, 50, 55, 70); }
pub fn chromeStatusbarBg() Color { return rgb3(current_overrides.statusbar_bg, 26, 28, 36); }
pub fn chromeSidebarBg() Color { return rgb3(current_overrides.sidebar_bg, 30, 32, 40); }
pub fn chromeTextPrimary() Color { return rgb3(current_overrides.text_primary, 220, 224, 235); }
pub fn chromeTextSecondary() Color { return rgb3(current_overrides.text_secondary, 160, 164, 176); }
pub fn chromeAccent() Color { return rgb3(current_overrides.accent, 137, 180, 250); }
pub fn chromeSeparator() Color { return rgb3(current_overrides.separator, 60, 62, 72); }
pub fn chromeHoverBg() Color { return rgb3(current_overrides.hover_bg, 55, 60, 78); }
pub fn chromeCornerRadius() f32 { return current_overrides.corner_radius orelse 4.0; }
pub fn chromeToolbarH() f32 { return current_overrides.toolbar_height orelse 32; }
pub fn chromeTabbarH() f32 { return current_overrides.tabbar_height orelse 28; }
pub fn chromeStatusbarH() f32 { return current_overrides.statusbar_height orelse 24; }
pub fn chromeTabShape() u8 { return current_overrides.tab_shape orelse 1; }

pub fn getSidebarBg() Color {
    if (current_overrides.sidebar_bg) |rgb| return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    return .{ .r = 28, .g = 30, .b = 38, .a = 255 };
}
pub fn getBottomBarBg() Color {
    if (current_overrides.bottombar_bg) |rgb| return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    return .{ .r = 28, .g = 30, .b = 38, .a = 255 };
}

fn rgb3(ov: ?[3]u8, dr: u8, dg: u8, db: u8) Color {
    if (ov) |c| return .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 };
    return .{ .r = dr, .g = dg, .b = db, .a = 255 };
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

    /// Returns a hardcoded dark-theme palette with plugin overrides applied.
    pub fn dark() Palette {
        const canvas_bg = Color{ .r = 15, .g = 17, .b = 23, .a = 255 };
        const grid_dot = Color{ .r = 47, .g = 47, .b = 51, .a = 90 };
        const wire = Color{ .r = 71, .g = 146, .b = 212, .a = 255 };
        const wire_sel = Color{ .r = 168, .g = 128, .b = 59, .a = 255 };
        const wire_endpoint = Color{ .r = 56, .g = 176, .b = 131, .a = 255 };
        const inst_body = Color{ .r = 56, .g = 105, .b = 148, .a = 255 };
        const inst_pin = Color{ .r = 214, .g = 205, .b = 142, .a = 255 };
        const symbol_line = Color{ .r = 188, .g = 188, .b = 188, .a = 255 };
        const symbol_pin = Color{ .r = 102, .g = 152, .b = 109, .a = 255 };
        const wire_preview = Color{ .r = 87, .g = 183, .b = 122, .a = 170 };
        const origin = Color{ .r = 110, .g = 110, .b = 110, .a = 160 };

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
            .{ "instance_body", "inst_body" }, .{ "instance_pin", "inst_pin" },
            .{ "symbol_line", "symbol_line" }, .{ "symbol_pin", "symbol_pin" },
        }) |pair| {
            if (@field(ov, pair[0])) |rgb| @field(result, pair[1]) = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        }
        if (ov.grid_dot) |rgba| result.grid_dot = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.wire_preview) |rgba| result.wire_preview = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.origin) |rgba| result.origin = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.wire_selected) |rgb| { result.wire_sel = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 }; result.inst_sel = result.wire_sel; }

        return result;
    }

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
        symbol_pin: ?[3]i64 = null,
        wire_preview: ?[4]i64 = null, origin: ?[4]i64 = null,
        sidebar_bg: ?[3]i64 = null, bottombar_bg: ?[3]i64 = null,
        toolbar_bg: ?[3]i64 = null, tabbar_bg: ?[3]i64 = null,
        tab_active_bg: ?[3]i64 = null, statusbar_bg: ?[3]i64 = null,
        text_primary: ?[3]i64 = null, text_secondary: ?[3]i64 = null,
        accent: ?[3]i64 = null, separator: ?[3]i64 = null, hover_bg: ?[3]i64 = null,
        corner_radius: ?f64 = null, border_width: ?f64 = null,
        button_padding_h: ?f64 = null, button_padding_v: ?f64 = null,
        wire_width: ?f64 = null, grid_dot_size: ?f64 = null, tab_shape: ?i64 = null,
        toolbar_height: ?f64 = null, tabbar_height: ?f64 = null, statusbar_height: ?f64 = null,
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
        .{ "symbol_pin", "symbol_pin" },
        .{ "sidebar_bg", "sidebar_bg" }, .{ "bottombar_bg", "bottombar_bg" },
        .{ "toolbar_bg", "toolbar_bg" }, .{ "tabbar_bg", "tabbar_bg" },
        .{ "tab_active_bg", "tab_active_bg" }, .{ "statusbar_bg", "statusbar_bg" },
        .{ "text_primary", "text_primary" }, .{ "text_secondary", "text_secondary" },
        .{ "accent", "accent" }, .{ "separator", "separator" }, .{ "hover_bg", "hover_bg" },
    }) |pair| {
        if (@field(v, pair[0])) |a| @field(ov, pair[1]) = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    }
    inline for (.{ .{ "grid_dot", "grid_dot" }, .{ "wire_preview", "wire_preview" }, .{ "origin", "origin" } }) |pair| {
        if (@field(v, pair[0])) |a| @field(ov, pair[1]) = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]), clamp8(a[3]) };
    }
    inline for (.{ "corner_radius", "border_width", "button_padding_h", "button_padding_v", "wire_width", "grid_dot_size", "toolbar_height", "tabbar_height", "statusbar_height" }) |name| {
        if (@field(v, name)) |f_val| @field(ov, name) = @floatCast(f_val);
    }
    if (v.tab_shape) |n| ov.tab_shape = @intCast(std.math.clamp(n, 0, 4));
}

fn clamp8(x: i64) u8 { return @intCast(std.math.clamp(x, 0, 255)); }
