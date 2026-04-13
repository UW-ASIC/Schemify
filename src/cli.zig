//! CLI subcommands — plugin management and help.
//! Called from main.zig when a CLI flag is detected; each handler exits the
//! process so the GUI never starts.

const std = @import("std");
const Installer = @import("installer/lib.zig").Installer;
const st = @import("state");
const utility = @import("utility");
const Logger = utility.Logger;

// ── Public type ──────────────────────────────────────────────────────────────

pub const ParsedArgs = union(enum) {
    none,
    help,
    plugin_install: struct { url: []const u8, web: bool },
    plugin_list,
    plugin_remove: []const u8,
    export_svg: []const u8,
    netlist: struct { path: []const u8, xyce: bool },
    err_missing_install_url,
    err_missing_remove_name,
    err_missing_file,
};

// ── Comptime command table ───────────────────────────────────────────────────

const Command = enum { help, plugin_install, plugin_list, plugin_remove, export_svg, netlist };

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "--plugin-install", .plugin_install },
    .{ "--plugin-list", .plugin_list },
    .{ "--plugin-remove", .plugin_remove },
    .{ "--export-svg", .export_svg },
    .{ "--netlist", .netlist },
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

const FlagPathParse = struct {
    enabled: bool = false,
    path: ?[]const u8 = null,
};

fn parseOptionalFlagThenPath(args: []const []const u8, start: usize, flag: []const u8) FlagPathParse {
    var idx = start;
    var out: FlagPathParse = .{};
    if (args.len > idx and std.mem.eql(u8, args[idx], flag)) {
        out.enabled = true;
        idx += 1;
    }
    if (args.len > idx) out.path = args[idx];
    return out;
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
            const parsed = parseOptionalFlagThenPath(args, 2, "--web");
            const path = parsed.path orelse break :blk .err_missing_install_url;
            break :blk .{ .plugin_install = .{ .url = path, .web = parsed.enabled } };
        },
        .plugin_remove => if (args.len < 3)
            .err_missing_remove_name
        else
            .{ .plugin_remove = args[2] },
        .export_svg => if (args.len < 3) .err_missing_file else .{ .export_svg = args[2] },
        .netlist => blk: {
            const parsed = parseOptionalFlagThenPath(args, 2, "--xyce");
            const path = parsed.path orelse break :blk .err_missing_file;
            break :blk .{ .netlist = .{ .path = path, .xyce = parsed.enabled } };
        },
    };
}

