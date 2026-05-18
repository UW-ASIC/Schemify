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

// ── Process-lifetime state ────────────────────────────────────────────────────

var app: AppState = undefined;
var runtime: Runtime = undefined;
var plugin_mgr: PluginManager = .{};
var project_dir: []const u8 = ".";
// Edge-detect state for view toggle flags that need backend calls.
var prev_fullscreen: bool = false;
var prev_dark_mode: bool = true;

// ── dvui callbacks ───────────────���───────────────────────���────────────────────

fn configureProjectDirAndCli() void {
    if (comptime !is_wasm) {
        if (cli.dispatch()) std.process.exit(0);
        // CLI returned false — GUI should start.
        switch (cli.startup) {
            .run => |r| {
                project_dir = std.fs.path.dirname(r.file) orelse ".";
            },
            .none => {
                // If argv[1] is a .chn file, set up headed open (no commands).
                if (std.os.argv.len > 1) {
                    const arg1 = std.mem.span(std.os.argv[1]);
                    if (cli.isChnPath(arg1)) {
                        const pa = std.heap.page_allocator;
                        const file_dupe = pa.dupe(u8, arg1) catch arg1;
                        cli.startup = .{ .run = .{ .file = file_dupe, .lines = "" } };
                        project_dir = std.fs.path.dirname(arg1) orelse ".";
                    } else {
                        project_dir = arg1;
                    }
                } else {
                    project_dir = ".";
                }
            },
        }
    } else {
        project_dir = ".";
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
    app.init(project_dir);
    try app.loadConfig();
    app.initLogger();

    // Load settings (theme + keybinds) from ~/.config/Schemify/
    const a = app.allocator();
    if (comptime !is_wasm) {
        gui_settings.load(a);
        gui_settings.ensureDefaults(a);
        applySettingsTheme(a);
        gui_settings.initBaseScale(win.content_scale);
        gui_settings.applyUiScale();
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
            _ = plugin_mgr.resolve(a, specs.items, config_dir);

            // Also try project-local plugins/ directory for any still missing.
            resolveLocalPlugins(a);

            // If some plugins are still missing, activate the startup download overlay.
            var fail_count: u32 = 0;
            for (plugin_mgr.paths.items) |path| {
                if (path == null) fail_count += 1;
            }
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

        // Spawn all resolved plugins that have a valid command.
        for (plugin_mgr.names.items, plugin_mgr.commands.items, plugin_mgr.dirs.items) |name, cmd_str, dir| {
            if (cmd_str.len == 0) continue;
            const resolved_cmd = resolvePluginCommand(a, cmd_str, dir) catch cmd_str;
            defer if (resolved_cmd.ptr != cmd_str.ptr) a.free(resolved_cmd);
            runtime.spawnPlugin(a, name, resolved_cmd, project_dir);
        }
    }

    // Execute startup commands (headed mode: open file + run commands visually).
    if (comptime !is_wasm) {
        switch (cli.startup) {
            .run => |r| {
                app.openPath(r.file) catch {};
                var lines_it = std.mem.splitScalar(u8, r.lines, '\n');
                while (lines_it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;
                    if (trimmed[0] == '#') continue;
                    const result = command.parser.parse(trimmed);
                    switch (result) {
                        .command => |c| {
                            command.dispatch(c, &app) catch {};
                        },
                        .meta => |m| {
                            _ = cli.handleMeta(m, &app);
                        },
                        .meta_arg => |ma| cli.handleMetaArg(ma, &app),
                        .err => {},
                    }
                }
            },
            .none => {},
        }
    }

    // Wire Runtime pointer into AppState so GUI can dispatch to plugins.
    app.plugin_runtime = &runtime;
}

fn appDeinit() void {
    const a = app.allocator();
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

    // Resolve theme cascade if config changed; tick animations every frame.
    if (theme_config.active_config.dirty) {
        theme_config.active_config.resolve();
        runtime.notifyThemeChanged();
    }
    theme_config.active_config.animation.tick(
        dvui.secondsSinceLastFrame(),
        &theme_config.active_config.resolved.canvas,
    );

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
        gui_settings.applyUiScale();
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

        if (comptime !is_wasm) {
            const config_dir = utility.platform.pluginConfigDir(a) catch "";
            defer if (config_dir.len > 0) a.free(config_dir);

            // Resolve plugins listed in the project Config.toml.
            if (app.config.plugins) |po| {
                var specs = std.ArrayListUnmanaged(plugins.PluginSpec){};
                defer specs.deinit(a);
                for (po.enabled) |name| {
                    if (!plugin_mgr.hasSpec(name)) {
                        specs.append(a, .{ .name = name }) catch continue;
                    }
                }
                if (specs.items.len > 0) {
                    // Try global config dir first.
                    _ = plugin_mgr.resolve(a, specs.items, config_dir);
                    // For any still missing, try project-local plugins/ directory.
                    resolveLocalPlugins(a);
                }
            }

            // Auto-discover plugins that may have been installed since startup.
            if (config_dir.len > 0) {
                _ = plugin_mgr.autoDiscover(a, config_dir);
            }

            // Spawn all resolved plugins that have a command and aren't running.
            // Use project dir as cwd so plugins can find Config.toml;
            // resolve relative commands against the plugin dir.
            for (plugin_mgr.names.items, plugin_mgr.commands.items, plugin_mgr.dirs.items) |name, cmd, dir| {
                if (cmd.len == 0) continue;
                if (isPluginRunning(name)) continue;
                const resolved_cmd = resolvePluginCommand(a, cmd, dir) catch cmd;
                defer if (resolved_cmd.ptr != cmd.ptr) a.free(resolved_cmd);
                runtime.spawnPlugin(a, name, resolved_cmd, app.project_dir);
            }
        }
    }
    runtime.tick(app.allocator(), dvui.secondsSinceLastFrame());
}

