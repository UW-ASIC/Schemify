//! MCP server over Unix domain socket.
//!
//! Implements the Model Context Protocol (JSON-RPC 2.0) handshake and
//! message routing. Runs on a background thread via std.Thread.
//! Handles multiple concurrent clients, each on its own thread.
//!
//! Protocol flow:
//!   Client -> initialize (with protocolVersion + capabilities)
//!   Server -> initialize result (with server capabilities)
//!   Client -> notifications/initialized
//!   Client -> tools/list, tools/call, resources/list, resources/read, etc.

const std = @import("std");
const posix = std.posix;
const mcp = @import("types.zig");
const tools_mod = @import("tools.zig");
const resources_mod = @import("resources.zig");
const prompts_mod = @import("prompts.zig");

const log = std.log.scoped(.mcp_server);

// ── Server ────────────────────────────────────────────────────────────────────

const MAX_CLIENTS = 8;

pub const Server = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    socket_path: []const u8,
    listen_fd: ?posix.socket_t = null,
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    client_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    client_fds: [MAX_CLIENTS]std.atomic.Value(posix.socket_t) = [_]std.atomic.Value(posix.socket_t){std.atomic.Value(posix.socket_t).init(-1)} ** MAX_CLIENTS,

    /// Initialize the server. Does not start listening yet.
    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, ctx: *anyopaque) Server {
        return .{
            .allocator = allocator,
            .socket_path = allocator.dupe(u8, socket_path) catch socket_path,
            .ctx = ctx,
        };
    }

    /// Start listening on the Unix domain socket. Spawns accept thread.
    pub fn start(self: *Server) !void {
        // Remove stale socket file
        std.fs.cwd().deleteFile(self.socket_path) catch {};

        // Create Unix domain socket
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        // Bind
        var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        const path_len = @min(self.socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.socket_path[0..path_len]);

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 4);

        self.listen_fd = fd;
        self.running.store(true, .release);

        // Spawn accept loop thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        log.info("MCP server listening on {s}", .{self.socket_path});
    }

    fn registerClient(self: *Server, fd: posix.socket_t) void {
        for (&self.client_fds) |*slot| {
            if (slot.cmpxchgStrong(-1, fd, .acq_rel, .monotonic) == null) return;
        }
    }

    fn unregisterClient(self: *Server, fd: posix.socket_t) void {
        for (&self.client_fds) |*slot| {
            if (slot.cmpxchgStrong(fd, -1, .acq_rel, .monotonic) == null) return;
        }
    }

    /// Stop the server, close all connections, clean up socket file.
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);

        // Shut down all client sockets to unblock read() in client threads.
        for (&self.client_fds) |*slot| {
            const fd = slot.load(.acquire);
            if (fd != -1) posix.shutdown(fd, .both) catch {};
        }

        // The accept loop polls with a short timeout and rechecks
        // `running`, so it will exit on its own. We join first, then
        // close the listen fd — closing before join causes EBADF
        // inside accept() which Zig marks unreachable.
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }

        if (self.listen_fd) |fd| {
            posix.close(fd);
            self.listen_fd = null;
        }

        // Remove socket file
        std.fs.cwd().deleteFile(self.socket_path) catch {};

        // Free duped path
        self.allocator.free(self.socket_path);

        log.info("MCP server stopped", .{});
    }

    /// Number of currently connected clients.
    pub fn clientCount(self: *const Server) u32 {
        return self.client_count.load(.acquire);
    }

    // ── Accept loop (runs on background thread) ──────────────────────────────

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            const fd = self.listen_fd orelse break;

            // Use poll() to wait for incoming connections with a 100ms
            // timeout.  This lets us re-check the running flag on shutdown.
            // The listen socket is NONBLOCK so accept() never blocks.
            var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfd, 100) catch |err| {
                if (self.running.load(.acquire)) log.err("poll error: {}", .{err});
                break;
            };
            if (ready == 0) continue; // timeout, re-check running flag

            // Re-check after poll unblocks — stop() may have closed the fd.
            if (!self.running.load(.acquire)) break;

            const conn_fd = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
                switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        if (self.running.load(.acquire)) {
                            log.err("accept error: {}", .{err});
                        }
                        break;
                    },
                }
            };

            // stop() wakes us with a dummy connection — discard it.
            if (!self.running.load(.acquire)) {
                posix.close(conn_fd);
                break;
            }

            // Spawn client handler thread
            const thread = std.Thread.spawn(.{}, clientLoop, .{ self, conn_fd }) catch {
                posix.close(conn_fd);
                continue;
            };
            thread.detach();
        }
    }

    // ── Client handler (runs on per-client thread) ───────────────────────────

    fn clientLoop(self: *Server, conn_fd: posix.socket_t) void {
        self.registerClient(conn_fd);
        _ = self.client_count.fetchAdd(1, .acq_rel);
        defer {
            self.unregisterClient(conn_fd);
            _ = self.client_count.fetchSub(1, .acq_rel);
            posix.close(conn_fd);
        }

        var read_buf: [65536]u8 = undefined;
        var line_buf: std.ArrayList(u8) = .{};
        defer line_buf.deinit(self.allocator);

        while (self.running.load(.acquire)) {
            const n = posix.read(conn_fd, &read_buf) catch break;
            if (n == 0) break; // Client disconnected

            line_buf.appendSlice(self.allocator, read_buf[0..n]) catch break;

            // Process complete newline-delimited messages
            while (std.mem.indexOf(u8, line_buf.items, "\n")) |nl_pos| {
                const line = line_buf.items[0..nl_pos];

                if (line.len > 0) {
                    const response = self.processMessage(line);
                    if (response) |resp| {
                        defer self.allocator.free(resp);
                        // Write response + newline
                        _ = posix.write(conn_fd, resp) catch break;
                        _ = posix.write(conn_fd, "\n") catch break;
                    }
                }

                // Remove processed line from buffer (including newline)
                const remaining = line_buf.items[nl_pos + 1 ..];
                std.mem.copyForwards(u8, line_buf.items[0..remaining.len], remaining);
                line_buf.shrinkRetainingCapacity(remaining.len);
            }
        }
    }

    // ── Message processing ───────────────────────────────────────────────────

    pub fn processMessage(self: *Server, data: []const u8) ?[]const u8 {
        // Parse JSON in an arena that lives for this single message
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{}) catch {
            return dupeResponse(self.allocator, mcp.errorResponse(arena, null, .parse_error, "Invalid JSON") catch return null);
        };

        const root = parsed.value;
        if (root != .object) {
            return dupeResponse(self.allocator, mcp.errorResponse(arena, null, .invalid_request, "Expected JSON object") catch return null);
        }

        const obj = root.object;

        // Extract id
        const id = extractId(obj);

        // Extract method
        const method_val = obj.get("method") orelse {
            return dupeResponse(self.allocator, mcp.errorResponse(arena, id, .invalid_request, "Missing method") catch return null);
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                return dupeResponse(self.allocator, mcp.errorResponse(arena, id, .invalid_request, "Method must be a string") catch return null);
            },
        };

        // Extract params
        const params = obj.get("params");

        // Route to handler
        const result = self.routeMethod(arena, method, params, id) catch |err| {
            const msg = std.fmt.allocPrint(arena, "Internal error: {}", .{err}) catch "Internal error";
            return dupeResponse(self.allocator, mcp.errorResponse(arena, id, .internal_error, msg) catch return null);
        };

        return result;
    }

    fn routeMethod(self: *Server, arena: std.mem.Allocator, method: []const u8, params: ?std.json.Value, id: ?mcp.JsonRpcId) !?[]const u8 {
        // ── MCP Lifecycle ────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "initialize")) {
            var buf: std.ArrayList(u8) = .{};
            const w = buf.writer(arena);
            try w.writeAll("{\"protocolVersion\":\"");
            try w.writeAll(mcp.MCP_PROTOCOL_VERSION);
            try w.writeAll("\",\"capabilities\":{\"tools\":{},\"resources\":{},\"prompts\":{}}");
            try w.writeAll(",\"serverInfo\":{\"name\":\"schemify\",\"version\":\"0.1.0\"}}");
            const resp = try mcp.successResponse(arena, id, buf.items);
            return dupeResponse(self.allocator, resp);
        }

        // Notifications (no response expected)
        if (std.mem.startsWith(u8, method, "notifications/")) {
            return null;
        }

        // ── ping ─────────────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "ping")) {
            const resp = try mcp.successResponse(arena, id, "{}");
            return dupeResponse(self.allocator, resp);
        }

        // ── Tools ────────────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "tools/list")) {
            const result = try tools_mod.listTools(arena);
            const resp = try mcp.successResponse(arena, id, result);
            return dupeResponse(self.allocator, resp);
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            const name = extractParamStr(params, "name") orelse {
                const resp = try mcp.errorResponse(arena, id, .invalid_params, "Missing tool name");
                return dupeResponse(self.allocator, resp);
            };
            const arguments = extractParamObj(params, "arguments");
            const result = try tools_mod.callTool(arena, name, arguments, self.ctx);
            const resp = try mcp.successResponse(arena, id, result);
            return dupeResponse(self.allocator, resp);
        }

        // ── Resources ────────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "resources/list")) {
            const result = try resources_mod.listResources(arena);
            const resp = try mcp.successResponse(arena, id, result);
            return dupeResponse(self.allocator, resp);
        }

        if (std.mem.eql(u8, method, "resources/read")) {
            const uri = extractParamStr(params, "uri") orelse {
                const resp = try mcp.errorResponse(arena, id, .invalid_params, "Missing uri");
                return dupeResponse(self.allocator, resp);
            };
            const result = try resources_mod.readResource(arena, uri, self.ctx);
            // If result is an error response (no "contents" key), pass through
            if (std.mem.indexOf(u8, result, "\"contents\"") == null) {
                return dupeResponse(self.allocator, result);
            }
            const resp = try mcp.successResponse(arena, id, result);
            return dupeResponse(self.allocator, resp);
        }

        // ── Prompts ──────────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "prompts/list")) {
            const result = try prompts_mod.listPrompts(arena);
            const resp = try mcp.successResponse(arena, id, result);
            return dupeResponse(self.allocator, resp);
        }

        if (std.mem.eql(u8, method, "prompts/get")) {
            const name = extractParamStr(params, "name") orelse {
                const resp = try mcp.errorResponse(arena, id, .invalid_params, "Missing prompt name");
                return dupeResponse(self.allocator, resp);
            };
            const arguments = extractParamObj(params, "arguments");
            const result = try prompts_mod.getPrompt(arena, name, arguments);
            if (std.mem.indexOf(u8, result, "\"messages\"") == null) {
                return dupeResponse(self.allocator, result);
            }
            const resp = try mcp.successResponse(arena, id, result);
            return dupeResponse(self.allocator, resp);
        }

        // ── Unknown method ───────────────────────────────────────────────────
        const resp = try mcp.errorResponse(arena, id, .method_not_found, "Unknown method");
        return dupeResponse(self.allocator, resp);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fn extractId(obj: std.json.ObjectMap) ?mcp.JsonRpcId {
        const id_val = obj.get("id") orelse return null;
        return switch (id_val) {
            .integer => |v| .{ .integer = v },
            .string => |s| .{ .string = s },
            .number_string => |s| .{ .integer = std.fmt.parseInt(i64, s, 10) catch 0 },
            else => null,
        };
    }

    fn extractParamStr(params: ?std.json.Value, key: []const u8) ?[]const u8 {
        const p = params orelse return null;
        if (p != .object) return null;
        const v = p.object.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn extractParamObj(params: ?std.json.Value, key: []const u8) ?std.json.Value {
        const p = params orelse return null;
        if (p != .object) return null;
        return p.object.get(key);
    }

    /// Dupe arena-allocated response into long-lived allocator.
    fn dupeResponse(allocator: std.mem.Allocator, data: ?[]const u8) ?[]const u8 {
        const d = data orelse return null;
        return allocator.dupe(u8, d) catch null;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Server init and stop without start" {
    var dummy: u8 = 0;
    var server = Server.init(std.testing.allocator, "/tmp/schemify-test-mcp.sock", @ptrCast(&dummy));
    server.stop();
}

test "processMessage handles initialize" {
    var dummy: u8 = 0;
    var server = Server.init(std.testing.allocator, "/tmp/schemify-test-mcp2.sock", @ptrCast(&dummy));
    defer server.stop();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
    ;
    const response = server.processMessage(msg);
    try std.testing.expect(response != null);
    defer std.testing.allocator.free(response.?);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "schemify") != null);
}

