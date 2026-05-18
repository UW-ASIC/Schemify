//! Theme system — cascade-based styling with per-widget-type and variant support.
//!
//! Cascade resolution (4 levels):
//!   widget.variant > widget.default > role > dvui builtin
//!
//! Old flat API (chromeToolbarBg, getWireWidth, etc.) kept as shims during migration.

const std = @import("std");
const dvui = @import("dvui");
pub const Color = dvui.Color;

// ═══════════════════════════════════════════════════════════════════════════
// Enums
// ═══════════════════════════════════════════════════════════════════════════

pub const WidgetType = enum(u5) {
    // Interactive (6)
    button,
    text_input,
    checkbox,
    dropdown,
    slider,
    scrollbar,
    // Chrome (6)
    toolbar,
    tab,
    sidebar_panel,
    dialog,
    statusbar,
    menubar,
    // Canvas (6)
    wire,
    pin,
    instance_body,
    grid,
    selection_rect,
    net_label,

    pub const count = 18;
};

pub const Variant = enum(u4) {
    default,
    primary,
    secondary,
    danger,
    ghost,
    active,
    err,
    disabled,
    success,

    pub const count = 9;
};

pub const Role = enum(u3) {
    content,
    control,
    window,
    highlight,
    err,
    canvas,
    chrome,
    accent,

    pub const count = 8;
};

pub const PinShape = enum { circle, square, diamond, triangle };
pub const GridPattern = enum { dots, lines, crosses };
pub const WireRouting = enum { straight, curved, ortho };

// ═══════════════════════════════════════════════════════════════════════════
// StyleBlock — sparse overlay struct (~120 bytes)
// ═══════════════════════════════════════════════════════════════════════════

