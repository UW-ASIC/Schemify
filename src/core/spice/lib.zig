//! Simulator handle — thin wrapper around the native sim backends (ngspice / Xyce).
//!
//! On platforms where the native simulators are not linked in, all methods
//! return `error.SimulatorNotAvailable` so the rest of the codebase can
//! compile and the `bridge` module can be type-checked without linking deps.

const std = @import("std");
const universal = @import("universal.zig");

pub const Backend = universal.Backend;

// ── Error set ──────────────────────────────────────────────────────────────── //

pub const SimulatorError = error{
    SimulatorNotAvailable,
    LoadNetlistFailed,
    RunFailed,
};

// ── Simulator ──────────────────────────────────────────────────────────────── //

/// Wraps a running native simulator process.
/// Constructed via `initNgspice` or `initXyce`; released with `deinit`.
pub const Simulator = struct {
    backend: Backend,

    pub const Error = SimulatorError;

    pub const InitOptions = struct {};

    /// Initialise an ngspice-backed simulator.
    pub fn initNgspice(_: InitOptions) Error!Simulator {
        return error.SimulatorNotAvailable;
    }

    /// Initialise a Xyce-backed simulator.
    pub fn initXyce(_: InitOptions) Error!Simulator {
        return error.SimulatorNotAvailable;
    }

    pub fn deinit(_: *Simulator) void {}

    /// Load a SPICE netlist from disk.
    pub fn loadNetlist(_: *Simulator, _: []const u8) Error!void {
        return error.SimulatorNotAvailable;
    }

    /// Execute the loaded simulation.
    pub fn run(_: *Simulator) Error!void {
        return error.SimulatorNotAvailable;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────── //

test "Expose struct size for Simulator" {
    const print = std.debug.print;
    print("Simulator: {d}B\n", .{@sizeOf(Simulator)});
}

test "initNgspice returns error when not available" {
    const result = Simulator.initNgspice(.{});
    try std.testing.expectError(error.SimulatorNotAvailable, result);
}
