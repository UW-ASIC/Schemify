const std = @import("std");
const html2dvui = @import("html2dvui");

test "types: Color fromU32 round-trip" {
    const original: u32 = 0xFF8040C0;
    const color = html2dvui.Color.fromU32(original);
    try std.testing.expectEqual(@as(u8, 0xFF), color.r);
    try std.testing.expectEqual(@as(u8, 0x80), color.g);
    try std.testing.expectEqual(@as(u8, 0x40), color.b);
    try std.testing.expectEqual(@as(u8, 0xC0), color.a);
    try std.testing.expectEqual(original, color.toU32());
}

test "types: Rect contains" {
    const r = html2dvui.Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(50, 40));
    try std.testing.expect(!r.contains(5, 40));
    try std.testing.expect(!r.contains(50, 80));
}

test "types: Rect intersects" {
    const a = html2dvui.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b = html2dvui.Rect{ .x = 50, .y = 50, .w = 100, .h = 100 };
    const c = html2dvui.Rect{ .x = 200, .y = 200, .w = 10, .h = 10 };
    try std.testing.expect(a.intersects(b));
    try std.testing.expect(!a.intersects(c));
}

test "container: init and draw commands" {
    const alloc = std.testing.allocator;
    var ctr = html2dvui.Container.init(alloc);
    defer ctr.deinit();

    ctr.drawText(10, 20, "hello", html2dvui.Color.black, .{});
    ctr.drawBackground(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, html2dvui.Color.white);
    ctr.drawBorders(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, html2dvui.Color.black, 1.0);

    const cmds = ctr.getCommands();
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
}

test "container: reset clears commands" {
    const alloc = std.testing.allocator;
    var ctr = html2dvui.Container.init(alloc);
    defer ctr.deinit();

    ctr.drawText(0, 0, "test", html2dvui.Color.black, .{});
    try std.testing.expectEqual(@as(usize, 1), ctr.getCommands().len);

    ctr.reset();
    try std.testing.expectEqual(@as(usize, 0), ctr.getCommands().len);
}

test "container: getTextWidth approximation" {
    const alloc = std.testing.allocator;
    var ctr = html2dvui.Container.init(alloc);
    defer ctr.deinit();
    const w = ctr.getTextWidth("hello", .{ .size = 10.0, .monospace = true });
    // 5 chars * 10.0 * 0.6 = 30.0 (monospace)
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), w, 0.01);
}

test "container: textHeight approximation" {
    const alloc = std.testing.allocator;
    var ctr = html2dvui.Container.init(alloc);
    defer ctr.deinit();
    const h = ctr.textHeight(.{ .size = 20.0 });
    // 20.0 * 1.2 = 24.0
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), h, 0.01);
}

test "Document: full pipeline with real litehtml" {
    const alloc = std.testing.allocator;
    var doc = html2dvui.Document.create(alloc, "<div>test</div>", "div { color: red; }");
    defer doc.destroy();

    try std.testing.expect(doc.needs_layout);
    doc.layout(400);
    try std.testing.expect(!doc.needs_layout);

    const cmds = doc.draw(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    // litehtml should produce at least one draw command (text or background)
    try std.testing.expect(cmds.len > 0);
}

test "Document: paragraph text produces text commands" {
    const alloc = std.testing.allocator;
    var doc = html2dvui.Document.create(alloc, "<p>Hello World</p>", "");
    defer doc.destroy();
    doc.layout(800);
    const cmds = doc.draw(.{ .x = 0, .y = 0, .w = 800, .h = 600 });

    // Should contain at least one text command
    var has_text = false;
    for (cmds) |cmd| {
        switch (cmd) {
            .text => {
                has_text = true;
                break;
            },
            else => {},
        }
    }
    try std.testing.expect(has_text);
}

test "Document: onMouseMove returns null when not over link" {
    const alloc = std.testing.allocator;
    var doc = html2dvui.Document.create(alloc, "<p>hi</p>", "");
    defer doc.destroy();
    doc.layout(400);
    _ = doc.draw(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    const result = doc.onMouseMove(10, 10);
    try std.testing.expectEqual(@as(?html2dvui.HitResult, null), result);
}

test "Document: empty HTML does not crash" {
    const alloc = std.testing.allocator;
    var doc = html2dvui.Document.create(alloc, "", "");
    defer doc.destroy();
    doc.layout(400);
    _ = doc.draw(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
}

test "Document: deeply nested divs (stress)" {
    const alloc = std.testing.allocator;
    // Build nested HTML: 64 levels deep
    var html_buf: [8192]u8 = undefined;
    var pos: usize = 0;
    for (0..64) |_| {
        const open = "<div>";
        @memcpy(html_buf[pos .. pos + open.len], open);
        pos += open.len;
    }
    const text = "content";
    @memcpy(html_buf[pos .. pos + text.len], text);
    pos += text.len;
    for (0..64) |_| {
        const close = "</div>";
        @memcpy(html_buf[pos .. pos + close.len], close);
        pos += close.len;
    }

    var doc = html2dvui.Document.create(alloc, html_buf[0..pos], "");
    defer doc.destroy();
    doc.layout(600);
    const cmds = doc.draw(.{ .x = 0, .y = 0, .w = 600, .h = 2000 });
    try std.testing.expect(cmds.len > 0);
}

test "render convenience function" {
    const alloc = std.testing.allocator;
    const cmds = html2dvui.render(alloc, "<p>hello</p>", "", .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try std.testing.expect(cmds.len > 0);
}
