//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const build_options = @import("build_options");
const toml = @import("toml.zig");
const command = @import("command.zig");
const state_mod = @import("state.zig");
const State = state_mod.AppState;
const dvui = @import("dvui");
const gui = @import("gui/gui.zig");
const has_cli = build_options.has_cli;
const cli = @import("cli.zig");
const plugin_runtime = @import("plugins/runtime.zig");

// state_mod.app is the process-wide AppState singleton (declared in state.zig).
var plugins: plugin_runtime.Runtime = undefined;

pub fn getConfig() dvui.App.StartOptions {
    if (comptime has_cli) {
        if (cli.dispatch()) std.process.exit(0);
    }

    const project_dir = projectDir();
    var tmp_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = tmp_gpa.deinit();
    var cfg = toml.ProjectConfig.parseFromPath(tmp_gpa.allocator(), project_dir) catch toml.ProjectConfig.init(tmp_gpa.allocator());
    defer cfg.deinit();

    return .{
        .size = .{ .w = 1280, .h = 800 },
        .title = "Schemify",
        .vsync = true,
        .window_init_options = .{ .theme = dvui.Theme.builtin.adwaita_dark },
    };
}

pub fn appInit(win: *dvui.Window) !void {
    _ = win;
    state_mod.app = try State.init(projectDir());
    state_mod.app.initLogger();
    try state_mod.app.newFile("untitled");
    plugins = plugin_runtime.Runtime.init(state_mod.app.allocator());
    plugins.loadStartup(&state_mod.app);
}

pub fn appDeinit() void {
    plugins.deinit(&state_mod.app);
    state_mod.app.deinit();
}

pub fn appFrame() !dvui.App.Result {
    while (state_mod.app.queue.pop()) |c| {
        command.dispatch(c, &state_mod.app) catch |err| {
            state_mod.app.setStatusErr("Command failed");
            state_mod.app.log.err("CMD", "dispatch {s} failed: {}", .{ @tagName(c), err });
        };
    }
    if (state_mod.app.plugin_refresh_requested) {
        state_mod.app.plugin_refresh_requested = false;
        plugins.refresh(&state_mod.app);
    }
    plugins.tick(&state_mod.app, 1.0 / 60.0);
    try gui.frame(&state_mod.app);
    return .ok;
}

fn projectDir() []const u8 {
    return if (std.os.argv.len > 1)
        std.mem.span(std.os.argv[1])
    else
        ".";
}

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = getConfig },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };
