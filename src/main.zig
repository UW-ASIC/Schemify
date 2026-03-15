//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const build_options = @import("build_options");
const state_mod = @import("state");
const command = @import("commands");
const dvui = @import("dvui");
const gui = @import("gui/Gui.zig");
const cli = @import("cli");
const plugin_runtime = @import("runtime");

// ── Process-lifetime state ────────────────────────────────────────────────────

var app: state_mod.AppState = undefined;
var plugins: plugin_runtime.Runtime = undefined;
var project_dir: []const u8 = ".";

// ── dvui callbacks ────────────────────────────────────────────────────────────

fn getConfig() dvui.App.StartOptions {
    // Runs before the window opens. CLI commands exit here; otherwise capture
    // the project dir so appInit can use it (no user-data param in the API).
    if (comptime build_options.has_cli) {
        if (cli.dispatch()) std.process.exit(0);
    }
    project_dir = if (std.os.argv.len > 1) std.mem.span(std.os.argv[1]) else ".";
    return .{
        .size = .{ .w = 1280, .h = 800 },
        .title = "Schemify",
        .vsync = true,
        .window_init_options = .{ .theme = dvui.Theme.builtin.adwaita_dark },
    };
}

fn appInit(win: *dvui.Window) !void {
    _ = win;
    app = try state_mod.AppState.init(project_dir);
    app.initLogger();
    try app.newFile("untitled.comp");
    plugins = plugin_runtime.Runtime.init(app.allocator());
    plugins.loadStartup(&app);
}

fn appDeinit() void {
    plugins.deinit(&app);
    app.deinit();
}

fn appFrame() !dvui.App.Result {
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
    plugins.tick(&app, dvui.secondsSinceLastFrame());
    try gui.frame(&app, &plugins);
    return .ok;
}

// ── dvui app descriptor ───────────────────────────────────────────────────────

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = getConfig },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };
