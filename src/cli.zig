const std = @import("std");
const core = @import("schematic");
const utility = @import("utility");
const st = @import("state");
const command = @import("commands");
const parser = command.parser;
const import_mod = @import("import");

// ── Parsed CLI action ────────────────────────────────────────────────────────

pub const ImportKind = enum { component, primitive, testbench };

pub const ParsedArgs = union(enum) {
    none,
    help,
    plugin_install: struct { url: []const u8, web: bool },
    plugin_list,
    plugin_remove: []const u8,
    export_svg: []const u8,
    netlist: struct { path: []const u8, xyce: bool, pyspice: bool },
    import_file: struct { path: []const u8, kind: ?ImportKind, output_dir: ?[]const u8 },
    import_project: struct { dir: []const u8, recursive: bool, output_dir: ?[]const u8 },
    discover: []const u8,
    optimize: struct { path: []const u8, max_gen: u32 },
    cmd: struct { file: []const u8, rest: []const []const u8, headless: bool },
    batch: struct { file: []const u8, headless: bool },
    commands,
    err_missing_install_url,
    err_missing_remove_name,
    err_missing_file,
    err_missing_cmd,
    err_invalid_import_kind,
};

// ── Comptime command table ───────────────────────────────────────────────────

const Cmd = enum { help, plugin_install, plugin_list, plugin_remove, export_svg, netlist, import_file, import_project, discover, optimize, cmd_mode, batch_mode, commands_mode };

const cmd_map = std.StaticStringMap(Cmd).initComptime(.{
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "--plugin-install", .plugin_install },
    .{ "--plugin-list", .plugin_list },
    .{ "--plugin-remove", .plugin_remove },
    .{ "--export-svg", .export_svg },
    .{ "--netlist", .netlist },
    .{ "--import", .import_file },
    .{ "--import-project", .import_project },
    .{ "--discover", .discover },
    .{ "--optimize", .optimize },
    .{ "--cmd", .cmd_mode },
    .{ "--batch", .batch_mode },
    .{ "--commands", .commands_mode },
});

// ── Startup mode (headed routing) ────────────────────────────────────────────

pub const StartupMode = union(enum) {
    none,
    /// Headed startup: open file in GUI, execute commands visually.
    run: struct {
        file: []const u8,
        lines: []const u8,
    },
};

pub var startup: StartupMode = .none;

pub fn isChnPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".chn") or
        std.mem.endsWith(u8, path, ".chn_tb") or
        std.mem.endsWith(u8, path, ".chn_prim");
}

// ── Output helpers ───────────────────────────────────────────────────────────

fn outPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const out = utility.platform.fs.stdout();
    out.writeAll(s) catch {};
}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const err = utility.platform.fs.stderr();
    err.writeAll(s) catch {};
}

// ── Arg parsing ──────────────────────────────────────────────────────────────

fn parseOptionalFlag(args: []const []const u8, start: usize, flag: []const u8) struct { enabled: bool, next: usize } {
    if (args.len > start and std.mem.eql(u8, args[start], flag))
        return .{ .enabled = true, .next = start + 1 };
    return .{ .enabled = false, .next = start };
}

fn parseOptionalArg(args: []const []const u8, start: usize, flag: []const u8) struct { value: ?[]const u8, next: usize } {
    if (args.len > start + 1 and std.mem.eql(u8, args[start], flag))
        return .{ .value = args[start + 1], .next = start + 2 };
    return .{ .value = null, .next = start };
}

pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len < 2) return .none;

    // Check for --headless prefix flag.
    const headless = std.mem.eql(u8, args[1], "--headless");
    const off: usize = if (headless) 1 else 0;

    if (args.len < 2 + off) return .none;

    if (cmd_map.get(args[1 + off])) |cmd| {
        return switch (cmd) {
            .help => .help,
            .plugin_list => .plugin_list,
            .plugin_install => blk: {
                const f = parseOptionalFlag(args, 2 + off, "--web");
                const path = if (args.len > f.next) args[f.next] else break :blk .err_missing_install_url;
                break :blk .{ .plugin_install = .{ .url = path, .web = f.enabled } };
            },
            .plugin_remove => if (args.len < 3 + off)
                .err_missing_remove_name
            else
                .{ .plugin_remove = args[2 + off] },
            .export_svg => if (args.len < 3 + off) .err_missing_file else .{ .export_svg = args[2 + off] },
            .netlist => blk: {
                var idx: usize = 2 + off;
                const xf = parseOptionalFlag(args, idx, "--xyce");
                idx = xf.next;
                const pf = parseOptionalFlag(args, idx, "--pyspice");
                idx = pf.next;
                const path = if (args.len > idx) args[idx] else break :blk .err_missing_file;
                break :blk .{ .netlist = .{ .path = path, .xyce = xf.enabled, .pyspice = pf.enabled } };
            },
            .import_file => blk: {
                var idx: usize = 2 + off;
                const o = parseOptionalArg(args, idx, "-o");
                idx = o.next;
                if (args.len <= idx) break :blk .err_missing_file;
                const path = args[idx];
                idx += 1;
                const kind: ?ImportKind = if (args.len > idx) parseImportKind(args[idx]) orelse break :blk .err_invalid_import_kind else null;
                break :blk .{ .import_file = .{ .path = path, .kind = kind, .output_dir = o.value } };
            },
            .import_project => blk: {
                var idx: usize = 2 + off;
                const o = parseOptionalArg(args, idx, "-o");
                idx = o.next;
                const f = parseOptionalFlag(args, idx, "-r");
                idx = f.next;
                const dir = if (args.len > idx) args[idx] else break :blk .err_missing_file;
                break :blk .{ .import_project = .{ .dir = dir, .recursive = f.enabled, .output_dir = o.value } };
            },
            .discover => if (args.len < 3 + off) .err_missing_file else .{ .discover = args[2 + off] },
            .optimize => blk: {
                var max_gen: u32 = 20;
                var path: ?[]const u8 = null;
                var idx: usize = 2 + off;
                while (idx < args.len) {
                    if (std.mem.eql(u8, args[idx], "--gen")) {
                        idx += 1;
                        if (idx < args.len) {
                            max_gen = std.fmt.parseInt(u32, args[idx], 10) catch 20;
                            idx += 1;
                        }
                    } else {
                        path = args[idx];
                        idx += 1;
                    }
                }
                break :blk if (path) |p| .{ .optimize = .{ .path = p, .max_gen = max_gen } } else .err_missing_file;
            },
            .cmd_mode => blk: {
                if (args.len < 3 + off) break :blk .err_missing_file;
                if (args.len < 4 + off) break :blk .err_missing_cmd;
                break :blk .{ .cmd = .{ .file = args[2 + off], .rest = args[3 + off ..], .headless = headless } };
            },
            .batch_mode => if (args.len < 3 + off) .err_missing_file else .{ .batch = .{ .file = args[2 + off], .headless = headless } },
            .commands_mode => .commands,
        };
    }

    // No known command flag — check for bare-file pattern.
    if (isChnPath(args[1 + off])) {
        if (args.len > 2 + off) {
            // bare file + commands: schemify [--headless] file.chn command args...
            return .{ .cmd = .{ .file = args[1 + off], .rest = args[2 + off ..], .headless = headless } };
        } else if (headless) {
            // schemify --headless file.chn (no commands) → batch from stdin
            return .{ .batch = .{ .file = args[1 + off], .headless = true } };
        }
        // schemify file.chn (no commands, no headless) → none (GUI opens with file)
    }

    return .none;
}

