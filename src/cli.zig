//! CLI subcommands — plugin management and help.
//! Called from main.zig when a CLI flag is detected; each handler exits the
//! process so the GUI never starts.

const std       = @import("std");
const Installer = @import("plugins/installer.zig");

pub const ParsedArgs = union(enum) {
    none,
    help,
    plugin_install:      struct { url: []const u8, web: bool },
    plugin_list,
    plugin_remove:       []const u8,
    err_missing_install_url,
    err_missing_remove_name,
};

// ── Output helpers ────────────────────────────────────────────────────────────

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

/// Return the per-user plugin base directory: `$HOME/.config/Schemify`.
pub fn userPluginBase(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "Schemify" });
}

// ── Subcommands ───────────────────────────────────────────────────────────────

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

    const opts: Installer.InstallOptions = if (web)
        .{ .target = .web }
    else
        .{ .target = .native };

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

    // Each subdirectory is a plugin; report its native binary.
    var it = root.iterate();
    var count: usize = 0;
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        outPrint("  {s}/\n", .{entry.name});
        count += 1;
    }
    if (count == 0) std.fs.File.stdout().writeAll("  (none)\n") catch {};
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

    // Remove the entire plugin subdirectory.
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

/// Parse CLI args into a command-like action for easier testing.
/// Expects `args` to include argv[0] as the first item.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len < 2) return .none;
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, cmd, "--plugin-install")) {
        // --plugin-install [--web] <url>
        var idx: usize = 2;
        var web = false;
        if (args.len > idx and std.mem.eql(u8, args[idx], "--web")) {
            web = true;
            idx += 1;
        }
        if (args.len <= idx) return .err_missing_install_url;
        return .{ .plugin_install = .{ .url = args[idx], .web = web } };
    }
    if (std.mem.eql(u8, cmd, "--plugin-list")) {
        return .plugin_list;
    }
    if (std.mem.eql(u8, cmd, "--plugin-remove")) {
        if (args.len < 3) return .err_missing_remove_name;
        return .{ .plugin_remove = args[2] };
    }

    return .none;
}

/// Dispatch CLI args. Returns true if a CLI command was handled (and the
/// process should exit), false if the GUI should start normally.
pub fn dispatch() bool {
    const argv = std.os.argv;
    var stack_args: [32][]const u8 = undefined;
    if (argv.len > stack_args.len) return false;
    for (argv, 0..) |arg, i| {
        stack_args[i] = std.mem.span(arg);
    }

    return switch (parseArgs(stack_args[0..argv.len])) {
        .none => false,
        .help => blk: {
            printHelp();
            break :blk true;
        },
        .plugin_install => |p| blk: {
            runPluginInstall(p.url, p.web);
            break :blk true;
        },
        .plugin_list => blk: {
            runPluginList();
            break :blk true;
        },
        .plugin_remove => |name| blk: {
            runPluginRemove(name);
            break :blk true;
        },
        .err_missing_install_url => blk: {
            errPrint("error: --plugin-install requires a URL\n", .{});
            std.process.exit(1);
            break :blk true;
        },
        .err_missing_remove_name => blk: {
            errPrint("error: --plugin-remove requires a plugin name\n", .{});
            std.process.exit(1);
            break :blk true;
        },
    };
}
