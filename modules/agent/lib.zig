const std = @import("std");

pub const McpServer = @import("server.zig").Server;
pub const types = @import("types.zig");
pub const tools = @import("tools.zig");
pub const resources = @import("resources.zig");
pub const prompts = @import("prompts.zig");
pub const diagnostics = @import("diagnostics.zig");

// ── Socket path resolution ───────────────────────────────────────────────────

fn socketPath(arena: std.mem.Allocator) ![]const u8 {
    // $XDG_RUNTIME_DIR/schemify.sock
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        return std.fmt.allocPrint(arena, "{s}/schemify.sock", .{runtime_dir});
    }
    // Fallback: ~/.config/Schemify/schemify.sock
    if (std.posix.getenv("HOME")) |home| {
        const dir = try std.fmt.allocPrint(arena, "{s}/.config/Schemify", .{home});
        std.fs.cwd().makePath(dir) catch {};
        return std.fmt.allocPrint(arena, "{s}/schemify.sock", .{dir});
    }
    return "/tmp/schemify.sock";
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Initialize and start the MCP server on a background thread.
/// `ctx` is an opaque pointer to application state (AppState) —
/// tool/resource handlers receive it for state access.
/// Returns the server handle, or null on failure.
pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque) !McpServer {
    const path = try socketPath(allocator);
    var server = McpServer.init(allocator, path, ctx);
    allocator.free(path); // Server dupes internally
    try server.start();
    return server;
}

/// Stop the MCP server and clean up resources.
pub fn deinit(server: *McpServer) void {
    server.stop();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "socketPath returns valid path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const path = try socketPath(arena_state.allocator());
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, "schemify.sock"));
}

test {
    // Pull in all sub-module tests
    @import("std").testing.refAllDecls(@This());
}