fn pluginBaseOrNull(allocator: std.mem.Allocator) ?[]u8 {
    return utility.platform.pluginConfigDir(allocator) catch {
        errPrint("error: cannot resolve $HOME\n", .{});
        return null;
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
            runPluginInstall(allocator, p.url, p.web);
            return true;
        },
        .plugin_list => {
            runPluginList(allocator);
            return true;
        },
        .plugin_remove => |name| {
            runPluginRemove(allocator, name);
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
        .export_svg => |path| {
            runExportSvg(allocator, path);
            return true;
        },
        .netlist => |p| {
            runNetlist(allocator, p.path, p.xyce);
            return true;
        },
        .err_missing_file => {
            errPrint("error: command requires a file path\n", .{});
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
        \\Export / netlist commands (exits immediately, no GUI):
        \\  --export-svg <file.chn>  Export schematic to SVG.
        \\  --netlist [--xyce] <file.chn>
        \\                           Generate SPICE netlist (ngspice default, --xyce for Xyce).
        \\
        \\  --help, -h               Show this help and exit.
        \\
    ) catch {};
}

pub fn runPluginInstall(allocator: std.mem.Allocator, url: []const u8, web: bool) void {
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

pub fn runPluginList(allocator: std.mem.Allocator) void {
    const base = pluginBaseOrNull(allocator) orelse return;
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

pub fn runPluginRemove(allocator: std.mem.Allocator, name: []const u8) void {
    const base = pluginBaseOrNull(allocator) orelse return;
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

// ── Export / netlist CLI ──────────────────────────────────────────────────────

fn openDocOrNull(allocator: std.mem.Allocator, log: *Logger, path: []const u8) ?st.Document {
    return st.Document.open(allocator, log, path) catch |e| {
        errPrint("error: failed to open {s}: {}\n", .{ path, e });
        return null;
    };
}

fn svgOutputPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    const stem_end = std.mem.lastIndexOf(u8, path, ".") orelse path.len;
    return std.fmt.bufPrint(buf, "{s}.svg", .{path[0..stem_end]}) catch {
        errPrint("error: path too long\n", .{});
        return null;
    };
}

pub fn runExportSvg(allocator: std.mem.Allocator, path: []const u8) void {
    var log = Logger.init(.info);

    var doc = openDocOrNull(allocator, &log, path) orelse return;
    defer doc.deinit();

    var buf: [512]u8 = undefined;
    const svg_path = svgOutputPath(path, &buf) orelse return;

    // Generate SVG.
    const file = std.fs.cwd().createFile(svg_path, .{}) catch {
        errPrint("error: cannot create {s}\n", .{svg_path});
        return;
    };
    defer file.close();

    writeSvgFromDoc(&doc, file) catch {
        errPrint("error: SVG write failed\n", .{});
        return;
    };
    outPrint("exported: {s}\n", .{svg_path});
}

fn writeSvgFromDoc(doc: *const st.Document, file: std.fs.File) !void {
    const sch = &doc.sch;
    var lo: @Vector(2, i32) = @splat(std.math.maxInt(i32));
    var hi: @Vector(2, i32) = @splat(std.math.minInt(i32));
    for (0..sch.wires.len) |i| {
        const wire = sch.wires.get(i);
        const ws = @Vector(2, i32){ wire.x0, wire.y0 };
        const we = @Vector(2, i32){ wire.x1, wire.y1 };
        lo = @min(lo, @min(ws, we));
        hi = @max(hi, @max(ws, we));
    }
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        const ip = @Vector(2, i32){ inst.x, inst.y };
        lo = @min(lo, ip);
        hi = @max(hi, ip);
    }
    if (lo[0] > hi[0]) {
        lo = @splat(0);
        hi = @splat(100);
    }
    const margin: @Vector(2, i32) = @splat(50);
    lo -= margin;
    hi += margin;

    var buf: [512]u8 = undefined;
    var len: usize = 0;

    len = (std.fmt.bufPrint(&buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d} {d} {d} {d}\">\n", .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] }) catch &buf).len;
    try file.writeAll(buf[0..len]);
    try file.writeAll("<style>line.w{stroke:#58d2ff;stroke-width:2}text{font:10px monospace;fill:#ccc}rect.i{fill:none;stroke:#8cf;stroke-width:1}</style>\n");
    try file.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"#16161c\"/>\n");
    for (0..sch.wires.len) |i| {
        const wire = sch.wires.get(i);
        len = (std.fmt.bufPrint(&buf, "<line class=\"w\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ wire.x0, wire.y0, wire.x1, wire.y1 }) catch &buf).len;
        try file.writeAll(buf[0..len]);
    }
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        len = (std.fmt.bufPrint(&buf, "<g><rect class=\"i\" x=\"{d}\" y=\"{d}\" width=\"30\" height=\"30\" rx=\"3\"/>", .{ inst.x - 15, inst.y - 15 }) catch &buf).len;
        try file.writeAll(buf[0..len]);
        len = (std.fmt.bufPrint(&buf, "<text x=\"{d}\" y=\"{d}\">{s}</text></g>\n", .{ inst.x - 12, inst.y + 3, inst.name }) catch &buf).len;
        try file.writeAll(buf[0..len]);
    }
    try file.writeAll("</svg>\n");
}

pub fn runNetlist(allocator: std.mem.Allocator, path: []const u8, xyce: bool) void {
    var log = Logger.init(.info);

    var doc = openDocOrNull(allocator, &log, path) orelse return;
    defer doc.deinit();

    const sim: st.Sim = if (xyce) .xyce else .ngspice;
    const netlist = doc.createNetlist(sim) catch {
        errPrint("error: netlist generation failed\n", .{});
        return;
    };

    // Write to stdout.
    std.fs.File.stdout().writeAll(netlist) catch {};
}
