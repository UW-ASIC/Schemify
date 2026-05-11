//! Shared GUI helper functions — eliminates cross-file duplication.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");

/// Convert theme Color to dvui Color.
pub fn toDvui(c: theme.Color) dvui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Extract the file basename from a path (handles both '/' and '\\').
pub fn baseName(path: []const u8) []const u8 {
    const after_slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    return if (std.mem.lastIndexOfScalar(u8, after_slash, '\\')) |i| after_slash[i + 1 ..] else after_slash;
}

/// ASCII lower-case for a single byte.
pub fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Case-insensitive substring search (ASCII only).
pub fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
