//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const build_options = @import("build_options");
const toml = @import("toml.zig");
const command = @import("command.zig");
const State = @import("state.zig").AppState;
const dvui = @import("dvui");
const gui = @import("gui/gui.zig");
const has_cli = build_options.has_cli;
const cli = @import("cli.zig");
const plugin_runtime = @import("plugins/runtime.zig");

var app: State = undefined;
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
    app = try State.init(projectDir());
    app.initLogger();
    try app.newFile("untitled");
    plugins = plugin_runtime.Runtime.init(app.allocator());
    plugins.loadStartup(&app);
}

pub fn appDeinit() void {
    plugins.deinit(&app);
    app.deinit();
}

pub fn appFrame() !dvui.App.Result {
    while (app.queue.pop()) |c| {
        command.dispatch(c, &app) catch |err| {
            app.setStatusErr("Command failed");
            app.log.err("CMD", "dispatch {s} failed: {}", .{ @tagName(c), err });
        };
    }
    if (app.plugin_refresh_requested) {
        app.plugin_refresh_requested = false;
        plugins.refresh(&app);
    }
    plugins.tick(&app, 1.0 / 60.0);
    try gui.frame(&app);
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
