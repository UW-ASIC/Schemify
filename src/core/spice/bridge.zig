//! Bridge between the Universal SPICE IR and backend Simulator handles.
//!
//! Extends a `lib.Simulator` with a typed `runNetlist` entry point that
//! accepts a `Netlist` instead of a raw SPICE string.
//!
//! ```zig
//! var sim = try spice.Simulator.initNgspice(.{});
//! defer sim.deinit();
//!
//! var nl = Netlist.init(allocator);
//! defer nl.deinit();
//! try nl.addComponent(.{ .resistor = .{ ... } });
//! try nl.addAnalysis(.{ .tran = .{ .step = 1e-6, .stop = 1e-3 } });
//!
//! const result = try Bridge.run(&sim, &nl, allocator);
//! defer result.deinit(allocator);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const lib = @import("lib.zig");
const universal = @import("universal.zig");
const Netlist = universal.Netlist;

pub const RunError = Netlist.EmitError || lib.Simulator.Error;

/// Owns the diagnostic list and emitted netlist text; caller must call deinit.
pub const RunResult = struct {
    diagnostics: std.ArrayListUnmanaged(Netlist.Diagnostic),
    /// Emitted netlist text; free with the same allocator passed to Bridge.run.
    netlist_text: []u8,

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        self.diagnostics.deinit(allocator);
        allocator.free(self.netlist_text);
    }
};

/// Validate → emit → write temp file → load into simulator → run.
///
/// Returns diagnostics (warnings for emulated features) and the emitted text.
/// Returns error.UnsupportedFeature on hard validation errors.
pub fn run(
    sim: *lib.Simulator,
    nl: *const Netlist,
    allocator: Allocator,
) RunError!RunResult {
    const diags = try nl.validate(sim.backend);

    for (diags.items) |d| {
        if (d.level == .err) return error.UnsupportedFeature;
    }

    const text = try nl.emit(sim.backend, allocator);
    errdefer allocator.free(text);

    const tmp_path = "/tmp/_universal_spice_netlist.cir";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(text);
    }

    try sim.loadNetlist(tmp_path);
    try sim.run();

    return .{ .diagnostics = diags, .netlist_text = text };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Expose struct size for bridge" {
    std.debug.print("RunResult: {d}B\n", .{@sizeOf(RunResult)});
}

test "example RC filter emits for both backends" {
    const allocator = std.testing.allocator;

    // Build an RC low-pass filter netlist inline.
    var nl = Netlist.init(allocator);
    defer nl.deinit();
    nl.title = "RC Low-Pass Filter — Universal SPICE";

    try nl.addParam(.{ .name = "Rval", .value = .{ .literal = 1e3 } });
    try nl.addParam(.{ .name = "Cval", .value = .{ .literal = 1e-9 } });

    try nl.addComponent(.{ .resistor = .{ .name = "R1", .p = "in", .n = "out", .value = .{ .param = "Rval" } } });
    try nl.addComponent(.{ .capacitor = .{ .name = "C1", .p = "out", .n = "0", .value = .{ .param = "Cval" } } });

    try nl.addSource(.{
        .name = "V1",
        .kind = .voltage,
        .p = "in",
        .n = "0",
        .dc = 0,
        .ac_mag = 1.0,
        .waveform = .{ .pulse = .{
            .v1 = 0, .v2 = 1, .delay = 0,
            .rise = 1e-9, .fall = 1e-9,
            .width = 50e-6, .period = 100e-6,
        } },
    });

    try nl.addAnalysis(.{ .tran = .{ .step = 10e-9, .stop = 200e-6 } });
    try nl.addAnalysis(.{ .ac = .{ .sweep = .dec, .n_points = 100, .f_start = 1e3, .f_stop = 1e9 } });

    try nl.addSweep(.{ .step = .{
        .param = "Rval",
        .kind = .{ .list = .{ .values = &[_]f64{ 100, 1e3, 10e3 } } },
    } });

    try nl.addMeasure(.{
        .name = "t_rise",
        .mode = .tran,
        .kind = .{ .trig_targ = .{
            .trig_var = "V(out)", .trig_val = 0.1,
            .targ_var = "V(out)", .targ_val = 0.9,
            .rise = 1,
        } },
    });

    try nl.addPrint(.{ .mode = .tran, .vars = &[_][]const u8{ "V(in)", "V(out)" } });

    // ngspice emission
    const ng_text = try nl.emit(.ngspice, allocator);
    defer allocator.free(ng_text);
    try std.testing.expect(std.mem.indexOf(u8, ng_text, ".tran") != null);
    try std.testing.expect(std.mem.indexOf(u8, ng_text, ".control") != null);
    try std.testing.expect(std.mem.indexOf(u8, ng_text, "foreach") != null);

    // Xyce emission
    const xy_text = try nl.emit(.xyce, allocator);
    defer allocator.free(xy_text);
    try std.testing.expect(std.mem.indexOf(u8, xy_text, ".tran") != null);
    try std.testing.expect(std.mem.indexOf(u8, xy_text, ".STEP") != null);
    try std.testing.expect(std.mem.indexOf(u8, xy_text, "foreach") == null);
}
