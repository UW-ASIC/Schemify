//! Application lifecycle — dvui callbacks and process-lifetime state.
//! CLI subcommands live in cli.zig; this file routes to them when detected.

const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");

const st = @import("state");
const AppState = st.AppState;
const command = @import("commands");
const gui = @import("gui");
const utility = @import("utility");
const plugins = @import("plugins");
const Runtime = plugins.Runtime;
const PluginHostMod = plugins.PluginHost;
const PluginManager = plugins.PluginManager;
const Cap = plugins.Capability;

const is_wasm = builtin.cpu.arch.isWasm();
const cli = if (is_wasm) struct {} else @import("cli");

// ── Process-lifetime state ────────────────���───────────────────────────────────

var app: AppState = undefined;
var runtime: Runtime = undefined;
var plugin_mgr: PluginManager = .{};
var project_dir: []const u8 = ".";

// ── dvui callbacks ───────────────���───────────────────────���────────────────────

fn configureProjectDirAndCli() void {
    project_dir = if (std.os.argv.len > 1) std.mem.span(std.os.argv[1]) else ".";
    if (comptime !is_wasm) {
        if (cli.dispatch()) std.process.exit(0);
    }
}

fn getConfig() dvui.App.StartOptions {
    if (comptime !is_wasm) configureProjectDirAndCli();
    return .{
        .size = .{ .w = 1280, .h = 800 },
        .title = "Schemify",
        .vsync = true,
        .window_init_options = .{ .theme = dvui.Theme.builtin.adwaita_dark },
    };
}

fn appInit(win: *dvui.Window) !void {
    _ = win;

    app.init(project_dir);
    try app.loadConfig();
    app.initLogger();

    const a = app.allocator();
    runtime = Runtime.init(a);

    if (comptime !is_wasm) {
        const config_dir = utility.platform.pluginConfigDir(a) catch "";
        defer if (config_dir.len > 0) a.free(config_dir);

        // Resolve plugin binaries from project config.
        if (app.config.plugins) |po| {
            var specs = std.ArrayListUnmanaged(plugins.PluginSpec){};
            defer specs.deinit(a);
            for (po.enabled) |name| {
                specs.append(a, .{ .name = name }) catch continue;
            }
            _ = plugin_mgr.resolve(a, specs.items, config_dir);
        }

        // Auto-discover plugins in config dir that aren't in Config.toml.
        if (config_dir.len > 0) {
            _ = plugin_mgr.autoDiscover(a, config_dir);
        }

        // Load all discovered plugins.
        runtime.setCallbacks(makeHostCallbacks());
        runtime.loadStartup(
            a,
            plugin_mgr.names.items,
            plugin_mgr.paths.items,
            plugin_mgr.lazys.items,
            &.{},
        );
    }

    // Wire PluginHost into AppState so GUI can dispatch to plugins.
    app.plugin_host = PluginHostMod.PluginHost{
        .ctx = @ptrCast(&runtime),
        .ensureLoaded = &phEnsureLoaded,
        .getPanelWidgets = &phGetPanelWidgets,
        .requestDrawPanel = &phDrawPanel,
        .buttonClicked = &phButtonClicked,
        .sliderChanged = &phSliderChanged,
        .checkboxChanged = &phCheckboxChanged,
        .textChanged = &phTextChanged,
        .hover = &phHover,
        .getTooltip = &phGetTooltip,
        .keyEvent = &phKeyEvent,
    };
}

fn appDeinit() void {
    const a = app.allocator();
    runtime.deinit(a);
    if (comptime !is_wasm) plugin_mgr.deinit(a);
    gui.file_explorer.reset(&app);
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
            app.log.err("CMD", "dispatch failed: {}", .{err});
        };
    }
}

fn tickPlugins() void {
    if (app.plugin_refresh_requested) {
        app.plugin_refresh_requested = false;
        const a = app.allocator();

        // Re-discover plugins that may have been installed since startup.
        if (comptime !is_wasm) {
            const config_dir = utility.platform.pluginConfigDir(a) catch "";
            defer if (config_dir.len > 0) a.free(config_dir);
            if (config_dir.len > 0) {
                _ = plugin_mgr.autoDiscover(a, config_dir);
            }
        }

        runtime.refresh(
            a,
            plugin_mgr.names.items,
            plugin_mgr.paths.items,
            plugin_mgr.lazys.items,
            &.{},
        );
    }
    runtime.tick(app.allocator(), dvui.secondsSinceLastFrame());
}

// ── PluginHost fn-pointer adapters ──────��────────────────────────────────────
// These convert *anyopaque -> *Runtime and forward the call.

fn phEnsureLoaded(ctx: *anyopaque, name: []const u8) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.ensureLoaded(name);
}
fn phGetPanelWidgets(ctx: *anyopaque, panel_id: u16) PluginHostMod.WidgetSlice {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    return rt.getPanelWidgets(panel_id);
}
fn phDrawPanel(ctx: *anyopaque, panel_id: u16) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.drawPanel(app.allocator(), panel_id);
}
fn phButtonClicked(ctx: *anyopaque, panel_id: u16, widget_id: u32) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.buttonClicked(panel_id, widget_id);
}
fn phSliderChanged(ctx: *anyopaque, panel_id: u16, widget_id: u32, val: f32) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.sliderChanged(panel_id, widget_id, val);
}
fn phCheckboxChanged(ctx: *anyopaque, panel_id: u16, widget_id: u32, val: bool) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.checkboxChanged(panel_id, widget_id, val);
}
fn phTextChanged(ctx: *anyopaque, panel_id: u16, widget_id: u32, text: []const u8) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.textChanged(panel_id, widget_id, text);
}
fn phHover(ctx: *anyopaque, wx: i32, wy: i32, etype: u8, eidx: i32, ename: []const u8) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.hover(wx, wy, etype, eidx, ename);
}
fn phGetTooltip(ctx: *anyopaque) []const u8 {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    return rt.getTooltip();
}
fn phKeyEvent(ctx: *anyopaque, key: u8, mods: u8, action: u8) bool {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    return rt.keyEvent(key, mods, action);
}

// ── HostCallbacks wiring ──────���───────────────────────���──────────────────────
// Wire Runtime's HostCallbacks to real AppState methods.

fn makeHostCallbacks() plugins.HostCallbacks {
    return .{
        .ctx = @ptrCast(&app),
        .register_panel = &hcRegisterPanel,
        .register_command = &hcRegisterCommand,
        .set_status = &hcSetStatus,
        .log_msg = &hcLogMsg,
        .push_command = &hcPushCommand,
        .request_refresh = &hcRequestRefresh,
        .read_file = &hcReadFile,
        .write_file = &hcWriteFile,
        .project_dir = &hcProjectDir,
        .plugin_data_dir = &hcPluginDataDir,
        .apply_config = &hcApplyConfig,
        .query_state = &hcQueryState,
        .register_keybind = &hcRegisterKeybind,
        .override_keybind = &hcOverrideKeybind,
        .mark_lazy_loading = &hcMarkLazy,
    };
}

fn asApp(ctx: *anyopaque) *AppState {
    return @ptrCast(@alignCast(ctx));
}

fn hcRegisterPanel(ctx: *anyopaque, id: []const u8, title: []const u8, vim_cmd: []const u8, layout_byte: u8, keybind: u8, panel_id: u16) u16 {
    const a = asApp(ctx);
    const layout: st.PluginPanelLayout = @enumFromInt(@min(layout_byte, 3));
    return a.registerPluginPanelEx(id, title, vim_cmd, layout, keybind, panel_id);
}

fn hcRegisterCommand(ctx: *anyopaque, id: []const u8, display_name: []const u8, desc: []const u8) void {
    asApp(ctx).registerPluginCommand(id, display_name, desc);
}

fn hcSetStatus(ctx: *anyopaque, msg: []const u8) void {
    asApp(ctx).setStatusBuf(msg);
}

fn hcLogMsg(ctx: *anyopaque, level: u8, tag: []const u8, msg: []const u8) void {
    _ = level;
    _ = tag;
    _ = msg;
    _ = ctx;
}

fn hcPushCommand(ctx: *anyopaque, cmd_tag: []const u8) bool {
    const a = asApp(ctx);
    const parsed = command.parser.tryTagLookup(cmd_tag) orelse return false;
    a.queue.push(a.gpa.allocator(), parsed) catch return false;
    return true;
}

fn hcRequestRefresh(ctx: *anyopaque) void {
    asApp(ctx).plugin_refresh_requested = true;
}

fn hcReadFile(ctx: *anyopaque, path: []const u8) ?[]const u8 {
    return dvui.fs.cwd().readFileAlloc(asApp(ctx).allocator(), path, std.math.maxInt(usize)) catch null;
}

fn hcWriteFile(_: *anyopaque, path: []const u8, data: []const u8) bool {
    dvui.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch return false;
    return true;
}

fn hcProjectDir(ctx: *anyopaque) []const u8 {
    return asApp(ctx).project_dir;
}

fn hcPluginDataDir(ctx: *anyopaque, plugin_name: []const u8) []const u8 {
    _ = ctx;
    _ = plugin_name;
    return "";
}

fn hcApplyConfig(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn hcQueryState(_: *anyopaque, _: []const u8) ?[]const u8 { return null; }

fn hcRegisterKeybind(ctx: *anyopaque, key: u8, mods: u8, cmd_tag: []const u8) void {
    const a = asApp(ctx);
    a.gui.cold.plugin_keybinds.append(a.allocator(), .{ .key = key, .mods = mods, .cmd_tag = cmd_tag }) catch {};
}

fn hcOverrideKeybind(ctx: *anyopaque, key: u8, mods: u8, cmd_tag: []const u8) void {
    hcRegisterKeybind(ctx, key, mods, cmd_tag);
}

fn hcMarkLazy(ctx: *anyopaque, name: []const u8) void {
    _ = ctx;
    _ = name;
}

// ── dvui app descriptor ───────────────���─────────────────────��─────────────────

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = getConfig },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };
