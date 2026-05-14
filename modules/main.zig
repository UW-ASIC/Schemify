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

const settings = @import("settings");
const theme_config = @import("theme_config");

const is_wasm = builtin.cpu.arch.isWasm();
const cli = if (is_wasm) struct {} else @import("cli");
const agent = if (is_wasm) struct { pub const McpServer = void; } else @import("agent");

// ── Process-lifetime state ────────────────���───────────────────────────────────

var app: AppState = undefined;
var runtime: Runtime = undefined;
var plugin_mgr: PluginManager = .{};
var project_dir: []const u8 = ".";
var mcp_server: if (is_wasm) void else ?agent.McpServer = if (is_wasm) {} else null;
var agent_ctx: if (is_wasm) void else agent.types.AgentContext = if (is_wasm) {} else .{
    .getSchematic = &agentGetSchematic,
    .dispatchCommand = &agentDispatchCommand,
    .getProjectDir = &agentGetProjectDir,
    .app = undefined, // set in appInit
};

fn agentGetSchematic(self: *agent.types.AgentContext) ?*const @import("schematic").Schemify {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const doc = app_ptr.active() orelse return null;
    return &doc.sch;
}

fn agentDispatchCommand(self: *agent.types.AgentContext, acmd: agent.types.AgentCommand) bool {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const cmd: command.Command = switch (acmd) {
        .place => |p| .{ .undoable = .{ .place_device = .{
            .sym_path = p.sym_path,
            .name = p.name,
            .x = p.x,
            .y = p.y,
        } } },
        .add_wire => |w| .{ .undoable = .{ .add_wire = .{
            .x0 = w.x0,
            .y0 = w.y0,
            .x1 = w.x1,
            .y1 = w.y1,
            .net_name = w.net_name,
        } } },
        .delete_instance => |d| .{ .undoable = .{ .delete_instance = .{ .idx = d.idx } } },
        .set_instance_prop => |s| .{ .undoable = .{ .set_instance_prop = .{
            .idx = s.idx,
            .key = s.key,
            .val = s.val,
        } } },
    };
    app_ptr.queue.push(app_ptr.gpa.allocator(), cmd) catch return false;
    return true;
}

fn agentGetProjectDir(self: *agent.types.AgentContext) []const u8 {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    return app_ptr.project_dir;
}

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

    // Load settings (theme + keybinds) from ~/.config/Schemify/
    const a = app.allocator();
    if (comptime !is_wasm) {
        settings.load(a);
        settings.ensureDefaults(a);
        applySettingsTheme(a);
    }

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
            const fail_count = plugin_mgr.resolve(a, specs.items, config_dir);

            // If some plugins are missing, activate the startup download overlay.
            if (fail_count > 0) {
                app.startup_dl.active = true;
                app.startup_dl.total = fail_count;
                app.startup_dl.done = 0;
                app.startup_dl.failed = false;
                triggerStartupDownload(a);
            }
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

    // Start MCP agent server (background thread, Unix socket).
    if (comptime !is_wasm) {
        agent_ctx.app = @ptrCast(&app);
        mcp_server = agent.init(a, @ptrCast(&agent_ctx)) catch null;
    }

    // Wire PluginHost into AppState so GUI can dispatch to plugins.
    app.plugin_host = PluginHostMod.PluginHost{
        .ctx = @ptrCast(&runtime),
        .ensureLoaded = &phEnsureLoaded,
        .getPanelWidgets = &phGetPanelWidgets,
        .getPanelHtml = &phGetPanelHtml,
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
    // Stop MCP server before tearing down app state.
    if (comptime !is_wasm) {
        if (mcp_server) |*s| agent.deinit(s);
        mcp_server = null;
    }
    if (comptime !is_wasm) settings.deinit(a);
    runtime.deinit(a);
    if (comptime !is_wasm) plugin_mgr.deinit(a);
    gui.file_explorer.reset(&app);
    app.deinit();
}

/// Apply the active settings theme to the live GUI theme system.
fn applySettingsTheme(a: std.mem.Allocator) void {
    const json = settings.getActiveThemeJson(a) orelse return;
    defer a.free(json);
    theme_config.applyJson(a, json);
}

fn appFrame() !dvui.App.Result {
    processQueuedCommands();
    tickPlugins();

    // Handle startup download retry requests.
    if (comptime !is_wasm) {
        if (app.startup_dl.active and app.startup_dl.retry_requested) {
            app.startup_dl.retry_requested = false;
            triggerStartupDownload(app.allocator());
        }
    }

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

// ── Startup plugin download ──────────────────────────────────────────────────

const StartupDlCtx = struct {
    dl: *st.StartupDownload,
    missing: []const []const u8,
    alloc: std.mem.Allocator,
    refresh_flag: *bool,
};

/// Registry JSON types — mirrored from marketplace.zig.
const RegistryDownloadJson = struct { linux: []const u8 = "", macos: []const u8 = "", wasm: []const u8 = "" };
const RegistryEntryJson = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    author: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    tags: [][]const u8 = &.{},
    repo: []const u8 = "",
    readme_url: []const u8 = "",
    logo_url: []const u8 = "",
    download: RegistryDownloadJson = .{},
};
const RegistryJsonFull = struct { version: u32 = 0, plugins: []RegistryEntryJson = &.{} };

