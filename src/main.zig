//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const state_mod = @import("state");
const command = @import("commands");
const dvui = @import("dvui");
const gui = @import("gui/lib.zig");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch.isWasm();
const cli = if (is_wasm) struct {} else @import("cli");
const plugin_runtime = @import("runtime");
const debug_server = @import("debug_server");

// ── Process-lifetime state ────────────────────────────────────────────────────

var app: state_mod.AppState = undefined;
var plugins: plugin_runtime.Runtime = undefined;
var project_dir: []const u8 = ".";

// ── dvui callbacks ────────────────────────────────────────────────────────────

fn configureProjectDirAndCli() void {
    project_dir = if (std.os.argv.len > 1) std.mem.span(std.os.argv[1]) else ".";
    if (cli.dispatch()) std.process.exit(0);
}

fn defaultStartOptions() dvui.App.StartOptions {
    return .{
        .size = .{ .w = 1280, .h = 800 },
        .title = "Schemify",
        .vsync = true,
        .window_init_options = .{ .theme = dvui.Theme.builtin.adwaita_dark },
    };
}

fn getConfig() dvui.App.StartOptions {
    if (comptime !is_wasm) configureProjectDirAndCli();
    return defaultStartOptions();
}

fn appInit(win: *dvui.Window) !void {
    _ = win;

    // gui
    app = state_mod.AppState.init(project_dir);
    try app.loadConfig();
    app.initLogger();

    // plugins
    plugins = plugin_runtime.Runtime.init(app.allocator());
    plugins.loadStartup(&app);
    app.plugin_runtime_ptr = @ptrCast(&plugins);

    if (comptime builtin.mode == .Debug) {
        debug_server.start(&app);
    }
}

fn appDeinit() void {
    if (comptime builtin.mode == .Debug) {
        debug_server.stop();
    }
    @import("gui/FileExplorer.zig").reset(&app);
    plugins.deinit(&app);
    app.deinit();
}

fn appFrame() !dvui.App.Result {
    processQueuedCommands();
    tickPlugins();
    try gui.frame(&app);

    return .ok;
}

fn processQueuedCommands() void {
    while (app.queue.pop()) |c| {
        command.dispatch(c, &app) catch |err| {
            app.setStatusErr("Command failed");
            app.log.err("CMD", "dispatch {s} failed: {}", .{ @tagName(c), err });
        };
    }
}

fn tickPlugins() void {
    if (app.plugin_refresh_requested) {
        app.plugin_refresh_requested = false;
        plugins.refresh(&app);
    }
    plugins.tick(&app, dvui.secondsSinceLastFrame());
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
