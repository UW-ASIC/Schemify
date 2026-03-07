const std = @import("std");
const core = @import("core");
const fixture_manifest = @import("fixture_manifest.zig");

const batch_dir_path = "test/.tmp_xschem_batch";
var batch_generated: bool = false;

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn commandExists(cmd: []const u8) bool {
    const sh_cmd = std.fmt.allocPrint(std.testing.allocator, "command -v {s}", .{cmd}) catch return false;
    defer std.testing.allocator.free(sh_cmd);
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "sh", "-c", sh_cmd },
    }) catch return false;
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn requirePathExists(path: []const u8) !void {
    if (!fileExists(path)) return error.MissingRequiredFixture;
}

fn canonicalizeSimple(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer lines.deinit(a);

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '*') continue;
        if (std.mem.eql(u8, line, ".end")) continue;
        if (line[0] == '+' and lines.items.len > 0) {
            const cont = std.mem.trimLeft(u8, line[1..], " \t");
            const prev = lines.items[lines.items.len - 1];
            const merged = try std.fmt.allocPrint(a, "{s} {s}", .{ prev, cont });
            lines.items[lines.items.len - 1] = merged;
            continue;
        }
        try lines.append(a, line);
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(a);
    for (lines.items) |line| {
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn emptyResolveShim(_: *anyopaque, _: []const u8) ?*const core.sch.Schemify {
    return null;
}

fn ensureBatchReferences() !void {
    if (batch_generated) return;
    batch_generated = true;
    if (!commandExists("xschem")) return error.MissingRequiredCommand;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.fs.cwd().deleteTree(batch_dir_path) catch {};
    try std.fs.cwd().makePath(batch_dir_path);

    var tcl_buf: std.ArrayListUnmanaged(u8) = .{};
    defer tcl_buf.deinit(a);
    const w = tcl_buf.writer(a);
    try w.writeAll("set base [pwd]\nset lvs_netlist 1\nset netlist_type spice\n");

    for (fixture_manifest.cases) |pair| {
        if (!fileExists(pair.sch_path)) continue;
        const h = std.hash.Wyhash.hash(0, pair.sch_path);
        const sub = try std.fmt.allocPrint(a, "{s}/{x}", .{ batch_dir_path, h });
        std.fs.cwd().makePath(sub) catch continue;
        const dir = std.fs.path.dirname(pair.sch_path) orelse ".";
        const base_name = std.fs.path.basename(pair.sch_path);
        try w.print("catch {{cd $base/{s}; set netlist_dir $base/{s}; xschem load {{{s}}}; xschem netlist}}\n", .{ dir, sub, base_name });
    }
    try w.writeAll("xschem exit closewindow force\n");

    const tcl_path = batch_dir_path ++ "/batch.tcl";
    try std.fs.cwd().writeFile(.{ .sub_path = tcl_path, .data = tcl_buf.items });
    _ = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "xschem", "--no_x", "--script", tcl_path },
        .max_output_bytes = 10 * 1024 * 1024,
    });
}

fn getBatchReferenceNetlist(a: std.mem.Allocator, sch_path: []const u8) ![]u8 {
    try ensureBatchReferences();
    const h = std.hash.Wyhash.hash(0, sch_path);
    const out_path = try std.fmt.allocPrint(a, "{s}/{x}/{s}.spice", .{ batch_dir_path, h, std.fs.path.stem(sch_path) });
    if (!fileExists(out_path)) return error.XschemReferenceNetlistFailed;
    return std.fs.cwd().readFileAlloc(a, out_path, std.math.maxInt(usize));
}

fn f2i(v: f64) i32 {
    const r = @round(v);
    return std.math.lossyCast(i32, r);
}

fn toUniversalFromXS(xs: *const core.XSchem, backing: std.mem.Allocator) !core.netlist.UniversalNetlistForm {
    var uni = core.netlist.UniversalNetlistForm.init(backing);
    const a = uni.arena.allocator();

    try uni.wires.ensureTotalCapacity(a, xs.wires.len);
    try uni.devices.ensureTotalCapacity(a, xs.instances.len);
    try uni.props.ensureTotalCapacity(a, xs.props.items.len);

    const ws = xs.wires.slice();
    for (0..xs.wires.len) |i| {
        try uni.wires.append(a, .{
            .x0 = f2i(ws.items(.x0)[i]),
            .y0 = f2i(ws.items(.y0)[i]),
            .x1 = f2i(ws.items(.x1)[i]),
            .y1 = f2i(ws.items(.y1)[i]),
            .net_name = if (ws.items(.net_name)[i]) |n| try a.dupe(u8, n) else null,
        });
    }

    const ins = xs.instances.slice();
    for (0..xs.instances.len) |i| {
        const prop_start: u32 = @intCast(uni.props.items.len);
        const src_prop_start = ins.items(.prop_start)[i];
        const src_prop_count = ins.items(.prop_count)[i];
        for (xs.props.items[src_prop_start..][0..src_prop_count]) |p| {
            try uni.props.append(a, .{
                .key = try a.dupe(u8, p.key),
                .value = try a.dupe(u8, p.value),
            });
        }

        const rot_i = ins.items(.rot)[i];
        const rot_u: u2 = @truncate(@as(u32, @bitCast(rot_i)));
        try uni.devices.append(a, .{
            .name = try a.dupe(u8, ins.items(.name)[i]),
            .symbol = try a.dupe(u8, ins.items(.symbol)[i]),
            .x = f2i(ins.items(.x)[i]),
            .y = f2i(ins.items(.y)[i]),
            .rot = rot_u,
            .flip = ins.items(.flip)[i],
            .prop_start = prop_start,
            .prop_count = @intCast(uni.props.items.len - prop_start),
        });
    }

    return uni;
}

fn getBatchCaseDir(a: std.mem.Allocator, sch_path: []const u8) ![]u8 {
    const h = std.hash.Wyhash.hash(0, sch_path);
    return std.fmt.allocPrint(a, "{s}/{x}", .{ batch_dir_path, h });
}

fn writeMismatchArtifacts(a: std.mem.Allocator, sch_path: []const u8, mine_raw: []const u8, xref_raw: []const u8, mine_can: []const u8, xref_can: []const u8) void {
    const case_dir = getBatchCaseDir(a, sch_path) catch return;
    std.fs.cwd().makePath(case_dir) catch return;

    const mine_raw_path = std.fmt.allocPrint(a, "{s}/schemify.raw.spice", .{case_dir}) catch return;
    const xref_raw_path = std.fmt.allocPrint(a, "{s}/xschem.raw.spice", .{case_dir}) catch return;
    const mine_can_path = std.fmt.allocPrint(a, "{s}/schemify.canon.spice", .{case_dir}) catch return;
    const xref_can_path = std.fmt.allocPrint(a, "{s}/xschem.canon.spice", .{case_dir}) catch return;

    std.fs.cwd().writeFile(.{ .sub_path = mine_raw_path, .data = mine_raw }) catch {};
    std.fs.cwd().writeFile(.{ .sub_path = xref_raw_path, .data = xref_raw }) catch {};
    std.fs.cwd().writeFile(.{ .sub_path = mine_can_path, .data = mine_can }) catch {};
    std.fs.cwd().writeFile(.{ .sub_path = xref_can_path, .data = xref_can }) catch {};
}

fn printFirstDiff(lhs: []const u8, rhs: []const u8, sch_path: []const u8) void {
    var l_it = std.mem.splitScalar(u8, lhs, '\n');
    var r_it = std.mem.splitScalar(u8, rhs, '\n');
    var line_no: usize = 1;
    while (true) {
        const l = l_it.next();
        const r = r_it.next();
        if (l == null and r == null) break;
        if (l == null) {
            std.debug.print("mismatch {s}: missing schemify line {d}; xschem='{s}'\n", .{ sch_path, line_no, r.? });
            return;
        }
        if (r == null) {
            std.debug.print("mismatch {s}: missing xschem line {d}; schemify='{s}'\n", .{ sch_path, line_no, l.? });
            return;
        }
        if (!std.mem.eql(u8, l.?, r.?)) {
            std.debug.print("mismatch {s} line {d}\nschemify: {s}\nxschem:   {s}\n", .{ sch_path, line_no, l.?, r.? });
            return;
        }
        line_no += 1;
    }
}

fn runPathCase(pair: fixture_manifest.Case) !void {
    try requirePathExists(pair.sch_path);
    try requirePathExists(pair.sym_path);
}

fn runReferenceCase(pair: fixture_manifest.Case) !void {
    if (!commandExists("xschem")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xref = try getBatchReferenceNetlist(a, pair.sch_path);
    try std.testing.expect(xref.len > 0);
}

fn runParityIntentCase(pair: fixture_manifest.Case) !void {
    if (!commandExists("xschem")) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var io = core.XSchemIO.init(a, pair.sch_path, pair.sym_path);
    defer io.deinit();
    var xs = try io.readFile();
    defer xs.deinit();

    var uni = try toUniversalFromXS(&xs, a);
    defer uni.deinit();

    const mine = core.netlist.GenerateNetlist(uni) orelse return error.NetlistGenerationFailed;
    const xref = try getBatchReferenceNetlist(a, pair.sch_path);

    const can_mine = try canonicalizeSimple(a, mine);
    const can_xref = try canonicalizeSimple(a, xref);
    if (can_mine.len == 0 or can_xref.len == 0) return error.EmptyNetlist;
    if (!std.mem.eql(u8, can_mine, can_xref)) {
        writeMismatchArtifacts(a, pair.sch_path, mine, xref, can_mine, can_xref);
        printFirstDiff(can_mine, can_xref, pair.sch_path);
        return error.NetlistMismatch;
    }
}

comptime {
    if (fixture_manifest.cases.len == 0) @compileError("fixture_manifest.cases must not be empty");
    for (fixture_manifest.cases) |pair| {
        const PairTests = struct {
            test {
                try runPathCase(pair);
            }
            test {
                try runReferenceCase(pair);
            }
            test {
                try runParityIntentCase(pair);
            }
        };
        _ = PairTests;
    }
}
