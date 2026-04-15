//! Backend dispatch table — static router for ngspice / xyce / vacask.
//!
//! Usage:
//!   const be = BackendHandle.initBackend(.vacask);
//!   const path = try be.netlist(allocator, content);
//!   const result = try be.run(allocator, path);

const std = @import("std");
const Allocator = std.mem.Allocator;
const Vfs = @import("utility").Vfs;
const Platform = @import("utility").Platform;
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

    pub fn initBackend(kind: Backend) BackendHandle {
        return .{ .kind = kind };
    }

    /// Write netlist content to a temp file and return the path.
    pub fn netlist(_: BackendHandle, _: Allocator, content: []const u8) ![]const u8 {
        const path = "/tmp/_schemify_spice_netlist.cir";
        try Vfs.writeAll(path, content);
        return path;
    }

    /// Run the simulator on a previously written netlist file.
    pub fn run(self: BackendHandle, alloc: Allocator, netlist_path: []const u8) !SimResult {
        return switch (self.kind) {
            .ngspice => runSimulator(alloc, "ngspice", netlist_path),
            .xyce => runSimulator(alloc, "xyce", netlist_path),
            .vacask => runSimulator(alloc, "vacask", netlist_path),
        };
    }

    // ── Emit dispatch ────────────────────────────────────────────────────── //

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

    pub fn emitIndependentSource(_: BackendHandle, writer: anytype, src: SpiceIF.IndependentSource) !void {
        return SpiceIF.emitIndependentSource(writer, src);
    }

    pub fn emitNgspiceControlSection(_: BackendHandle, writer: anytype, nl: *const SpiceIF.Netlist) !void {
        return ngspice_mod.emitControlSection(writer, nl);
    }
};

fn runSimulator(alloc: Allocator, binary_name: []const u8, netlist_path: []const u8) !SimResult {
    const path = Platform.findBinary(binary_name) orelse {
        return SimResult{
            .success = false,
            .stdout = &.{},
            .stderr = @constCast(@as([]const u8, binary_name ++ " not found")),
            .rc = 127,
        };
    };
    return runProcess(alloc, &.{ path, netlist_path });
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

    const rc: u32 = switch (term) {
        .exited => |code| code,
        else => 255,
    };

    return SimResult{
        .success = rc == 0,
        .stdout = stdout,
        .stderr = stderr,
        .rc = rc,
    };
}

test "backend init" {
    const be = BackendHandle.initBackend(.vacask);
    try std.testing.expect(be.kind == .vacask);
}

test "backend init ngspice" {
    const be = BackendHandle.initBackend(.ngspice);
    try std.testing.expect(be.kind == .ngspice);
}
