//! CLI subcommands — plugin management and help.
//! Called from main.zig when a CLI flag is detected; each handler exits the
//! process so the GUI never starts.

const std = @import("std");
const Installer = @import("installer");

// ── Public type ──────────────────────────────────────────────────────────────

pub const ParsedArgs = union(enum) {
    none,
    help,
    plugin_install: struct { url: []const u8, web: bool },
    plugin_list,
    plugin_remove: []const u8,
    err_missing_install_url,
    err_missing_remove_name,
};

// ── Comptime command table ───────────────────────────────────────────────────

const Command = enum { help, plugin_install, plugin_list, plugin_remove };

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "--plugin-install", .plugin_install },
    .{ "--plugin-list", .plugin_list },
    .{ "--plugin-remove", .plugin_remove },
});

// ── Output helpers (private) ─────────────────────────────────────────────────

fn outPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stderr().writeAll(s) catch {};
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Return the per-user plugin base directory: `$HOME/.config/Schemify`.
pub fn userPluginBase(allocator: std.mem.Allocator) (error{NoHomeDir} || std.mem.Allocator.Error)![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "Schemify" });
}

/// Parse CLI args into a command-like action for easier testing.
/// Expects `args` to include argv[0] as the first item.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len < 2) return .none;

    const cmd = command_map.get(args[1]) orelse return .none;
    return switch (cmd) {
        .help => .help,
        .plugin_list => .plugin_list,
        .plugin_install => blk: {
            var idx: usize = 2;
            var web = false;
            if (args.len > idx and std.mem.eql(u8, args[idx], "--web")) {
                web = true;
                idx += 1;
            }
            if (args.len <= idx) break :blk .err_missing_install_url;
            break :blk .{ .plugin_install = .{ .url = args[idx], .web = web } };
        },
        .plugin_remove => if (args.len < 3)
            .err_missing_remove_name
        else
            .{ .plugin_remove = args[2] },
    };
}

/// Dispatch CLI args. Returns true if a CLI command was handled (and the
/// process should exit), false if the GUI should start normally.
pub fn dispatch() bool {
    const argv = std.os.argv;
    // Only the first 2 argv entries (program + command verb) are needed to
    // decide whether a CLI command is present; anything beyond that is
    // retrieved on-demand inside parseArgs. Bail out early if we have
    // fewer than 2 to avoid any work.
    if (argv.len < 2) return false;

    // Heap-allocate a slice to avoid a fixed-capacity stack limit.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);
    for (argv) |arg| {
        args.append(allocator, std.mem.span(arg)) catch return false;
    }

    switch (parseArgs(args.items)) {
        .none => return false,
        .help => {
            printHelp();
            return true;
        },
        .plugin_install => |p| {
            runPluginInstall(p.url, p.web);
            return true;
        },
        .plugin_list => {
            runPluginList();
            return true;
        },
        .plugin_remove => |name| {
            runPluginRemove(name);
            return true;
        },
        .err_missing_install_url => {
            errPrint("error: --plugin-install requires a URL\n", .{});
            std.process.exit(1);
        },
        .err_missing_remove_name => {
            errPrint("error: --plugin-remove requires a plugin name\n", .{});
            std.process.exit(1);
        },
    }
}

pub fn printHelp() void {
    std.fs.File.stdout().writeAll(
        \\Usage: schemify [OPTIONS] [PROJECT_DIR]
        \\
        \\  PROJECT_DIR              Open this project directory (default: .)
        \\
        \\Plugin commands (exits immediately, no GUI):
        \\  --plugin-install [--web] <url>
        \\                           Install a plugin from a URL.
        \\                           Without --web: downloads the native binary
        \\                             (.so/.dylib/.dll) to ~/.config/Schemify/<name>/
        \\                           With --web: downloads the .wasm artifact to
        \\                             zig-out/bin/plugins/ and updates plugins.json
        \\                           Accepts a GitHub repo URL (auto-resolves latest
        \\                           release) or a direct file link.
        \\                           Examples:
        \\                             schemify --plugin-install https://github.com/user/my-plugin
        \\                             schemify --plugin-install https://github.com/user/my-plugin/releases/download/v1.0/libMyPlugin.so
        \\                             schemify --plugin-install --web https://github.com/user/my-plugin
        \\
        \\  --plugin-list            List installed native plugins.
        \\
        \\  --plugin-remove <name>   Remove a native plugin by name stem.
        \\                             schemify --plugin-remove my-plugin
        \\
        \\  --help, -h               Show this help and exit.
        \\
    ) catch {};
}

pub fn runPluginInstall(url: []const u8, web: bool) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts: Installer.InstallOptions = .{ .target = if (web) .web else .native };

    const path = Installer.install(allocator, url, opts) catch |e| {
        errPrint("error: install failed: {}\n", .{e});
        return;
    };
    defer allocator.free(path);

    if (web) {
        outPrint("installed (web): {s}\n", .{path});
        outPrint("plugins.json updated — deploy zig-out/bin/ to your web server.\n", .{});
    } else {
        outPrint("installed: {s}\n", .{path});
        outPrint("Restart Schemify (or press the refresh key) to load the plugin.\n", .{});
    }
}

pub fn runPluginList() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const base = userPluginBase(allocator) catch {
        errPrint("error: cannot resolve $HOME\n", .{});
        return;
    };
    defer allocator.free(base);

    var root = std.fs.cwd().openDir(base, .{ .iterate = true }) catch {
        outPrint("No plugins installed ({s} not found).\n", .{base});
        return;
    };
    defer root.close();

    outPrint("Installed plugins in {s}:\n", .{base});

    var it = root.iterate();
    var count: usize = 0;
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        outPrint("  {s}/\n", .{entry.name});
        count += 1;
    }
    if (count == 0) outPrint("  (none)\n", .{});
}

pub fn runPluginRemove(name: []const u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const base = userPluginBase(allocator) catch {
        errPrint("error: cannot resolve $HOME\n", .{});
        return;
    };
    defer allocator.free(base);

    const plugin_dir = std.fs.path.join(allocator, &.{ base, name }) catch {
        errPrint("error: OOM\n", .{});
        return;
    };
    defer allocator.free(plugin_dir);

    if (std.fs.cwd().deleteTree(plugin_dir)) {
        outPrint("removed: {s}\n", .{plugin_dir});
    } else |_| {
        errPrint("error: plugin '{s}' not found in {s}\n", .{ name, base });
    }
}
