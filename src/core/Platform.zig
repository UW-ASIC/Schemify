//! Platform — OS/host abstraction for HTTP, URL opening, env vars, and processes.
//!
//! Backend selection is comptime: native uses std library, WASM uses `extern "host"` imports.
//! Unused backends are never compiled (Zig lazy analysis).
//!
//! WASM host contract (schemify_host.js must implement these):
//!   host.platform_open_url(ptr, len)                         -> void
//!   host.platform_http_get_start(url_ptr, url_len, req_id)   -> void
//!   host.platform_http_get_poll(req_id, buf_ptr, buf_len)    -> i32
//!     Returns: -1 = pending, -2 = error, >=0 = bytes written
//!   host.platform_env_get(name_ptr, name_len, out_ptr, out_len) -> i32
//!     Returns: bytes written, or -1 if not found

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub const UrlError = error{
    SpawnFailed,
};

pub const HttpError = error{
    UseAsyncGetOnWasm,
    HttpRequestFailed,
    OutOfMemory,
};

pub const AsyncGetError = error{
    NativeUseHttpGetSync,
    OutOfMemory,
};

pub const EnvError = error{
    NotFound,
    OutOfMemory,
};

pub const ProcessError = error{
    ProcessesNotSupported,
    SpawnFailed,
};

pub const openUrl = if (is_wasm) wasm.openUrl else native.openUrl;
pub const httpGetSync = if (is_wasm) wasm.httpGetSync else native.httpGetSync;

// Async HTTP GET — WASM polling model (called each frame until done):
//
//   var get = try Platform.AsyncGet.start(alloc, url, req_id, 256*1024);
//   if (get.poll()) |result| {
//       if (result.len > 0) processData(result);
//       get.deinit(alloc);
//   }

pub const AsyncGet = struct {
    buf: []u8,
    req_id: i32,

    const pending: i32 = -1;
    const failed: i32 = -2;

    /// Kick off a non-blocking fetch; call `poll` each frame until it returns non-null.
    pub fn start(alloc: std.mem.Allocator, url: []const u8, req_id: i32, buf_cap: usize) AsyncGetError!AsyncGet {
        if (comptime !is_wasm) return error.NativeUseHttpGetSync;
        const buf = try alloc.alloc(u8, buf_cap);
        host.platform_http_get_start(wasmPtr(url), wasmLen(url), req_id);
        return .{ .buf = buf, .req_id = req_id };
    }

    /// Returns null while pending, empty slice on error, or data slice on success.
    pub fn poll(self: *AsyncGet) ?[]const u8 {
        if (comptime !is_wasm) return null;
        const n = host.platform_http_get_poll(self.req_id, wasmPtr(self.buf), wasmLen(self.buf));
        if (n == pending) return null;
        if (n == failed) return self.buf[0..0];
        return self.buf[0..@intCast(n)];
    }

    /// Release the response buffer after the caller has processed the data.
    pub fn deinit(self: AsyncGet, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
};

pub const getEnvVar = if (is_wasm) wasm.getEnvVar else native.getEnvVar;
pub const spawnProcess = if (is_wasm) wasm.spawnProcess else native.spawnProcess;

// WASM host imports — dead code on native builds.
const host = struct {
    extern "host" fn platform_open_url(ptr: i32, len: i32) void;
    extern "host" fn platform_http_get_start(url_ptr: i32, url_len: i32, req_id: i32) void;
    extern "host" fn platform_http_get_poll(req_id: i32, buf_ptr: i32, buf_len: i32) i32;
    extern "host" fn platform_env_get(name_ptr: i32, name_len: i32, out_ptr: i32, out_len: i32) i32;
};

/// Reinterpret a Zig pointer as an i32 address for the WASM host ABI.
inline fn wasmPtr(s: []const u8) i32 {
    return @intCast(@intFromPtr(s.ptr));
}

/// Truncate a usize length to i32 for the WASM host ABI (payloads < 2 GiB).
inline fn wasmLen(s: []const u8) i32 {
    return @intCast(s.len);
}

/// Fire-and-forget child process — stdio silenced so it doesn't block the GUI.
fn spawnDetached(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

const wasm = struct {
    fn openUrl(_: std.mem.Allocator, url: []const u8) UrlError!void {
        host.platform_open_url(wasmPtr(url), wasmLen(url));
    }

    fn httpGetSync(_: std.mem.Allocator, _: []const u8) HttpError![]u8 {
        return error.UseAsyncGetOnWasm;
    }

    fn getEnvVar(alloc: std.mem.Allocator, name: []const u8) EnvError![]u8 {
        var buf: [512]u8 = undefined;
        const n = host.platform_env_get(
            wasmPtr(name),
            wasmLen(name),
            @intCast(@intFromPtr(&buf)),
            buf.len,
        );
        if (n < 0) return error.NotFound;
        return alloc.dupe(u8, buf[0..@intCast(n)]);
    }

    fn spawnProcess(_: std.mem.Allocator, _: []const []const u8) ProcessError!void {
        return error.ProcessesNotSupported;
    }
};

const native = struct {
    fn openUrl(alloc: std.mem.Allocator, url: []const u8) UrlError!void {
        const opener = switch (builtin.os.tag) {
            .macos => "open",
            .windows => "start",
            else => "xdg-open",
        };
        spawnDetached(alloc, &.{ opener, url }) catch return error.SpawnFailed;
    }

    fn httpGetSync(alloc: std.mem.Allocator, url: []const u8) HttpError![]u8 {
        var client = std.http.Client{ .allocator = alloc };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        const res = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
        }) catch return error.HttpRequestFailed;
        if (res.status != .ok) return error.HttpRequestFailed;
        return body.toOwnedSlice() catch error.OutOfMemory;
    }

    fn getEnvVar(alloc: std.mem.Allocator, name: []const u8) EnvError![]u8 {
        return std.process.getEnvVarOwned(alloc, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotFound,
        };
    }

    fn spawnProcess(alloc: std.mem.Allocator, argv: []const []const u8) ProcessError!void {
        spawnDetached(alloc, argv) catch return error.SpawnFailed;
    }
};

test "Expose struct size for Platform" {
    const print = std.debug.print;
    print("AsyncGet: {d}B\n", .{@sizeOf(AsyncGet)});
    // buf ([]u8 = 16 B) + req_id (i32 = 4 B) + tail-padding (4 B) = 24 B.
    // Zig reorders non-extern fields for optimal layout regardless of source order.
    try std.testing.expect(@sizeOf(AsyncGet) == 24);
}
