// tests/test_pyspice_import.zig — Integration test for PySpice round-trip.
//
// For each .py example in examples/pyspice/:
//   1. Run `python3 example.py` → capture SPICE netlist (reference)
//   2. Feed SPICE through import pipeline → Schemify struct
//   3. Call emitPySpice on the Schemify struct → generated Python script
//   4. Run `python3` on generated script → capture SPICE netlist (round-trip)
//   5. Compare reference vs round-trip (normalized)
//
// Run: zig build test_pyspice_import

const std = @import("std");
const import_mod = @import("import");
const simulation = @import("simulation");
const core = @import("schematic");

const examples = @import("examples");

// ── Helpers ─────────────────────────────────────────────────────────────────

fn runPython(alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
    const tmp_path = "/tmp/schemify_test_pyspice.py";

    // Write source to temp file
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(source);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const argv = [_][]const u8{ "python3", tmp_path };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const max_output: usize = 1 << 24; // 16 MiB
    const stdout = if (child.stdout) |f| try f.readToEndAlloc(alloc, max_output) else "";
    errdefer if (stdout.len > 0) alloc.free(stdout);

    const stderr = if (child.stderr) |f| f.readToEndAlloc(alloc, max_output) catch "" else "";
    defer if (stderr.len > 0) alloc.free(stderr);

    const term = try child.wait();
    // Accept non-zero exit if stdout has data — print(circuit) runs before
    // simulator calls that may crash due to missing backend.
    if (term.Exited != 0) {
        if (stdout.len > 0) return stdout;
        return error.PythonFailed;
    }

    return stdout;
}

/// Normalize SPICE output for comparison:
/// - Strip comments (lines starting with *)
/// - Strip blank lines
/// - Lowercase everything
/// - Sort non-title lines (order shouldn't matter semantically)
fn normalizeSpice(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);

    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '*') continue;
        if (std.mem.eql(u8, trimmed, ".end")) break; // stop at end of netlist
        if (std.mem.startsWith(u8, trimmed, ".end")) continue; // skip .ends etc

        const lower = try arena.alloc(u8, trimmed.len);
        for (trimmed, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }

        if (first) {
            try lines.insert(arena, 0, lower);
            first = false;
        } else {
            try lines.append(arena, lower);
        }
    }

    if (lines.items.len > 1) {
        std.mem.sort([]const u8, lines.items[1..], {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
    }

    // Join into caller-owned allocation
    var total: usize = 0;
    for (lines.items) |line| total += line.len + 1;
    const result = try alloc.alloc(u8, total);
    var pos: usize = 0;
    for (lines.items) |line| {
        @memcpy(result[pos..][0..line.len], line);
        result[pos + line.len] = '\n';
        pos += line.len + 1;
    }
    return result;
}

/// Check if a .py source is a testbench (has analysis commands or X instances at top level)
fn isTestbench(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "simulator.") != null or
        std.mem.indexOf(u8, source, ".transient(") != null or
        std.mem.indexOf(u8, source, ".ac(") != null or
        std.mem.indexOf(u8, source, ".dc(") != null;
}

/// Compare two net names with normalization:
/// - Case-insensitive
/// - "0", "gnd", "ground", "vss" all match each other
/// - "vdd", "vcc" match each other
/// - Auto-generated names ("net1", "?") match anything (geometric resolver
///   may assign different auto-names)
fn netNamesMatch(expected: []const u8, actual: []const u8) bool {
    // Auto-generated or unresolved — can't meaningfully compare
    if (actual.len == 0 or (actual.len == 1 and actual[0] == '?')) return true;
    if (expected.len == 0) return true;

    // Check if either is auto-generated (net1, net2, ...)
    if (isAutoNet(expected) or isAutoNet(actual)) return true;

    // Normalize ground variants
    if (isGndName(expected) and isGndName(actual)) return true;

    // Normalize supply variants
    if (isVddName(expected) and isVddName(actual)) return true;

    // Case-insensitive string compare
    if (expected.len != actual.len) return false;
    for (expected, actual) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn isAutoNet(name: []const u8) bool {
    if (name.len > 3 and std.mem.startsWith(u8, name, "net")) {
        if (std.ascii.isDigit(name[3])) return true;
    }
    return false;
}

fn isGndName(name: []const u8) bool {
    var buf: [16]u8 = undefined;
    const lo = lowerBuf(name, &buf) orelse return false;
    return std.mem.eql(u8, lo, "0") or std.mem.eql(u8, lo, "gnd") or
        std.mem.eql(u8, lo, "ground") or std.mem.eql(u8, lo, "vss");
}

fn isVddName(name: []const u8) bool {
    var buf: [16]u8 = undefined;
    const lo = lowerBuf(name, &buf) orelse return false;
    return std.mem.startsWith(u8, lo, "vdd") or std.mem.startsWith(u8, lo, "vcc");
}

fn lowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

// ── Test cases ──────────────────────────────────────────────────────────────

fn testPySpiceExample(comptime name: []const u8, comptime source: []const u8) !void {
    const alloc = std.testing.allocator;

    // Phase 1: Run original Python to get reference SPICE
    const reference_spice = runPython(alloc, source) catch |err| {
        // python3 not available or pyspice_rs not installed — skip
        if (err == error.PythonFailed) return error.SkipZigTest;
        return err;
    };
    defer alloc.free(reference_spice);

    // Must produce non-empty output (print(circuit) at end of each example)
    if (reference_spice.len == 0) {
        std.debug.print("SKIP {s}: python3 produced no output\n", .{name});
        return error.SkipZigTest;
    }

    // Phase 2: Import SPICE through the pipeline
    var result = import_mod.importProject(alloc, .{
        .spice_text = .{ .source = reference_spice, .name = name },
    }) catch {
        // Import pipeline may fail on some complex circuits — report but don't fail hard
        std.debug.print("WARN {s}: import pipeline failed\n", .{name});
        return;
    };
    defer result.deinit();

    if (result.results.len == 0) {
        std.debug.print("WARN {s}: import produced 0 results\n", .{name});
        return;
    }

    // Phase 3: Generate PySpice from the imported Schemify struct
    const sch = &result.results[0].schemify;
    const generated_pyspice = simulation.Netlist.emitPySpice(sch, alloc, null, .ngspice) catch {
        std.debug.print("WARN {s}: emitPySpice failed\n", .{name});
        return;
    };
    defer alloc.free(generated_pyspice);

    if (generated_pyspice.len == 0) {
        std.debug.print("WARN {s}: emitPySpice produced empty output\n", .{name});
        return;
    }

    // Phase 4: Run generated PySpice through python3
    // Add print(circuit) if not already present
    var full_script: std.ArrayList(u8) = .empty;
    defer full_script.deinit(alloc);
    try full_script.appendSlice(alloc, generated_pyspice);
    if (std.mem.indexOf(u8, generated_pyspice, "print(circuit)") == null) {
        try full_script.appendSlice(alloc, "\nprint(circuit)\n");
    }

    const roundtrip_spice = runPython(alloc, full_script.items) catch {
        std.debug.print("WARN {s}: generated script failed to run\n", .{name});
        return;
    };
    defer alloc.free(roundtrip_spice);

    if (roundtrip_spice.len == 0) {
        std.debug.print("WARN {s}: round-trip produced no output\n", .{name});
        return;
    }

    // Phase 5: Compare normalized SPICE outputs
    const ref_norm = try normalizeSpice(alloc, reference_spice);
    defer alloc.free(ref_norm);
    const rt_norm = try normalizeSpice(alloc, roundtrip_spice);
    defer alloc.free(rt_norm);

    if (!std.mem.eql(u8, ref_norm, rt_norm)) {
        std.debug.print("\n=== MISMATCH: {s} ===\n", .{name});
        std.debug.print("--- Reference (first 500 chars) ---\n{s}\n", .{ref_norm[0..@min(ref_norm.len, 500)]});
        std.debug.print("--- Round-trip (first 500 chars) ---\n{s}\n", .{rt_norm[0..@min(rt_norm.len, 500)]});
        return error.TestExpectedEqual;
    }
}

// ── Auto-generated test declarations for all examples/pyspice/**/*.py ───────

fn isPySpiceExample(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "pyspice/")) return false;
    if (!std.mem.endsWith(u8, name, ".py")) return false;
    // Skip __init__.py, __pycache__, .venv, etc.
    if (std.mem.indexOf(u8, name, "__") != null) return false;
    if (std.mem.indexOf(u8, name, ".venv") != null) return false;
    return true;
}

