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
const PluginManager = plugins.PluginManager;


const gui_settings = gui.settings;
const theme_config = @import("theme_config");

const is_wasm = builtin.cpu.arch.isWasm();
const cli = if (is_wasm) struct {} else @import("cli");
const agent = if (is_wasm) struct { pub const McpServer = void; } else @import("agent");

// ── Process-lifetime state ────────────────────────────────────────────────────

var app: AppState = undefined;
var runtime: Runtime = undefined;
var plugin_mgr: PluginManager = .{};
var project_dir: []const u8 = ".";
var mcp_server: if (is_wasm) void else ?agent.McpServer = if (is_wasm) {} else null;

// Edge-detect state for view toggle flags that need backend calls.
var prev_fullscreen: bool = false;
var prev_dark_mode: bool = true;
var agent_ctx: if (is_wasm) void else agent.types.AgentContext = if (is_wasm) {} else .{
    .getSchematic = &agentGetSchematic,
    .getProjectDir = &agentGetProjectDir,
    .setPySpiceSource = &agentSetPySpiceSource,
    .getPySpiceSource = &agentGetPySpiceSource,
    .setDocumentation = &agentSetDocumentation,
    .getDocumentation = &agentGetDocumentation,
    .app = undefined, // set in appInit
};

fn agentGetSchematic(self: *agent.types.AgentContext) ?*const @import("schematic").Schemify {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const doc = app_ptr.active() orelse return null;
    return &doc.sch;
}

fn agentGetProjectDir(self: *agent.types.AgentContext) []const u8 {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    return app_ptr.project_dir;
}

fn agentSetPySpiceSource(self: *agent.types.AgentContext, source: []const u8) bool {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const doc = app_ptr.active() orelse return false;
    doc.sch.setPySpiceSource(doc.alloc, source) catch return false;
    doc.dirty = true;
    return true;
}

fn agentGetPySpiceSource(self: *agent.types.AgentContext) ?[]const u8 {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const doc = app_ptr.active() orelse return null;
    const src = doc.sch.str(doc.sch.pyspice_source);
    return if (src.len > 0) src else null;
}

fn agentSetDocumentation(self: *agent.types.AgentContext, content: []const u8) bool {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const doc = app_ptr.active() orelse return false;
    doc.sch.setDocumentation(doc.alloc, content) catch return false;
    doc.dirty = true;
    return true;
}

fn agentGetDocumentation(self: *agent.types.AgentContext) ?[]const u8 {
    const app_ptr: *AppState = @ptrCast(@alignCast(self.app));
    const doc = app_ptr.active() orelse return null;
    const content = doc.sch.str(doc.sch.documentation);
    return if (content.len > 0) content else null;
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
        gui_settings.load(a);
        gui_settings.ensureDefaults(a);
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

        // Wire host callbacks so plugins can call back into the app.
        runtime.setCallbacks(makeHostCallbacks());
    }

    // Start MCP agent server (background thread, Unix socket).
    if (comptime !is_wasm) {
        agent_ctx.app = @ptrCast(&app);
        mcp_server = agent.init(a, @ptrCast(&agent_ctx));
        if (mcp_server) |*s| s.start() catch {
            mcp_server = null;
        };
    }

    // Wire Runtime pointer into AppState so GUI can dispatch to plugins.
    app.plugin_runtime = &runtime;
}

fn appDeinit() void {
    const a = app.allocator();
    // Stop MCP server before tearing down app state.
    if (comptime !is_wasm) {
        if (mcp_server) |*s| agent.deinit(s);
        mcp_server = null;
    }
    if (comptime !is_wasm) gui_settings.deinit(a);
    runtime.deinit(a);
    if (comptime !is_wasm) plugin_mgr.deinit(a);
    gui.file_explorer.reset(&app);
    app.deinit();
}

/// Apply the active settings theme to the live GUI theme system.
fn applySettingsTheme(a: std.mem.Allocator) void {
    const json = gui_settings.getActiveThemeJson(a) orelse return;
    defer a.free(json);
    theme_config.applyJson(a, json);
}

fn appFrame() !dvui.App.Result {
    processQueuedCommands();
    processSettingsRequests();
    tickPlugins();

    // Handle startup download retry requests.
    if (comptime !is_wasm) {
        if (app.startup_dl.active and app.startup_dl.retry_requested) {
            app.startup_dl.retry_requested = false;
            triggerStartupDownload(app.allocator());
        }
    }

    // Fullscreen toggle — detect edge.
    // TODO: SDL3 fullscreen via dvui.Window API when dvui exposes it.
    if (comptime !is_wasm) {
        if (app.cmd_flags.fullscreen != prev_fullscreen) {
            prev_fullscreen = app.cmd_flags.fullscreen;
        }
    }

    // Dark mode / color scheme toggle — switch dvui theme on edge.
    if (app.cmd_flags.dark_mode != prev_dark_mode) {
        prev_dark_mode = app.cmd_flags.dark_mode;
        dvui.themeSet(if (app.cmd_flags.dark_mode) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light);
    }

    try gui.frame(&app);
    return if (app.quit_requested) .close else .ok;
}

fn processQueuedCommands() void {
    while (app.queue.pop()) |c| {
        command.dispatch(c, &app) catch |err| {
            app.setStatusErr("Command failed");
            app.log.err("CMD", "dispatch failed: {}", .{err});
        };
    }
}

fn processSettingsRequests() void {
    if (app.settings_reload_requested) {
        app.settings_reload_requested = false;
        gui_settings.reload(app.allocator());
        applySettingsTheme(app.allocator());
    }
    if (app.settings_save_requested) {
        app.settings_save_requested = false;
        const dir = gui_settings.configDir();
        if (dir.len > 0) {
            const a = app.allocator();
            _ = gui_settings.theme_persistence.saveToDisk(dir, a);
            _ = gui_settings.keybind_persistence.saveToDisk(dir, a);
        }
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

        // TODO: spawn discovered plugins via runtime.spawnPlugin()
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
