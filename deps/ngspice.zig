//! Zig bindings for the NGSpice shared library API (`sharedspice.h`).
//!
//! NGSpice exposes a callback-driven C API via `libngspice.so`.
//! This module provides a safe, idiomatic Zig wrapper.
//!
//! ## Build from source
//!
//! ```sh
//! git clone https://github.com/ngspice/ngspice.git deps/ngspice
//! cd deps/ngspice
//! ./autogen.sh
//! ./configure --with-ngshared --enable-xspice --enable-cider
//! make -j$(nproc)
//! ```

const std = @import("std");

// ============================================================================
// Raw C bindings (from sharedspice.h)
// ============================================================================

pub const c = @cImport({
    @cInclude("sharedspice.h");
});

/// Aliases for the key C types.
pub const VecValuesAll = c.pvecvaluesall;
pub const VecInfo = c.pvecinfo;

// ============================================================================
// Callback types
// ============================================================================

/// User-provided function signatures for ngspice callbacks.
pub const Callbacks = struct {
    /// Called when ngspice wants to print a line of text (stdout).
    send_char: ?*const fn (msg: [*:0]const u8, id: c_int, user: ?*anyopaque) callconv(.C) c_int = null,

    /// Called when ngspice reports simulation status / progress.
    send_stat: ?*const fn (msg: [*:0]const u8, id: c_int, user: ?*anyopaque) callconv(.C) c_int = null,

    /// Called when ngspice exits or encounters a fatal error.
    controlled_exit: ?*const fn (status: c_int, unload: bool, quit: bool, id: c_int, user: ?*anyopaque) callconv(.C) c_int = null,

    /// Called when simulation data is ready (per timestep).
    send_data: ?*const fn (data: ?*c.vecvaluesall, count: c_int, id: c_int, user: ?*anyopaque) callconv(.C) c_int = null,

    /// Called once at init with the vector info for the current simulation.
    send_init_data: ?*const fn (data: ?*c.vecinfoall, id: c_int, user: ?*anyopaque) callconv(.C) c_int = null,

    /// Called to report whether the background thread is running.
    bg_thread_running: ?*const fn (is_running: bool, id: c_int, user: ?*anyopaque) callconv(.C) c_int = null,

    /// Opaque user data pointer passed to all callbacks.
    user_data: ?*anyopaque = null,
};

// ============================================================================
// NGSpice handle
// ============================================================================

pub const NgSpice = struct {
    callbacks: Callbacks,
    id: c_int,

    pub const Error = error{
        InitFailed,
        CommandFailed,
        NotInitialized,
    };

    /// Initialize the ngspice shared library with the given callbacks.
    /// `id` is an instance identifier (use 0 for single-instance).
    pub fn init(callbacks: Callbacks, id: c_int) Error!NgSpice {
        const ret = c.ngSpice_Init(
            callbacks.send_char,
            callbacks.send_stat,
            callbacks.controlled_exit,
            callbacks.send_data,
            callbacks.send_init_data,
            callbacks.bg_thread_running,
            callbacks.user_data,
        );
        if (ret != 0) return Error.InitFailed;

        return .{
            .callbacks = callbacks,
            .id = id,
        };
    }

    /// Send a command string to ngspice (e.g. "source circuit.sp", "run", "quit").
    pub fn command(self: *NgSpice, cmd: [*:0]const u8) Error!void {
        _ = self;
        const ret = c.ngSpice_Command(cmd);
        if (ret != 0) return Error.CommandFailed;
    }

    /// Load a netlist/circuit file.
    pub fn source(self: *NgSpice, path: [*:0]const u8) Error!void {
        var buf: [4096]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&buf, "source {s}", .{path}) catch return Error.CommandFailed;
        return self.command(cmd);
    }

    /// Start a transient simulation in the background.
    pub fn run(self: *NgSpice) Error!void {
        return self.command("bg_run");
    }

    /// Halt a running background simulation.
    pub fn halt(self: *NgSpice) Error!void {
        return self.command("bg_halt");
    }

    /// Resume a halted background simulation.
    pub fn @"resume"(self: *NgSpice) Error!void {
        return self.command("bg_resume");
    }

    /// Check if a background simulation is currently running.
    pub fn isRunning(self: *NgSpice) bool {
        _ = self;
        return c.ngSpice_running() != 0;
    }

    /// Get the name of the current plot (e.g. "tran1").
    pub fn currentPlot(self: *NgSpice) ?[*:0]const u8 {
        _ = self;
        return c.ngSpice_CurPlot();
    }

    /// Get all vector names in the current plot.
    /// Returns a null-terminated array of C strings.
    pub fn allVectors(self: *NgSpice) ?[*]const [*:0]const u8 {
        _ = self;
        const plot = c.ngSpice_CurPlot() orelse return null;
        const vecs = c.ngSpice_AllVecs(plot);
        if (vecs == null) return null;
        return @ptrCast(vecs);
    }

    /// Get info for a specific vector by name (e.g. "v(out)").
    /// Caller does NOT own the returned pointer — it is valid until the
    /// next simulation or command.
    pub fn vectorInfo(self: *NgSpice, vec_name: [*:0]const u8) ?*c.vector_info {
        _ = self;
        return c.ngGet_Vec_Info(vec_name);
    }

    /// Get a voltage value from the last simulation.
    /// `node` should be the node name (e.g. "out", "in").
    /// Returns the real-valued data array and its length.
    pub fn getVoltage(self: *NgSpice, node: [*:0]const u8) ?[]const f64 {
        var buf: [256]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "v({s})", .{node}) catch return null;
        const info = self.vectorInfo(name) orelse return null;
        if (info.v_realdata == null) return null;
        const len: usize = @intCast(info.v_length);
        return info.v_realdata[0..len];
    }

    /// Shut down ngspice.
    pub fn deinit(self: *NgSpice) void {
        self.command("quit") catch {};
    }
};

// ============================================================================
// Convenience: simple log-to-stderr callbacks
// ============================================================================

/// A set of default callbacks that print ngspice output to stderr.
/// Useful for quick testing.
pub const stderr_callbacks = Callbacks{
    .send_char = &defaultSendChar,
    .send_stat = &defaultSendStat,
    .controlled_exit = null,
    .send_data = null,
    .send_init_data = null,
    .bg_thread_running = null,
    .user_data = null,
};

fn defaultSendChar(msg: [*:0]const u8, _: c_int, _: ?*anyopaque) callconv(.C) c_int {
    std.debug.print("[ngspice] {s}\n", .{msg});
    return 0;
}

fn defaultSendStat(msg: [*:0]const u8, _: c_int, _: ?*anyopaque) callconv(.C) c_int {
    std.debug.print("[ngspice/stat] {s}\n", .{msg});
    return 0;
}
