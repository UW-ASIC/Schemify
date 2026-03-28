//! Synthesis — yosys synthesis invocation and validation.
//!
//! Provides functions to invoke yosys for RTL→gate-level synthesis,
//! validate synthesized netlists against symbol pins, and list standard
//! cells used in the synthesized design.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const sch = @import("Schemify.zig");
const Schemify = sch.Schemify;
const YosysJson = @import("YosysJson.zig");
const Vfs = @import("utility").Vfs;

// ── Public types ─────────────────────────────────────────────────────────── //

pub const SynthOptions = struct {
    liberty_path: []const u8,
    mapping: []const u8,
    output_json: ?[]const u8 = null,
    flatten: bool = true,
};

pub const SynthReport = struct {
    output_path: []const u8,
    cell_count: u32,
    area_estimate: ?f64,
    critical_path_ns: ?f64,
    success: bool,
    log: []const u8,
};

pub const ValidationReport = struct {
    ports_match: bool,
    missing_ports: []const []const u8,
    extra_ports: []const []const u8,
    supply_pins: []const []const u8,
};

pub const CellInfo = struct {
    cell_type: []const u8,
    count: u32,
};

pub const Error = error{
    YosysNotFound,
    NotSynthesizable,
    NoDigitalConfig,
    NoBehavioralSource,
    NoSynthesizedSource,
    SynthesisFailed,
    JsonParseFailed,
};

// ── runSynthesis ─────────────────────────────────────────────────────────── //

pub fn runSynthesis(
    s: *Schemify,
    gpa: Allocator,
    options: SynthOptions,
) (Error || Allocator.Error || std.process.Child.RunError)!SynthReport {
    // 1. Validate digital config exists.
    if (s.digital == null) return Error.NoDigitalConfig;
    const digital = &s.digital.?;

    // 2. Check language is synthesizable.
    switch (digital.language) {
        .verilog, .vhdl => {},
        .xspice, .xyce_digital => return Error.NotSynthesizable,
    }

    // 3. Check behavioral source exists.
    const source = digital.behavioral.source orelse return Error.NoBehavioralSource;

    // 3b. Resolve source path — write inline source to temp file if needed.
    const source_path: []const u8 = switch (digital.behavioral.mode) {
        .file => source,
        .@"inline" => blk: {
            const ext: []const u8 = if (digital.language == .vhdl) ".vhd" else ".v";
            const tmp_path = try std.fmt.allocPrint(gpa, "/tmp/schemify_synth_{s}{s}", .{ s.name, ext });
            Vfs.writeAll(tmp_path, source) catch {
                gpa.free(tmp_path);
                return Error.SynthesisFailed;
            };
            break :blk tmp_path;
        },
    };

    // 4. Determine output JSON path.
    const output_path = options.output_json orelse
        try std.fmt.allocPrint(gpa, "synth/{s}.json", .{s.name});

    // 5. Generate yosys script.
    const read_cmd: []const u8 = if (digital.language == .vhdl) "read_vhdl" else "read_verilog";
    const top_name = digital.behavioral.top_module orelse s.name;
    const flatten_cmd: []const u8 = if (options.flatten) "flatten\n" else "";

    const script = try std.fmt.allocPrint(gpa,
        \\{s} {s}
        \\synth -top {s}
        \\{s}dfflibmap -liberty {s}
        \\abc -liberty {s}
        \\stat
        \\write_json {s}
    , .{
        read_cmd,
        source_path,
        top_name,
        flatten_cmd,
        options.liberty_path,
        options.liberty_path,
        output_path,
    });
    defer gpa.free(script);

    // 6. Spawn yosys.
    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{ "yosys", "-p", script },
    }) catch |e| {
        // If yosys is not found in PATH, return a clear error.
        if (e == error.FileNotFound) return Error.YosysNotFound;
        return e;
    };

    const log_output = result.stdout;
    // Free stderr separately — we only keep stdout as the log.
    gpa.free(result.stderr);

    // 8. Check exit code.
    const success = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!success) {
        return SynthReport{
            .output_path = output_path,
            .cell_count = 0,
            .area_estimate = null,
            .critical_path_ns = null,
            .success = false,
            .log = log_output,
        };
    }

    // 9. Parse stat output for cell count and area.
    const cell_count = parseCellCount(log_output);
    const area_estimate = parseArea(log_output);

    // 10. Update digital config with synthesis results.
    const arena_alloc = s.alloc();
    digital.synthesized.source = arena_alloc.dupe(u8, output_path) catch output_path;
    digital.synthesized.liberty = arena_alloc.dupe(u8, options.liberty_path) catch options.liberty_path;
    digital.synthesized.mapping = arena_alloc.dupe(u8, options.mapping) catch options.mapping;

    // 12. Return report.
    return SynthReport{
        .output_path = output_path,
        .cell_count = cell_count,
        .area_estimate = area_estimate,
        .critical_path_ns = null,
        .success = true,
        .log = log_output,
    };
}

