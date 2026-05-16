const std = @import("std");
const Allocator = std.mem.Allocator;

// JS host imports (namespace "host" in schemify_host.js).
// Each plugin runs as a Web Worker; the JS side manages worker
// lifecycle and queues incoming JSON-RPC messages.

extern "host" fn plugin_spawn(url_ptr: [*]const u8, url_len: u32) i32;
extern "host" fn plugin_send(id: i32, data_ptr: [*]const u8, data_len: u32) void;
extern "host" fn plugin_recv(id: i32, buf_ptr: [*]u8, buf_len: u32) i32;
extern "host" fn plugin_kill(id: i32) void;
extern "host" fn plugin_alive(id: i32) i32;

pub const WebWorkerTransport = struct {
    worker_id: i32,
    alive: bool = true,

    /// Spawn a Web Worker plugin. argv[0] is the worker script URL;
    /// remaining argv elements and cwd are ignored (web has no CWD).
    pub fn spawn(_: Allocator, argv: []const []const u8, _: ?[]const u8) !WebWorkerTransport {
        if (argv.len == 0) return error.InvalidCommand;
        const url = argv[0];
        const id = plugin_spawn(url.ptr, @intCast(url.len));
        if (id < 0) return error.SpawnFailed;
        return .{ .worker_id = id };
    }

    /// Send raw bytes to the worker via postMessage.
    pub fn writeAll(self: *WebWorkerTransport, data: []const u8) !void {
        if (!self.alive) return error.BrokenPipe;
        plugin_send(self.worker_id, data.ptr, @intCast(data.len));
    }

    /// Read one complete JSON-RPC line from the worker's message queue.
    /// Returns null if no message is available (non-blocking).
    pub fn readLine(self: *WebWorkerTransport, buf: []u8) !?[]const u8 {
        if (!self.alive) return null;
        const n = plugin_recv(self.worker_id, buf.ptr, @intCast(buf.len));
        if (n < 0) return null;
        // SAFETY: plugin_recv returns at most buf_len bytes.
        return buf[0..@intCast(@as(u32, @bitCast(n)))];
    }

    pub fn isAlive(self: *WebWorkerTransport) bool {
        if (!self.alive) return false;
        self.alive = plugin_alive(self.worker_id) != 0;
        return self.alive;
    }

    pub fn kill(self: *WebWorkerTransport) void {
        if (!self.alive) return;
        plugin_kill(self.worker_id);
        self.alive = false;
    }

    pub fn deinit(self: *WebWorkerTransport) void {
        self.kill();
    }
};