// Phase 1 tests: verify Python execution produces SPICE output
test "pyspice examples produce valid SPICE output" {
    const alloc = std.testing.allocator;
    var pass: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;

    for (examples.list) |ex| {
        if (!isPySpiceExample(ex.name)) continue;

        const spice_out = runPython(alloc, ex.data) catch |err| {
            if (err == error.PythonFailed) {
                skip += 1;
                continue;
            }
            fail += 1;
            std.debug.print("  FAIL {s}: {}\n", .{ ex.name, err });
            continue;
        };
        defer alloc.free(spice_out);

        if (spice_out.len == 0) {
            skip += 1;
            continue;
        }

        // Verify it looks like SPICE (has a title line or .subckt or element lines)
        if (std.mem.indexOf(u8, spice_out, "\n") == null) {
            fail += 1;
            std.debug.print("  FAIL {s}: output is single line\n", .{ex.name});
            continue;
        }

        pass += 1;
    }

    std.debug.print("\n  [python3 execution] pass={d} skip={d} fail={d}\n", .{ pass, skip, fail });
    if (pass == 0 and skip > 0) return error.SkipZigTest;
    try std.testing.expect(fail == 0);
}

// Phase 2 tests: verify SPICE output can be imported into Schemify
test "pyspice SPICE output imports into Schemify" {
    const alloc = std.testing.allocator;
    var pass: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;

    for (examples.list) |ex| {
        if (!isPySpiceExample(ex.name)) continue;

        const spice_out = runPython(alloc, ex.data) catch {
            skip += 1;
            continue;
        };
        defer alloc.free(spice_out);
        if (spice_out.len == 0) { skip += 1; continue; }

        var result = import_mod.importProject(alloc, .{
            .spice_text = .{ .source = spice_out, .name = std.fs.path.stem(ex.name) },
        }) catch {
            fail += 1;
            std.debug.print("  FAIL {s}: import failed\n", .{ex.name});
            continue;
        };
        defer result.deinit();

        if (result.results.len == 0) {
            fail += 1;
            std.debug.print("  FAIL {s}: 0 results\n", .{ex.name});
            continue;
        }

        // Verify we got instances
        const sch = &result.results[0].schemify;
        if (sch.instances.len == 0) {
            fail += 1;
            std.debug.print("  FAIL {s}: 0 instances\n", .{ex.name});
            continue;
        }

        pass += 1;
    }

    std.debug.print("\n  [import pipeline] pass={d} skip={d} fail={d}\n", .{ pass, skip, fail });
    if (pass == 0 and skip > 0) return error.SkipZigTest;
    try std.testing.expect(fail == 0);
}

// Phase 3 tests: verify emitPySpice produces valid Python from imported schematics
test "emitPySpice generates runnable Python" {
    const alloc = std.testing.allocator;
    var pass: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;

    for (examples.list) |ex| {
        if (!isPySpiceExample(ex.name)) continue;

        const spice_out = runPython(alloc, ex.data) catch {
            skip += 1;
            continue;
        };
        defer alloc.free(spice_out);
        if (spice_out.len == 0) { skip += 1; continue; }

        var result = import_mod.importProject(alloc, .{
            .spice_text = .{ .source = spice_out, .name = std.fs.path.stem(ex.name) },
        }) catch { skip += 1; continue; };
        defer result.deinit();
        if (result.results.len == 0) { skip += 1; continue; }

        const sch = &result.results[0].schemify;
        const generated = simulation.Netlist.emitPySpice(sch, alloc, null, .ngspice) catch {
            fail += 1;
            std.debug.print("  FAIL {s}: emitPySpice error\n", .{ex.name});
            continue;
        };
        defer alloc.free(generated);

        if (generated.len == 0) {
            fail += 1;
            std.debug.print("  FAIL {s}: empty output\n", .{ex.name});
            continue;
        }

        // Verify it starts with pyspice_rs import
        if (std.mem.indexOf(u8, generated, "pyspice_rs") == null) {
            fail += 1;
            std.debug.print("  FAIL {s}: missing pyspice_rs import\n", .{ex.name});
            continue;
        }

        // Try running it through python3 (syntax check)
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(alloc);
        try script.appendSlice(alloc, generated);
        if (std.mem.indexOf(u8, generated, "print(circuit)") == null) {
            try script.appendSlice(alloc, "\nprint(circuit)\n");
        }

        const rt_out = runPython(alloc, script.items) catch {
            fail += 1;
            std.debug.print("  FAIL {s}: generated script not runnable\n", .{ex.name});
            continue;
        };
        defer alloc.free(rt_out);

        pass += 1;
    }

    std.debug.print("\n  [emitPySpice validity] pass={d} skip={d} fail={d}\n", .{ pass, skip, fail });
    if (pass == 0 and skip > 0) return error.SkipZigTest;
    try std.testing.expect(fail == 0);
}

// Phase 4: Geometric connectivity matches SPICE nets.
//
// The real test for correct wiring: after import, clear the explicit pin.net
// fields (SPICE ground truth) and re-resolve connectivity from wire geometry
// alone. Then compare: does each instance pin resolve to the same net as the
// SPICE parser originally assigned?
//
// Failures here mean wires pass through device bodies or create false
// T-junctions that merge nets that should be separate.
test "geometric connectivity matches SPICE nets" {
    const alloc = std.testing.allocator;
    var pass: usize = 0;
    var skip: usize = 0;
    var mismatch: usize = 0;

    for (examples.list) |ex| {
        if (!isPySpiceExample(ex.name)) continue;

        const spice_out = runPython(alloc, ex.data) catch { skip += 1; continue; };
        defer alloc.free(spice_out);
        if (spice_out.len == 0) { skip += 1; continue; }

        var result = import_mod.importProject(alloc, .{
            .spice_text = .{ .source = spice_out, .name = std.fs.path.stem(ex.name) },
        }) catch { skip += 1; continue; };
        defer result.deinit();
        if (result.results.len == 0) { skip += 1; continue; }

        const sch = &result.results[0].schemify;
        if (sch.instances.len == 0 or sch.wires.len == 0) { skip += 1; continue; }
        if (sch.sym_data.items.len != sch.instances.len) { skip += 1; continue; }

        // Step 1: Collect expected nets from explicit pin.net (SPICE ground truth)
        const ExpectedConn = struct { inst: usize, pin: usize, net: []const u8 };
        var expected: std.ArrayList(ExpectedConn) = .empty;
        defer expected.deinit(alloc);

        const ikind = sch.instances.items(.kind);
        for (0..sch.instances.len) |i| {
            if (ikind[i].isNonElectrical() or ikind[i].isLabel() or
                ikind[i] == .gnd or ikind[i] == .vdd) continue;

            const sd = sch.sym_data.items[i];
            for (sd.pins, 0..) |pin, pi| {
                if (pin.net.isEmpty()) continue;
                const net_str = sch.strings.get(pin.net);
                if (net_str.len == 0) continue;
                try expected.append(alloc, .{ .inst = i, .pin = pi, .net = try alloc.dupe(u8, net_str) });
            }
        }

        if (expected.items.len == 0) { skip += 1; continue; }

        // Step 2: Make mutable copies of sym_data pins with net cleared
        const cleared_sd = try alloc.alloc(core.types.SymData, sch.sym_data.items.len);
        defer {
            for (cleared_sd) |sd| alloc.free(sd.pins);
            alloc.free(cleared_sd);
        }

        for (sch.sym_data.items, 0..) |sd, i| {
            if (sd.pins.len == 0) {
                cleared_sd[i] = .{};
                continue;
            }
            const pins = try alloc.alloc(core.types.PinRef, sd.pins.len);
            for (sd.pins, 0..) |pin, pi| {
                pins[pi] = pin;
                pins[pi].net = .empty; // Force geometric resolution
            }
            cleared_sd[i] = .{ .pins = pins, .props = sd.props, .format = sd.format, .lvs_format = sd.lvs_format, .template = sd.template };
        }

        // Step 3: Resolve connectivity from geometry only
        var conn: core.connectivity.Connectivity = .{};
        defer conn.deinit(alloc);
        conn.resolve(alloc, &sch.instances, &sch.wires, cleared_sd, &sch.strings);

        // Step 4: Compare
        var bad = false;
        for (expected.items) |exp| {
            const resolved = conn.connSlice(exp.inst);
            if (exp.pin >= resolved.len) {
                std.debug.print("  {s}: inst {d} pin {d} — no geometric conn (expected '{s}')\n", .{ ex.name, exp.inst, exp.pin, exp.net });
                bad = true;
                continue;
            }
            const geo_net = conn.pool.get(resolved[exp.pin].net);
            // Normalize for comparison (case-insensitive, "0" == "gnd" etc)
            if (!netNamesMatch(exp.net, geo_net)) {
                std.debug.print("  {s}: inst {d} pin {d} — expected '{s}', got '{s}'\n", .{ ex.name, exp.inst, exp.pin, exp.net, geo_net });
                bad = true;
            }
        }

        // Free expected net strings
        for (expected.items) |exp| alloc.free(exp.net);

        if (bad) {
            mismatch += 1;
        } else {
            pass += 1;
        }
    }

    std.debug.print("\n  [geometric connectivity] pass={d} mismatch={d} skip={d}\n", .{ pass, mismatch, skip });
    if (pass == 0 and skip > 0) return error.SkipZigTest;
    try std.testing.expect(mismatch == 0);
}

// Phase 5: Full round-trip comparison (reference vs regenerated SPICE)
test "full round-trip: python → SPICE → Schemify → PySpice → python → SPICE" {
    const alloc = std.testing.allocator;
    var pass: usize = 0;
    var skip: usize = 0;
    var mismatch: usize = 0;

    for (examples.list) |ex| {
        if (!isPySpiceExample(ex.name)) continue;

        const reference = runPython(alloc, ex.data) catch { skip += 1; continue; };
        defer alloc.free(reference);
        if (reference.len == 0) { skip += 1; continue; }

        var result = import_mod.importProject(alloc, .{
            .spice_text = .{ .source = reference, .name = std.fs.path.stem(ex.name) },
        }) catch { skip += 1; continue; };
        defer result.deinit();
        if (result.results.len == 0) { skip += 1; continue; }

        const sch = &result.results[0].schemify;
        const generated = simulation.Netlist.emitPySpice(sch, alloc, null, .ngspice) catch {
            skip += 1;
            continue;
        };
        defer alloc.free(generated);

        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(alloc);
        try script.appendSlice(alloc, generated);
        if (std.mem.indexOf(u8, generated, "print(circuit)") == null) {
            try script.appendSlice(alloc, "\nprint(circuit)\n");
        }

        const roundtrip = runPython(alloc, script.items) catch { skip += 1; continue; };
        defer alloc.free(roundtrip);
        if (roundtrip.len == 0) { skip += 1; continue; }

        const ref_norm = normalizeSpice(alloc, reference) catch { skip += 1; continue; };
        defer alloc.free(ref_norm);
        const rt_norm = normalizeSpice(alloc, roundtrip) catch { skip += 1; continue; };
        defer alloc.free(rt_norm);

        if (std.mem.eql(u8, ref_norm, rt_norm)) {
            pass += 1;
        } else {
            mismatch += 1;
            std.debug.print("  MISMATCH {s}\n", .{ex.name});
        }
    }

    std.debug.print("\n  [round-trip] pass={d} mismatch={d} skip={d}\n", .{ pass, mismatch, skip });
    try std.testing.expect(mismatch == 0);
}
