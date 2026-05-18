const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;

pub fn handleConfig(imm: Immediate, state: anytype) void {
    switch (imm) {
        .open_preferences => {
            state.gui.cold.dialogs.settings.is_open = true;
            state.setStatus("Settings");
        },
        .reload_config => {
            state.loadConfig() catch { state.setStatus("Config reload failed"); return; };
            state.setStatus("Config reloaded");
        },
        .reload_settings => {
            state.settings_reload_requested = true;
            state.setStatus("Settings reloaded");
        },
        .save_settings => {
            state.settings_save_requested = true;
            state.setStatus("Settings saved");
        },
        .clear_sim_cache => {
            clearSimCache(state);
        },
        else => {},
    }
}

fn clearSimCache(state: anytype) void {
    const platform = @import("utility").platform;
    const home = platform.homeDir() orelse {
        state.setStatus("Cannot determine home directory");
        return;
    };
    var path_buf: [256]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&path_buf, "{s}/.cache/schemify", .{home}) catch {
        state.setStatus("Path too long");
        return;
    };
    platform.fs.cwd().deleteTree(cache_dir) catch |err| {
        if (err == error.FileNotFound) {
            state.setStatus("No simulation cache to clear");
            return;
        }
        state.setStatus("Failed to clear simulation cache");
        return;
    };
    state.setStatus("Simulation cache cleared");
}
