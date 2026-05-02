//! Backend dispatch — static router for ngspice / xyce / vacask.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SpiceIF = @import("../SpiceIF.zig");
const Backend = SpiceIF.Backend;
const ngspice_mod = @import("ngspice.zig");
const xyce_mod = @import("xyce.zig");
const vacask_mod = @import("vacask.zig");

pub const SimResult = struct {
    success: bool,
    stdout: []u8,
    stderr: []u8,
    rc: u32,
};

pub const BackendHandle = struct {
    kind: Backend,

    pub fn init(kind: Backend) BackendHandle {
        return .{ .kind = kind };
    }

    pub fn emitAnalysis(self: BackendHandle, writer: anytype, an: SpiceIF.Analysis) !void {
        return switch (self.kind) {
            .ngspice => ngspice_mod.emitAnalysis(writer, an),
            .xyce => xyce_mod.emitAnalysis(writer, an),
            .vacask => vacask_mod.emitAnalysis(writer, an),
        };
    }

    pub fn emitSweep(self: BackendHandle, writer: anytype, sw: SpiceIF.Sweep) !void {
        return switch (self.kind) {
            .ngspice => ngspice_mod.emitSweep(writer, sw),
            .xyce => xyce_mod.emitSweep(writer, sw),
            .vacask => vacask_mod.emitSweep(writer, sw),
        };
    }

    pub fn emitMeasure(_: BackendHandle, writer: anytype, meas: SpiceIF.Measure) !void {
        return SpiceIF.emitMeasureShared(writer, meas);
    }

    pub fn emitPrint(_: BackendHandle, writer: anytype, p: SpiceIF.PrintDirective) !void {
        return SpiceIF.emitPrintShared(writer, p);
    }

    pub fn emitNetlistComponent(self: BackendHandle, writer: anytype, comp: SpiceIF.ComponentType) !void {
        return switch (self.kind) {
            .ngspice => ngspice_mod.emitNetlistComponent(writer, comp),
            .xyce => xyce_mod.emitNetlistComponent(writer, comp),
            .vacask => vacask_mod.emitNetlistComponent(writer, comp),
        };
    }

    pub fn emitNgspiceControlSection(_: BackendHandle, writer: anytype, nl: *const SpiceIF.Netlist) !void {
        return ngspice_mod.emitControlSection(writer, nl);
    }

    pub fn run(self: BackendHandle, alloc: Allocator, netlist_path: []const u8) !SimResult {
        const bin: []const u8 = switch (self.kind) { .ngspice => "ngspice", .xyce => "xyce", .vacask => "vacask" };
        return runProcess(alloc, &.{ bin, netlist_path });
    }

    fn runProcess(alloc: Allocator, argv: []const []const u8) !SimResult {
        var child = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .ignore;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .pipe;
        try child.spawn();
        const stdout = try child.stdout.?.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        const stderr = try child.stderr.?.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        const term = try child.wait();
        const rc: u32 = switch (term) { .exited => |code| code, else => 255 };
        return .{ .success = rc == 0, .stdout = stdout, .stderr = stderr, .rc = rc };
    }
};

test "backend init" {
    const be = BackendHandle.init(.vacask);
    try std.testing.expect(be.kind == .vacask);
}