const REGISTRY_URL = "https://raw.githubusercontent.com/UW-ASIC/Schemify/main/plugins/registry.json";

fn triggerStartupDownload(a: std.mem.Allocator) void {
    // Collect missing plugin names (those with null paths).
    var missing = std.ArrayListUnmanaged([]const u8){};
    for (plugin_mgr.names.items, plugin_mgr.paths.items) |name, path| {
        if (path == null) {
            missing.append(a, a.dupe(u8, name) catch continue) catch continue;
        }
    }

    if (missing.items.len == 0) {
        app.startup_dl.active = false;
        missing.deinit(a);
        return;
    }

    const ctx = StartupDlCtx{
        .dl = &app.startup_dl,
        .missing = missing.toOwnedSlice(a) catch {
            app.startup_dl.failed = true;
            setStartupDlError(&app.startup_dl, "Out of memory");
            for (missing.items) |m| a.free(m);
            missing.deinit(a);
            return;
        },
        .alloc = a,
        .refresh_flag = &app.plugin_refresh_requested,
    };
    const thread = std.Thread.spawn(.{}, startupDownloadThread, .{ctx}) catch {
        app.startup_dl.failed = true;
        setStartupDlError(&app.startup_dl, "Failed to start download thread");
        for (ctx.missing) |m| a.free(m);
        a.free(ctx.missing);
        return;
    };
    thread.detach();
}

fn startupDownloadThread(ctx: StartupDlCtx) void {
    const a = ctx.alloc;
    const dl = ctx.dl;
    defer {
        for (ctx.missing) |m| a.free(m);
        a.free(ctx.missing);
    }

    // Fetch registry.json
    const body = utility.platform.httpGetSync(a, REGISTRY_URL) catch {
        @atomicStore(bool, &dl.failed, true, .seq_cst);
        setStartupDlError(dl, "Failed to fetch plugin registry");
        return;
    };
    defer a.free(body);

    const parsed = std.json.parseFromSlice(RegistryJsonFull, a, body, .{ .ignore_unknown_fields = true }) catch {
        @atomicStore(bool, &dl.failed, true, .seq_cst);
        setStartupDlError(dl, "Failed to parse plugin registry");
        return;
    };
    defer parsed.deinit();

    const config_dir = utility.platform.pluginConfigDir(a) catch {
        @atomicStore(bool, &dl.failed, true, .seq_cst);
        setStartupDlError(dl, "Cannot determine config directory");
        return;
    };
    defer a.free(config_dir);

    // For each missing plugin, find it in the registry and install.
    for (ctx.missing) |missing_name| {
        // Update current_name for display.
        setStartupDlCurrentName(dl, missing_name);

        // Find matching registry entry.
        var found_entry: ?RegistryEntryJson = null;
        for (parsed.value.plugins) |entry| {
            if (std.mem.eql(u8, entry.id, missing_name)) {
                found_entry = entry;
                break;
            }
        }

        const entry = found_entry orelse {
            // Plugin not in registry — skip but count as done.
            _ = @atomicRmw(u32, &dl.done, .Add, 1, .seq_cst);
            continue;
        };

        const url = if (builtin.os.tag == .linux) entry.download.linux else if (builtin.os.tag == .macos) entry.download.macos else entry.download.wasm;
        if (url.len == 0) {
            _ = @atomicRmw(u32, &dl.done, .Add, 1, .seq_cst);
            continue;
        }

        // Build destination directory.
        const plugin_dir = std.fmt.allocPrint(a, "{s}/{s}", .{ config_dir, entry.id }) catch {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Out of memory");
            return;
        };
        defer a.free(plugin_dir);

        std.fs.cwd().makePath(plugin_dir) catch {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Cannot create plugin directory");
            return;
        };

        const dest_path = std.fmt.allocPrint(a, "{s}/lib{s}.so", .{ plugin_dir, entry.id }) catch {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Out of memory");
            return;
        };
        defer a.free(dest_path);

        // Download via curl.
        var child = std.process.Child.init(&.{ "curl", "-sfL", "-o", dest_path, url }, a);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Failed to start download (is curl installed?)");
            return;
        };
        const term = child.wait() catch {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Download interrupted");
            return;
        };
        if (term.Exited != 0) {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Download failed (curl error)");
            return;
        }

        // Verify the file.
        const file = std.fs.cwd().openFile(dest_path, .{}) catch {
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Download produced no file");
            return;
        };
        const stat = file.stat() catch {
            file.close();
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Cannot stat downloaded file");
            return;
        };
        file.close();
        if (stat.size == 0) {
            std.fs.cwd().deleteFile(dest_path) catch {};
            @atomicStore(bool, &dl.failed, true, .seq_cst);
            setStartupDlError(dl, "Download produced empty file");
            return;
        }

        // Make executable.
        if (comptime builtin.os.tag != .windows) {
            var chmod = std.process.Child.init(&.{ "chmod", "+x", dest_path }, a);
            chmod.stdin_behavior = .Ignore;
            chmod.stdout_behavior = .Ignore;
            chmod.stderr_behavior = .Ignore;
            chmod.spawn() catch {};
            _ = chmod.wait() catch {};
        }

        // Write a minimal plugin.toml.
        writeStartupPluginManifest(a, plugin_dir, entry);

        _ = @atomicRmw(u32, &dl.done, .Add, 1, .seq_cst);
    }

    // Signal plugin refresh so the runtime picks up the newly installed plugins.
    @atomicStore(bool, ctx.refresh_flag, true, .seq_cst);
}