pub const StyleBlock = struct {
    fill: ?Color = null,
    fill_hover: ?Color = null,
    fill_press: ?Color = null,
    text: ?Color = null,
    text_hover: ?Color = null,
    text_press: ?Color = null,
    border_color: ?Color = null,
    corner_radius: ?[4]f32 = null,
    border_width: ?[4]f32 = null,
    margin: ?[4]f32 = null,
    padding: ?[4]f32 = null,
    font_size_scale: ?f32 = null,
    background: ?bool = null,
    min_size: ?[2]f32 = null,
    max_size: ?[2]f32 = null,

    /// Overlay self on top of fallback. Self wins where non-null.
    pub fn overlay(self: StyleBlock, fallback: StyleBlock) StyleBlock {
        var result = fallback;
        inline for (comptime std.meta.fieldNames(StyleBlock)) |name| {
            if (@field(self, name) != null) {
                @field(result, name) = @field(self, name);
            }
        }
        return result;
    }

    /// Convert to dvui.Options for widget consumption.
    pub fn toDvuiOptions(self: StyleBlock) dvui.Options {
        var opts: dvui.Options = .{};
        if (self.fill) |c| opts.color_fill = c;
        if (self.fill_hover) |c| opts.color_fill_hover = c;
        if (self.text) |c| opts.color_text = c;
        if (self.border_color) |c| opts.color_border = c;
        if (self.corner_radius) |cr| opts.corner_radius = .{ .x = cr[0], .y = cr[1], .w = cr[2], .h = cr[3] };
        if (self.border_width) |bw| opts.border = .{ .x = bw[0], .y = bw[1], .w = bw[2], .h = bw[3] };
        if (self.margin) |m| opts.margin = .{ .x = m[0], .y = m[1], .w = m[2], .h = m[3] };
        if (self.padding) |p| opts.padding = .{ .x = p[0], .y = p[1], .w = p[2], .h = p[3] };
        if (self.background) |bg| opts.background = bg;
        if (self.min_size) |ms| opts.min_size_content = .{ .w = ms[0], .h = ms[1] };
        return opts;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Canvas-specific styles
// ═══════════════════════════════════════════════════════════════════════════

pub const FlowAnimation = struct {
    speed: f32 = 0,
    dash_len: f32 = 8,
    gap_len: f32 = 4,
};

pub const WireStyle = struct {
    color: Color = .{ .r = 71, .g = 146, .b = 212, .a = 255 },
    color_selected: Color = .{ .r = 168, .g = 128, .b = 59, .a = 255 },
    stroke_width: f32 = 1.0,
    glow_color: ?Color = null,
    glow_radius: f32 = 0,
    routing: WireRouting = .ortho,
    flow: FlowAnimation = .{},
};

pub const PinStyle = struct {
    color: Color = .{ .r = 214, .g = 205, .b = 142, .a = 255 },
    radius: f32 = 2.5,
    shape: PinShape = .circle,
    glow_color: ?Color = null,
    glow_radius: f32 = 0,
};

pub const InstanceStyle = struct {
    fill: Color = .{ .r = 56, .g = 105, .b = 148, .a = 255 },
    stroke_color: Color = .{ .r = 188, .g = 188, .b = 188, .a = 255 },
    stroke_width: f32 = 1.8,
    label_color: Color = .{ .r = 188, .g = 188, .b = 188, .a = 180 },
};

pub const GridStyle = struct {
    color: Color = .{ .r = 47, .g = 47, .b = 51, .a = 90 },
    pattern: GridPattern = .dots,
    dot_size: f32 = 1.0,
};

pub const SelectionStyle = struct {
    color: Color = .{ .r = 71, .g = 146, .b = 212, .a = 160 },
    fill_color: Color = .{ .r = 71, .g = 146, .b = 212, .a = 30 },
    dash_pattern: [2]f32 = .{ 6, 3 },
    pulse_speed: f32 = 2.0,
    glow_color: ?Color = null,
    glow_radius: f32 = 0,
};

pub const CanvasStyles = struct {
    wire: WireStyle = .{},
    pin: PinStyle = .{},
    instance: InstanceStyle = .{},
    grid: GridStyle = .{},
    selection: SelectionStyle = .{},
};

// ═══════════════════════════════════════════════════════════════════════════
// AnimationState — ticked every frame, zero alloc
// ═══════════════════════════════════════════════════════════════════════════

pub const AnimationState = struct {
    flow_phase: f32 = 0,
    selection_pulse: f32 = 0,

    pub fn tick(self: *AnimationState, dt: f32, canvas: *const CanvasStyles) void {
        const period = canvas.wire.flow.dash_len + canvas.wire.flow.gap_len;
        if (canvas.wire.flow.speed > 0 and period > 0) {
            self.flow_phase = @mod(self.flow_phase + canvas.wire.flow.speed * dt, period);
        }
        if (canvas.selection.pulse_speed > 0) {
            self.selection_pulse = @mod(
                self.selection_pulse + canvas.selection.pulse_speed * dt,
                std.math.tau,
            );
        }
    }

    /// Selection rect alpha oscillation (0.5..1.0 range).
    pub fn selectionAlpha(self: *const AnimationState) f32 {
        return 0.75 + 0.25 * @sin(self.selection_pulse);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// WidgetConfig — per-widget base + variant overrides
// ═══════════════════════════════════════════════════════════════════════════

pub const WidgetConfig = struct {
    base: StyleBlock = .{},
    variants: [Variant.count]StyleBlock = [_]StyleBlock{.{}} ** Variant.count,
};

// ═══════════════════════════════════════════════════════════════════════════
// ResolvedTheme — pre-computed, cached, ~26KB
// ═══════════════════════════════════════════════════════════════════════════

pub const ResolvedTheme = struct {
    widget_styles: [WidgetType.count][Variant.count]StyleBlock =
        [_][Variant.count]StyleBlock{[_]StyleBlock{.{}} ** Variant.count} ** WidgetType.count,
    canvas: CanvasStyles = .{},
    palette: Palette = default_palette,
};

const default_palette = Palette{
    .canvas_bg = .{ .r = 15, .g = 17, .b = 23, .a = 255 },
    .grid_dot = .{ .r = 47, .g = 47, .b = 51, .a = 90 },
    .wire = .{ .r = 71, .g = 146, .b = 212, .a = 255 },
    .wire_sel = .{ .r = 168, .g = 128, .b = 59, .a = 255 },
    .wire_endpoint = .{ .r = 56, .g = 176, .b = 131, .a = 255 },
    .bus = .{ .r = 70, .g = 180, .b = 170, .a = 255 },
    .inst_body = .{ .r = 56, .g = 105, .b = 148, .a = 255 },
    .inst_sel = .{ .r = 168, .g = 128, .b = 59, .a = 255 },
    .inst_pin = .{ .r = 214, .g = 205, .b = 142, .a = 255 },
    .symbol_line = .{ .r = 188, .g = 188, .b = 188, .a = 255 },
    .symbol_pin = .{ .r = 102, .g = 152, .b = 109, .a = 255 },
    .wire_preview = .{ .r = 87, .g = 183, .b = 122, .a = 170 },
    .origin = .{ .r = 110, .g = 110, .b = 110, .a = 160 },
};

// ═══════════════════════════════════════════════════════════════════════════
// Widget → Role default mapping
// ═══════════════════════════════════════════════════════════════════════════

const widget_roles: [WidgetType.count]Role = blk: {
    var r: [WidgetType.count]Role = @splat(.control);
    r[@intFromEnum(WidgetType.toolbar)] = .chrome;
    r[@intFromEnum(WidgetType.tab)] = .chrome;
    r[@intFromEnum(WidgetType.sidebar_panel)] = .chrome;
    r[@intFromEnum(WidgetType.dialog)] = .window;
    r[@intFromEnum(WidgetType.statusbar)] = .chrome;
    r[@intFromEnum(WidgetType.menubar)] = .chrome;
    r[@intFromEnum(WidgetType.wire)] = .canvas;
    r[@intFromEnum(WidgetType.pin)] = .canvas;
    r[@intFromEnum(WidgetType.instance_body)] = .canvas;
    r[@intFromEnum(WidgetType.grid)] = .canvas;
    r[@intFromEnum(WidgetType.selection_rect)] = .highlight;
    r[@intFromEnum(WidgetType.net_label)] = .canvas;
    break :blk r;
};

// ═══════════════════════════════════════════════════════════════════════════
// Module-level state
// ═══════════════════════════════════════════════════════════════════════════

/// Old flat overrides — kept for backward compat with plugins via SET_CONFIG.
pub var current_overrides: ThemeOverrides = .{};

/// New cascade theme config.
pub var active_config: ThemeConfig = .{};

// ═══════════════════════════════════════════════════════════════════════════
// ThemeConfig — full nested config with cascade resolver
// ═══════════════════════════════════════════════════════════════════════════

pub const ThemeConfig = struct {
    dirty: bool = true,
    resolved: ResolvedTheme = .{},
    animation: AnimationState = .{},

    // Source data
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    dark: bool = true,
    roles: [Role.count]StyleBlock = [_]StyleBlock{.{}} ** Role.count,
    widgets: [WidgetType.count]WidgetConfig = [_]WidgetConfig{.{}} ** WidgetType.count,
    canvas_config: CanvasStyles = .{},

    pub fn nameSlice(self: *const ThemeConfig) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *ThemeConfig, name: []const u8) void {
        self.name_len = @intCast(@min(name.len, 63));
        @memcpy(self.name_buf[0..self.name_len], name[0..self.name_len]);
    }

    /// Rebuild resolved theme from config. Call when dirty.
    pub fn resolve(self: *ThemeConfig) void {
        // Rebuild palette from dvui theme + dark/light preference.
        const dvui_t = dvui.themeGet();
        self.resolved.palette = if (self.dark) Palette.dark() else Palette.fromDvui(dvui_t);

        // Apply canvas config, then sync palette into canvas defaults.
        self.resolved.canvas = self.canvas_config;
        syncPaletteToCanvas(&self.resolved);

        // Cascade: variant > widget.default > role
        for (0..WidgetType.count) |wt| {
            const role = widget_roles[wt];
            const role_style = self.roles[@intFromEnum(role)];
            const widget_base = self.widgets[wt].base;

            for (0..Variant.count) |v| {
                const variant_style = self.widgets[wt].variants[v];
                self.resolved.widget_styles[wt][v] = variant_style.overlay(widget_base.overlay(role_style));
            }
        }

        // Sync old ThemeOverrides from resolved state for backward compat.
        syncOverridesFromResolved(&self.resolved);
        self.dirty = false;
    }

    /// Get resolved options for a widget type + variant.
    pub fn widgetOptions(self: *const ThemeConfig, wt: WidgetType, v: Variant) dvui.Options {
        return self.resolved.widget_styles[@intFromEnum(wt)][@intFromEnum(v)].toDvuiOptions();
    }
};

fn syncPaletteToCanvas(resolved: *ResolvedTheme) void {
    const pal = &resolved.palette;
    // Only sync if canvas styles are at defaults (i.e. user hasn't overridden them).
    // This ensures palette-derived presets get sensible canvas colors.
    const default_wire = WireStyle{};
    if (std.meta.eql(resolved.canvas.wire.color, default_wire.color)) {
        resolved.canvas.wire.color = pal.wire;
        resolved.canvas.wire.color_selected = pal.wire_sel;
    }
    const default_pin = PinStyle{};
    if (std.meta.eql(resolved.canvas.pin.color, default_pin.color)) {
        resolved.canvas.pin.color = pal.inst_pin;
    }
    const default_inst = InstanceStyle{};
    if (std.meta.eql(resolved.canvas.instance.fill, default_inst.fill)) {
        resolved.canvas.instance.fill = pal.inst_body;
        resolved.canvas.instance.stroke_color = pal.symbol_line;
    }
    const default_grid = GridStyle{};
    if (std.meta.eql(resolved.canvas.grid.color, default_grid.color)) {
        resolved.canvas.grid.color = pal.grid_dot;
    }
}

fn syncOverridesFromResolved(resolved: *const ResolvedTheme) void {
    const pal = &resolved.palette;
    const cs = &resolved.canvas;
    current_overrides = .{};

    // Canvas colors
    current_overrides.canvas_bg = .{ pal.canvas_bg.r, pal.canvas_bg.g, pal.canvas_bg.b };
    current_overrides.wire = .{ cs.wire.color.r, cs.wire.color.g, cs.wire.color.b };
    current_overrides.wire_selected = .{ cs.wire.color_selected.r, cs.wire.color_selected.g, cs.wire.color_selected.b };
    current_overrides.wire_endpoint = .{ pal.wire_endpoint.r, pal.wire_endpoint.g, pal.wire_endpoint.b };
    current_overrides.instance_body = .{ cs.instance.fill.r, cs.instance.fill.g, cs.instance.fill.b };
    current_overrides.instance_pin = .{ cs.pin.color.r, cs.pin.color.g, cs.pin.color.b };
    current_overrides.symbol_line = .{ cs.instance.stroke_color.r, cs.instance.stroke_color.g, cs.instance.stroke_color.b };
    current_overrides.grid_dot = .{ cs.grid.color.r, cs.grid.color.g, cs.grid.color.b, cs.grid.color.a };
    current_overrides.wire_preview = .{ pal.wire_preview.r, pal.wire_preview.g, pal.wire_preview.b, pal.wire_preview.a };
    current_overrides.origin = .{ pal.origin.r, pal.origin.g, pal.origin.b, pal.origin.a };

    // Shape
    current_overrides.wire_width = cs.wire.stroke_width;
    current_overrides.grid_dot_size = cs.grid.dot_size;
}

// ═══════════════════════════════════════════════════════════════════════════
// Old ThemeOverrides — backward compat for plugins via SET_CONFIG
// ═══════════════════════════════════════════════════════════════════════════

pub const ThemeOverrides = struct {
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

// ═══════════════════════════════════════════════════════════════════════════
// Old shape / spacing getters — shims reading from current_overrides
// ═══════════════════════════════════════════════════════════════════════════

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
    return current_overrides.tab_shape orelse 1;
}

// ═══════════════════════════════════════════════════════════════════════════
// Old chrome color getters — shims
// ═══════════════════════════════════════════════════════════════════════════

pub fn chromeToolbarBg() Color {
    return rgb3(current_overrides.toolbar_bg, 35, 38, 48);
}
pub fn chromeTabbarBg() Color {
    return rgb3(current_overrides.tabbar_bg, 22, 24, 30);
}
pub fn chromeTabActiveBg() Color {
    return rgb3(current_overrides.tab_active_bg, 50, 55, 70);
}
pub fn chromeStatusbarBg() Color {
    return rgb3(current_overrides.statusbar_bg, 26, 28, 36);
}
pub fn chromeSidebarBg() Color {
    return rgb3(current_overrides.sidebar_bg, 30, 32, 40);
}
pub fn chromeTextPrimary() Color {
    return rgb3(current_overrides.text_primary, 220, 224, 235);
}
pub fn chromeTextSecondary() Color {
    return rgb3(current_overrides.text_secondary, 160, 164, 176);
}
pub fn chromeAccent() Color {
    return rgb3(current_overrides.accent, 137, 180, 250);
}
pub fn chromeSeparator() Color {
    return rgb3(current_overrides.separator, 60, 62, 72);
}
pub fn chromeHoverBg() Color {
    return rgb3(current_overrides.hover_bg, 55, 60, 78);
}
pub fn chromeCornerRadius() f32 {
    return current_overrides.corner_radius orelse 4.0;
}
pub fn chromeToolbarH() f32 {
    return current_overrides.toolbar_height orelse 32;
}
pub fn chromeTabbarH() f32 {
    return current_overrides.tabbar_height orelse 28;
}
pub fn chromeStatusbarH() f32 {
    return current_overrides.statusbar_height orelse 24;
}
pub fn chromeTabShape() u8 {
    return current_overrides.tab_shape orelse 1;
}

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

// ═══════════════════════════════════════════════════════════════════════════
// Palette
// ═══════════════════════════════════════════════════════════════════════════

pub const Palette = struct {
    canvas_bg: Color,
    grid_dot: Color,
    wire: Color,
    wire_sel: Color,
    wire_endpoint: Color,
    bus: Color,
    inst_body: Color,
    inst_sel: Color,
    inst_pin: Color,
    symbol_line: Color,
    symbol_pin: Color,
    wire_preview: Color,
    origin: Color,

    pub fn dark() Palette {
        const canvas_bg = Color{ .r = 15, .g = 17, .b = 23, .a = 255 };
        const grid_dot = Color{ .r = 47, .g = 47, .b = 51, .a = 90 };
        const wire = Color{ .r = 71, .g = 146, .b = 212, .a = 255 };
        const wire_sel = Color{ .r = 168, .g = 128, .b = 59, .a = 255 };
        const wire_endpoint = Color{ .r = 56, .g = 176, .b = 131, .a = 255 };
        const bus_col = Color{ .r = 70, .g = 180, .b = 170, .a = 255 };
        const inst_body = Color{ .r = 56, .g = 105, .b = 148, .a = 255 };
        const inst_pin = Color{ .r = 214, .g = 205, .b = 142, .a = 255 };
        const symbol_line = Color{ .r = 188, .g = 188, .b = 188, .a = 255 };
        const symbol_pin = Color{ .r = 102, .g = 152, .b = 109, .a = 255 };
        const wire_preview = Color{ .r = 87, .g = 183, .b = 122, .a = 170 };
        const origin = Color{ .r = 110, .g = 110, .b = 110, .a = 160 };

        var result = Palette{
            .canvas_bg = canvas_bg, .grid_dot = grid_dot, .wire = wire, .wire_sel = wire_sel,
            .wire_endpoint = wire_endpoint, .bus = bus_col, .inst_body = inst_body, .inst_sel = wire_sel,
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
        if (ov.wire_selected) |rgb| {
            result.wire_sel = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
            result.inst_sel = result.wire_sel;
        }

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
        const bus_col = if (t.dark) Color{ .r = 70, .g = 180, .b = 170, .a = 255 } else Color{ .r = 30, .g = 120, .b = 115, .a = 255 };

        var result = Palette{
            .canvas_bg = canvas_bg, .grid_dot = grid_dot, .wire = wire, .wire_sel = wire_sel,
            .wire_endpoint = wire_endpoint, .bus = bus_col, .inst_body = inst_body, .inst_sel = wire_sel,
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
        if (ov.wire_selected) |rgb| {
            result.wire_sel = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
            result.inst_sel = result.wire_sel;
        }

        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Color math
// ═══════════════════════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════════════════════
// JSON config — auto-detects old flat vs new nested format
// ═══════════════════════════════════════════════════════════════════════════

pub fn applyJson(alloc: std.mem.Allocator, json_str: []const u8) void {
    // Detect new format by presence of "roles" or "widgets" or "canvas" keys.
    if (isNestedFormat(json_str)) {
        applyNestedJson(alloc, json_str);
    } else {
        applyFlatJson(alloc, json_str);
    }
}

pub fn isNestedFormat(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"roles\"") != null or
        std.mem.indexOf(u8, json, "\"widgets\"") != null or
        std.mem.indexOf(u8, json, "\"canvas\"") != null;
}

// ── New nested format parsing ────────────────────────────────────────────

fn applyNestedJson(alloc: std.mem.Allocator, json_str: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    var cfg = &active_config;

    // Name
    if (root.object.get("name")) |v| {
        if (v == .string) cfg.setName(v.string);
    }
    // Dark
    if (root.object.get("dark")) |v| {
        if (v == .bool) cfg.dark = v.bool;
    }

    // Roles
    if (root.object.get("roles")) |roles_val| {
        if (roles_val == .object) {
            const role_names = [_][]const u8{ "content", "control", "window", "highlight", "err", "canvas", "chrome", "accent" };
            for (role_names, 0..) |rn, ri| {
                if (roles_val.object.get(rn)) |block_val| {
                    cfg.roles[ri] = parseStyleBlockFromValue(block_val);
                }
            }
        }
    }

    // Widgets
    if (root.object.get("widgets")) |widgets_val| {
        if (widgets_val == .object) parseWidgetConfigs(widgets_val, &cfg.widgets);
    }

    // Canvas
    if (root.object.get("canvas")) |canvas_val| {
        if (canvas_val == .object) parseCanvasConfig(canvas_val, &cfg.canvas_config);
    }

    // Also apply flat overrides from the same JSON for chrome colors etc.
    applyFlatJson(alloc, json_str);

    cfg.dirty = true;
}

fn parseWidgetConfigs(widgets_val: std.json.Value, configs: *[WidgetType.count]WidgetConfig) void {
    const wt_names = [WidgetType.count][]const u8{
        "button", "text_input", "checkbox", "dropdown", "slider", "scrollbar",
        "toolbar", "tab", "sidebar_panel", "dialog", "statusbar", "menubar",
        "wire", "pin", "instance_body", "grid", "selection_rect", "net_label",
    };
    for (wt_names, 0..) |wtn, wti| {
        const wobj = widgets_val.object.get(wtn) orelse continue;
        if (wobj != .object) continue;
        configs[wti].base = parseStyleBlockFromValue(wobj);

        if (wobj.object.get("variants")) |vars| {
            if (vars == .object) {
                const var_names = [Variant.count][]const u8{
                    "default", "primary", "secondary", "danger", "ghost",
                    "active", "error", "disabled", "success",
                };
                for (var_names, 0..) |vn, vi| {
                    if (vars.object.get(vn)) |vobj| {
                        configs[wti].variants[vi] = parseStyleBlockFromValue(vobj);
                    }
                }
            }
        }
    }
}

fn parseStyleBlockFromValue(val: std.json.Value) StyleBlock {
    if (val != .object) return .{};
    var sb: StyleBlock = .{};
    if (val.object.get("fill")) |v| sb.fill = parseColor(v);
    if (val.object.get("fill_hover")) |v| sb.fill_hover = parseColor(v);
    if (val.object.get("fill_press")) |v| sb.fill_press = parseColor(v);
    if (val.object.get("text")) |v| sb.text = parseColor(v);
    if (val.object.get("text_hover")) |v| sb.text_hover = parseColor(v);
    if (val.object.get("text_press")) |v| sb.text_press = parseColor(v);
    if (val.object.get("border_color")) |v| sb.border_color = parseColor(v);
    if (val.object.get("corner_radius")) |v| sb.corner_radius = parseF32x4(v);
    if (val.object.get("border_width")) |v| sb.border_width = parseF32x4(v);
    if (val.object.get("margin")) |v| sb.margin = parseF32x4(v);
    if (val.object.get("padding")) |v| sb.padding = parseF32x4(v);
    if (val.object.get("font_size_scale")) |v| sb.font_size_scale = jsonF32(v);
    if (val.object.get("background")) |v| {
        if (v == .bool) sb.background = v.bool;
    }
    if (val.object.get("min_size")) |v| sb.min_size = parseF32x2(v);
    if (val.object.get("max_size")) |v| sb.max_size = parseF32x2(v);
    return sb;
}

fn parseCanvasConfig(canvas_val: std.json.Value, cs: *CanvasStyles) void {
    if (canvas_val.object.get("wire")) |w| {
        if (w == .object) {
            if (w.object.get("color")) |v| if (parseColor(v)) |c| {
                cs.wire.color = c;
            };
            if (w.object.get("color_selected")) |v| if (parseColor(v)) |c| {
                cs.wire.color_selected = c;
            };
            if (w.object.get("stroke_width")) |v| if (jsonF32(v)) |f| {
                cs.wire.stroke_width = f;
            };
            if (w.object.get("style")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "straight")) cs.wire.routing = .straight
                    else if (std.mem.eql(u8, v.string, "curved")) cs.wire.routing = .curved
                    else if (std.mem.eql(u8, v.string, "ortho")) cs.wire.routing = .ortho;
                }
            }
            if (w.object.get("glow_color")) |v| cs.wire.glow_color = parseColor(v);
            if (w.object.get("glow_radius")) |v| if (jsonF32(v)) |f| {
                cs.wire.glow_radius = f;
            };
            if (w.object.get("flow_animation")) |fa| {
                if (fa == .object) {
                    if (fa.object.get("speed")) |v| if (jsonF32(v)) |f| {
                        cs.wire.flow.speed = f;
                    };
                    if (fa.object.get("dash_len")) |v| if (jsonF32(v)) |f| {
                        cs.wire.flow.dash_len = f;
                    };
                    if (fa.object.get("gap_len")) |v| if (jsonF32(v)) |f| {
                        cs.wire.flow.gap_len = f;
                    };
                }
            }
        }
    }
    if (canvas_val.object.get("pin")) |p| {
        if (p == .object) {
            if (p.object.get("color")) |v| if (parseColor(v)) |c| {
                cs.pin.color = c;
            };
            if (p.object.get("radius")) |v| if (jsonF32(v)) |f| {
                cs.pin.radius = f;
            };
            if (p.object.get("shape")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "circle")) cs.pin.shape = .circle
                    else if (std.mem.eql(u8, v.string, "square")) cs.pin.shape = .square
                    else if (std.mem.eql(u8, v.string, "diamond")) cs.pin.shape = .diamond
                    else if (std.mem.eql(u8, v.string, "triangle")) cs.pin.shape = .triangle;
                }
            }
            if (p.object.get("glow_color")) |v| cs.pin.glow_color = parseColor(v);
            if (p.object.get("glow_radius")) |v| if (jsonF32(v)) |f| {
                cs.pin.glow_radius = f;
            };
        }
    }
    if (canvas_val.object.get("grid")) |g| {
        if (g == .object) {
            if (g.object.get("color")) |v| if (parseColor(v)) |c| {
                cs.grid.color = c;
            };
            if (g.object.get("style")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "dots")) cs.grid.pattern = .dots
                    else if (std.mem.eql(u8, v.string, "lines")) cs.grid.pattern = .lines
                    else if (std.mem.eql(u8, v.string, "crosses")) cs.grid.pattern = .crosses;
                }
            }
            if (g.object.get("dot_size")) |v| if (jsonF32(v)) |f| {
                cs.grid.dot_size = f;
            };
        }
    }
    if (canvas_val.object.get("selection_rect")) |s| {
        if (s == .object) {
            if (s.object.get("color")) |v| if (parseColor(v)) |c| {
                cs.selection.color = c;
            };
            if (s.object.get("fill_color")) |v| if (parseColor(v)) |c| {
                cs.selection.fill_color = c;
            };
            if (s.object.get("dash_pattern")) |v| if (parseF32x2(v)) |dp| {
                cs.selection.dash_pattern = dp;
            };
            if (s.object.get("pulse_speed")) |v| if (jsonF32(v)) |f| {
                cs.selection.pulse_speed = f;
            };
            if (s.object.get("glow_color")) |v| cs.selection.glow_color = parseColor(v);
            if (s.object.get("glow_radius")) |v| if (jsonF32(v)) |f| {
                cs.selection.glow_radius = f;
            };
        }
    }
    if (canvas_val.object.get("instance_body")) |ib| {
        if (ib == .object) {
            if (ib.object.get("fill")) |v| if (parseColor(v)) |c| {
                cs.instance.fill = c;
            };
            if (ib.object.get("stroke_color")) |v| if (parseColor(v)) |c| {
                cs.instance.stroke_color = c;
            };
            if (ib.object.get("stroke_width")) |v| if (jsonF32(v)) |f| {
                cs.instance.stroke_width = f;
            };
            if (ib.object.get("label_color")) |v| if (parseColor(v)) |c| {
                cs.instance.label_color = c;
            };
        }
    }
}

// ── Color parsing (hex "#RRGGBB" or array [R,G,B] / [R,G,B,A]) ─────────

fn parseColor(val: std.json.Value) ?Color {
    switch (val) {
        .string => |s| return parseHexColor(s),
        .array => |arr| {
            if (arr.items.len >= 3) {
                const r = jsonU8(arr.items[0]) orelse return null;
                const g = jsonU8(arr.items[1]) orelse return null;
                const b = jsonU8(arr.items[2]) orelse return null;
                const a = if (arr.items.len >= 4) (jsonU8(arr.items[3]) orelse 255) else 255;
                return .{ .r = r, .g = g, .b = b, .a = a };
            }
            return null;
        },
        else => return null,
    }
}

fn parseHexColor(hex: []const u8) ?Color {
    if (hex.len < 7 or hex[0] != '#') return null;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return null;
    const a: u8 = if (hex.len >= 9) (std.fmt.parseInt(u8, hex[7..9], 16) catch 255) else 255;
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn jsonU8(val: std.json.Value) ?u8 {
    return switch (val) {
        .integer => |i| @intCast(std.math.clamp(i, 0, 255)),
        .float => |f| @intFromFloat(std.math.clamp(f, 0, 255)),
        else => null,
    };
}

fn jsonF32(val: std.json.Value) ?f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn parseF32x4(val: std.json.Value) ?[4]f32 {
    switch (val) {
        .array => |arr| {
            if (arr.items.len == 4) {
                return .{
                    jsonF32(arr.items[0]) orelse return null,
                    jsonF32(arr.items[1]) orelse return null,
                    jsonF32(arr.items[2]) orelse return null,
                    jsonF32(arr.items[3]) orelse return null,
                };
            }
            // Single value → all four
            if (arr.items.len == 1) {
                const v = jsonF32(arr.items[0]) orelse return null;
                return .{ v, v, v, v };
            }
            return null;
        },
        .float, .integer => {
            const v = jsonF32(val) orelse return null;
            return .{ v, v, v, v };
        },
        else => return null,
    }
}

fn parseF32x2(val: std.json.Value) ?[2]f32 {
    switch (val) {
        .array => |arr| {
            if (arr.items.len >= 2) {
                return .{
                    jsonF32(arr.items[0]) orelse return null,
                    jsonF32(arr.items[1]) orelse return null,
                };
            }
            return null;
        },
        else => return null,
    }
}

// ── Old flat format parsing (backward compat) ────────────────────────────

fn applyFlatJson(alloc: std.mem.Allocator, json_str: []const u8) void {
    const FlatSchema = struct {
        canvas_bg: ?[3]i64 = null,
        grid_dot: ?[4]i64 = null,
        wire: ?[3]i64 = null,
        wire_selected: ?[3]i64 = null,
        wire_endpoint: ?[3]i64 = null,
        instance_body: ?[3]i64 = null,
        instance_pin: ?[3]i64 = null,
        symbol_line: ?[3]i64 = null,
        symbol_pin: ?[3]i64 = null,
        wire_preview: ?[4]i64 = null,
        origin: ?[4]i64 = null,
        sidebar_bg: ?[3]i64 = null,
        bottombar_bg: ?[3]i64 = null,
        toolbar_bg: ?[3]i64 = null,
        tabbar_bg: ?[3]i64 = null,
        tab_active_bg: ?[3]i64 = null,
        statusbar_bg: ?[3]i64 = null,
        text_primary: ?[3]i64 = null,
        text_secondary: ?[3]i64 = null,
        accent: ?[3]i64 = null,
        separator: ?[3]i64 = null,
        hover_bg: ?[3]i64 = null,
        corner_radius: ?f64 = null,
        border_width: ?f64 = null,
        button_padding_h: ?f64 = null,
        button_padding_v: ?f64 = null,
        wire_width: ?f64 = null,
        grid_dot_size: ?f64 = null,
        tab_shape: ?i64 = null,
        toolbar_height: ?f64 = null,
        tabbar_height: ?f64 = null,
        statusbar_height: ?f64 = null,
        name: ?[]const u8 = null,
        dark: ?bool = null,
    };
    const parsed = std.json.parseFromSlice(FlatSchema, alloc, json_str, .{
        .ignore_unknown_fields = true,
    }) catch return;
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

    // Also populate active_config from flat overrides.
    if (v.name) |n| active_config.setName(n);
    if (v.dark) |d| active_config.dark = d;
    if (v.wire_width) |w| active_config.canvas_config.wire.stroke_width = @floatCast(w);
    if (v.grid_dot_size) |s| active_config.canvas_config.grid.dot_size = @floatCast(s);
    active_config.dirty = true;
}

fn clamp8(x: i64) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}