/// Walk up from `start_dir` looking for a directory containing xschemrc.
fn findXschemRoot(start_dir: []const u8) ?[]const u8 {
    var dir = start_dir;
    var depth: u8 = 0;
    while (depth < 5) : (depth += 1) {
        // Check if xschemrc exists in this directory
        var buf: [512]u8 = undefined;
        const rc = std.fmt.bufPrint(&buf, "{s}/xschemrc", .{dir}) catch return null;
        utility.platform.fs.cwd().access(rc, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse return null;
            continue;
        };
        return dir;
    }
    return null;
}

// ── Dispatch ─────────────────────────────────────────────────────────────────

/// Returns true if a CLI command was handled (process should exit).
/// Returns false if the GUI should start.
pub fn dispatch() bool {
    const argv = std.os.argv;
    if (argv.len < 2) return false;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(a);
    for (argv) |arg| args.append(a, std.mem.span(arg)) catch return false;

    switch (parseArgs(args.items)) {
        .none => return false,
        .help => { printHelp(); return true; },
        .plugin_install => |p| { runPluginInstall(a, p.url, p.web); return true; },
        .plugin_list => { runPluginList(a); return true; },
        .plugin_remove => |name| { runPluginRemove(a, name); return true; },
        .export_svg => |path| { runExportSvg(a, path); return true; },
        .netlist => |p| { runNetlist(a, p.path, p.xyce, p.pyspice); return true; },
        .import_file => |p| { runImport(a, p.path, p.kind, p.output_dir); return true; },
        .import_project => |p| { runImportProject(a, p.dir, p.recursive, p.output_dir); return true; },
        .discover => |path| { runDiscover(a, path); return true; },
        .optimize => |p| { runOptimize(a, p.path, p.max_gen); return true; },
        .cmd => |c| {
            if (c.headless) {
                runHeadlessCmd(a, c.file, c.rest);
            } else {
                setupHeadedRun(c.file, c.rest);
                return false;
            }
            return true;
        },
        .batch => |b| {
            if (b.headless) {
                runHeadlessBatch(a, b.file);
            } else {
                setupHeadedBatch(a, b.file);
                return false;
            }
            return true;
        },
        .commands => { printAllCommands(); return true; },
        .err_missing_install_url => { errPrint("error: --plugin-install requires a URL\n", .{}); std.process.exit(1); },
        .err_missing_remove_name => { errPrint("error: --plugin-remove requires a plugin name\n", .{}); std.process.exit(1); },
        .err_missing_file => { errPrint("error: command requires a file path\n", .{}); std.process.exit(1); },
        .err_missing_cmd => { errPrint("error: --cmd requires: <file> <command> [args...]\n", .{}); std.process.exit(1); },
        .err_invalid_import_kind => { errPrint("error: --import kind must be: component, primitive, or testbench\n", .{}); std.process.exit(1); },
    }
}

fn setupHeadedRun(file: []const u8, cmd_args: []const []const u8) void {
    const pa = std.heap.page_allocator;
    // Join command args into a single line.
    var total: usize = 0;
    for (cmd_args, 0..) |arg, i| {
        if (i > 0) total += 1;
        total += arg.len;
    }
    const lines = pa.alloc(u8, total) catch return;
    var pos: usize = 0;
    for (cmd_args, 0..) |arg, i| {
        if (i > 0) {
            lines[pos] = ' ';
            pos += 1;
        }
        @memcpy(lines[pos..][0..arg.len], arg);
        pos += arg.len;
    }
    const file_dupe = pa.dupe(u8, file) catch return;
    startup = .{ .run = .{ .file = file_dupe, .lines = lines } };
}

fn setupHeadedBatch(a: std.mem.Allocator, file: []const u8) void {
    const pa = std.heap.page_allocator;
    // Read all stdin.
    const stdin_file = utility.platform.fs.stdin();
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&buf) catch break;
        if (n == 0) break;
        content.appendSlice(a, buf[0..n]) catch break;
    }
    const lines = pa.dupe(u8, content.items) catch return;
    const file_dupe = pa.dupe(u8, file) catch return;
    startup = .{ .run = .{ .file = file_dupe, .lines = lines } };
}

