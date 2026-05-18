const std = @import("std");

pub const PROTOCOL_VERSION: u32 = 1;

// Standard JSON-RPC 2.0 error codes.
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

pub const ErrorInfo = struct {
    code: i32,
    message: []const u8,
};

pub const Notification = struct {
    method: []const u8,
    params: ?[]const u8,
};

pub const Request = struct {
    id: u32,
    method: []const u8,
    params: ?[]const u8,
};

pub const Response = struct {
    id: u32,
    result: ?[]const u8,
    err: ?ErrorInfo,
};

pub const ParsedMessage = union(enum) {
    notification: Notification,
    request: Request,
    response: Response,
    parse_error,
};

// -- Sending ------------------------------------------------------------------

pub fn sendNotification(writer: anytype, method: []const u8, params_json: ?[]const u8) void {
    writeObj(writer, .{
        .jsonrpc = "2.0",
        .method = method,
    }, params_json, null, null);
}

pub fn sendRequest(writer: anytype, id: u32, method: []const u8, params_json: ?[]const u8) void {
    writeObj(writer, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
    }, params_json, null, null);
}

pub fn sendResponse(writer: anytype, id: u32, result_json: []const u8) void {
    writeObj(writer, .{
        .jsonrpc = "2.0",
        .id = id,
    }, null, result_json, null);
}

pub fn sendError(writer: anytype, id: u32, code: i32, message: []const u8) void {
    writeObj(writer, .{
        .jsonrpc = "2.0",
        .id = id,
    }, null, null, .{ .code = code, .message = message });
}

fn writeObj(writer: anytype, header: anytype, params_json: ?[]const u8, result_json: ?[]const u8, err_info: ?struct { code: i32, message: []const u8 }) void {
    // Write the header fields using std.json.
    // We manually construct the JSON to embed raw JSON fragments for params/result.
    writer.writeByte('{') catch return;

    // "jsonrpc":"2.0"
    writer.writeAll("\"jsonrpc\":\"2.0\"") catch return;

    // "id":N  (if present in header)
    if (@hasField(@TypeOf(header), "id")) {
        writer.print(",\"id\":{d}", .{header.id}) catch return;
    }

    // "method":"..."
    if (@hasField(@TypeOf(header), "method")) {
        writer.writeAll(",\"method\":\"") catch return;
        writer.writeAll(header.method) catch return;
        writer.writeByte('"') catch return;
    }

    // "params":<raw json>
    if (params_json) |p| {
        writer.writeAll(",\"params\":") catch return;
        writer.writeAll(p) catch return;
    }

    // "result":<raw json>
    if (result_json) |r| {
        writer.writeAll(",\"result\":") catch return;
        writer.writeAll(r) catch return;
    }

    // "error":{"code":N,"message":"..."}
    if (err_info) |e| {
        writer.print(",\"error\":{{\"code\":{d},\"message\":\"", .{e.code}) catch return;
        writer.writeAll(e.message) catch return;
        writer.writeAll("\"}") catch return;
    }

    writer.writeAll("}\n") catch return;
}

// -- Parsing ------------------------------------------------------------------

pub fn parseLine(line: []const u8) ParsedMessage {
    const trimmed = std.mem.trimRight(u8, line, "\r\n");
    if (trimmed.len == 0) return .parse_error;
    if (trimmed[0] != '{') return .parse_error;

    // Check jsonrpc version field.
    const version_raw = extractRawJson(trimmed, "jsonrpc") orelse return .parse_error;
    if (!std.mem.eql(u8, version_raw, "\"2.0\"")) return .parse_error;

    // Extract method (optional — responses don't have it).
    const method: ?[]const u8 = blk: {
        const raw = extractRawJson(trimmed, "method") orelse break :blk null;
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return .parse_error;
        break :blk raw[1 .. raw.len - 1];
    };

    // Extract id (optional — notifications don't have it).
    const id: ?u32 = blk: {
        const raw = extractRawJson(trimmed, "id") orelse break :blk null;
        break :blk std.fmt.parseInt(u32, raw, 10) catch return .parse_error;
    };

    const params = extractRawJson(trimmed, "params");

    if (method) |m| {
        if (id) |i| {
            return .{ .request = .{ .id = i, .method = m, .params = params } };
        }
        return .{ .notification = .{ .method = m, .params = params } };
    }

    // No method — must be a response.
    if (id) |i| {
        const result = extractRawJson(trimmed, "result");
        var err_info: ?ErrorInfo = null;
        if (extractRawJson(trimmed, "error")) |err_raw| {
            if (err_raw.len > 0 and err_raw[0] == '{') {
                const code_raw = extractRawJson(err_raw, "code") orelse return .parse_error;
                const code = std.fmt.parseInt(i32, code_raw, 10) catch return .parse_error;
                const msg_raw = extractRawJson(err_raw, "message") orelse return .parse_error;
                if (msg_raw.len < 2 or msg_raw[0] != '"' or msg_raw[msg_raw.len - 1] != '"') return .parse_error;
                err_info = .{ .code = code, .message = msg_raw[1 .. msg_raw.len - 1] };
            }
        }
        return .{ .response = .{ .id = i, .result = result, .err = err_info } };
    }

    return .parse_error;
}