// ── validateSynthesized ──────────────────────────────────────────────────── //

pub fn validateSynthesized(
    s: *const Schemify,
    gpa: Allocator,
) (Error || Allocator.Error)!ValidationReport {
    // 1. Check synthesized source exists.
    const digital = s.digital orelse return Error.NoDigitalConfig;
    const synth_path = digital.synthesized.source orelse return Error.NoSynthesizedSource;

    // 2. Read the JSON file.
    const json_text = Vfs.readAlloc(gpa, synth_path) catch
        return Error.JsonParseFailed;
    defer gpa.free(json_text);

    // 3. Parse with YosysJson.
    const module = YosysJson.parse(json_text, null, gpa) catch return Error.JsonParseFailed;
    defer YosysJson.deinit(&module, gpa);

    // 4. Collect symbol pin names.
    var symbol_ports = std.StringHashMap(void).init(gpa);
    defer symbol_ports.deinit();

    const pin_names = s.pins.items(.name);
    for (0..s.pins.len) |i| {
        symbol_ports.put(pin_names[i], {}) catch {};
    }

    // 5. Collect synth port names.
    var synth_ports = std.StringHashMap(void).init(gpa);
    defer synth_ports.deinit();

    for (module.ports) |port| {
        synth_ports.put(port.name, {}) catch {};
    }

    // 6. Compute differences.
    var missing = List([]const u8){};
    var extra = List([]const u8){};
    var supply = List([]const u8){};

    // Ports in symbol but not in synth → missing.
    var sym_it = symbol_ports.keyIterator();
    while (sym_it.next()) |key| {
        if (!synth_ports.contains(key.*)) {
            missing.append(gpa, key.*) catch {};
        }
    }

    // Ports in synth but not in symbol → check supply or extra.
    var synth_it = synth_ports.keyIterator();
    while (synth_it.next()) |key| {
        if (!symbol_ports.contains(key.*)) {
            if (isSupplyPin(key.*)) {
                supply.append(gpa, key.*) catch {};
            } else {
                extra.append(gpa, key.*) catch {};
            }
        }
    }

    const missing_slice = missing.toOwnedSlice(gpa) catch &.{};
    const extra_slice = extra.toOwnedSlice(gpa) catch &.{};
    const supply_slice = supply.toOwnedSlice(gpa) catch &.{};

    return ValidationReport{
        .ports_match = missing_slice.len == 0 and extra_slice.len == 0,
        .missing_ports = missing_slice,
        .extra_ports = extra_slice,
        .supply_pins = supply_slice,
    };
}

// ── getSynthesizedCellList ───────────────────────────────────────────────── //

pub fn getSynthesizedCellList(
    s: *const Schemify,
    gpa: Allocator,
) (Error || Allocator.Error)![]const CellInfo {
    // 1. Load and parse.
    const digital = s.digital orelse return Error.NoDigitalConfig;
    const synth_path = digital.synthesized.source orelse return Error.NoSynthesizedSource;

    const json_text = Vfs.readAlloc(gpa, synth_path) catch
        return Error.JsonParseFailed;
    defer gpa.free(json_text);

    const module = YosysJson.parse(json_text, null, gpa) catch return Error.JsonParseFailed;
    defer YosysJson.deinit(&module, gpa);

    // 2. Count occurrences of each cell type.
    var counts = std.StringHashMap(u32).init(gpa);
    defer counts.deinit();

    for (module.cells) |cell| {
        const entry = counts.getOrPut(cell.cell_type) catch continue;
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    // 3. Build sorted list.
    var result = List(CellInfo){};
    var it = counts.iterator();
    while (it.next()) |entry| {
        result.append(gpa, .{
            .cell_type = entry.key_ptr.*,
            .count = entry.value_ptr.*,
        }) catch {};
    }

    const slice = result.toOwnedSlice(gpa) catch return &.{};

    // Sort by count descending, then by name ascending.
    std.mem.sort(CellInfo, slice, {}, struct {
        fn lessThan(_: void, a: CellInfo, b: CellInfo) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.cell_type, b.cell_type) == .lt;
        }
    }.lessThan);

    return slice;
}

// ── Helpers ──────────────────────────────────────────────────────────────── //

fn isSupplyPin(name: []const u8) bool {
    const supply_names = [_][]const u8{ "VDD", "VSS", "VPWR", "VGND", "VNB", "VPB", "vdd", "vss" };
    for (&supply_names) |sn| {
        if (std.ascii.eqlIgnoreCase(name, sn)) return true;
    }
    return false;
}

