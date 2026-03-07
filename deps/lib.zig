//! Unified SPICE simulator interface.
//!
//! Provides a common `Simulator` API that abstracts over the NGSpice and
//! Xyce backends. Use this module when your application should be agnostic
//! to the underlying simulator engine.
//!
//! ```zig
//! const spice = @import("deps/lib.zig");
//!
//! // Choose backend at init time:
//! var sim = try spice.Simulator.initNgspice(.{});
//! // or:
//! var sim = try spice.Simulator.initXyce("path/to/circuit.cir");
//!
//! try sim.loadNetlist("circuit.sp");
//! try sim.run();
//! const v = sim.getVoltage("out");
//! sim.deinit();
//! ```

const std = @import("std");

// When built via build_dep.zig, these are wired as named modules.
// When used standalone, they resolve as relative imports.
pub const ngspice = @import("ngspice");
pub const xyce = @import("xyce");

// ============================================================================
// Backend tag
// ============================================================================

pub const Backend = enum {
    ngspice,
    xyce,
};

// ============================================================================
// Simulation result — a timestamped voltage/current vector
// ============================================================================

pub const WaveformPoint = struct {
    time: f64,
    value: f64,
};

// ============================================================================
// Unified Simulator
// ============================================================================

pub const Simulator = struct {
    backend: Backend,
    ng: ?ngspice.NgSpice,
    xy: ?xyce.Xyce,

    pub const Error = error{
        BackendMismatch,
        NotLoaded,
        NoData,
    } || ngspice.NgSpice.Error || xyce.Xyce.Error;

    // ========================================================================
    // Construction
    // ========================================================================

    /// Initialize with the NGSpice backend.
    pub fn initNgspice(callbacks: ngspice.Callbacks) Error!Simulator {
        const ng = try ngspice.NgSpice.init(callbacks, 0);
        return .{
            .backend = .ngspice,
            .ng = ng,
            .xy = null,
        };
    }

    /// Initialize with the NGSpice backend using default stderr logging.
    pub fn initNgspiceDefault() Error!Simulator {
        return initNgspice(ngspice.stderr_callbacks);
    }

    /// Initialize with the Xyce backend.
    pub fn initXyce() Error!Simulator {
        const xy = try xyce.Xyce.init();
        return .{
            .backend = .xyce,
            .ng = null,
            .xy = xy,
        };
    }

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Load a netlist / circuit file.
    pub fn loadNetlist(self: *Simulator, path: []const u8) Error!void {
        switch (self.backend) {
            .ngspice => {
                // ngspice wants a null-terminated string for its command
                var buf: [4096]u8 = undefined;
                const cmd = std.fmt.bufPrintZ(&buf, "source {s}", .{path}) catch
                    return error.CommandFailed;
                try self.ng.?.command(cmd);
            },
            .xyce => {
                try self.xy.?.initializeFromNetlist(path);
            },
        }
    }

    /// Clean up and release all resources.
    pub fn deinit(self: *Simulator) void {
        switch (self.backend) {
            .ngspice => {
                if (self.ng) |*ng| ng.deinit();
                self.ng = null;
            },
            .xyce => {
                if (self.xy) |*xy| xy.deinit();
                self.xy = null;
            },
        }
    }

    // ========================================================================
    // Simulation execution
    // ========================================================================

    /// Run the simulation to completion.
    ///
    /// For NGSpice this starts a foreground `run` command.
    /// For Xyce this calls `runSimulation()`.
    pub fn run(self: *Simulator) Error!void {
        switch (self.backend) {
            .ngspice => try self.ng.?.command("run"),
            .xyce => try self.xy.?.runSimulation(),
        }
    }

    /// Run the simulation in the background (NGSpice only).
    /// For Xyce, this is equivalent to `run()`.
    pub fn runBackground(self: *Simulator) Error!void {
        switch (self.backend) {
            .ngspice => try self.ng.?.run(),
            .xyce => try self.xy.?.runSimulation(),
        }
    }

    /// Step the simulation to `requested_time` (Xyce co-simulation mode).
    /// Returns the time actually achieved.
    ///
    /// For NGSpice this is not natively supported in the same way — it
    /// returns an error. Use the callback-based approach with NGSpice
    /// for fine-grained time control, or access the `.ng` handle directly.
    pub fn simulateUntil(self: *Simulator, requested_time: f64) Error!f64 {
        switch (self.backend) {
            .ngspice => return error.BackendMismatch,
            .xyce => return self.xy.?.simulateUntil(requested_time),
        }
    }

    /// Check if a background simulation is still running.
    pub fn isRunning(self: *Simulator) bool {
        switch (self.backend) {
            .ngspice => return if (self.ng) |*ng| ng.isRunning() else false,
            .xyce => return false, // Xyce runs synchronously
        }
    }

    // ========================================================================
    // Data access
    // ========================================================================

    /// Get voltage data for a node from the last completed simulation.
    ///
    /// NGSpice: reads from the current plot using `ngGet_Vec_Info`.
    /// Xyce:    reads from the device solution vector.
    ///
    /// Returns a slice of f64 values. For NGSpice the slice points into
    /// ngspice-owned memory (valid until next simulation). For Xyce the
    /// data is written into the provided buffer.
    pub fn getVoltageNg(self: *Simulator, node: [*:0]const u8) Error![]const f64 {
        switch (self.backend) {
            .ngspice => {
                return self.ng.?.getVoltage(node) orelse return error.NoData;
            },
            .xyce => return error.BackendMismatch,
        }
    }

    /// Get Xyce solution data into a caller-provided buffer.
    pub fn getSolutionXyce(self: *Simulator, device: [*:0]const u8, buf: []f64) Error![]f64 {
        switch (self.backend) {
            .xyce => return self.xy.?.getSolution(device, buf),
            .ngspice => return error.BackendMismatch,
        }
    }

    // ========================================================================
    // Send arbitrary command (NGSpice) or access raw handles
    // ========================================================================

    /// Send a raw command string (NGSpice only).
    pub fn command(self: *Simulator, cmd: [*:0]const u8) Error!void {
        switch (self.backend) {
            .ngspice => try self.ng.?.command(cmd),
            .xyce => return error.BackendMismatch,
        }
    }

    /// Get the underlying NGSpice handle for direct access.
    pub fn getNgspice(self: *Simulator) ?*ngspice.NgSpice {
        return if (self.ng) |*ng| ng else null;
    }

    /// Get the underlying Xyce handle for direct access.
    pub fn getXyce(self: *Simulator) ?*xyce.Xyce {
        return if (self.xy) |*xy| xy else null;
    }

    // ========================================================================
    // Info
    // ========================================================================

    /// Return a human-readable backend name.
    pub fn backendName(self: *const Simulator) []const u8 {
        return switch (self.backend) {
            .ngspice => "ngspice",
            .xyce => "Xyce",
        };
    }
};