// ═══════════════════════════════════════════════════════════════════════════
// Embedded preset themes
// ═══════════════════════════════════════════════════════════════════════════

pub const PresetTheme = struct {
    name: []const u8,
    dark: bool,
    canvas: CanvasStyles,
    chrome: struct {
        toolbar_bg: ?[3]u8 = null,
        tabbar_bg: ?[3]u8 = null,
        tab_active_bg: ?[3]u8 = null,
        statusbar_bg: ?[3]u8 = null,
        sidebar_bg: ?[3]u8 = null,
        text_primary: ?[3]u8 = null,
        text_secondary: ?[3]u8 = null,
        accent: ?[3]u8 = null,
        separator: ?[3]u8 = null,
        hover_bg: ?[3]u8 = null,
    } = .{},
};

pub const builtin_presets = [_]PresetTheme{
    // Schemify Dark (default)
    .{
        .name = "Schemify Dark",
        .dark = true,
        .canvas = .{},
    },
    // Schemify Neon
    .{
        .name = "Schemify Neon",
        .dark = true,
        .canvas = .{
            .wire = .{
                .color = .{ .r = 0, .g = 255, .b = 170, .a = 255 },
                .color_selected = .{ .r = 255, .g = 100, .b = 200, .a = 255 },
                .stroke_width = 1.5,
                .flow = .{ .speed = 40, .dash_len = 10, .gap_len = 5 },
            },
            .pin = .{ .color = .{ .r = 255, .g = 255, .b = 0, .a = 255 }, .shape = .diamond },
            .grid = .{ .color = .{ .r = 20, .g = 80, .b = 60, .a = 80 }, .dot_size = 0.8 },
            .selection = .{
                .color = .{ .r = 255, .g = 0, .b = 255, .a = 200 },
                .fill_color = .{ .r = 255, .g = 0, .b = 255, .a = 20 },
                .pulse_speed = 3.0,
            },
        },
        .chrome = .{
            .toolbar_bg = .{ 15, 15, 25 },
            .accent = .{ 0, 255, 170 },
            .text_primary = .{ 200, 255, 230 },
        },
    },
    // Schemify Paper
    .{
        .name = "Schemify Paper",
        .dark = false,
        .canvas = .{
            .wire = .{
                .color = .{ .r = 30, .g = 80, .b = 150, .a = 255 },
                .color_selected = .{ .r = 200, .g = 80, .b = 0, .a = 255 },
                .stroke_width = 1.2,
            },
            .pin = .{ .color = .{ .r = 160, .g = 140, .b = 60, .a = 255 } },
            .instance = .{
                .fill = .{ .r = 60, .g = 100, .b = 160, .a = 255 },
                .stroke_color = .{ .r = 40, .g = 40, .b = 40, .a = 255 },
                .label_color = .{ .r = 60, .g = 60, .b = 60, .a = 200 },
            },
            .grid = .{ .color = .{ .r = 180, .g = 180, .b = 200, .a = 100 } },
            .selection = .{
                .color = .{ .r = 30, .g = 80, .b = 150, .a = 180 },
                .fill_color = .{ .r = 30, .g = 80, .b = 150, .a = 25 },
            },
        },
        .chrome = .{
            .toolbar_bg = .{ 235, 235, 240 },
            .tabbar_bg = .{ 225, 225, 230 },
            .tab_active_bg = .{ 245, 245, 250 },
            .statusbar_bg = .{ 230, 230, 235 },
            .sidebar_bg = .{ 240, 240, 245 },
            .text_primary = .{ 30, 30, 40 },
            .text_secondary = .{ 100, 100, 115 },
            .accent = .{ 30, 80, 150 },
            .separator = .{ 200, 200, 210 },
            .hover_bg = .{ 210, 215, 230 },
        },
    },
};