/// Parse "Number of cells:" from yosys stat output.
fn parseCellCount(log_text: []const u8) u32 {
    const needle = "Number of cells:";
    var pos: usize = 0;
    while (pos < log_text.len) {
        if (std.mem.indexOfPos(u8, log_text, pos, needle)) |idx| {
            const after = idx + needle.len;
            const rest = std.mem.trimLeft(u8, log_text[after..], " \t");
            // Find end of number.
            var end: usize = 0;
            while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
            if (end > 0) {
                return std.fmt.parseInt(u32, rest[0..end], 10) catch 0;
            }
            pos = after;
        } else break;
    }
    return 0;
}

/// Parse "Chip area for module" from yosys stat output.
fn parseArea(log_text: []const u8) ?f64 {
    const needle = "Chip area for module";
    if (std.mem.indexOf(u8, log_text, needle)) |idx| {
        // Find the colon after the module name.
        const after_needle = log_text[idx..];
        if (std.mem.indexOf(u8, after_needle, ":")) |colon_offset| {
            const after_colon = std.mem.trimLeft(u8, after_needle[colon_offset + 1 ..], " \t");
            // Find end of number (may include '.').
            var end: usize = 0;
            while (end < after_colon.len and
                (after_colon[end] >= '0' and after_colon[end] <= '9' or after_colon[end] == '.')) : (end += 1)
            {}
            if (end > 0) {
                return std.fmt.parseFloat(f64, after_colon[0..end]) catch null;
            }
        }
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────── //

test "isSupplyPin" {
    try std.testing.expect(isSupplyPin("VDD"));
    try std.testing.expect(isSupplyPin("VPWR"));
    try std.testing.expect(isSupplyPin("vss"));
    try std.testing.expect(!isSupplyPin("CLK"));
    try std.testing.expect(!isSupplyPin("DATA"));
}

test "isSupplyPin case insensitive" {
    try std.testing.expect(isSupplyPin("Vdd"));
    try std.testing.expect(isSupplyPin("vGND"));
    try std.testing.expect(isSupplyPin("Vpb"));
    try std.testing.expect(!isSupplyPin("RESET"));
}

test "parseCellCount" {
    try std.testing.expectEqual(@as(u32, 47), parseCellCount(
        \\=== design hierarchy ===
        \\   top          1
        \\Number of cells:                 47
        \\   $_AND_              12
    ));
    try std.testing.expectEqual(@as(u32, 0), parseCellCount("no cells here"));
}

test "parseArea" {
    const log =
        \\Chip area for module '\\top': 1234.560000
        \\
    ;
    const area = parseArea(log);
    try std.testing.expect(area != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1234.56), area.?, 0.01);
    try std.testing.expect(parseArea("nothing here") == null);
}

test "not synthesizable language" {
    var s = Schemify.init(std.testing.allocator);
    defer s.deinit();
    s.digital = .{ .language = .xspice };
    const result = runSynthesis(&s, std.testing.allocator, .{
        .liberty_path = "test.lib",
        .mapping = "test",
    });
    try std.testing.expectError(Error.NotSynthesizable, result);
}

test "no digital config" {
    var s = Schemify.init(std.testing.allocator);
    defer s.deinit();
    const result = runSynthesis(&s, std.testing.allocator, .{
        .liberty_path = "test.lib",
        .mapping = "test",
    });
    try std.testing.expectError(Error.NoDigitalConfig, result);
}

test "no behavioral source" {
    var s = Schemify.init(std.testing.allocator);
    defer s.deinit();
    s.digital = .{ .language = .verilog };
    const result = runSynthesis(&s, std.testing.allocator, .{
        .liberty_path = "test.lib",
        .mapping = "test",
    });
    try std.testing.expectError(Error.NoBehavioralSource, result);
}

test "xyce_digital not synthesizable" {
    var s = Schemify.init(std.testing.allocator);
    defer s.deinit();
    s.digital = .{ .language = .xyce_digital, .behavioral = .{ .source = "test", .mode = .@"inline" } };
    const result = runSynthesis(&s, std.testing.allocator, .{
        .liberty_path = "test.lib",
        .mapping = "test",
    });
    try std.testing.expectError(Error.NotSynthesizable, result);
}

test "no synthesized source for validation" {
    var s = Schemify.init(std.testing.allocator);
    defer s.deinit();
    s.digital = .{ .language = .verilog };
    const result = validateSynthesized(&s, std.testing.allocator);
    try std.testing.expectError(Error.NoSynthesizedSource, result);
}

test "no digital config for cell list" {
    var s = Schemify.init(std.testing.allocator);
    defer s.deinit();
    const result = getSynthesizedCellList(&s, std.testing.allocator);
    try std.testing.expectError(Error.NoDigitalConfig, result);
}