test "processMessage handles ping" {
    var dummy: u8 = 0;
    var server = Server.init(std.testing.allocator, "/tmp/schemify-test-mcp3.sock", @ptrCast(&dummy));
    defer server.stop();

    const msg =
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    ;
    const response = server.processMessage(msg);
    try std.testing.expect(response != null);
    defer std.testing.allocator.free(response.?);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"id\":2") != null);
}

test "processMessage handles unknown method" {
    var dummy: u8 = 0;
    var server = Server.init(std.testing.allocator, "/tmp/schemify-test-mcp4.sock", @ptrCast(&dummy));
    defer server.stop();

    const msg =
        \\{"jsonrpc":"2.0","id":3,"method":"unknown/method"}
    ;
    const response = server.processMessage(msg);
    try std.testing.expect(response != null);
    defer std.testing.allocator.free(response.?);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "-32601") != null);
}

test "processMessage handles tools/list" {
    var dummy: u8 = 0;
    var server = Server.init(std.testing.allocator, "/tmp/schemify-test-mcp5.sock", @ptrCast(&dummy));
    defer server.stop();

    const msg =
        \\{"jsonrpc":"2.0","id":4,"method":"tools/list"}
    ;
    const response = server.processMessage(msg);
    try std.testing.expect(response != null);
    defer std.testing.allocator.free(response.?);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "write_pyspice") != null);
}

test "processMessage returns null for notifications" {
    var dummy: u8 = 0;
    var server = Server.init(std.testing.allocator, "/tmp/schemify-test-mcp6.sock", @ptrCast(&dummy));
    defer server.stop();

    const msg =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    const response = server.processMessage(msg);
    try std.testing.expect(response == null);
}
