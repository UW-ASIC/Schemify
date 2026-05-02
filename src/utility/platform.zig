const std = @import("std");
const builtin = @import("builtin");

/// Synchronous HTTP GET via curl. Caller owns returned slice.
pub fn httpGetSync(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var child = std.process.Child.init(&.{ "curl", "-sfL", url }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize)) catch
        return error.HttpRequestFailed;
    const term = try child.wait();
    if (term.Exited != 0) {
        alloc.free(stdout);
        return error.HttpRequestFailed;
    }
    return stdout;
}

/// Returns `$HOME/.config/Schemify`.
pub fn configDir() []const u8 {
    const home = homeDir() orelse "/tmp";
    return home ++ "/.config/Schemify";
}

/// Returns `$HOME/.config/Schemify` (runtime, caller owns memory).
pub fn pluginConfigDir(alloc: std.mem.Allocator) ![]u8 {
    const home = homeDir() orelse return error.HomeNotFound;
    return std.fmt.allocPrint(alloc, "{s}/.config/Schemify", .{home});
}

/// Return HOME environment variable, or null.
pub fn homeDir() ?[]const u8 {
    return std.posix.getenv("HOME");
}

/// Open a URL in the platform default browser.
pub fn openUrl(alloc: std.mem.Allocator, url: []const u8) !void {
    const opener: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        .windows => "start",
        else => "xdg-open",
    };
    var child = std.process.Child.init(&.{ opener, url }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

test "homeDir returns non-null on linux" {
    if (builtin.os.tag == .linux) {
        try std.testing.expect(homeDir() != null);
    }
}