/// Apply a builtin preset to the active config + overrides.
pub fn applyBuiltinPreset(idx: usize) void {
    if (idx >= builtin_presets.len) return;
    const preset = &builtin_presets[idx];

    active_config = .{};
    active_config.setName(preset.name);
    active_config.dark = preset.dark;
    active_config.canvas_config = preset.canvas;

    // Apply chrome colors to flat overrides.
    const ch = &preset.chrome;
    current_overrides = .{};
    current_overrides.toolbar_bg = ch.toolbar_bg;
    current_overrides.tabbar_bg = ch.tabbar_bg;
    current_overrides.tab_active_bg = ch.tab_active_bg;
    current_overrides.statusbar_bg = ch.statusbar_bg;
    current_overrides.sidebar_bg = ch.sidebar_bg;
    current_overrides.text_primary = ch.text_primary;
    current_overrides.text_secondary = ch.text_secondary;
    current_overrides.accent = ch.accent;
    current_overrides.separator = ch.separator;
    current_overrides.hover_bg = ch.hover_bg;

    active_config.dirty = true;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "StyleBlock overlay" {
    const base = StyleBlock{
        .fill = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
        .corner_radius = .{ 4, 4, 4, 4 },
    };
    const over = StyleBlock{
        .fill = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .text = .{ .r = 100, .g = 100, .b = 100, .a = 255 },
    };
    const result = over.overlay(base);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0, .a = 255 }, result.fill.?);
    try std.testing.expectEqual(Color{ .r = 100, .g = 100, .b = 100, .a = 255 }, result.text.?);
    try std.testing.expectEqual([4]f32{ 4, 4, 4, 4 }, result.corner_radius.?);
}