/// Extracts raw JSON text for a top-level key by scanning for `"key":` and
/// finding the extent of the value. Returns null if key not found.
pub fn extractRawJson(json: []const u8, key: []const u8) ?[]const u8 {
    // Build the search needle: `"key":`
    var needle_buf: [128]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    const needle = needle_buf[0 .. 3 + key.len];

    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = idx + needle.len;
    // Skip whitespace after colon.
    var pos = start;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    if (pos >= json.len) return null;

    const end = findValueEnd(json, pos) orelse return null;
    return json[pos..end];
}

/// Given a position at the start of a JSON value, find where it ends.
fn findValueEnd(json: []const u8, start: usize) ?usize {
    if (start >= json.len) return null;
    const c = json[start];
    if (c == '"') return findStringEnd(json, start);
    if (c == '{' or c == '[') return findBracketEnd(json, start);
    // Number, bool, null — scan until delimiter.
    var pos = start;
    while (pos < json.len) : (pos += 1) {
        switch (json[pos]) {
            ',', '}', ']' => return pos,
            else => {},
        }
    }
    return pos;
}

fn findStringEnd(json: []const u8, start: usize) ?usize {
    var pos = start + 1; // skip opening quote
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1; // skip escaped char
        } else if (json[pos] == '"') {
            return pos + 1;
        }
    }
    return null;
}

fn findBracketEnd(json: []const u8, start: usize) ?usize {
    const open = json[start];
    const close: u8 = if (open == '{') '}' else ']';
    var depth: u32 = 0;
    var pos = start;
    var in_string = false;
    while (pos < json.len) : (pos += 1) {
        if (in_string) {
            if (json[pos] == '\\') {
                pos += 1;
            } else if (json[pos] == '"') {
                in_string = false;
            }
        } else {
            if (json[pos] == '"') {
                in_string = true;
            } else if (json[pos] == open) {
                depth += 1;
            } else if (json[pos] == close) {
                depth -= 1;
                if (depth == 0) return pos + 1;
            }
        }
    }
    return null;
}

// -- Tests --------------------------------------------------------------------

test "round-trip notification" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    sendNotification(writer, "test/ping", "{\"a\":1}");
    const line = fbs.getWritten();

    const msg = parseLine(line);
    switch (msg) {
        .notification => |n| {
            try std.testing.expectEqualStrings("test/ping", n.method);
            try std.testing.expect(n.params != null);
            try std.testing.expectEqualStrings("{\"a\":1}", n.params.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "round-trip request" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    sendRequest(writer, 42, "tool/run", "{\"name\":\"x\"}");
    const line = fbs.getWritten();

    const msg = parseLine(line);
    switch (msg) {
        .request => |r| {
            try std.testing.expectEqual(@as(u32, 42), r.id);
            try std.testing.expectEqualStrings("tool/run", r.method);
            try std.testing.expect(r.params != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "round-trip response" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    sendResponse(writer, 7, "\"ok\"");
    const line = fbs.getWritten();

    const msg = parseLine(line);
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(u32, 7), r.id);
            try std.testing.expect(r.result != null);
            try std.testing.expectEqualStrings("\"ok\"", r.result.?);
            try std.testing.expect(r.err == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "round-trip error response" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    sendError(writer, 3, METHOD_NOT_FOUND, "no such method");
    const line = fbs.getWritten();

    const msg = parseLine(line);
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(u32, 3), r.id);
            try std.testing.expect(r.err != null);
            try std.testing.expectEqual(METHOD_NOT_FOUND, r.err.?.code);
            try std.testing.expectEqualStrings("no such method", r.err.?.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "notification without params" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    sendNotification(writer, "ping", null);
    const line = fbs.getWritten();

    const msg = parseLine(line);
    switch (msg) {
        .notification => |n| {
            try std.testing.expectEqualStrings("ping", n.method);
            try std.testing.expect(n.params == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "invalid JSON returns parse_error" {
    const msg = parseLine("not json at all");
    try std.testing.expect(msg == .parse_error);
}

test "empty line returns parse_error" {
    const msg = parseLine("");
    try std.testing.expect(msg == .parse_error);
}
