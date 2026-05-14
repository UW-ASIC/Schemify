const std = @import("std");
const core = @import("schematic");
const utility = @import("utility");
const st = @import("state");
const command = @import("commands");
const parser = command.parser;

// ── Parsed CLI action ────────────────────────────────────────────────────────

pub const ParsedArgs = union(enum) {
    none,
    help,
    plugin_install: struct { url: []const u8, web: bool },
    plugin_list,
    plugin_remove: []const u8,
    export_svg: []const u8,
    netlist: struct { path: []const u8, xyce: bool },
    cmd: struct { file: []const u8, rest: []const []const u8 },
    batch: []const u8,
    commands,
    err_missing_install_url,
    err_missing_remove_name,
    err_missing_file,
    err_missing_cmd,
};

// ── Comptime command table ───────────────────────────────────────────────────

const Cmd = enum { help, plugin_install, plugin_list, plugin_remove, export_svg, netlist, cmd_mode, batch_mode, commands_mode };

const cmd_map = std.StaticStringMap(Cmd).initComptime(.{
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "--plugin-install", .plugin_install },
    .{ "--plugin-list", .plugin_list },
    .{ "--plugin-remove", .plugin_remove },
    .{ "--export-svg", .export_svg },
    .{ "--netlist", .netlist },
    .{ "--cmd", .cmd_mode },
    .{ "--batch", .batch_mode },
    .{ "--commands", .commands_mode },
});

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

pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len < 2) return .none;

    const cmd = cmd_map.get(args[1]) orelse return .none;
    return switch (cmd) {
        .help => .help,
        .plugin_list => .plugin_list,
        .plugin_install => blk: {
            const f = parseOptionalFlag(args, 2, "--web");
            const path = if (args.len > f.next) args[f.next] else break :blk .err_missing_install_url;
            break :blk .{ .plugin_install = .{ .url = path, .web = f.enabled } };
        },
        .plugin_remove => if (args.len < 3)
            .err_missing_remove_name
        else
            .{ .plugin_remove = args[2] },
        .export_svg => if (args.len < 3) .err_missing_file else .{ .export_svg = args[2] },
        .netlist => blk: {
            const f = parseOptionalFlag(args, 2, "--xyce");
            const path = if (args.len > f.next) args[f.next] else break :blk .err_missing_file;
            break :blk .{ .netlist = .{ .path = path, .xyce = f.enabled } };
        },
        .cmd_mode => blk: {
            if (args.len < 3) break :blk .err_missing_file;
            if (args.len < 4) break :blk .err_missing_cmd;
            break :blk .{ .cmd = .{ .file = args[2], .rest = args[3..] } };
        },
        .batch_mode => if (args.len < 3) .err_missing_file else .{ .batch = args[2] },
        .commands_mode => .commands,
    };
}

// ── Dispatch ─────────────────────────────────────────────────────────────────

/// Returns true if a CLI command was handled (process should exit).
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
        .netlist => |p| { runNetlist(a, p.path, p.xyce); return true; },
        .cmd => |c| { runHeadlessCmd(a, c.file, c.rest); return true; },
        .batch => |file| { runHeadlessBatch(a, file); return true; },
        .commands => { printAllCommands(); return true; },
        .err_missing_install_url => { errPrint("error: --plugin-install requires a URL\n", .{}); std.process.exit(1); },
        .err_missing_remove_name => { errPrint("error: --plugin-remove requires a plugin name\n", .{}); std.process.exit(1); },
        .err_missing_file => { errPrint("error: command requires a file path\n", .{}); std.process.exit(1); },
        .err_missing_cmd => { errPrint("error: --cmd requires: <file> <command> [args...]\n", .{}); std.process.exit(1); },
    }
}

pub fn printHelp() void {
    const out = utility.platform.fs.stdout();
    out.writeAll(
        \\Usage: schemify [OPTIONS] [PROJECT_DIR]
        \\
        \\  PROJECT_DIR              Open this project directory (default: .)
        \\
        \\Headless commands (no GUI):
        \\  --cmd <file.chn> <command> [args...]
        \\                           Run a single command on a schematic and save.
        \\  --batch <file.chn>       Read commands from stdin (one per line).
        \\  --commands               List all available headless commands.
        \\
        \\Plugin commands:
        \\  --plugin-install [--web] <url>
        \\                           Install a plugin from a URL.
        \\  --plugin-list            List installed native plugins.
        \\  --plugin-remove <name>   Remove a native plugin by name.
        \\
        \\Export / netlist commands:
        \\  --export-svg <file.chn>  Export schematic to SVG.
        \\  --netlist [--xyce] <file.chn>
        \\                           Generate SPICE netlist (ngspice default).
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
        len = (std.fmt.bufPrint(&buf, "<text x=\"{d}\" y=\"{d}\">{s}</text></g>\n", .{ inst.x - 12, inst.y + 3, inst.name }) catch &buf).len;
        try file.writeAll(buf[0..len]);
    }
    try file.writeAll("</svg>\n");
}

pub fn runNetlist(a: std.mem.Allocator, path: []const u8, xyce: bool) void {
    var log = utility.Logger.init(.info);
    var doc = openDocOrNull(a, &log, path) orelse return;
    defer doc.deinit();

    _ = xyce;
    const netlist = doc.createNetlist() catch {
        errPrint("error: netlist generation failed\n", .{});
        return;
    };
    const out = utility.platform.fs.stdout();
    out.writeAll(netlist) catch {};
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

fn handleMeta(m: parser.MetaCommand, app: *st.AppState) bool {
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
                    i, inst.name, inst.symbol, inst.x, inst.y, inst.flags.rot, inst.flags.flip,
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
                    i, w.x0, w.y0, w.x1, w.y1, w.net_name orelse "",
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

fn handleMetaArg(ma: parser.MetaArg, app: *st.AppState) void {
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