fn isPluginRunning(name: []const u8) bool {
    for (runtime.plugins.items) |*p| {
        if (std.mem.eql(u8, p.name, name) and (p.state == .running or p.state == .starting)) return true;
    }
    return false;
}

/// For plugins with null paths (not found in config_dir), check local
/// plugins/ directories and fill in their command + dir if found.
/// Search order: {project_dir}/plugins/, then ./plugins/ (repo root).
/// Stores absolute paths so subprocess cwd doesn't affect resolution.
fn resolveLocalPlugins(a: std.mem.Allocator) void {
    const search_dirs: [2][]const u8 = .{
        std.fmt.allocPrint(a, "{s}/plugins", .{app.project_dir}) catch "",
        "plugins",
    };
    defer if (search_dirs[0].len > 0) a.free(@constCast(search_dirs[0]));

    for (plugin_mgr.names.items, plugin_mgr.paths.items, plugin_mgr.commands.items, plugin_mgr.dirs.items) |name, *path, *cmd, *dir| {
        if (path.* != null) continue; // already resolved
        for (&search_dirs) |search_dir| {
            if (search_dir.len == 0) continue;
            const toml_path = std.fmt.allocPrint(a, "{s}/{s}/plugin.toml", .{ search_dir, name }) catch continue;
            utility.platform.fs.cwd().access(toml_path, .{}) catch {
                a.free(toml_path);
                continue;
            };
            // Found locally — read command and set dir.
            path.* = toml_path;
            const new_cmd = readLocalPluginCommand(a, toml_path);
            if (new_cmd.len > 0) {
                if (cmd.len > 0) a.free(cmd.*);
                cmd.* = new_cmd;
            }
            // Store absolute plugin dir so command resolution is cwd-independent.
            const rel_dir = std.fmt.allocPrint(a, "{s}/{s}", .{ search_dir, name }) catch "";
            const abs_dir = if (rel_dir.len > 0)
                (std.fs.cwd().realpathAlloc(a, rel_dir) catch a.dupe(u8, rel_dir) catch "")
            else
                "";
            if (rel_dir.len > 0) a.free(rel_dir);
            if (abs_dir.len > 0) {
                if (dir.len > 0) a.free(dir.*);
                dir.* = abs_dir;
            }
            break;
        }
    }
}

