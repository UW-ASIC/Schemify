//! Theme config — runtime plugin color override storage.
//!
//! This file has zero dependencies (no dvui, no state) so it can be imported
//! from both the renderer modules (src/gui/renderer/*.zig) and the plugin
//! runtime (src/plugins/runtime.zig) without introducing circular imports.
//!
//! Usage from a plugin that calls SET_CONFIG key="theme":
//!
//!   JSON value format:
//!   {
//!     "wire":        [88, 210, 255],
//!     "wire_sel":    [255, 165, 50],
//!     "canvas_bg":   [18, 18, 24]
//!   }
//!
//! The runtime parses the JSON and updates `current_overrides` directly.
//! The renderer reads `current_overrides` once per frame in Palette.fromTheme().

const std = @import("std");

// ── ThemeOverrides ────────────────────────────────────────────────────────── //

/// JSON-parsed color overrides from the Themes plugin.
/// All fields are optional — null means "use computed default from dvui theme".
pub const ThemeOverrides = struct {
    canvas_bg:      ?[3]u8 = null,
    grid_dot:       ?[4]u8 = null,  // RGBA
    wire:           ?[3]u8 = null,
    wire_selected:  ?[3]u8 = null,
    wire_endpoint:  ?[3]u8 = null,
    instance_body:  ?[3]u8 = null,
    instance_pin:   ?[3]u8 = null,
    symbol_line:    ?[3]u8 = null,
    wire_preview:   ?[4]u8 = null,  // RGBA
    sidebar_bg:     ?[3]u8 = null,
    bottombar_bg:   ?[3]u8 = null,

    // Shape/spacing properties
    corner_radius:    ?f32 = null,  // 0=sharp, 8=rounded, 16=pill
    border_width:     ?f32 = null,  // panel/card border thickness
    button_padding_h: ?f32 = null,  // horizontal padding inside buttons
    button_padding_v: ?f32 = null,  // vertical padding inside buttons
    wire_width:       ?f32 = null,  // wire stroke width multiplier
    grid_dot_size:    ?f32 = null,  // grid dot radius multiplier (0.5–2.0)

    /// Tab shape style.  Stored as u8 for JSON compatibility.
    /// 0 = rect      (sharp rectangle)
    /// 1 = rounded   (pill — uses corner_radius, current default)
    /// 2 = arrow     (right-pointing chevron via Unicode suffix ›)
    /// 3 = angled    (trapezoid: rounded top, sharp bottom)
    /// 4 = underline (flat bar — rounded top, square bottom)
    tab_shape: ?u8 = null,
};

/// Global mutable override. Written by the themes plugin via SET_CONFIG.
/// Reset to .{} to restore all defaults.
pub var current_overrides: ThemeOverrides = .{};

// ── JSON parsing ──────────────────────────────────────────────────────────── //

fn clamp8(x: i64) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}

/// Parse a JSON theme string and apply it to `current_overrides`.
/// Unrecognised keys are silently ignored (forward-compatible).
/// On any parse error the function returns without modifying overrides.
///
/// Expected format:
///   { "wire": [88, 210, 255], "canvas_bg": [18, 18, 24], ... }
///
/// RGBA fields (grid_dot, wire_preview) expect 4-element arrays.
pub fn applyJson(json_text: []const u8) void {
    const alloc = std.heap.page_allocator;

    const Schema = struct {
        canvas_bg:      ?[3]i64 = null,
        grid_dot:       ?[4]i64 = null,
        wire:           ?[3]i64 = null,
        wire_selected:  ?[3]i64 = null,
        wire_endpoint:  ?[3]i64 = null,
        instance_body:  ?[3]i64 = null,
        instance_pin:   ?[3]i64 = null,
        symbol_line:    ?[3]i64 = null,
        wire_preview:   ?[4]i64 = null,
        sidebar_bg:     ?[3]i64 = null,
        bottombar_bg:   ?[3]i64 = null,
        corner_radius:    ?f64 = null,
        border_width:     ?f64 = null,
        button_padding_h: ?f64 = null,
        button_padding_v: ?f64 = null,
        wire_width:       ?f64 = null,
        grid_dot_size:    ?f64 = null,
        tab_shape:        ?i64 = null,
    };

    const parsed = std.json.parseFromSlice(Schema, alloc, json_text, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const v = &parsed.value;

    if (v.canvas_bg)     |a| current_overrides.canvas_bg     = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.grid_dot)      |a| current_overrides.grid_dot      = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]), clamp8(a[3]) };
    if (v.wire)          |a| current_overrides.wire          = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.wire_selected) |a| current_overrides.wire_selected = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.wire_endpoint) |a| current_overrides.wire_endpoint = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.instance_body) |a| current_overrides.instance_body = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.instance_pin)  |a| current_overrides.instance_pin  = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.symbol_line)   |a| current_overrides.symbol_line   = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.wire_preview)  |a| current_overrides.wire_preview  = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]), clamp8(a[3]) };
    if (v.sidebar_bg)    |a| current_overrides.sidebar_bg    = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.bottombar_bg)  |a| current_overrides.bottombar_bg  = .{ clamp8(a[0]), clamp8(a[1]), clamp8(a[2]) };
    if (v.corner_radius)    |f| current_overrides.corner_radius    = @floatCast(f);
    if (v.border_width)     |f| current_overrides.border_width     = @floatCast(f);
    if (v.button_padding_h) |f| current_overrides.button_padding_h = @floatCast(f);
    if (v.button_padding_v) |f| current_overrides.button_padding_v = @floatCast(f);
    if (v.wire_width)       |f| current_overrides.wire_width       = @floatCast(f);
    if (v.grid_dot_size)    |f| current_overrides.grid_dot_size    = @floatCast(f);
    if (v.tab_shape)        |n| current_overrides.tab_shape        = @intCast(std.math.clamp(n, 0, 4));
}

// ── Shape/spacing getters ─────────────────────────────────────────────────── //

pub fn getCornerRadius() f32 {
    return current_overrides.corner_radius orelse 4.0;
}

pub fn getBorderWidth() f32 {
    return current_overrides.border_width orelse 1.0;
}

pub fn getButtonPaddingH() f32 {
    return current_overrides.button_padding_h orelse 6.0;
}

pub fn getButtonPaddingV() f32 {
    return current_overrides.button_padding_v orelse 3.0;
}

pub fn getWireWidth() f32 {
    return current_overrides.wire_width orelse 1.0;
}

pub fn getGridDotSize() f32 {
    return current_overrides.grid_dot_size orelse 1.0;
}

pub fn getTabShape() u8 {
    return current_overrides.tab_shape orelse 1; // default: rounded
}
