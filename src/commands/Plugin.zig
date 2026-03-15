//! Plugin command handlers.

const Immediate = @import("command.zig").Immediate;

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .plugins_refresh => state.plugin_refresh_requested = true,
        .plugin_command  => |p| state.log.info("CMD", "plugin command: {s}", .{p.tag}),
        else => unreachable,
    }
}
