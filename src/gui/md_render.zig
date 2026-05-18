const std = @import("std");
const dvui = @import("dvui");
const tc = @import("theme_config");
const markdown = @import("schematic").markdown;
const math_render = @import("math_render.zig");

const Font = dvui.Font;
const Color = dvui.Color;

// Font sizes relative to base
const base_size: f32 = 14;
const h1_size: f32 = 24;
const h2_size: f32 = 20;
const h3_size: f32 = 16;

fn fontFor(kind: markdown.SpanKind) Font {
    return switch (kind) {
        .bold => Font.find(.{ .family = "Vera Sans", .size = base_size, .weight = .bold }),
        .italic => Font.find(.{ .family = "Vera Sans", .size = base_size, .style = .italic }),
        .code, .math_inline => Font.find(.{ .family = "Vera Sans", .size = base_size - 1 }),
        else => Font.find(.{ .family = "Vera Sans", .size = base_size }),
    };
}

fn colorFor(kind: markdown.SpanKind) Color {
    return switch (kind) {
        .code => tc.chromeAccent(),
        .math_inline => tc.chromeAccent(),
        .link => dvui.Color{ .r = 100, .g = 160, .b = 255, .a = 255 },
        else => tc.chromeTextPrimary(),
    };
}

fn headingFont(kind: markdown.BlockKind) Font {
    const size: f32 = switch (kind) {
        .heading1 => h1_size,
        .heading2 => h2_size,
        .heading3 => h3_size,
        else => base_size,
    };
    return Font.find(.{ .family = "Vera Sans", .size = size, .weight = .bold });
}

/// Render parsed markdown blocks into a dvui scroll area.
/// Call this inside an existing scroll area or vertical box.
pub fn render(text: []const u8) void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const blocks = markdown.parse(arena, text);

    for (blocks, 0..) |block, i| {
        const id_base: u16 = @intCast(i & 0xFFFF);
        switch (block.kind) {
            .heading1, .heading2, .heading3 => renderHeading(block, id_base),
            .paragraph => renderParagraph(block.spans, id_base),
            .code_block => renderCodeBlock(block, id_base),
            .math_display => renderMathDisplay(block, id_base),
            .list_item => renderListItem(block, id_base),
            .blockquote => renderBlockquote(block, id_base),
            .horizontal_rule => renderHorizontalRule(id_base),
        }
    }
}

fn renderHeading(block: markdown.Block, id_base: u16) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = id_base *% 7 +% 1000 });

    const font = headingFont(block.kind);
    if (block.spans.len > 0) {
        renderSpansWithFont(block.spans, font, id_base);
    } else {
        dvui.labelNoFmt(@src(), block.raw, .{}, .{
            .id_extra = id_base *% 7 +% 1001,
            .font = font,
            .color_text = tc.chromeTextPrimary(),
        });
    }

    if (block.kind == .heading1) {
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = id_base *% 7 +% 1002 });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = id_base *% 7 +% 1003 });
}

fn renderParagraph(spans: []const markdown.Span, id_base: u16) void {
    if (spans.len == 0) return;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = id_base *% 7 +% 2000 });
    renderSpans(spans, id_base);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = id_base *% 7 +% 2001 });
}

fn renderCodeBlock(block: markdown.Block, id_base: u16) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = id_base *% 7 +% 3000 });
    {
        var code_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id_base *% 7 +% 3001,
            .expand = .horizontal,
            .background = true,
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
            .color_fill = dvui.Color{ .r = 30, .g = 32, .b = 40, .a = 255 },
        });
        defer code_box.deinit();

        const mono = Font.find(.{ .family = "Vera Sans", .size = base_size - 1 });
        dvui.labelNoFmt(@src(), block.raw, .{}, .{
            .id_extra = id_base *% 7 +% 3002,
            .font = mono,
            .color_text = dvui.Color{ .r = 200, .g = 210, .b = 230, .a = 255 },
            .expand = .horizontal,
        });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = id_base *% 7 +% 3003 });
}

fn renderMathDisplay(block: markdown.Block, id_base: u16) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = id_base *% 7 +% 4000 });
    math_render.renderDisplay(block.raw, id_base *% 7 +% 4001);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = id_base *% 7 +% 4005 });
}

fn renderListItem(block: markdown.Block, id_base: u16) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_base *% 7 +% 5000,
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 2, .w = 0, .h = 2 },
    });
    defer row.deinit();

    dvui.labelNoFmt(@src(), "\xe2\x80\xa2 ", .{}, .{
        .id_extra = id_base *% 7 +% 5001,
        .color_text = tc.chromeTextSecondary(),
    });

    if (block.spans.len > 0) {
        renderSpans(block.spans, id_base *% 3 +% 5100);
    } else {
        dvui.labelNoFmt(@src(), block.raw, .{}, .{
            .id_extra = id_base *% 7 +% 5002,
            .color_text = tc.chromeTextPrimary(),
        });
    }
}

fn renderBlockquote(block: markdown.Block, id_base: u16) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_base *% 7 +% 6000,
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer row.deinit();

    // Accent bar
    {
        var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id_base *% 7 +% 6001,
            .min_size_content = .{ .w = 3 },
            .expand = .vertical,
            .background = true,
            .corner_radius = dvui.Rect.all(2),
            .color_fill = tc.chromeAccent(),
        });
        bar.deinit();
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = id_base *% 7 +% 6002 });

    if (block.spans.len > 0) {
        renderSpans(block.spans, id_base *% 3 +% 6100);
    } else {
        dvui.labelNoFmt(@src(), block.raw, .{}, .{
            .id_extra = id_base *% 7 +% 6003,
            .color_text = tc.chromeTextSecondary(),
            .font = Font.find(.{ .family = "Vera Sans", .size = base_size, .style = .italic }),
        });
    }
}

fn renderHorizontalRule(id_base: u16) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = id_base *% 7 +% 7000 });
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = id_base *% 7 +% 7001 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = id_base *% 7 +% 7002 });
}

fn renderSpans(spans: []const markdown.Span, id_base: u16) void {
    for (spans, 0..) |span, j| {
        const id: u16 = id_base *% 7 +% @as(u16, @intCast(j & 0xFF)) +% 8000;
        if (span.kind == .math_inline) {
            math_render.renderInline(span.text, id);
        } else {
            dvui.labelNoFmt(@src(), span.text, .{}, .{
                .id_extra = id,
                .font = fontFor(span.kind),
                .color_text = colorFor(span.kind),
            });
        }
    }
}

fn renderSpansWithFont(spans: []const markdown.Span, heading_font: Font, id_base: u16) void {
    for (spans, 0..) |span, j| {
        const id: u16 = id_base *% 7 +% @as(u16, @intCast(j & 0xFF)) +% 9000;
        if (span.kind == .math_inline) {
            math_render.renderInline(span.text, id);
        } else {
            const font = switch (span.kind) {
                .code => Font.find(.{ .family = "Vera Sans", .size = heading_font.size - 1 }),
                else => heading_font,
            };
            dvui.labelNoFmt(@src(), span.text, .{}, .{
                .id_extra = id,
                .font = font,
                .color_text = colorFor(span.kind),
            });
        }
    }
}
