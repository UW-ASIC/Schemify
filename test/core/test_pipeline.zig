const std = @import("std");
const testing = std.testing;
const core = @import("core");
const fixtures = @import("fixture_manifest.zig");
const preflight = @import("preflight.zig");

const XSchem = core.XSchem;

// ── Helpers ──────────────────────────────────────────────────────────────── //

fn shardOf(path: []const u8, shard_count: usize) usize {
    std.debug.assert(shard_count > 0);
    return @intCast(std.hash.Wyhash.hash(0, path) % shard_count);
}

/// SPICE-aware canonicalization: collapse whitespace, merge `+` continuations,
/// strip blank lines, comments, and `.end` sentinels.
fn canonicalizeSpice(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ta = arena.allocator();

    var lines: std.ArrayListUnmanaged([]const u8) = .{};
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_raw| {
        const trimmed = std.mem.trim(u8, line_raw, " \t\r");
        var collapsed = std.ArrayListUnmanaged(u8){};
        var prev_ws = false;
        for (trimmed) |c| {
            const is_ws = c == ' ' or c == '\t';
            if (is_ws) {
                if (!prev_ws) try collapsed.append(ta, ' ');
                prev_ws = true;
            } else {
                try collapsed.append(ta, c);
                prev_ws = false;
            }
        }
        const line = collapsed.items;
        if (line.len == 0 or line[0] == '*') continue;
        if (std.mem.eql(u8, line, ".end")) continue;
        if (line[0] == '+' and lines.items.len > 0) {
            const cont = std.mem.trimLeft(u8, line[1..], " \t");
            const prev = lines.items[lines.items.len - 1];
            lines.items[lines.items.len - 1] = try std.fmt.allocPrint(ta, "{s} {s}", .{ prev, cont });
            continue;
        }
        try lines.append(ta, line);
    }
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(a);
    for (lines.items) |line| {
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn normalizeNoCommentLines(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(a);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const ltrim = std.mem.trimLeft(u8, line, " \t");
        if (ltrim.len > 0 and ltrim[0] == '*') continue;
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

var print_mtx = std.Thread.Mutex{};

fn printFirstDiff(lhs: []const u8, rhs: []const u8, label: []const u8) void {
    var l_it = std.mem.splitScalar(u8, lhs, '\n');
    var r_it = std.mem.splitScalar(u8, rhs, '\n');
    var line_no: usize = 1;
    while (true) {
        const l = l_it.next();
        const r = r_it.next();
        if (l == null and r == null) break;
        if (l == null) {
            print_mtx.lock(); defer print_mtx.unlock();
            std.debug.print("{s}: missing lhs line {d}; rhs='{s}'\n", .{ label, line_no, r.? });
            return;
        }
        if (r == null) {
            print_mtx.lock(); defer print_mtx.unlock();
            std.debug.print("{s}: missing rhs line {d}; lhs='{s}'\n", .{ label, line_no, l.? });
            return;
        }
        if (!std.mem.eql(u8, l.?, r.?)) {
            print_mtx.lock(); defer print_mtx.unlock();
            std.debug.print("{s}: first diff at line {d}\nlhs: {s}\nrhs: {s}\n", .{ label, line_no, l.?, r.? });
            return;
        }
        line_no += 1;
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn caseDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn loadXs(a: std.mem.Allocator, sch_path: []const u8) !XSchem {
    const bytes = try std.fs.cwd().readFileAlloc(a, sch_path, std.math.maxInt(usize));
    defer a.free(bytes);
    var x = XSchem.readFile(bytes, a, null);
    x.name = std.fs.path.stem(sch_path);
    return x;
}

// ── Symbol search dirs ────────────────────────────────────────────────────── //

fn buildSearchDirs(a: std.mem.Allocator, sch_path: []const u8) ![]const []const u8 {
    var dirs = std.ArrayListUnmanaged([]const u8){};

    const sky130_base = "test/examples/xschem_sky130";
    const sky130_sub_dirs = [_][]const u8{
        "sky130_stdcells", "sky130_fd_pr", "stdcells",
        "sky130_tests",    "mips_cpu",     "decred_hash_macro", "xschem_verilog_import",
    };
    try dirs.append(a, "test/examples/xschem_core_examples");

    // System dirs come before PDK-specific dirs so that standard library symbols
    // (e.g. diode.sym, res.sym) are found before PDK variants with different pin names.
    const system_dirs = [_][]const u8{
        "/nix/store/qriw4afhakn3sqg2al06kdyr745hx86w-xschem-3.4.7/share/xschem/xschem_library/devices",
        "/nix/store/qriw4afhakn3sqg2al06kdyr745hx86w-xschem-3.4.7/share/xschem/xschem_library",
        "/nix/store/qriw4afhakn3sqg2al06kdyr745hx86w-xschem-3.4.7/share/doc/xschem/examples",
        // xschem example sub-libraries: logic (latch.sym), ngspice (inv_ngspice.sym), rom8k (rom2_sa.sym)
        "/nix/store/qriw4afhakn3sqg2al06kdyr745hx86w-xschem-3.4.7/share/doc/xschem/logic",
        "/nix/store/qriw4afhakn3sqg2al06kdyr745hx86w-xschem-3.4.7/share/doc/xschem/ngspice",
        "/nix/store/qriw4afhakn3sqg2al06kdyr745hx86w-xschem-3.4.7/share/doc/xschem/rom8k",
        "/usr/share/xschem/xschem_library/devices",
        "/usr/local/share/xschem/xschem_library/devices",
        "/usr/share/doc/xschem/logic",
        "/usr/share/doc/xschem/ngspice",
        "/usr/share/doc/xschem/rom8k",
        "/usr/local/share/doc/xschem/logic",
        "/usr/local/share/doc/xschem/ngspice",
        "/usr/local/share/doc/xschem/rom8k",
    };
    for (system_dirs) |d| if (fileExists(d)) try dirs.append(a, d);

    // Volare-installed Sky130 library takes precedence over the git submodule copy,
    // because the test references were generated with the volare library.
    const volare_base_candidates = [_][]const u8{
        "/home/omare/.volare/sky130A/libs.tech/xschem",
        "/root/.volare/sky130A/libs.tech/xschem",
        "/home/user/.volare/sky130A/libs.tech/xschem",
    };
    for (volare_base_candidates) |vb| {
        if (fileExists(vb)) {
            try dirs.append(a, vb);
            for (sky130_sub_dirs) |sd|
                try dirs.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ vb, sd }));
            break;
        }
    }

    try dirs.append(a, sky130_base);
    for (sky130_sub_dirs) |sd|
        try dirs.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ sky130_base, sd }));
    if (fileExists("test/examples/sky130_schematics"))
        try dirs.append(a, "test/examples/sky130_schematics");

    try dirs.append(a, caseDir(sch_path));
    return dirs.toOwnedSlice(a);
}

