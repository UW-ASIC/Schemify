//! Color palette for the schematic canvas and UI elements.
//! Computed from a dvui.Theme with optional plugin overrides applied.

const std = @import("std");
const dvui = @import("dvui");

const Color = dvui.Color;
const current_overrides = @import("Theme.zig").current_overrides;

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

        const canvas_bg = if (t.dark)
            Color{ .r = 22, .g = 22, .b = 28, .a = 255 }
        else
            colorScale(win_bg, 240);

        const grid_dot = withAlpha(
            colorScale(t.border, if (t.dark) 130 else 160),
            if (t.dark) 120 else 160,
        );

        const wire = if (t.dark)
            blend(focus, .{ .r = 88, .g = 210, .b = 255, .a = 255 }, 120)
        else
            blend(focus, .{ .r = 0, .g = 40, .b = 120, .a = 255 }, 40);

        const wire_sel = if (t.dark)
            blend(hl, .{ .r = 255, .g = 165, .b = 50, .a = 255 }, 140)
        else
            blend(hl, .{ .r = 200, .g = 90, .b = 0, .a = 255 }, 90);

        const wire_endpoint = blend(focus, .{ .r = 50, .g = 255, .b = 130, .a = 255 }, 90);
        const inst_body = blend(ctrl, wire, 60);
        const inst_pin = blend(t.text, .{ .r = 255, .g = 230, .b = 60, .a = 255 }, 90);
        const symbol_line = colorScale(t.text, 230);
        const symbol_pin = blend(focus, .{ .r = 255, .g = 220, .b = 60, .a = 255 }, 100);
        const wire_preview = withAlpha(
            blend(hl, .{ .r = 80, .g = 255, .b = 120, .a = 255 }, 90),
            180,
        );
        const origin = withAlpha(t.border, if (t.dark) 190 else 170);

        var result = Palette{
            .canvas_bg = canvas_bg,
            .grid_dot = grid_dot,
            .wire = wire,
            .wire_sel = wire_sel,
            .wire_endpoint = wire_endpoint,
            .inst_body = inst_body,
            .inst_sel = wire_sel,
            .inst_pin = inst_pin,
            .symbol_line = symbol_line,
            .symbol_pin = symbol_pin,
            .wire_preview = wire_preview,
            .origin = origin,
        };

        // Apply plugin theme overrides (RGB fields).
        const ov = &current_overrides;
        inline for (.{
            .{ "canvas_bg", "canvas_bg" },   .{ "wire", "wire" },
            .{ "wire_endpoint", "wire_endpoint" }, .{ "instance_body", "inst_body" },
            .{ "instance_pin", "inst_pin" },       .{ "symbol_line", "symbol_line" },
        }) |pair| {
            if (@field(ov, pair[0])) |rgb|
                @field(result, pair[1]) = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
        }
        // RGBA override fields.
        if (ov.grid_dot) |rgba| result.grid_dot = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        if (ov.wire_preview) |rgba| result.wire_preview = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        // wire_selected also sets inst_sel.
        if (ov.wire_selected) |rgb| {
            result.wire_sel = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
            result.inst_sel = result.wire_sel;
        }

        return result;
    }
};

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