pub fn printHelp() void {
    const out = utility.platform.fs.stdout();
    out.writeAll(
        \\Usage: schemify [--headless] [OPTIONS] [PROJECT_DIR|FILE]
        \\
        \\  PROJECT_DIR              Open this project directory (default: .)
        \\  FILE.chn [command...]    Open file in GUI and execute commands visually.
        \\  --headless               Execute commands without opening the GUI.
        \\                           Default behavior is headed (opens GUI).
        \\
        \\Command execution:
        \\  schemify file.chn <command> [args...]
        \\                           Open file, execute command, show result in GUI.
        \\  --cmd <file.chn> <command> [args...]
        \\                           Same as above (explicit form).
        \\  --batch <file.chn>       Open file, read commands from stdin, show in GUI.
        \\  --headless file.chn <command> [args...]
        \\                           Execute command without GUI, auto-save, exit.
        \\  --headless --batch <file.chn>
        \\                           Execute stdin commands without GUI, save, exit.
        \\  --commands               List all available commands.
        \\
        \\Plugin commands:
        \\  --plugin-install [--web] <url>
        \\                           Install a plugin from a URL.
        \\  --plugin-list            List installed native plugins.
        \\  --plugin-remove <name>   Remove a native plugin by name.
        \\
        \\Import commands:
        \\  --import [-o <dir>] <file> [component|primitive|testbench]
        \\                           Import .py or .sp/.spice/.cir file as .chn.
        \\                           Type auto-detected from content if omitted.
        \\                           -o: output directory (default: CWD).
        \\  --import-project [-o <dir>] [-r] <dir>
        \\                           Import all PySpice files from a directory.
        \\                           -r: recurse into subdirectories.
        \\                           -o: output directory (default: CWD).
        \\
        \\Export / netlist commands:
        \\  --export-svg <file.chn>  Export schematic to SVG.
        \\  --netlist [--xyce] [--pyspice] <file.chn|.chn_tb>
        \\                           Generate SPICE netlist (ngspice default).
        \\                           --pyspice: emit pyspice_rs Python script.
        \\                           Pipe to python3 for actual SPICE output.
        \\
        \\Optimizer commands:
        \\  --discover <file.chn|.chn_tb>
        \\                           Discover optimizable devices and measurements.
        \\                           Scans linked .chn_tb files for measurements.
        \\  --optimize [--gen <N>] <file.chn>
        \\                           Run NSGA-II optimizer on a schematic.
        \\                           --gen: max generations (default: 20).
        \\                           Auto-discovers devices, measurements, and
        \\                           testbench script from linked .chn_tb files.
        \\
        \\  --help, -h               Show this help and exit.
        \\
    ) catch {};
}

// ── Plugin commands ──────────────────────────────────────────────────────────

fn pluginBaseOrNull(a: std.mem.Allocator) ?[]u8 {
    return utility.platform.pluginConfigDir(a) catch {
        errPrint("error: cannot resolve $HOME\n", .{});
        return null;
    };
}

pub fn runPluginInstall(a: std.mem.Allocator, url: []const u8, web: bool) void {
    const base = pluginBaseOrNull(a) orelse return;
    defer a.free(base);

    // Ensure plugin directory exists
    var mkdir = std.process.Child.init(&.{ "mkdir", "-p", base }, a);
    mkdir.stdin_behavior = .Ignore;
    mkdir.stdout_behavior = .Ignore;
    mkdir.stderr_behavior = .Ignore;
    mkdir.spawn() catch {};
    _ = mkdir.wait() catch {};

    if (web) {
        // Web plugin: download file to plugins directory
        outPrint("Downloading plugin from {s}...\n", .{url});
        const data = utility.platform.httpGetSync(a, url) catch {
            errPrint("error: failed to download {s}\n", .{url});
            return;
        };
        defer a.free(data);
        const fname = std.fs.path.basename(url);
        const target = std.fs.path.join(a, &.{ base, fname }) catch {
            errPrint("error: OOM\n", .{});
            return;
        };
        defer a.free(target);
        utility.platform.fs.cwd().writeFile(.{ .sub_path = target, .data = data }) catch {
            errPrint("error: failed to write {s}\n", .{target});
            return;
        };
        outPrint("installed: {s}\n", .{target});
    } else {
        // Native plugin: git clone into plugins directory
        outPrint("Cloning {s} into {s}...\n", .{ url, base });
        var child = std.process.Child.init(&.{ "git", "-C", base, "clone", url }, a);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            errPrint("error: failed to run git clone (is git installed?)\n", .{});
            return;
        };
        const term = child.wait() catch {
            errPrint("error: git clone failed\n", .{});
            return;
        };
        if (term == .Exited and term.Exited == 0) {
            outPrint("Plugin installed successfully.\n", .{});
        } else {
            errPrint("error: git clone exited with non-zero status\n", .{});
        }
    }
}