fn setStartupDlError(dl: *st.StartupDownload, msg: []const u8) void {
    const n: u8 = @intCast(@min(msg.len, dl.error_msg.len));
    @memcpy(dl.error_msg[0..n], msg[0..n]);
    dl.error_len = n;
}

fn setStartupDlCurrentName(dl: *st.StartupDownload, name: []const u8) void {
    const n: u8 = @intCast(@min(name.len, dl.current_name.len));
    @memcpy(dl.current_name[0..n], name[0..n]);
    dl.current_name_len = n;
}

fn writeStartupPluginManifest(a: std.mem.Allocator, plugin_dir: []const u8, entry: RegistryEntryJson) void {
    const toml_path = std.fmt.allocPrint(a, "{s}/plugin.toml", .{plugin_dir}) catch return;
    defer a.free(toml_path);

    const content = std.fmt.allocPrint(a,
        \\[plugin]
        \\name        = "{s}"
        \\version     = "{s}"
        \\author      = "{s}"
        \\entry       = "lib{s}.so"
        \\description = "{s}"
        \\scope       = "user"
        \\
    , .{ entry.name, entry.version, entry.author, entry.id, entry.description }) catch return;
    defer a.free(content);

    std.fs.cwd().writeFile(.{ .sub_path = toml_path, .data = content }) catch {};
}

// ── PluginHost fn-pointer adapters ──────────────────────────────────────────
// These convert *anyopaque -> *Runtime and forward the call.

fn phEnsureLoaded(ctx: *anyopaque, name: []const u8) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    rt.ensureLoaded(name);
}
fn phGetPanelWidgets(ctx: *anyopaque, panel_id: u16) PluginHostMod.WidgetSlice {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    return rt.getPanelWidgets(panel_id);
}
fn phGetPanelHtml(ctx: *anyopaque, panel_id: u16) []const u8 {
    const rt: *Runtime = @ptrCast(@alignCast(ctx));
    return rt.getPanelHtml(panel_id);
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

fn hcLogMsg(_: *anyopaque, level: u8, tag: []const u8, msg: []const u8) void {
    const label: []const u8 = switch (level) {
        0 => "INFO ",
        1 => "WARN ",
        else => "ERROR",
    };
    const cat: []const u8 = if (tag.len > 0) tag else "PLUGIN";
    const w = std.fs.File.stderr().deprecatedWriter();
    w.print("[{s}] {s}: {s}\n", .{ label, cat, msg }) catch {};
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
    return utility.platform.fs.cwd().readFileAlloc(asApp(ctx).allocator(), path, std.math.maxInt(usize)) catch null;
}

fn hcWriteFile(_: *anyopaque, path: []const u8, data: []const u8) bool {
    utility.platform.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch return false;
    return true;
}

fn hcProjectDir(ctx: *anyopaque) []const u8 {
    return asApp(ctx).project_dir;
}

var plugin_data_dir_buf: [512]u8 = undefined;

fn hcPluginDataDir(_: *anyopaque, plugin_name: []const u8) []const u8 {
    const home = utility.platform.homeDir() orelse return "";
    return std.fmt.bufPrint(&plugin_data_dir_buf, "{s}/.config/Schemify/{s}", .{ home, plugin_name }) catch "";
}

fn hcApplyConfig(ctx: *anyopaque, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "theme") or std.mem.eql(u8, key, "colors")) {
        gui.theme.applyJson(asApp(ctx).allocator(), val);
    }
}
var query_state_buf: [1024]u8 = undefined;

fn hcQueryState(ctx: *anyopaque, key: []const u8) ?[]const u8 {
    const a = asApp(ctx);
    if (std.mem.eql(u8, key, "view_mode")) {
        return @tagName(a.gui.hot.view_mode);
    } else if (std.mem.eql(u8, key, "tool")) {
        return a.tool.active.label();
    } else if (std.mem.eql(u8, key, "status")) {
        return a.status_msg;
    } else if (std.mem.eql(u8, key, "document_count")) {
        return std.fmt.bufPrint(&query_state_buf, "{d}", .{a.documents.items.len}) catch null;
    } else if (std.mem.eql(u8, key, "active_document")) {
        const doc = a.active() orelse return null;
        return std.fmt.bufPrint(&query_state_buf,
            \\{{"name":"{s}","dirty":{s}}}
        , .{ doc.name, if (doc.dirty) "true" else "false" }) catch null;
    } else if (std.mem.eql(u8, key, "project_dir")) {
        return a.project_dir;
    }
    return null;
}

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
