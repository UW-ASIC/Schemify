const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;

pub fn handleConfig(imm: Immediate, state: anytype) void {
    switch (imm) {
        .open_preferences => {
            state.gui.cold.settings_dialog.is_open = true;
            state.setStatus("Settings");
        },
        .reload_config => {
            state.loadConfig() catch { state.setStatus("Config reload failed"); return; };
            state.setStatus("Config reloaded (use :settings to reload theme/keybinds)");
        },
        .clear_sim_cache => {
            clearSimCache(state);
        },
        else => {},
    }
}

fn clearSimCache(state: anytype) void {
    const home = std.posix.getenv("HOME") orelse {
        state.setStatus("Cannot determine home directory");
        return;
    };
    var path_buf: [256]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&path_buf, "{s}/.cache/schemify", .{home}) catch {
        state.setStatus("Path too long");
        return;
    };
    std.fs.cwd().deleteTree(cache_dir) catch |err| {
        if (err == error.FileNotFound) {
            state.setStatus("No simulation cache to clear");
            return;
        }
        state.setStatus("Failed to clear simulation cache");
        return;
    };
    state.setStatus("Simulation cache cleared");
}