pub fn runPluginList(a: std.mem.Allocator) void {
    const base = pluginBaseOrNull(a) orelse return;
    defer a.free(base);

    var root = utility.platform.fs.cwd().openDir(base, .{ .iterate = true }) catch {
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

pub fn runPluginRemove(a: std.mem.Allocator, name: []const u8) void {
    const base = pluginBaseOrNull(a) orelse return;
    defer a.free(base);

    const plugin_dir = std.fs.path.join(a, &.{ base, name }) catch {
        errPrint("error: OOM\n", .{});
        return;
    };
    defer a.free(plugin_dir);

    if (utility.platform.fs.cwd().deleteTree(plugin_dir)) {
        outPrint("removed: {s}\n", .{plugin_dir});
    } else |_| {
        errPrint("error: plugin '{s}' not found in {s}\n", .{ name, base });
    }
}

// ── Export / Netlist ─────────────────────────────────────────────────────────

fn openDocOrNull(a: std.mem.Allocator, log: *utility.Logger, path: []const u8) ?st.Document {
    return st.Document.open(a, log, path) catch |e| {
        errPrint("error: failed to open {s}: {}\n", .{ path, e });
        return null;
    };
}

pub fn runExportSvg(a: std.mem.Allocator, path: []const u8) void {
    var log = utility.Logger.init(.info);
    var doc = openDocOrNull(a, &log, path) orelse return;
    defer doc.deinit();

    var buf: [512]u8 = undefined;
    const stem_end = std.mem.lastIndexOf(u8, path, ".") orelse path.len;
    const svg_path = std.fmt.bufPrint(&buf, "{s}.svg", .{path[0..stem_end]}) catch {
        errPrint("error: path too long\n", .{});
        return;
    };

    const file = utility.platform.fs.cwd().createFile(svg_path, .{}) catch {
        errPrint("error: cannot create {s}\n", .{svg_path});
        return;
    };
    defer file.close();

    writeSvg(&doc.sch, file) catch {
        errPrint("error: SVG write failed\n", .{});
        return;
    };
    outPrint("exported: {s}\n", .{svg_path});
}

fn writeSvg(sch: *const core.Schemify, file: utility.platform.fs.File) !void {
    var lo: @Vector(2, i32) = @splat(std.math.maxInt(i32));
    var hi: @Vector(2, i32) = @splat(std.math.minInt(i32));
    for (0..sch.wires.len) |i| {
        const w = sch.wires.get(i);
        lo = @min(lo, @min(@Vector(2, i32){ w.x0, w.y0 }, @Vector(2, i32){ w.x1, w.y1 }));
        hi = @max(hi, @max(@Vector(2, i32){ w.x0, w.y0 }, @Vector(2, i32){ w.x1, w.y1 }));
    }
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        const p = @Vector(2, i32){ inst.x, inst.y };
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    if (lo[0] > hi[0]) { lo = @splat(0); hi = @splat(100); }
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
        const w = sch.wires.get(i);
        len = (std.fmt.bufPrint(&buf, "<line class=\"w\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ w.x0, w.y0, w.x1, w.y1 }) catch &buf).len;
        try file.writeAll(buf[0..len]);
    }
    for (0..sch.instances.len) |i| {
        const inst = sch.instances.get(i);
        len = (std.fmt.bufPrint(&buf, "<g><rect class=\"i\" x=\"{d}\" y=\"{d}\" width=\"30\" height=\"30\" rx=\"3\"/>", .{ inst.x - 15, inst.y - 15 }) catch &buf).len;
        try file.writeAll(buf[0..len]);
        len = (std.fmt.bufPrint(&buf, "<text x=\"{d}\" y=\"{d}\">{s}</text></g>\n", .{ inst.x - 12, inst.y + 3, sch.str(inst.name) }) catch &buf).len;
        try file.writeAll(buf[0..len]);
    }
    try file.writeAll("</svg>\n");
}

pub fn runNetlist(a: std.mem.Allocator, path: []const u8, xyce: bool, pyspice: bool) void {
    var log = utility.Logger.init(.info);
    var doc = openDocOrNull(a, &log, path) orelse return;
    defer doc.deinit();

    // Reject primitives — they have no simulatable netlist
    if (doc.sch.stype == .primitive) {
        errPrint("error: cannot generate netlist from a primitive (.chn_prim)\n", .{});
        return;
    }

    const out = utility.platform.fs.stdout();

    if (pyspice) {
        // Prefer stored pyspice_source if available (user-edited or imported)
        const stored = doc.sch.str(doc.sch.pyspice_source);
        if (stored.len > 0) {
            out.writeAll(stored) catch {};
            // Ensure trailing newline
            if (stored[stored.len - 1] != '\n') out.writeAll("\n") catch {};
            return;
        }
        // Otherwise generate from schematic
        const simulation = @import("simulation");
        const backend: simulation.SpiceIF.Backend = if (xyce) .xyce else .ngspice;
        const code = simulation.Netlist.emitPySpice(&doc.sch, a, null, backend) catch {
            errPrint("error: PySpice generation failed\n", .{});
            return;
        };
        defer a.free(code);
        out.writeAll(code) catch {};
    } else {
        const netlist = doc.createNetlist() catch {
            errPrint("error: netlist generation failed\n", .{});
            return;
        };
        defer a.free(netlist);
        out.writeAll(netlist) catch {};
    }
}

// ── Import ───────────────────────────────────────────────────────────────────

fn parseImportKind(arg: []const u8) ?ImportKind {
    const map = std.StaticStringMap(ImportKind).initComptime(.{
        .{ "component", .component },
        .{ "primitive", .primitive },
        .{ "testbench", .testbench },
    });
    return map.get(arg);
}

/// Unified import: .py files → PySpice pipeline, .sp/.spice/.cir → raw SPICE pipeline.
/// Kind is optional — auto-detected from content when null.
pub fn runImport(a: std.mem.Allocator, path: []const u8, kind: ?ImportKind, output_dir: ?[]const u8) void {
    const ext = std.fs.path.extension(path);
    const is_python = std.mem.eql(u8, ext, ".py");
    const is_xschem = std.mem.eql(u8, ext, ".sch") or std.mem.eql(u8, ext, ".sym");

    var result: import_mod.ConvertResultList = undefined;

    if (is_python) {
        result = import_mod.importProject(a, .{
            .pyspice_file = .{ .path = path },
        }) catch |e| {
            errPrint("error: import failed: {}\n", .{e});
            return;
        };
    } else if (is_xschem) {
        // Single .sym/.sch file: parse and convert directly (no full project scan)
        const source = utility.platform.fs.cwd().readFileAlloc(a, path, 4 << 20) catch {
            errPrint("error: cannot read {s}\n", .{path});
            return;
        };
        defer a.free(source);

        const XSchem = import_mod.XSchem;
        var parsed = XSchem.reader.parse(a, source) catch {
            errPrint("error: failed to parse xschem file\n", .{});
            return;
        };
        defer parsed.deinit();

        var list_arena = std.heap.ArenaAllocator.init(a);
        errdefer list_arena.deinit();
        const la = list_arena.allocator();

        const stem = std.fs.path.stem(std.fs.path.basename(path));
        const schemify = XSchem.converter.convert(la, &parsed, null, stem, null) catch {
            errPrint("error: xschem conversion failed\n", .{});
            list_arena.deinit();
            return;
        };

        var results_buf = [1]import_mod.ConvertResult{.{
            .name = stem,
            .sch_path = null,
            .sym_path = path,
            .schemify = schemify,
        }};
        result = .{ .results = &results_buf, .arena = list_arena };
        // Write results before deinit (result lives on stack, writeImportResults below uses it)
        writeImportResults(a, result.results, kind, output_dir);
        list_arena.deinit();
        return;
    } else {
        // Raw SPICE files
        const source = utility.platform.fs.cwd().readFileAlloc(a, path, 1 << 24) catch {
            errPrint("error: cannot read {s}\n", .{path});
            return;
        };
        defer a.free(source);

        result = import_mod.importProject(a, .{
            .spice_text = .{ .source = source, .name = std.fs.path.stem(path) },
        }) catch |e| {
            errPrint("error: import failed: {}\n", .{e});
            return;
        };
    }
    defer result.deinit();

    if (result.results.len == 0) {
        errPrint("error: import produced no results\n", .{});
        return;
    }

    // Single-file import: use filename stem as output name to avoid
    // collisions from generic SPICE .title values.
    const file_stem = std.fs.path.stem(std.fs.path.basename(path));
    if (result.results.len == 1) {
        result.results[0].name = file_stem;
    }

    writeImportResults(a, result.results, kind, output_dir);
}

/// Import a project directory. Auto-detects format:
///   - xschemrc present → XSchem project
///   - else → PySpice project
pub fn runImportProject(a: std.mem.Allocator, dir: []const u8, recursive: bool, output_dir: ?[]const u8) void {
    // Auto-detect: check for xschemrc
    var xschem_backend = import_mod.XSchem.Backend.init(a);
    defer xschem_backend.deinit();
    const is_xschem = xschem_backend.detectProjectRoot(dir);

    var result: import_mod.ConvertResultList = undefined;
    if (is_xschem) {
        result = import_mod.importProject(a, .{
            .xschem = .{ .project_dir = dir },
        }) catch |e| {
            errPrint("error: xschem import failed: {}\n", .{e});
            return;
        };
    } else {
        result = import_mod.importProject(a, .{
            .pyspice = .{ .project_dir = dir, .recursive = recursive },
        }) catch |e| {
            errPrint("error: project import failed: {}\n", .{e});
            return;
        };
    }
    defer result.deinit();

    if (result.results.len == 0) {
        errPrint("error: no importable files found in {s}\n", .{dir});
        return;
    }

    writeImportResults(a, result.results, null, output_dir);
}

/// Write import results to disk, routing output by stype.
fn writeImportResults(a: std.mem.Allocator, results: []import_mod.ConvertResult, kind_override: ?ImportKind, output_dir: ?[]const u8) void {
    for (results) |*r| {
        // Recommendation #5: apply explicit override, else keep auto-detected stype
        if (kind_override) |k| {
            r.schemify.stype = switch (k) {
                .component => .schematic,
                .primitive => .primitive,
                .testbench => .testbench,
            };
        }

        const chn_data = core.fileio.Writer.writeCHN(a, &r.schemify) orelse {
            errPrint("error: failed to serialize {s}\n", .{r.name});
            continue;
        };
        defer a.free(chn_data);

        // Route output based on stype: dir + extension
        const stype_dir: []const u8 = switch (r.schemify.stype) {
            .testbench => "testbenches",
            .primitive => "primitives",
            else => "components",
        };
        const out_ext: []const u8 = switch (r.schemify.stype) {
            .testbench => ".chn_tb",
            .primitive => ".chn_prim",
            else => ".chn",
        };

        var out_buf: [512]u8 = undefined;
        const out_path = if (output_dir) |base|
            std.fmt.bufPrint(&out_buf, "{s}/{s}{s}", .{ base, r.name, out_ext }) catch {
                errPrint("error: name too long\n", .{});
                continue;
            }
        else
            std.fmt.bufPrint(&out_buf, "{s}/{s}{s}", .{ stype_dir, r.name, out_ext }) catch {
                errPrint("error: name too long\n", .{});
                continue;
            };

        // Ensure output directory exists
        const dir_part = std.fs.path.dirname(out_path) orelse ".";
        utility.platform.fs.cwd().makePath(dir_part) catch {};

        utility.platform.fs.cwd().writeFile(.{ .sub_path = out_path, .data = chn_data }) catch {
            errPrint("error: failed to write {s}\n", .{out_path});
            continue;
        };
        outPrint("imported: {s} ({s})\n", .{ out_path, @tagName(r.schemify.stype) });
    }
}

// ── Optimizer discovery ──────────────────────────────────────────────────────

pub fn runDiscover(a: std.mem.Allocator, path: []const u8) void {
    const simulation = @import("simulation");
    const optimizer = simulation.optimizer;

    var log = utility.Logger.init(.info);
    var doc = openDocOrNull(a, &log, path) orelse return;
    defer doc.deinit();

    const sch = &doc.sch;
    const out = utility.platform.fs.stdout();

    // ── Discover devices ─────────────────────────────────────────────────
    outPrint("=== Discovered Devices ===\n", .{});
    var devices: [32]optimizer.DiscoveredDevice = undefined;
    const inst_slice = sch.instances.slice();
    const n_dev = optimizer.discoverOptimizableDevices(
        inst_slice.items(.kind),
        inst_slice.items(.name),
        inst_slice.items(.prop_start),
        inst_slice.items(.prop_count),
        sch.props.items,
        &sch.strings,
        &devices,
    );

    if (n_dev == 0) {
        outPrint("  (none)\n", .{});
    } else {
        for (devices[0..n_dev]) |d| {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "  {s}  {s}  bounds=[{s}, {s}]\n", .{
                d.instanceSlice(),
                d.kindSlice(),
                trimNullBytes(&d.bound_min),
                trimNullBytes(&d.bound_max),
            }) catch continue;
            out.writeAll(line) catch {};
        }
    }

    // ── Discover measurements from this file's measurements_decl ─────────
    outPrint("\n=== Declared Measurements ===\n", .{});
    const meas_decl = sch.strings.get(sch.measurements_decl);
    if (meas_decl.len > 0) {
        outPrint("  (from measurements_decl: {s})\n", .{meas_decl});
        const meas_list = optimizer.discoverMeasurementsFromDecl(meas_decl);
        for (meas_list.items[0..meas_list.len]) |m| {
            var buf: [128]u8 = undefined;
            const line = if (m.unit_len > 0)
                std.fmt.bufPrint(&buf, "  {s} ({s})\n", .{ m.nameSlice(), m.unitSlice() }) catch continue
            else
                std.fmt.bufPrint(&buf, "  {s}\n", .{m.nameSlice()}) catch continue;
            out.writeAll(line) catch {};
        }
    } else {
        outPrint("  (no measurements: field in this file)\n", .{});
    }

    // ── Scan for linked .chn_tb files in same directory ──────────────────
    outPrint("\n=== Linked Testbenches ===\n", .{});
    const design_name = sch.strings.get(sch.name);
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = utility.platform.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        outPrint("  (cannot open directory)\n", .{});
        return;
    };
    defer dir.close();

    var found_tb = false;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".chn_tb")) continue;
        const tb_content = dir.readFileAlloc(a, entry.name, 1 << 20) catch continue;
        defer a.free(tb_content);

        if (!optimizer.testbenchReferencesDut(tb_content, design_name)) continue;
        found_tb = true;
        outPrint("  {s}/{s}", .{ dir_path, entry.name });

        // Parse the testbench to extract measurements_decl
        var tb_sch = core.fileio.Reader.readCHN(tb_content, a);
        defer tb_sch.deinit(a);
        const tb_meas = tb_sch.strings.get(tb_sch.measurements_decl);
        if (tb_meas.len > 0) {
            outPrint(" -> measurements: {s}", .{tb_meas});
            const tb_list = optimizer.discoverMeasurementsFromDecl(tb_meas);
            outPrint(" ({d} specs)\n", .{tb_list.len});
        } else {
            outPrint(" (no measurements declared)\n", .{});
        }
    }
    if (!found_tb) {
        outPrint("  (no .chn_tb files reference {s})\n", .{design_name});
    }
}

fn trimNullBytes(buf: []const u8) []const u8 {
    for (buf, 0..) |b, i| {
        if (b == 0) return buf[0..i];
    }
    return buf;
}

// ── Optimizer run ────────────────────────────────────────────────────────────

pub fn runOptimize(a: std.mem.Allocator, path: []const u8, max_gen: u32) void {
    const simulation = @import("simulation");
    const optimizer = simulation.optimizer;

    var log = utility.Logger.init(.info);
    var doc = openDocOrNull(a, &log, path) orelse return;
    defer doc.deinit();

    const sch = &doc.sch;
    const design_name = sch.strings.get(sch.name);

    // ── Step 1: Discover devices ─────────────────────────────────────────
    var devices: [32]optimizer.DiscoveredDevice = undefined;
    const inst_slice = sch.instances.slice();
    const n_dev = optimizer.discoverOptimizableDevices(
        inst_slice.items(.kind),
        inst_slice.items(.name),
        inst_slice.items(.prop_start),
        inst_slice.items(.prop_count),
        sch.props.items,
        &sch.strings,
        &devices,
    );

    if (n_dev == 0) {
        errPrint("error: no optimizable devices found in {s}\n", .{path});
        return;
    }

    // ── Step 2: Build Problem from discovered devices ─────────────────────
    var problem = optimizer.Problem{};
    problem.max_iter = max_gen;

    for (devices[0..n_dev]) |d| {
        switch (d.device_type) {
            .mosfet => {
                var m = optimizer.Mosfet{};
                m.setInstance(d.instanceSlice());
                m.gmid_min = 3.0;
                m.gmid_max = 25.0;
                problem.mosfets.append(m);
            },
            .bjt => {
                var b = optimizer.Bjt{};
                b.setInstance(d.instanceSlice());
                b.gmic_min = 1.0;
                b.gmic_max = 50.0;
                problem.bjts.append(b);
            },
            .resistor => {
                var r = optimizer.Resistor{};
                r.setInstance(d.instanceSlice());
                r.w_min = 0.5e-6;
                r.w_max = 50e-6;
                r.l_min = 0.5e-6;
                r.l_max = 100e-6;
                problem.resistors.append(r);
            },
            .parameter => {},
        }
    }

    // ── Step 3: Discover measurements + script from linked .chn_tb ───────
    var meas_found = false;
    var tmp_script_path: ?[]u8 = null;
    defer if (tmp_script_path) |p| a.free(p);
    var tb_path_buf: [512]u8 = undefined;
    var tb_path: []const u8 = "";

    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = utility.platform.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        errPrint("error: cannot open directory {s}\n", .{dir_path});
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".chn_tb")) continue;
        const tb_content = dir.readFileAlloc(a, entry.name, 1 << 20) catch continue;
        defer a.free(tb_content);

        if (!optimizer.testbenchReferencesDut(tb_content, design_name)) continue;

        // Found a linked testbench — extract measurements + pyspice_source
        var tb_sch = core.fileio.Reader.readCHN(tb_content, a);
        defer tb_sch.deinit(a);

        const tb_meas = tb_sch.strings.get(tb_sch.measurements_decl);
        if (tb_meas.len > 0) {
            const meas_list = optimizer.discoverMeasurementsFromDecl(tb_meas);
            for (meas_list.items[0..meas_list.len]) |m| {
                var spec = optimizer.Specification{ .kind = .maximize };
                spec.setName(m.nameSlice());
                problem.specs.append(spec);
                meas_found = true;
            }
        }

        // Extract pyspice_source as the runnable script
        if (tb_path.len == 0) {
            const pyspice = tb_sch.strings.get(tb_sch.pyspice_source);
            if (pyspice.len > 0) {
                const tmp_path = std.fmt.allocPrint(a, "/tmp/schemify_opt_{s}.py", .{std.fs.path.stem(entry.name)}) catch continue;
                tmp_script_path = tmp_path;
                utility.platform.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = pyspice }) catch continue;
                tb_path = tmp_path;
            }
        }
    }

    if (!meas_found) {
        errPrint("error: no measurements discovered. Add `measurements:` to a linked .chn_tb.\n", .{});
        return;
    }

    // Fallback: look for eval scripts if no pyspice_source in .chn_tb
    if (tb_path.len == 0) {
        // Try tb_<design>_eval.py first
        const stem = std.fs.path.stem(path);
        const c1 = std.fmt.bufPrint(&tb_path_buf, "{s}/tb_{s}_eval.py", .{ dir_path, stem }) catch "";
        if (c1.len > 0) {
            utility.platform.fs.cwd().access(c1, .{}) catch {
                // Try <tb_stem>_eval.py (based on the .chn_tb filename)
                var tb_stem_buf: [256]u8 = undefined;
                var found_fallback = false;
                var iter2 = dir.iterate();
                while (iter2.next() catch null) |entry2| {
                    if (!std.mem.endsWith(u8, entry2.name, ".chn_tb")) continue;
                    const tb_stem = std.fs.path.stem(entry2.name);
                    const c2 = std.fmt.bufPrint(&tb_stem_buf, "{s}/{s}_eval.py", .{ dir_path, tb_stem }) catch continue;
                    utility.platform.fs.cwd().access(c2, .{}) catch continue;
                    @memcpy(tb_path_buf[0..c2.len], c2);
                    tb_path = tb_path_buf[0..c2.len];
                    found_fallback = true;
                    break;
                }
                if (!found_fallback) {
                    errPrint("error: no runnable testbench found. Add PYSPICE section to .chn_tb or create {s}\n", .{c1});
                    return;
                }
            };
            if (tb_path.len == 0) tb_path = c1;
        }
    }

    outPrint("=== Optimizer Configuration ===\n", .{});
    outPrint("  Design:       {s}\n", .{design_name});
    outPrint("  Devices:      {d}\n", .{n_dev});
    outPrint("  Design vars:  {d}\n", .{problem.designVarCount()});
    outPrint("  Objectives:   {d}\n", .{problem.objectiveCount()});
    outPrint("  Testbench:    {s}\n", .{tb_path});
    outPrint("  Generations:  {d}\n", .{max_gen});
    outPrint("\n", .{});

    // ── Step 5: Run NSGA-II ──────────────────────────────────────────────
    var cancelled = std.atomic.Value(bool).init(false);
    var linked_tb = optimizer.LinkedTestbench{};
    const plen: u16 = @intCast(@min(tb_path.len, 512));
    @memcpy(linked_tb.path[0..plen], tb_path[0..plen]);
    linked_tb.path_len = plen;
    const testbenches = [_]optimizer.LinkedTestbench{linked_tb};

    var runner = optimizer.TestbenchRunner.init(a, &problem, 1, 60_000);

    var nsga = optimizer.Nsga2.init(&problem, .{
        .max_generations = max_gen,
        .pop_size = 50,
        .seed = 12345,
    }, &cancelled);
    nsga.seedPopulation();

    // Evaluation function that uses the TestbenchRunner
    const EvalCtx = struct {
        var tb_runner: *optimizer.TestbenchRunner = undefined;
        var tb_list: []const optimizer.LinkedTestbench = undefined;

        fn eval(x: []const f64, prob: *const optimizer.Problem, ind: *optimizer.Individual) void {
            _ = x;
            _ = prob;
            tb_runner.evaluateIndividual(ind, tb_list);
        }
    };
    EvalCtx.tb_runner = &runner;
    EvalCtx.tb_list = &testbenches;

    outPrint("=== Running NSGA-II ===\n", .{});
    var best_obj: f64 = -std.math.inf(f64);
    for (0..max_gen) |gen| {
        const result = nsga.step(&EvalCtx.eval);

        // Track best feasible
        var gen_best: f64 = -std.math.inf(f64);
        for (nsga.population[0..nsga.pop_size]) |ind| {
            if (ind.valid and ind.n_objectives > 0) {
                // For maximize, objectives are negated internally
                const obj_val = -ind.objectives[0];
                if (obj_val > gen_best) gen_best = obj_val;
            }
        }
        if (gen_best > best_obj) best_obj = gen_best;

        if ((gen + 1) % 5 == 0 or gen == 0) {
            outPrint("  Gen {d:>3}: feasible={d}/{d}  best_obj={d:.2}\n", .{
                gen + 1, result.feasible_count, nsga.pop_size, best_obj,
            });
        }

        if (result.stop != null) {
            outPrint("  Stopped: {s}\n", .{@tagName(result.stop.?)});
            break;
        }
    }

    // ── Step 6: Print results ────────────────────────────────────────────
    outPrint("\n=== Results (Pareto Front) ===\n", .{});

    // Sort by rank
    std.mem.sort(optimizer.Individual, nsga.population[0..nsga.pop_size], {}, struct {
        fn lessThan(_: void, aa: optimizer.Individual, bb: optimizer.Individual) bool {
            if (aa.rank != bb.rank) return aa.rank < bb.rank;
            return aa.crowding_distance > bb.crowding_distance;
        }
    }.lessThan);

    const n_show = @min(nsga.pop_size, 10);
    outPrint("  Top {d} solutions (rank, feasible, objectives, design vars):\n", .{n_show});
    for (nsga.population[0..n_show], 0..) |ind, i| {
        var obj_buf: [128]u8 = undefined;
        var obj_pos: usize = 0;
        for (0..ind.n_objectives) |oi| {
            const seg = std.fmt.bufPrint(obj_buf[obj_pos..], "{d:.3} ", .{-ind.objectives[oi]}) catch break;
            obj_pos += seg.len;
        }

        var var_buf: [256]u8 = undefined;
        var var_pos: usize = 0;
        const n_vars_show = @min(ind.n_vars, 8);
        for (0..n_vars_show) |vi| {
            const seg = std.fmt.bufPrint(var_buf[var_pos..], "{e:.3} ", .{ind.x[vi]}) catch break;
            var_pos += seg.len;
        }

        outPrint("  [{d}] rank={d} feas={} obj=[{s}] x=[{s}]\n", .{
            i, ind.rank, ind.feasible, obj_buf[0..obj_pos], var_buf[0..var_pos],
        });
    }

    // Print device mapping for best solution
    if (nsga.pop_size > 0) {
        const best = &nsga.population[0];
        outPrint("\n=== Best Solution — Device Values ===\n", .{});
        var var_idx: usize = 0;

        for (problem.mosfets.slice()) |m| {
            outPrint("  {s}: gm/Id = {d:.2}\n", .{ m.instanceSlice(), best.x[var_idx] });
            var_idx += 1;
        }
        for (problem.bjts.slice()) |b| {
            outPrint("  {s}: gm/Ic = {d:.2}\n", .{ b.instanceSlice(), best.x[var_idx] });
            var_idx += 1;
        }
        for (problem.resistors.slice()) |r| {
            outPrint("  {s}: W = {e:.3}, L = {e:.3}\n", .{ r.instanceSlice(), best.x[var_idx], best.x[var_idx + 1] });
            var_idx += 2;
        }
    }
}

// ── Headless command execution ───────────────────────────────────────────────

fn printAllCommands() void {
    const out = utility.platform.fs.stdout();
    parser.printCommandList(out);
}

fn initHeadlessApp(app: *st.AppState, file_path: []const u8) bool {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    app.init(dir);
    app.initLogger();

    // Try to open existing file; create new if not found.
    app.openPath(file_path) catch {
        app.newFile(file_path) catch {
            errPrint("error: failed to open or create {s}\n", .{file_path});
            return false;
        };
    };
    return true;
}

fn runHeadlessCmd(a: std.mem.Allocator, file_path: []const u8, cmd_args: []const []const u8) void {
    _ = a;

    // Join remaining args into a single command line.
    var line_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (cmd_args, 0..) |arg, i| {
        if (i > 0) {
            if (pos >= line_buf.len) break;
            line_buf[pos] = ' ';
            pos += 1;
        }
        const n = @min(arg.len, line_buf.len - pos);
        @memcpy(line_buf[pos..][0..n], arg[0..n]);
        pos += n;
    }
    const cmd_line = line_buf[0..pos];

    var app: st.AppState = undefined;
    if (!initHeadlessApp(&app, file_path)) return;
    defer app.deinit();

    _ = executeOne(cmd_line, &app);

    // Auto-save if the schematic was modified.
    autoSave(&app, file_path);
}