/// Given a command like "python3 src/plugin.py" and a plugin dir, produce a
/// command with the script path as an absolute path.
/// E.g. plugin_dir="/abs/plugins/PDKSwitcher" → "python3 /abs/plugins/PDKSwitcher/src/plugin.py".
fn resolvePluginCommand(a: std.mem.Allocator, cmd: []const u8, plugin_dir: []const u8) ![]const u8 {
    if (plugin_dir.len == 0) return cmd;
    // Split on first space: binary + script path
    const space_idx = std.mem.indexOfScalar(u8, cmd, ' ') orelse return cmd;
    const binary = cmd[0..space_idx];
    const rest = std.mem.trimLeft(u8, cmd[space_idx + 1 ..], &[_]u8{' '});
    if (rest.len == 0) return cmd;
    // If the script path is already absolute, no change needed.
    if (std.fs.path.isAbsolute(rest)) return cmd;
    return std.fmt.allocPrint(a, "{s} {s}/{s}", .{ binary, plugin_dir, rest });
}

fn readLocalPluginCommand(a: std.mem.Allocator, toml_path: []const u8) []const u8 {
    const data = utility.platform.fs.cwd().readFileAlloc(a, toml_path, 64 * 1024) catch return "";
    defer a.free(data);
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
        const trimmed = std.mem.trimLeft(u8, line, &[_]u8{ ' ', '\t' });
        if (!std.mem.startsWith(u8, trimmed, "command")) continue;
        const rest = std.mem.trimLeft(u8, trimmed["command".len..], &[_]u8{ ' ', '\t' });
        if (rest.len == 0 or rest[0] != '=') continue;
        const val = std.mem.trimLeft(u8, rest[1..], &[_]u8{ ' ', '\t' });
        const unquoted = if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val[1 .. val.len - 1] else val;
        if (unquoted.len == 0) continue;
        return a.dupe(u8, unquoted) catch "";
    }
    return "";
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
        .handle_request = &hcHandleRequest,
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
    const alloc = a.gpa.allocator();
    // Dupe the input so parsed slices survive through dispatch.
    const owned = alloc.dupe(u8, cmd_tag) catch return false;
    defer alloc.free(owned);
    const result = command.parser.parse(owned);
    switch (result) {
        .command => |cmd| {
            command.dispatch(cmd, a) catch return false;
            return true;
        },
        else => return false,
    }
}

fn hcRequestRefresh(ctx: *anyopaque) void {
    asApp(ctx).plugin_refresh_requested = true;
}

fn hcHandleRequest(ctx: *anyopaque, method: []const u8, _: ?[]const u8, result: *plugins.RequestResult) bool {
    if (std.mem.eql(u8, method, "host/get_documentation")) {
        const a = asApp(ctx);
        const doc = a.active() orelse {
            writeResult(result, "{\"text\":null}");
            return true;
        };
        const text = doc.sch.str(doc.sch.documentation);
        var fbs = std.io.fixedBufferStream(&result.buf);
        const w = fbs.writer();
        if (text.len == 0) {
            w.writeAll("{\"text\":null}") catch return false;
        } else {
            w.writeAll("{\"text\":\"") catch return false;
            writeJsonEscaped(w, text) catch return false;
            w.writeAll("\"}") catch return false;
        }
        result.len = @intCast(fbs.getWritten().len);
        return true;
    }
    if (std.mem.eql(u8, method, "theme.get_style")) {
        const tc = &theme_config.active_config;
        const cs = &tc.resolved.canvas;
        const pal = &tc.resolved.palette;

        var fbs = std.io.fixedBufferStream(&result.buf);
        const w = fbs.writer();
        w.writeAll("{") catch return false;
        w.print("\"dark\":{s}", .{if (tc.dark) "true" else "false"}) catch return false;
        w.print(",\"wire_color\":[{d},{d},{d}]", .{ cs.wire.color.r, cs.wire.color.g, cs.wire.color.b }) catch return false;
        w.print(",\"pin_color\":[{d},{d},{d}]", .{ cs.pin.color.r, cs.pin.color.g, cs.pin.color.b }) catch return false;
        w.print(",\"canvas_bg\":[{d},{d},{d}]", .{ pal.canvas_bg.r, pal.canvas_bg.g, pal.canvas_bg.b }) catch return false;
        w.writeAll("}") catch return false;
        result.len = @intCast(fbs.getWritten().len);
        return true;
    }
    return false;
}


fn writeResult(result: *plugins.RequestResult, comptime literal: []const u8) void {
    @memcpy(result.buf[0..literal.len], literal);
    result.len = literal.len;
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
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
