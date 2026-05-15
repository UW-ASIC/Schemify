pub const types = @import("types.zig");
pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");
pub const Framework = @import("Framework.zig");
pub const PluginHost = @import("PluginHost.zig");
pub const Capability = @import("Capability.zig");
pub const PluginManager = @import("PluginManager.zig").PluginManager;
pub const PluginSpec = @import("PluginManager.zig").PluginSpec;
pub const Runtime = @import("Runtime.zig").Runtime;
pub const HostCallbacks = @import("Runtime.zig").HostCallbacks;

pub const Tag = types.Tag;
pub const InMsg = types.InMsg;
pub const PanelDef = types.PanelDef;
pub const PanelLayout = types.PanelLayout;
pub const Descriptor = types.Descriptor;
pub const ProcessFn = types.ProcessFn;
pub const ParsedWidget = types.ParsedWidget;
pub const WidgetTag = types.WidgetTag;
pub const ABI_VERSION = types.ABI_VERSION;

const std = @import("std");

test "Reader round-trip: load message" {
    var buf: [64]u8 = undefined;
    buf[0] = 0x01;
    std.mem.writeInt(u16, buf[1..3], 6, .little);
    std.mem.writeInt(u16, buf[3..5], 4, .little);
    @memcpy(buf[5..9], "test");
    var r = Reader.init(buf[0..9]);
    const msg = r.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("test", msg.load.project_dir);
    try std.testing.expect(r.next() == null);
}

test "Writer round-trip: setStatus" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    w.setStatus("hello");
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, buf[1..3], .little));
    try std.testing.expectEqualStrings("hello", buf[5..10]);
    try std.testing.expect(!w.overflow());
}

test "Writer overflow flag" {
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    w.setStatus("this is way too long for a 2-byte buffer");
    try std.testing.expect(w.overflow());
}

test "Reader skips plugin->host tags" {
    var buf: [64]u8 = undefined;
    buf[0] = 0x80;
    std.mem.writeInt(u16, buf[1..3], 0, .little);
    buf[3] = 0x03;
    std.mem.writeInt(u16, buf[4..6], 4, .little);
    std.mem.writeInt(u32, buf[6..10], @as(u32, @bitCast(@as(f32, 1.0))), .little);
    var r = Reader.init(buf[0..10]);
    const msg = r.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 1.0), msg.tick.dt);
    try std.testing.expect(r.next() == null);
}

comptime {
    _ = @import("types.zig");
    _ = @import("Reader.zig");
    _ = @import("Writer.zig");
    _ = @import("PluginHost.zig");
    _ = Capability;
}