fn runHeadlessBatch(a: std.mem.Allocator, file_path: []const u8) void {
    var app: st.AppState = undefined;
    if (!initHeadlessApp(&app, file_path)) return;
    defer app.deinit();

    // Read all stdin content, then process line by line.
    const stdin_file = utility.platform.fs.stdin();
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(a);
    {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdin_file.read(&buf) catch break;
            if (n == 0) break;
            content.appendSlice(a, buf[0..n]) catch break;
        }
    }
    var lines = std.mem.splitScalar(u8, content.items, '\n');
    while (lines.next()) |line| {
        if (!executeOne(line, &app)) break; // quit was requested
    }

    // Auto-save on exit if dirty (batch scripts can also use explicit "save").
    autoSave(&app, file_path);
}

/// Execute a single parsed command line.  Returns false if quit was requested.
fn executeOne(line: []const u8, app: *st.AppState) bool {
    const result = parser.parse(line);
    switch (result) {
        .command => |cmd| {
            command.dispatch(cmd, app) catch |err| {
                errPrint("error: command failed: {}\n", .{err});
            };
        },
        .meta => |m| {
            if (!handleMeta(m, app)) return false;
        },
        .meta_arg => |ma| handleMetaArg(ma, app),
        .err => |msg| {
            if (msg.len > 0) errPrint("error: {s}\n", .{msg});
        },
    }
    return true;
}

