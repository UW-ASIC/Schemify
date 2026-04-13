//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const state_mod = @import("state");
const command = @import("commands");
const dvui = @import("dvui");
const gui = @import("gui/lib.zig");
const builtin = @import("builtin");
const utility = @import("utility");
const is_wasm = builtin.cpu.arch.isWasm();
const cli = if (is_wasm) struct {} else @import("cli");
const plugin_runtime = @import("runtime");

// ── Process-lifetime state ────────────────────────────────────────────────────

var app: state_mod.AppState = undefined;
var plugins: plugin_runtime.Runtime = undefined;
var plugin_mgr: plugin_runtime.PluginManager = undefined;
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

    app.init(project_dir);
    try app.loadConfig();
    app.initLogger();

    if (comptime !is_wasm) {
        const a = app.allocator();
        plugin_mgr = plugin_runtime.PluginManager.init(a);

        // Project plugins first, then user plugins — each with its own source tag
        // so the scope check in PluginManager can reject mismatches.
        const res_proj = plugin_mgr.ensureInstalled(
            app.config.plugin_specs,
            .project,
            &app.log,
            a,
        );

        var user_cfg: ?state_mod.ProjectConfig = loadUserPluginConfig(a);
        defer if (user_cfg) |*uc| uc.deinit();
        const user_specs = if (user_cfg) |uc| uc.plugin_specs else &[_]state_mod.ProjectConfig.PluginSpec{};
        const res_user = plugin_mgr.ensureInstalled(user_specs, .user, &app.log, a);

        if (res_proj.fail_count + res_user.fail_count > 0)
            app.setStatusBuf("Some plugins failed to install — check logs.");
    }

    plugins = plugin_runtime.Runtime.init(app.allocator());
    plugins.loadStartup(&app, if (comptime !is_wasm) &plugin_mgr else null);
    app.plugin_runtime_ptr = @ptrCast(&plugins);

}

fn loadUserPluginConfig(alloc: std.mem.Allocator) ?state_mod.ProjectConfig {
    const home = utility.platform.getEnvVar(alloc, "HOME") catch return null;
    defer alloc.free(home);
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.config/Schemify/plugins.toml", .{home}) catch return null;
    return state_mod.ProjectConfig.parseFromFile(alloc, path) catch null;
}

fn appDeinit() void {
    @import("gui/Panels/FileExplorer.zig").reset(&app);
    plugins.deinit(&app);
    if (comptime !is_wasm) plugin_mgr.deinit();
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
        plugins.refresh(&app, if (comptime !is_wasm) &plugin_mgr else null);
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
