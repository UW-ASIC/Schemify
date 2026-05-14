const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");

pub fn toDvui(c: theme.Color) dvui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub fn baseName(path: []const u8) []const u8 {
    const after_slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    return if (std.mem.lastIndexOfScalar(u8, after_slash, '\\')) |i| after_slash[i + 1 ..] else after_slash;
}