pub fn handleMeta(m: parser.MetaCommand, app: *st.AppState) bool {
    const out = utility.platform.fs.stdout();
    switch (m) {
        .quit => return false,
        .save => {
            const doc = app.active() orelse {
                errPrint("error: no active document\n", .{});
                return true;
            };
            const path: []const u8 = switch (doc.origin) {
                .chn_file => |p| p,
                else => {
                    errPrint("error: no file path (use saveas <path>)\n", .{});
                    return true;
                },
            };
            doc.saveAsChn(path) catch {
                errPrint("error: save failed\n", .{});
                return true;
            };
            outPrint("saved: {s}\n", .{path});
        },
        .list_instances => {
            const doc = app.active() orelse return true;
            const sch = &doc.sch;
            out.writeAll("IDX\tNAME\tSYMBOL\tX\tY\tROT\tFLIP\n") catch {};
            for (0..sch.instances.len) |i| {
                const inst = sch.instances.get(i);
                var buf: [512]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{}\n", .{
                    i, sch.str(inst.name), sch.str(inst.symbol), inst.x, inst.y, inst.flags.rot, inst.flags.flip,
                }) catch continue;
                out.writeAll(s) catch {};
            }
        },
        .list_wires => {
            const doc = app.active() orelse return true;
            const sch = &doc.sch;
            out.writeAll("IDX\tX0\tY0\tX1\tY1\tNET\n") catch {};
            for (0..sch.wires.len) |i| {
                const w = sch.wires.get(i);
                var buf: [512]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{
                    i, w.x0, w.y0, w.x1, w.y1, sch.str(w.net_name),
                }) catch continue;
                out.writeAll(s) catch {};
            }
        },
        .info => {
            const doc = app.active() orelse {
                outPrint("no active document\n", .{});
                return true;
            };
            outPrint("name:      {s}\n", .{doc.name});
            outPrint("origin:    {s}\n", .{switch (doc.origin) {
                .chn_file => |p| p,
                .unsaved => "unsaved",
                .buffer => "buffer",
            }});
            outPrint("type:      {s}\n", .{@tagName(doc.sch.stype)});
            outPrint("instances: {d}\n", .{doc.sch.instances.len});
            outPrint("wires:     {d}\n", .{doc.sch.wires.len});
            outPrint("dirty:     {}\n", .{doc.dirty});
        },
        .print_netlist => {
            const doc = app.active() orelse return true;
            const nl = doc.createNetlist() catch {
                errPrint("error: netlist generation failed\n", .{});
                return true;
            };
            out.writeAll(nl) catch {};
        },
        .list_commands => printAllCommands(),
    }
    return true;
}

pub fn handleMetaArg(ma: parser.MetaArg, app: *st.AppState) void {
    switch (ma) {
        .saveas => |path| {
            const doc = app.active() orelse {
                errPrint("error: no active document\n", .{});
                return;
            };
            doc.saveAsChn(path) catch {
                errPrint("error: save failed\n", .{});
                return;
            };
            outPrint("saved: {s}\n", .{path});
        },
        .open_file => |path| {
            app.openPath(path) catch {
                errPrint("error: failed to open {s}\n", .{path});
                return;
            };
            outPrint("opened: {s}\n", .{path});
        },
        .set_snap => |v| {
            app.tool.snap_size = v;
            outPrint("snap: {d}\n", .{v});
        },
        .select_instance => |idx| {
            const doc = app.active() orelse return;
            if (idx >= doc.sch.instances.len) {
                errPrint("error: instance index {d} out of range (max {d})\n", .{ idx, doc.sch.instances.len });
                return;
            }
            doc.selection.ensureCapacity(app.allocator(), doc.sch.instances.len, doc.sch.wires.len, false) catch return;
            doc.selection.instances.set(idx);
        },
        .select_wire => |idx| {
            const doc = app.active() orelse return;
            if (idx >= doc.sch.wires.len) {
                errPrint("error: wire index {d} out of range (max {d})\n", .{ idx, doc.sch.wires.len });
                return;
            }
            doc.selection.ensureCapacity(app.allocator(), doc.sch.instances.len, doc.sch.wires.len, false) catch return;
            doc.selection.wires.set(idx);
        },
        .deselect_instance => |idx| {
            const doc = app.active() orelse return;
            if (idx < doc.selection.instances.bit_length) doc.selection.instances.unset(idx);
        },
        .deselect_wire => |idx| {
            const doc = app.active() orelse return;
            if (idx < doc.selection.wires.bit_length) doc.selection.wires.unset(idx);
        },
    }
}

fn autoSave(app: *st.AppState, original_path: []const u8) void {
    const doc = app.active() orelse return;
    if (!doc.dirty) return;
    doc.saveAsChn(original_path) catch {
        errPrint("error: auto-save failed for {s}\n", .{original_path});
        return;
    };
    outPrint("auto-saved: {s}\n", .{original_path});
}