test "StyleBlock toDvuiOptions" {
    const sb = StyleBlock{
        .fill = .{ .r = 50, .g = 60, .b = 70, .a = 255 },
        .padding = .{ 8, 4, 8, 4 },
        .background = true,
    };
    const opts = sb.toDvuiOptions();
    try std.testing.expectEqual(Color{ .r = 50, .g = 60, .b = 70, .a = 255 }, opts.color_fill.?);
    try std.testing.expect(opts.background.?);
}

test "AnimationState tick" {
    var anim = AnimationState{};
    var canvas = CanvasStyles{};
    canvas.wire.flow.speed = 30;
    canvas.selection.pulse_speed = 2.0;
    anim.tick(0.016, &canvas);
    try std.testing.expect(anim.flow_phase > 0);
    try std.testing.expect(anim.selection_pulse > 0);
}

test "parseHexColor" {
    const c = parseHexColor("#4792d4").?;
    try std.testing.expectEqual(@as(u8, 0x47), c.r);
    try std.testing.expectEqual(@as(u8, 0x92), c.g);
    try std.testing.expectEqual(@as(u8, 0xd4), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parseHexColor with alpha" {
    const c = parseHexColor("#ff0000aa").?;
    try std.testing.expectEqual(@as(u8, 0xff), c.r);
    try std.testing.expectEqual(@as(u8, 0xaa), c.a);
}

test "isNestedFormat detection" {
    try std.testing.expect(isNestedFormat("{\"roles\":{}}"));
    try std.testing.expect(isNestedFormat("{\"widgets\":{\"button\":{}}}"));
    try std.testing.expect(isNestedFormat("{\"canvas\":{\"wire\":{}}}"));
    try std.testing.expect(!isNestedFormat("{\"wire\":[71,146,212]}"));
}

test "flat JSON backward compat" {
    const json =
        \\{"wire":[100,200,255],"corner_radius":8.0}
    ;
    applyFlatJson(std.testing.allocator, json);
    try std.testing.expectEqual([3]u8{ 100, 200, 255 }, current_overrides.wire.?);
    try std.testing.expectEqual(@as(f32, 8.0), current_overrides.corner_radius.?);
}

test "builtin presets" {
    try std.testing.expect(builtin_presets.len >= 3);
    try std.testing.expect(std.mem.eql(u8, builtin_presets[0].name, "Schemify Dark"));
    try std.testing.expect(builtin_presets[2].dark == false);
}
