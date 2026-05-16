// lib.zig — Import module entry point.
//
// Single pure function `importProject()` dispatches to format-specific backends:
//   - XSchem: reads .sch/.sym files with own geometry
//   - Virtuoso: parses CDL/Spectre netlists from Cadence projects
//   - SPICE: parses raw SPICE netlists, generates layout + routing
//   - PySpice: runs Python scripts, captures SPICE output, generates layout

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const XSchem = @import("XSchem/mod.zig");
pub const Virtuoso = @import("Virtuoso/mod.zig");
pub const spice = @import("spice/mod.zig");
pub const PySpice = @import("PySpice/mod.zig");
pub const VerilogA = @import("VerilogA.zig");
pub const Router = @import("Router.zig");
pub const LabelPlacer = @import("LabelPlacer.zig");
pub const PdkMap = @import("PdkMap.zig");
pub const conventions = @import("conventions.zig");

const ct = @import("types.zig");
pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;

// ── Import source ───────────────────────────────────────────────────────────

pub const ImportSource = union(enum) {
    xschem: struct { project_dir: []const u8 },
    virtuoso: struct { project_dir: []const u8 },
    spice: struct { project_dir: []const u8 },
    pyspice: struct { project_dir: []const u8 },
    spice_text: struct { source: []const u8, name: []const u8 },
    pyspice_text: struct { source: []const u8, name: []const u8 },
    pyspice_file: struct { path: []const u8 },
    verilog_a_text: struct { source: []const u8, name: []const u8 },
};

// ── Single entry point ──────────────────────────────────────────────────────

pub fn importProject(alloc: Allocator, source: ImportSource) !ConvertResultList {
    return switch (source) {
        .xschem => |s| importXSchem(alloc, s.project_dir),
        .virtuoso => |s| importVirtuoso(alloc, s.project_dir),
        .spice => |s| importSpiceDir(alloc, s.project_dir),
        .pyspice => |s| PySpice.importPySpiceProject(alloc, s.project_dir),
        .spice_text => |s| importSpiceText(alloc, s.source, s.name),
        .pyspice_text => |s| PySpice.importPySpiceText(alloc, s.source, s.name),
        .pyspice_file => |s| PySpice.importPySpiceFile(alloc, s.path),
        .verilog_a_text => |s| importVerilogAText(alloc, s.source, s.name),
    };
}

// ── Backend dispatchers ─────────────────────────────────────────────────────

fn importXSchem(alloc: Allocator, project_dir: []const u8) !ConvertResultList {
    var backend = XSchem.Backend.init(alloc);
    defer backend.deinit();
    return backend.convertProject(project_dir);
}

fn importVirtuoso(alloc: Allocator, project_dir: []const u8) !ConvertResultList {
    var backend = Virtuoso.Backend.init(alloc);
    defer backend.deinit();
    return backend.convertProject(project_dir);
}

fn importSpiceDir(alloc: Allocator, project_dir: []const u8) !ConvertResultList {
    var backend = spice.Backend.init(alloc);
    defer backend.deinit();
    return backend.convertProject(project_dir);
}

fn importSpiceText(alloc: Allocator, source: []const u8, name: []const u8) !ConvertResultList {
    var list_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer list_arena.deinit();
    const la = list_arena.allocator();

    const results = try spice.importSpice(la, source, name);

    return .{
        // SAFETY: results allocated from list_arena which we own; deinit needs mutability
        .results = @constCast(results),
        .arena = list_arena,
    };
}

fn importVerilogAText(alloc: Allocator, source: []const u8, name: []const u8) !ConvertResultList {
    const core = @import("schematic");
    var list_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer list_arena.deinit();
    const la = list_arena.allocator();

    const va_mod = (try VerilogA.parseVerilogA(la, source)) orelse return error.InvalidVerilogA;

    var sfy = core.Schemify{};
    try sfy.setName(la, va_mod.name);
    sfy.stype = .symbol;

    for (va_mod.ports, 0..) |port, idx| {
        const dir: core.types.PinDir = switch (port.direction) {
            .input => .input,
            .output => .output,
            .inout => .inout,
        };
        try sfy.drawPinStr(la, port.name, 0, @as(i32, @intCast(idx)) * 40, dir);
    }

    try sfy.addSymProp(la, "type", "verilog_a");
    try sfy.addSymProp(la, "va_source", source);

    for (va_mod.params) |param| {
        try sfy.addSymProp(la, param.name, param.default_value orelse "");
    }

    _ = name;

    var results = std.ArrayListUnmanaged(ConvertResult){};
    try results.append(la, .{
        .name = try la.dupe(u8, va_mod.name),
        .sch_path = null,
        .sym_path = null,
        .schemify = sfy,
    });

    return .{
        .results = results.items,
        .arena = list_arena,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "importProject — spice_text produces results" {
    const source =
        \\* Test
        \\.subckt inv in out vdd vss
        \\M1 out in vdd vdd sky130_fd_pr__pfet_01v8 W=1u L=0.18u
        \\M2 out in vss vss sky130_fd_pr__nfet_01v8 W=0.5u L=0.18u
        \\.ends inv
        \\.end
    ;

    var result = try importProject(std.testing.allocator, .{
        .spice_text = .{ .source = source, .name = "test.sp" },
    });
    defer result.deinit();

    try std.testing.expect(result.results.len >= 1);
    try std.testing.expectEqualStrings("inv", result.results[0].name);
}

test "ImportSource — tagged union covers all backends" {
    // Compile-time verification that all variants exist
    const sources = [_]ImportSource{
        .{ .xschem = .{ .project_dir = "/tmp" } },
        .{ .virtuoso = .{ .project_dir = "/tmp" } },
        .{ .spice = .{ .project_dir = "/tmp" } },
        .{ .pyspice = .{ .project_dir = "/tmp" } },
        .{ .spice_text = .{ .source = "", .name = "test" } },
        .{ .pyspice_text = .{ .source = "", .name = "test" } },
        .{ .pyspice_file = .{ .path = "/tmp/test.py" } },
        .{ .verilog_a_text = .{ .source = "", .name = "test" } },
    };
    try std.testing.expectEqual(@as(usize, 8), sources.len);
}

// Force-reference sub-modules for test discovery
comptime {
    _ = spice;
    _ = PySpice;
    _ = VerilogA;
    _ = Router;
    _ = LabelPlacer;
    _ = PdkMap;
    _ = conventions;
}