fn toNetlister(a: std.mem.Allocator, xs: *const XSchem, sch_path: []const u8) !core.netlist.UniversalNetlistForm {
    var dirs_arena = std.heap.ArenaAllocator.init(a);
    defer dirs_arena.deinit();
    const dirs = try buildSearchDirs(dirs_arena.allocator(), sch_path);
    return core.netlist.UniversalNetlistForm.fromXSchemWithSymbols(a, xs, dirs);
}

// ── .sym pin-order loading ────────────────────────────────────────────────── //

fn isBusElement(name: []const u8) bool {
    if (name.len < 3 or name[name.len - 1] != ']') return false;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return false;
    const inner = name[open + 1 .. name.len - 1];
    if (inner.len == 0) return false;
    for (inner) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn loadSymPinOrder(a: std.mem.Allocator, nl: *core.netlist.UniversalNetlistForm, sym_path: []const u8) !void {
    if (!fileExists(sym_path) or nl.pins.items.len != 0) return;
    const sym_data = std.fs.cwd().readFileAlloc(a, sym_path, 4 * 1024 * 1024) catch return;
    defer a.free(sym_data);
    var sym_xs = core.XSchem.readFile(sym_data, a, null);
    defer sym_xs.deinit();
    const uni_a = nl.arena.allocator();

    const sym_pins = sym_xs.pins.slice();
    var pin_dir_map = std.StringHashMap(core.sch.PinDir).init(a);
    defer pin_dir_map.deinit();
    for (0..sym_xs.pins.len) |i| {
        const dir = core.sch.PinDir.fromStr(sym_pins.items(.direction)[i].toStr());
        pin_dir_map.put(sym_pins.items(.name)[i], dir) catch {};
    }

    var format_str: ?[]const u8 = null;
    for (sym_xs.props.items) |p| {
        if (std.mem.eql(u8, p.key, "format")) { format_str = p.value; break; }
    }

    var extra_pin_set = std.StringHashMapUnmanaged(void){};
    defer extra_pin_set.deinit(a);
    for (sym_xs.props.items) |p| {
        if (std.mem.eql(u8, p.key, "extra")) {
            var tok_it = std.mem.tokenizeAny(u8, p.value, " \t\n\r");
            while (tok_it.next()) |tok| extra_pin_set.put(a, tok, {}) catch {};
            break;
        }
    }

    const has_explicit_pins = if (format_str) |fs|
        std.mem.indexOf(u8, fs, "@@") != null and std.mem.indexOf(u8, fs, "@pinlist") == null
    else
        false;

    if (has_explicit_pins) {
        const fs = format_str.?;
        var pos: usize = 0;
        while (pos < fs.len) {
            const at = std.mem.indexOfScalarPos(u8, fs, pos, '@') orelse break;
            pos = at;
            const is_double = pos + 1 < fs.len and fs[pos + 1] == '@';
            pos += if (is_double) @as(usize, 2) else @as(usize, 1);
            var end = pos;
            while (end < fs.len and fs[end] != ' ' and fs[end] != '"' and
                fs[end] != '\t' and fs[end] != '\n') : (end += 1) {}
            if (end > pos) {
                const pin_name = fs[pos..end];
                if (is_double) {
                    if (!isBusElement(pin_name) and sym_xs.pins.len > 0) {
                        const dir = pin_dir_map.get(pin_name) orelse .inout;
                        try nl.pins.append(uni_a, .{ .name = try uni_a.dupe(u8, pin_name), .dir = dir });
                    }
                } else {
                    if (extra_pin_set.contains(pin_name))
                        try nl.pins.append(uni_a, .{ .name = try uni_a.dupe(u8, pin_name), .dir = .inout });
                }
            }
            pos = end;
        }
    } else {
        for (0..sym_xs.pins.len) |i| {
            const dir = core.sch.PinDir.fromStr(sym_pins.items(.direction)[i].toStr());
            try nl.pins.append(uni_a, .{ .name = try uni_a.dupe(u8, sym_pins.items(.name)[i]), .dir = dir });
        }
        if (format_str) |fs| {
            var pos: usize = 0;
            while (pos < fs.len) {
                const at = std.mem.indexOfScalarPos(u8, fs, pos, '@') orelse break;
                if (at + 1 < fs.len and fs[at + 1] == '@') { pos = at + 2; continue; }
                if (at > 0 and fs[at - 1] == '=') { pos = at + 1; continue; }
                pos = at + 1;
                var end = pos;
                while (end < fs.len and fs[end] != ' ' and fs[end] != '"' and
                    fs[end] != '\t' and fs[end] != '\n') : (end += 1) {}
                if (end > pos) {
                    const token = fs[pos..end];
                    if (extra_pin_set.contains(token))
                        try nl.pins.append(uni_a, .{ .name = try uni_a.dupe(u8, token), .dir = .inout });
                }
                pos = end;
            }
        }
    }
}

// ── Batch xschem reference netlist ───────────────────────────────────────── //

const batch_dir = "test/.tmp_xschem_batch";
var batch_generated: bool = false;

fn commandExists(a: std.mem.Allocator, cmd: []const u8) bool {
    const sh = std.fmt.allocPrint(a, "command -v {s}", .{cmd}) catch return false;
    defer a.free(sh);
    const res = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "sh", "-c", sh },
    }) catch return false;
    defer a.free(res.stdout);
    defer a.free(res.stderr);
    return switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn allBatchFilesExist(a: std.mem.Allocator) bool {
    for (fixtures.cases) |pair| {
        if (!fileExists(pair.sch_path)) continue;
        const h = std.hash.Wyhash.hash(0, pair.sch_path);
        const p = std.fmt.allocPrint(a, "{s}/{x}/{s}.spice", .{
            batch_dir, h, std.fs.path.stem(pair.sch_path),
        }) catch return false;
        defer a.free(p);
        if (!fileExists(p)) return false;
    }
    return true;
}

fn ensureBatchReferences() !void {
    if (batch_generated) return;
    const pa = std.heap.page_allocator;
    if (!commandExists(pa, "xschem")) return error.MissingRequiredCommand;

    var arena = std.heap.ArenaAllocator.init(pa);
    defer arena.deinit();
    const a = arena.allocator();

    // Skip xschem invocation if all .spice reference files already exist.
    if (allBatchFilesExist(a)) {
        batch_generated = true;
        return;
    }

    batch_generated = true;
    std.fs.cwd().deleteTree(batch_dir) catch {};
    try std.fs.cwd().makePath(batch_dir);

    var tcl: std.ArrayListUnmanaged(u8) = .{};
    const w = tcl.writer(a);
    try w.writeAll("set base [pwd]\nset lvs_netlist 1\nset netlist_type spice\n");
    try w.writeAll(
        \\if {[info exists XSCHEM_SHAREDIR]} {
        \\  append XSCHEM_LIBRARY_PATH :${XSCHEM_SHAREDIR}/xschem_library
        \\}
        \\
    );
    if (std.process.getEnvVarOwned(a, "HOME") catch null) |h| {
        const volare = try std.fmt.allocPrint(a, "{s}/.volare/sky130A/libs.tech/xschem", .{h});
        if (fileExists(volare)) {
            try w.print("append XSCHEM_LIBRARY_PATH :{s}\n", .{volare});
            const sky130_tests = try std.fmt.allocPrint(a, "{s}/sky130_tests", .{volare});
            if (fileExists(sky130_tests))
                try w.print("set XSCHEM_LIBRARY_PATH \"{s}:${{XSCHEM_LIBRARY_PATH}}\"\n", .{sky130_tests});
        }
    }
    for (fixtures.cases) |pair| {
        if (!fileExists(pair.sch_path)) continue;
        const h = std.hash.Wyhash.hash(0, pair.sch_path);
        const sub = try std.fmt.allocPrint(a, "{s}/{x}", .{ batch_dir, h });
        std.fs.cwd().makePath(sub) catch continue;
        const dir = caseDir(pair.sch_path);
        try w.print("catch {{cd $base/{s}; set netlist_dir $base/{s}; xschem load \"$base/{s}\"; xschem netlist}}\n", .{ dir, sub, pair.sch_path });
    }
    try w.writeAll("xschem exit closewindow force\n");

    const tcl_path = batch_dir ++ "/batch.tcl";
    try std.fs.cwd().writeFile(.{ .sub_path = tcl_path, .data = tcl.items });
    _ = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "xschem", "--no_x", "--script", tcl_path },
        .max_output_bytes = 10 * 1024 * 1024,
    });
}

fn getBatchReference(a: std.mem.Allocator, sch_path: []const u8) ![]u8 {
    if (!batch_generated) return error.XschemReferenceNetlistFailed;
    const h = std.hash.Wyhash.hash(0, sch_path);
    const path = try std.fmt.allocPrint(a, "{s}/{x}/{s}.spice", .{ batch_dir, h, std.fs.path.stem(sch_path) });
    defer a.free(path);
    if (!fileExists(path)) return error.XschemReferenceNetlistFailed;
    return std.fs.cwd().readFileAlloc(a, path, std.math.maxInt(usize));
}

// ── Per-fixture runners (explicit allocator, no global state) ─────────────── //

fn runFamilyA(a: std.mem.Allocator, c: fixtures.Case) !void {
    if (!fileExists(c.sch_path)) return error.SkipZigTest;
    var x1 = try loadXs(a, c.sch_path);
    defer x1.deinit();
    const out1 = x1.writeFile(a, null) orelse return error.SkipZigTest;
    defer a.free(out1);
    var x2 = XSchem.readFile(out1, a, null);
    defer x2.deinit();
    const out2 = x2.writeFile(a, null) orelse return error.SkipZigTest;
    defer a.free(out2);
    const can1 = try normalizeNoCommentLines(a, out1);
    defer a.free(can1);
    const can2 = try normalizeNoCommentLines(a, out2);
    defer a.free(can2);
    if (!std.mem.eql(u8, can1, can2)) {
        printFirstDiff(can1, can2, c.sch_path);
        return error.RoundtripMismatch;
    }
}

fn runFamilyC(a: std.mem.Allocator, c: fixtures.Case) !void {
    if (!fileExists(c.sch_path)) return error.SkipZigTest;
    var x = try loadXs(a, c.sch_path);
    defer x.deinit();
    var s = try x.toSchemify(a);
    defer s.deinit();
    const out = s.writeFile(a, null) orelse return error.SkipZigTest;
    defer a.free(out);
    var s_back = core.sch.Schemify.readFile(out, a, null);
    defer s_back.deinit();
    const out2 = s_back.writeFile(a, null) orelse return error.SkipZigTest;
    defer a.free(out2);
    const can1 = try normalizeNoCommentLines(a, out);
    defer a.free(can1);
    const can2 = try normalizeNoCommentLines(a, out2);
    defer a.free(can2);
    if (!std.mem.eql(u8, can1, can2)) {
        printFirstDiff(can1, can2, c.sch_path);
        return error.ConversionLossDetected;
    }
}

fn runFamilyB(a: std.mem.Allocator, c: fixtures.Case) !void {
    if (!fileExists(c.sch_path)) return error.SkipZigTest;
    var xs = try loadXs(a, c.sch_path);
    defer xs.deinit();
    var nl = try toNetlister(a, &xs, c.sch_path);
    defer nl.deinit();
    try loadSymPinOrder(a, &nl, c.sym_path);

    if (nl.devices.len == 0) return error.SkipZigTest;

    const mine = nl.generateSpiceFor(a, .ngspice) catch return error.SkipZigTest;
    defer a.free(mine);
    if (std.mem.indexOf(u8, mine, "tcleval(") != null) return error.SkipZigTest;
    if (std.mem.indexOf(u8, mine, "$::") != null) return error.SkipZigTest;
    if (std.mem.indexOf(u8, mine, "[if [") != null) return error.SkipZigTest;

    const xref = getBatchReference(a, c.sch_path) catch return error.SkipZigTest;
    defer a.free(xref);
    if (std.mem.indexOf(u8, xref, "IS MISSING") != null) return error.SkipZigTest;

    const mine_can = try canonicalizeSpice(a, mine);
    defer a.free(mine_can);
    const xref_can = try canonicalizeSpice(a, xref);
    defer a.free(xref_can);
    if (!std.mem.eql(u8, xref_can, mine_can)) {
        printFirstDiff(xref_can, mine_can, c.sch_path);
        return error.NetlistMismatch;
    }
}

// ── Parallel runner ───────────────────────────────────────────────────────── //

const RunState = struct {
    pass: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    skip: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn workerA(c: fixtures.Case, state: *RunState) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    runFamilyA(arena.allocator(), c) catch |err| switch (err) {
        error.SkipZigTest => { _ = state.skip.fetchAdd(1, .monotonic); return; },
        else => { _ = state.fail.fetchAdd(1, .monotonic); return; },
    };
    _ = state.pass.fetchAdd(1, .monotonic);
}

fn workerC(c: fixtures.Case, state: *RunState) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    runFamilyC(arena.allocator(), c) catch |err| switch (err) {
        error.SkipZigTest => { _ = state.skip.fetchAdd(1, .monotonic); return; },
        else => { _ = state.fail.fetchAdd(1, .monotonic); return; },
    };
    _ = state.pass.fetchAdd(1, .monotonic);
}

fn workerB(c: fixtures.Case, state: *RunState) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    runFamilyB(arena.allocator(), c) catch |err| switch (err) {
        error.SkipZigTest => { _ = state.skip.fetchAdd(1, .monotonic); return; },
        else => { _ = state.fail.fetchAdd(1, .monotonic); return; },
    };
    _ = state.pass.fetchAdd(1, .monotonic);
}

fn runParallel(comptime worker: anytype, state: *RunState) !void {
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.heap.page_allocator });
    defer pool.deinit();
    var wg = std.Thread.WaitGroup{};
    for (fixtures.cases) |c| pool.spawnWg(&wg, worker, .{ c, state });
    pool.waitAndWork(&wg);
}

// ── Tests ─────────────────────────────────────────────────────────────────── //

test "core_new preflight: xschem available" {
    preflight.requireXschem() catch return error.SkipZigTest;
}

test "core_new shard assignment deterministic" {
    try testing.expectEqual(shardOf(fixtures.cases[0].sch_path, 8), shardOf(fixtures.cases[0].sch_path, 8));
}

test "core_new family A: xschem roundtrip" {
    var state = RunState{};
    try runParallel(workerA, &state);
    const p = state.pass.load(.acquire);
    const f = state.fail.load(.acquire);
    const s = state.skip.load(.acquire);
    std.debug.print("  family A: {d} passed, {d} failed, {d} skipped\n", .{ p, f, s });
    if (f > 0) return error.TestsFailed;
}

test "core_new family C: xschem→schemify conversion" {
    var state = RunState{};
    try runParallel(workerC, &state);
    const p = state.pass.load(.acquire);
    const f = state.fail.load(.acquire);
    const s = state.skip.load(.acquire);
    std.debug.print("  family C: {d} passed, {d} failed, {d} skipped\n", .{ p, f, s });
    if (f > 0) return error.TestsFailed;
}

test "core_new family B: netlist parity" {
    preflight.requireXschem() catch return error.SkipZigTest;
    ensureBatchReferences() catch |err| switch (err) {
        error.MissingRequiredCommand => return error.SkipZigTest,
        else => return err,
    };
    var state = RunState{};
    try runParallel(workerB, &state);
    const p = state.pass.load(.acquire);
    const f = state.fail.load(.acquire);
    const s = state.skip.load(.acquire);
    std.debug.print("  family B: {d} passed, {d} failed, {d} skipped\n", .{ p, f, s });
    if (f > 0) return error.TestsFailed;
}
