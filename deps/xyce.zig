//! Zig bindings for the Xyce circuit simulator via the C shim API.
//!
//! Xyce is driven as an embedded library through `GenCouplingSimulator`.
//! Since Xyce is C++, we go through a thin C wrapper (`xyce_c_api.h`)
//! that lives in `deps/Xyce/`.
//!
//! ## Build from source
//!
//! ```sh
//! # See tools/build_dep.zig or the top-level build instructions.
//! # Short version:
//! #   1. Build Trilinos with -fPIC → deps/Xyce/XyceLibs/Serial/
//! #   2. Build Xyce with --enable-shared → deps/Xyce/install/
//! ```

const std = @import("std");

// ============================================================================
// Raw C bindings (from xyce_c_api.h)
// ============================================================================

pub const c = @cImport({
    @cInclude("xyce_c_api.h");
});

// ============================================================================
// Xyce handle
// ============================================================================

pub const Xyce = struct {
    handle: c.XyceHandle,

    pub const Error = error{
        CreateFailed,
        InitEarlyFailed,
        InitLateFailed,
        SimulationFailed,
        SimulateUntilFailed,
        DeviceQueryFailed,
        ParamAccessFailed,
        SolutionReadFailed,
        NullHandle,
    };

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Create a new Xyce simulator instance.
    pub fn init() Error!Xyce {
        const h = c.xyce_create();
        if (h == null) return Error.CreateFailed;
        return .{ .handle = h };
    }

    /// Destroy the simulator and free all resources.
    pub fn deinit(self: *Xyce) void {
        if (self.handle != null) {
            c.xyce_finalize(self.handle);
            c.xyce_destroy(self.handle);
            self.handle = null;
        }
    }

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Phase 1: parse a netlist and set up the circuit topology.
    /// Call this before registering any external devices.
    pub fn initializeEarly(self: *Xyce, netlist_path: []const u8) Error!void {
        // Build an argv: ["xyce", "<netlist_path>"]
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..netlist_path.len], netlist_path);
        path_buf[netlist_path.len] = 0;

        const prog_name: [*:0]const u8 = "xyce";
        const path_z: [*:0]const u8 = @ptrCast(path_buf[0..netlist_path.len :0]);
        const argv = [_][*:0]const u8{ prog_name, path_z };
        const argv_ptr: [*]const [*:0]const u8 = &argv;

        const ret = c.xyce_initialize_early(self.handle, 2, @ptrCast(argv_ptr));
        if (ret != 0) return Error.InitEarlyFailed;
    }

    /// Phase 2: finalize setup. Call after registering external devices /
    /// vector loaders and before running any simulation.
    pub fn initializeLate(self: *Xyce) Error!void {
        const ret = c.xyce_initialize_late(self.handle);
        if (ret != 0) return Error.InitLateFailed;
    }

    /// Convenience: initialize both phases in one call.
    pub fn initializeFromNetlist(self: *Xyce, netlist_path: []const u8) Error!void {
        try self.initializeEarly(netlist_path);
        try self.initializeLate();
    }

    // ========================================================================
    // Simulation execution
    // ========================================================================

    /// Run the full simulation to completion (non-interactive).
    pub fn runSimulation(self: *Xyce) Error!void {
        const ret = c.xyce_run_simulation(self.handle);
        if (ret != 0) return Error.SimulationFailed;
    }

    /// Advance the simulation to `requested_time` (seconds).
    /// Returns the time actually achieved (may differ due to adaptive stepping).
    ///
    /// Use in a co-simulation loop:
    /// ```zig
    /// var t: f64 = 0;
    /// while (t < t_end) : (t += dt) {
    ///     const achieved = try xyce.simulateUntil(t);
    ///     // exchange boundary data with digital simulator
    /// }
    /// ```
    pub fn simulateUntil(self: *Xyce, requested_time: f64) Error!f64 {
        var achieved: f64 = 0;
        const ret = c.xyce_simulate_until(self.handle, requested_time, &achieved);
        if (ret != 0) return Error.SimulateUntilFailed;
        return achieved;
    }

    // ========================================================================
    // Device queries
    // ========================================================================

    /// Get the names of all devices of a given type (e.g. "YGENEXT") in the
    /// loaded netlist. Returns a slice of C string pointers valid for the
    /// lifetime of the handle (or until the next call to this function).
    pub fn getDeviceNames(self: *Xyce, device_type: [*:0]const u8) Error![]const [*:0]const u8 {
        var name_buf: [64]?[*:0]const u8 = undefined;
        const count = c.xyce_get_device_names(
            self.handle,
            device_type,
            @ptrCast(&name_buf),
            64,
        );
        if (count < 0) return Error.DeviceQueryFailed;
        const n: usize = @intCast(count);
        // Safe cast: we know these are non-null since count > 0.
        const result: [*]const [*:0]const u8 = @ptrCast(name_buf[0..n].ptr);
        return result[0..n];
    }

    // ========================================================================
    // Parameter access
    // ========================================================================

    /// Get a double-valued parameter from a device instance.
    pub fn getParam(self: *Xyce, device: [*:0]const u8, param: [*:0]const u8) Error!f64 {
        var value: f64 = 0;
        const ret = c.xyce_get_device_param_double(self.handle, device, param, &value);
        if (ret != 0) return Error.ParamAccessFailed;
        return value;
    }

    /// Set a double-valued parameter on a device instance.
    pub fn setParam(self: *Xyce, device: [*:0]const u8, param: [*:0]const u8, value: f64) Error!void {
        const ret = c.xyce_set_device_param_double(self.handle, device, param, value);
        if (ret != 0) return Error.ParamAccessFailed;
    }

    // ========================================================================
    // Solution access
    // ========================================================================

    /// Read the solution vector (node voltages / branch currents) for a device.
    /// Writes into `buf` and returns the slice of values actually written.
    pub fn getSolution(self: *Xyce, device: [*:0]const u8, buf: []f64) Error![]f64 {
        const count = c.xyce_get_solution(
            self.handle,
            device,
            buf.ptr,
            @intCast(buf.len),
        );
        if (count < 0) return Error.SolutionReadFailed;
        return buf[0..@intCast(count)];
    }

    /// Get the total number of solution variables for a device.
    pub fn getNumVars(self: *Xyce, device: [*:0]const u8) Error!usize {
        const n = c.xyce_get_num_vars(self.handle, device);
        if (n < 0) return Error.DeviceQueryFailed;
        return @intCast(n);
    }

    /// Get the number of external (circuit-node) variables for a device.
    pub fn getNumExtVars(self: *Xyce, device: [*:0]const u8) Error!usize {
        const n = c.xyce_get_num_ext_vars(self.handle, device);
        if (n < 0) return Error.DeviceQueryFailed;
        return @intCast(n);
    }

    // ========================================================================
    // External device coupling (YGENEXT)
    // ========================================================================

    /// Set the number of internal variables for a general external device.
    /// Must be called between initializeEarly and initializeLate.
    pub fn setNumInternalVars(self: *Xyce, device: [*:0]const u8, count: usize) Error!void {
        const ret = c.xyce_set_num_internal_vars(self.handle, device, @intCast(count));
        if (ret != 0) return Error.DeviceQueryFailed;
    }

    /// Set the Jacobian stamp (sparsity pattern) for a general external device.
    /// `stamp` is a row-major matrix of dimensions `rows × cols`.
    /// Must be called between initializeEarly and initializeLate.
    pub fn setJacStamp(self: *Xyce, device: [*:0]const u8, stamp: []const i32, rows: usize, cols: usize) Error!void {
        const ret = c.xyce_set_jac_stamp(
            self.handle,
            device,
            stamp.ptr,
            @intCast(rows),
            @intCast(cols),
        );
        if (ret != 0) return Error.DeviceQueryFailed;
    }

    // ========================================================================
    // Utility
    // ========================================================================

    /// Get the Xyce version string.
    pub fn version() [*:0]const u8 {
        return c.xyce_version();
    }
};
