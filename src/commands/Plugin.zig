//! Plugin command handlers.

const Immediate = @import("command.zig").Immediate;

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .plugins_refresh => state.plugin_refresh_requested = true,
        .plugin_command => |p| {
            // TODO: dispatch to plugin runtime — forward tag+payload to the
            // appropriate plugin's schemify_process() via runtime.dispatchEvent().
            // Currently just logs for debugging.
            state.log.info("CMD", "plugin command: {s}", .{p.tag});
        },
        else => unreachable,
    }
}
