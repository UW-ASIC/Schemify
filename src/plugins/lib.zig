//! Plugin module root.
//!
//! Re-exports the plugin runtime, installer, ABI protocol types (formerly
//! PluginIF), and widget types.  Everything else in `types.zig` is
//! module-internal.

const std = @import("std");

// -- Runtime & Installer ------------------------------------------------------

pub const Runtime = @import("runtime.zig").Runtime;

const installer = @import("installer.zig");
pub const Installer = installer.Installer;
pub const InstallError = installer.InstallError;
pub const InstallOptions = installer.InstallOptions;
pub const Target = installer.Target;
pub const install = installer.install;

// -- ABI v6 Protocol (formerly PluginIF) --------------------------------------

const types = @import("types.zig");

// Constants
pub const EXPORT_SYMBOL = types.EXPORT_SYMBOL;
pub const HEADER_SZ = types.HEADER_SZ;
pub const U16_SZ = types.U16_SZ;
pub const U32_SZ = types.U32_SZ;
pub const ABI_VERSION = types.ABI_VERSION;

// Enums & data types
pub const PanelLayout = types.PanelLayout;
pub const LogLevel = types.LogLevel;
pub const PanelDef = types.PanelDef;
pub const ProcessFn = types.ProcessFn;
pub const Descriptor = types.Descriptor;
pub const Tag = types.Tag;
pub const InMsg = types.InMsg;

// Core structs
pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");
pub const Framework = @import("Framework.zig");

// Widget types
pub const ParsedWidget = types.ParsedWidget;
pub const WidgetTag = types.WidgetTag;

// ── Tests ───────────────────────────────────────────────────────────────────

test "ParsedWidget field order is data-oriented (largest alignment first)" {
    const pw_size = @sizeOf(ParsedWidget);
    try std.testing.expect(pw_size <= 40);
}

test "Descriptor size" {
    std.debug.print("Descriptor: {d}B\n", .{@sizeOf(Descriptor)});
}

test "Reader size" {
    std.debug.print("Reader: {d}B\n", .{@sizeOf(Reader)});
}

test "Writer size" {
    std.debug.print("Writer: {d}B\n", .{@sizeOf(Writer)});
}

test "Expose struct size for Runtime" {
    std.debug.print("Runtime: {d}B\n", .{@sizeOf(Runtime)});
}

test "Expose struct size for ParsedWidget" {
    std.debug.print("ParsedWidget: {d}B\n", .{@sizeOf(ParsedWidget)});
}

test "Reader round-trip: load message" {
    var buf: [64]u8 = undefined;
    buf[0] = 0x01; // Tag.load
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
    const payload_sz = std.mem.readInt(u16, buf[1..3], .little);
    try std.testing.expectEqual(@as(u16, 7), payload_sz);
    const str_len = std.mem.readInt(u16, buf[3..5], .little);
    try std.testing.expectEqual(@as(u16, 5), str_len);
    try std.testing.expectEqualStrings("hello", buf[5..10]);
    try std.testing.expectEqual(@as(usize, 10), w.pos);
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

// Pull in tests from sub-files
comptime {
    _ = @import("types.zig");
    _ = @import("Reader.zig");
    _ = @import("Writer.zig");
    _ = @import("Framework.zig");
    _ = @import("runtime.zig");
    _ = @import("installer.zig");
}
