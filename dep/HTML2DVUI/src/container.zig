const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const DrawCommand = types.DrawCommand;
const Rect = types.Rect;
const Color = types.Color;
const FontHandle = types.FontHandle;

const c = @import("c.zig").bridge;

/// Container that bridges litehtml's C callbacks to a list of DrawCommands.
///
/// When litehtml calls draw_text/draw_background/draw_borders during its
/// draw() pass, those calls are forwarded through c_bridge.cpp into the
/// callback function pointers in this struct. Each callback appends a
/// DrawCommand to the internal array.
///
/// The Container also manages the font table (two-font model: monospace vs
/// proportional) and provides text measurement for litehtml layout.
pub const Container = struct {
    draw_commands: std.ArrayListUnmanaged(DrawCommand),
    alloc: Allocator,
    fonts: std.ArrayListUnmanaged(FontHandle),
    viewport: Rect,

    /// Last anchor URL clicked (stored for hit-test results).
    last_anchor_url: ?[]const u8,
    /// Current cursor string from litehtml.
    cursor: ?[]const u8,

    pub fn init(alloc: Allocator) Container {
        return .{
            .draw_commands = .{},
            .alloc = alloc,
            .fonts = .{},
            .viewport = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
            .last_anchor_url = null,
            .cursor = null,
        };
    }

    pub fn deinit(self: *Container) void {
        self.draw_commands.deinit(self.alloc);
        self.fonts.deinit(self.alloc);
    }

    pub fn reset(self: *Container) void {
        self.draw_commands.clearRetainingCapacity();
        self.last_anchor_url = null;
        self.cursor = null;
    }

    pub fn getCommands(self: *const Container) []const DrawCommand {
        return self.draw_commands.items;
    }

    /// Build the C callback struct that points back to this Container instance.
    pub fn getCallbacks(self: *Container) c.lh_callbacks_t {
        return .{
            .user_data = @ptrCast(self),
            .create_font = &cbCreateFont,
            .delete_font = &cbDeleteFont,
            .text_width = &cbTextWidth,
            .draw_text = &cbDrawText,
            .draw_background = &cbDrawBackground,
            .draw_borders = &cbDrawBorders,
            .draw_image = &cbDrawImage,
            .draw_list_marker = &cbDrawListMarker,
            .set_clip = &cbSetClip,
            .del_clip = &cbDelClip,
            .get_client_rect = &cbGetClientRect,
            .on_anchor_click = &cbOnAnchorClick,
            .set_cursor = &cbSetCursor,
        };
    }

    // ── Direct draw methods (for backward compatibility with tests) ──────────

    pub fn drawText(self: *Container, x: f32, y: f32, text: []const u8, color: Color, font: FontHandle) void {
        self.draw_commands.append(self.alloc, .{ .text = .{
            .x = x,
            .y = y,
            .content = text,
            .color = color,
            .font = font,
        } }) catch {};
    }

    pub fn drawBackground(self: *Container, rect: Rect, color: Color) void {
        self.draw_commands.append(self.alloc, .{ .rect_fill = .{
            .rect = rect,
            .color = color,
        } }) catch {};
    }

    pub fn drawBorders(self: *Container, rect: Rect, color: Color, width: f32) void {
        self.draw_commands.append(self.alloc, .{ .rect_stroke = .{
            .rect = rect,
            .color = color,
            .width = width,
        } }) catch {};
    }

    /// Approximate text width based on character count and font size.
    pub fn getTextWidth(_: *Container, text: []const u8, font: FontHandle) f32 {
        const char_width: f32 = if (font.monospace) font.size * 0.6 else font.size * 0.55;
        return @as(f32, @floatFromInt(text.len)) * char_width;
    }

    /// Approximate text height (line height).
    pub fn textHeight(_: *Container, font: FontHandle) f32 {
        return font.size * 1.2;
    }

    // ── C callback implementations (static, called from litehtml via c_bridge) ──

    fn getSelf(ud: ?*anyopaque) *Container {
        return @ptrCast(@alignCast(ud.?));
    }

    fn cbCreateFont(
        ud: ?*anyopaque,
        face: [*c]const u8,
        size: c_int,
        weight: c_int,
        italic: c_int,
        _: c_uint, // decoration
        out_height: [*c]c_int,
        out_ascent: [*c]c_int,
        out_descent: [*c]c_int,
        out_x_height: [*c]c_int,
        out_draw_spaces: [*c]c_int,
    ) callconv(.c) c_int {
        const self = getSelf(ud);

        // Two-font model: detect monospace from face name
        const monospace = isMonospace(face);
        const font = FontHandle{
            .monospace = monospace,
            .size = @floatFromInt(size),
            .bold = weight >= 600,
            .italic = italic != 0,
        };

        // Store font and return its index as the handle
        const font_id: c_int = @intCast(self.fonts.items.len + 1);
        self.fonts.append(self.alloc, font) catch {};

        // Fill metrics
        const h: c_int = @intFromFloat(font.size * 1.2);
        const asc: c_int = @intFromFloat(font.size * 0.8);
        const desc: c_int = @intFromFloat(font.size * 0.2);
        const xh: c_int = @intFromFloat(font.size * 0.5);
        if (out_height != null) out_height.* = h;
        if (out_ascent != null) out_ascent.* = asc;
        if (out_descent != null) out_descent.* = desc;
        if (out_x_height != null) out_x_height.* = xh;
        if (out_draw_spaces != null) out_draw_spaces.* = 1;

        return font_id;
    }

    fn cbDeleteFont(_: ?*anyopaque, _: c_int) callconv(.c) void {
        // Fonts are arena-managed, no individual deallocation needed
    }

    fn cbTextWidth(ud: ?*anyopaque, text: [*c]const u8, font_id: c_int) callconv(.c) c_int {
        const self = getSelf(ud);
        const font = self.getFontById(font_id);
        const len = std.mem.len(text);
        const char_width: f32 = if (font.monospace) font.size * 0.6 else font.size * 0.55;
        return @intFromFloat(@as(f32, @floatFromInt(len)) * char_width);
    }

    fn cbDrawText(
        ud: ?*anyopaque,
        text: [*c]const u8,
        font_id: c_int,
        color: u32,
        x: c_int,
        y: c_int,
        _: c_int, // w
        _: c_int, // h
    ) callconv(.c) void {
        const self = getSelf(ud);
        const font = self.getFontById(font_id);
        const text_slice = std.mem.span(text);
        self.draw_commands.append(self.alloc, .{ .text = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .content = text_slice,
            .color = Color.fromU32(color),
            .font = font,
        } }) catch {};
    }

    fn cbDrawBackground(
        ud: ?*anyopaque,
        color: u32,
        x: c_int,
        y: c_int,
        w: c_int,
        h: c_int,
        _: c_int, // clip_x
        _: c_int, // clip_y
        _: c_int, // clip_w
        _: c_int, // clip_h
    ) callconv(.c) void {
        const self = getSelf(ud);
        self.draw_commands.append(self.alloc, .{ .rect_fill = .{
            .rect = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .w = @floatFromInt(w),
                .h = @floatFromInt(h),
            },
            .color = Color.fromU32(color),
        } }) catch {};
    }

    fn cbDrawBorders(
        ud: ?*anyopaque,
        color_top: u32,
        _: c_int, // width_top (unused — we use a single representative)
        _: u32, // color_right
        _: c_int, // width_right
        _: u32, // color_bottom
        _: c_int, // width_bottom
        _: u32, // color_left
        width_left: c_int,
        x: c_int,
        y: c_int,
        w: c_int,
        h: c_int,
    ) callconv(.c) void {
        const self = getSelf(ud);
        // Use top border color as representative for the stroke command
        self.draw_commands.append(self.alloc, .{ .rect_stroke = .{
            .rect = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .w = @floatFromInt(w),
                .h = @floatFromInt(h),
            },
            .color = Color.fromU32(color_top),
            .width = @floatFromInt(width_left),
        } }) catch {};
    }

    fn cbDrawImage(
        ud: ?*anyopaque,
        src: [*c]const u8,
        x: c_int,
        y: c_int,
        w: c_int,
        h: c_int,
    ) callconv(.c) void {
        const self = getSelf(ud);
        const src_slice = std.mem.span(src);
        self.draw_commands.append(self.alloc, .{ .image = .{
            .rect = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .w = @floatFromInt(w),
                .h = @floatFromInt(h),
            },
            .data = src_slice,
        } }) catch {};
    }

    fn cbDrawListMarker(
        ud: ?*anyopaque,
        color: u32,
        x: c_int,
        y: c_int,
        w: c_int,
        h: c_int,
    ) callconv(.c) void {
        const self = getSelf(ud);
        self.draw_commands.append(self.alloc, .{ .rect_fill = .{
            .rect = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .w = @floatFromInt(w),
                .h = @floatFromInt(h),
            },
            .color = Color.fromU32(color),
        } }) catch {};
    }

    fn cbSetClip(ud: ?*anyopaque, x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
        const self = getSelf(ud);
        self.draw_commands.append(self.alloc, .{ .clip = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
        } }) catch {};
    }

    fn cbDelClip(ud: ?*anyopaque) callconv(.c) void {
        const self = getSelf(ud);
        self.draw_commands.append(self.alloc, .{ .clip_end = {} }) catch {};
    }

    fn cbGetClientRect(ud: ?*anyopaque, x: [*c]c_int, y: [*c]c_int, w: [*c]c_int, h: [*c]c_int) callconv(.c) void {
        const self = getSelf(ud);
        if (x != null) x.* = @intFromFloat(self.viewport.x);
        if (y != null) y.* = @intFromFloat(self.viewport.y);
        if (w != null) w.* = @intFromFloat(self.viewport.w);
        if (h != null) h.* = @intFromFloat(self.viewport.h);
    }

    fn cbOnAnchorClick(ud: ?*anyopaque, url: [*c]const u8) callconv(.c) void {
        const self = getSelf(ud);
        self.last_anchor_url = std.mem.span(url);
    }

    fn cbSetCursor(ud: ?*anyopaque, cursor_str: [*c]const u8) callconv(.c) void {
        const self = getSelf(ud);
        self.cursor = std.mem.span(cursor_str);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fn getFontById(self: *const Container, font_id: c_int) FontHandle {
        const idx = @as(usize, @intCast(font_id)) -| 1;
        if (idx < self.fonts.items.len) {
            return self.fonts.items[idx];
        }
        return .{}; // default font
    }

    /// Detect monospace fonts from CSS font-family name.
    fn isMonospace(face: [*c]const u8) bool {
        const name = std.mem.span(face);
        const mono_families = [_][]const u8{
            "monospace", "Courier", "Consolas", "Fira Code",
            "Monaco", "Menlo", "DejaVu Sans Mono", "Liberation Mono",
            "Source Code Pro", "JetBrains Mono", "IBM Plex Mono",
        };
        for (&mono_families) |family| {
            if (std.ascii.indexOfIgnoreCase(name, family) != null) return true;
        }
        return false;
    }
};
