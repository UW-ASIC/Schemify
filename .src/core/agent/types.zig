//! MCP protocol types — JSON-RPC 2.0 and Model Context Protocol structures.
//!
//! All serialization uses manual JSON building with a small writeJsonStr helper
//! for string escaping. This avoids Zig 0.15 std.json API churn.

const std = @import("std");

// ── JSON-RPC 2.0 ─────────────────────────────────────────────────────────────

pub const JSONRPC_VERSION = "2.0";
pub const MCP_PROTOCOL_VERSION = "2024-11-05";

/// JSON-RPC id can be string, number, or null.
pub const JsonRpcId = union(enum) {
    integer: i64,
    string: []const u8,
};

// ── Error codes ───────────────────────────────────────────────────────────────

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    // MCP-specific
    resource_not_found = -32001,
    tool_not_found = -32002,
    prompt_not_found = -32003,
};

// ── MCP types ─────────────────────────────────────────────────────────────────

pub const ToolAnnotations = struct {
    readOnlyHint: ?bool = null,
    destructiveHint: ?bool = null,
    idempotentHint: ?bool = null,
};

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

// ── Agent command ─────────────────────────────────────────────────────────────
// Locally-defined command union for agent tool dispatch.
// main.zig translates these to commands.Command before pushing to the queue.
// This avoids a cross-module dependency on the commands module.

pub const AgentCommand = union(enum) {
    place: struct {
        sym_path: []const u8,
        name: []const u8,
        x: i32,
        y: i32,
    },
    add_wire: struct {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        net_name: ?[]const u8,
    },
    delete_instance: struct { idx: u32 },
    set_instance_prop: struct {
        idx: u32,
        key: []const u8,
        val: []const u8,
    },
};

// ── Agent context ─────────────────────────────────────────────────────────────
// Opaque bridge between the MCP server and the application.
// main.zig constructs one of these and passes it as ctx to the Server.
// Tool handlers cast ctx back to *AgentContext to access the schematic.

const Schemify = @import("../Schemify.zig").Schemify;

pub const AgentContext = struct {
    /// Returns a pointer to the active document's Schemify, or null if no
    /// document is open. The pointer is valid only for the duration of the
    /// current tool handler call (arena-scoped).
    getSchematic: *const fn (*AgentContext) ?*const Schemify,

    /// Dispatch an AgentCommand to the application's command queue.
    /// Returns true if the command was accepted, false if the queue is full.
    /// Null when not wired (e.g. in tests).
    dispatchCommand: ?*const fn (*AgentContext, AgentCommand) bool = null,

    /// Returns the project directory path, or "." if unavailable.
    getProjectDir: ?*const fn (*AgentContext) []const u8 = null,

    /// Opaque application state pointer (AppState). Only dereferenced by
    /// the callbacks above — tool handlers never touch this directly.
    app: *anyopaque,
};

// ── JSON string writer ───────────────────────────────────────────────────────
// Writes a JSON-escaped string with surrounding quotes.

pub fn writeJsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(w, "\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ── Response builder helpers ──────────────────────────────────────────────────

/// Write a JSON-RPC id value.
fn writeId(w: anytype, id: ?JsonRpcId) !void {
    if (id) |req_id| {
        switch (req_id) {
            .integer => |v| try std.fmt.format(w, "{d}", .{v}),
            .string => |v| try writeJsonStr(w, v),
        }
    } else {
        try w.writeAll("null");
    }
}

/// Build a success JSON-RPC response.
pub fn successResponse(a: std.mem.Allocator, id: ?JsonRpcId, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeByte('}');
    return buf.items;
}

/// Build an error JSON-RPC response.
pub fn errorResponse(a: std.mem.Allocator, id: ?JsonRpcId, code: ErrorCode, message: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"error\":{\"code\":");
    try std.fmt.format(w, "{d}", .{@intFromEnum(code)});
    try w.writeAll(",\"message\":");
    try writeJsonStr(w, message);
    try w.writeAll("}}");
    return buf.items;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "writeJsonStr escapes correctly" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeJsonStr(w, "hello \"world\"\nline2");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline2\"", buf.items);
}

test "successResponse valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const resp = try successResponse(a, .{ .integer = 1 }, "{}");
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\":{}") != null);
}

test "errorResponse valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const resp = try errorResponse(a, null, .parse_error, "bad");
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32700") != null);
}
