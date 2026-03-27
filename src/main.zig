//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const build_options = @import("build_options");
const state_mod = @import("state");
const command = @import("commands");
const dvui = @import("dvui");
const gui = @import("gui/lib.zig");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch.isWasm();
const cli = if (is_wasm) struct {} else @import("cli");
const plugin_runtime = @import("runtime");

// ── Process-lifetime state ────────────────────────────────────────────────────

var app: state_mod.AppState = undefined;
var plugins: plugin_runtime.Runtime = undefined;
var project_dir: []const u8 = ".";

// ── dvui callbacks ────────────────────────────────────────────────────────────

fn getConfig() dvui.App.StartOptions {
    if (comptime !is_wasm) {
        // 1) Read config from Config.toml
        project_dir = if (std.os.argv.len > 1) std.mem.span(std.os.argv[1]) else ".";

        // 2) cli dispatch and dont return screen IF --headless is passed in
        if (cli.dispatch()) std.process.exit(0);
    }

    // 3) only return if not headless
    return .{
        .size = .{ .w = 1280, .h = 800 },
        .title = "Schemify",
        .vsync = true,
        .window_init_options = .{ .theme = dvui.Theme.builtin.adwaita_dark },
    };
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
}

fn appDeinit() void {
    @import("gui/FileExplorer.zig").reset();
    plugins.deinit(&app);
    app.deinit();
}

fn appFrame() !dvui.App.Result {
    // handle the commands per frame
    while (app.queue.pop()) |c| {
        command.dispatch(c, &app) catch |err| {
            app.setStatusErr("Command failed");
            app.log.err("CMD", "dispatch {s} failed: {}", .{ @tagName(c), err });
        };
    }

    // pass-through to plugins so they can render
    if (app.plugin_refresh_requested) {
        app.plugin_refresh_requested = false;
        plugins.refresh(&app);
    }
    plugins.tick(&app, dvui.secondsSinceLastFrame());
    try gui.frame(&app);

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
