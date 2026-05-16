const std = @import("std");

pub const StreamEvent = union(enum) {
    text_delta: []const u8,
    tool_use_start: struct { id: []const u8, name: []const u8 },
    tool_use_delta: []const u8,
    tool_use_end: void,
    message_stop: void,
    error_event: []const u8,
    keepalive: void,
};

/// Accumulates SSE bytes and emits complete events.
pub const SseParser = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    provider: Provider,

    const Provider = @import("client.zig").Provider;

    pub fn init(provider: Provider) SseParser {
        return .{ .provider = provider };
    }

    /// Feed raw bytes from HTTP response. Returns events found.
    pub fn feed(self: *SseParser, arena: std.mem.Allocator, data: []const u8) ![]StreamEvent {
        var events: std.ArrayList(StreamEvent) = .{};

        // Append to internal buffer
        const space = self.buf.len - self.len;
        const copy_len = @min(data.len, space);
        @memcpy(self.buf[self.len..][0..copy_len], data[0..copy_len]);
        self.len += copy_len;

        // Process complete lines
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.buf[0..self.len], start, '\n')) |nl| {
            const line = std.mem.trimRight(u8, self.buf[start..nl], "\r");
            if (line.len > 0) {
                if (self.parseLine(arena, line)) |ev| {
                    try events.append(arena, ev);
                }
            }
            start = nl + 1;
        }

        // Shift remaining data
        if (start > 0) {
            const remaining = self.len - start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[start..self.len]);
            }
            self.len = remaining;
        }

        return events.items;
    }

    fn parseLine(self: *SseParser, arena: std.mem.Allocator, line: []const u8) ?StreamEvent {
        switch (self.provider) {
            .claude, .openai => {
                // SSE format: "data: {...}"
                if (!std.mem.startsWith(u8, line, "data: ")) return null;
                const json_str = line["data: ".len..];
                if (std.mem.eql(u8, json_str, "[DONE]")) return .message_stop;
                return parseJsonEvent(arena, json_str, self.provider);
            },
            .ollama => {
                // NDJSON format: each line is a JSON object
                return parseJsonEvent(arena, line, .ollama);
            },
        }
    }
};

fn parseJsonEvent(arena: std.mem.Allocator, json_str: []const u8, provider: @import("client.zig").Provider) ?StreamEvent {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, json_str, .{ .ignore_unknown_fields = true }) catch return null;
    const root = parsed.value;
    if (root != .object) return null;

    switch (provider) {
        .claude => {
            const type_val = root.object.get("type") orelse return null;
            if (type_val != .string) return null;
            const event_type = type_val.string;

            if (std.mem.eql(u8, event_type, "content_block_delta")) {
                const delta = root.object.get("delta") orelse return null;
                if (delta != .object) return null;
                const delta_type = delta.object.get("type") orelse return null;
                if (delta_type != .string) return null;
                if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                    const text = delta.object.get("text") orelse return null;
                    if (text == .string) return .{ .text_delta = text.string };
                } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
                    const pj = delta.object.get("partial_json") orelse return null;
                    if (pj == .string) return .{ .tool_use_delta = pj.string };
                }
            } else if (std.mem.eql(u8, event_type, "content_block_start")) {
                const cb = root.object.get("content_block") orelse return null;
                if (cb != .object) return null;
                const cb_type = cb.object.get("type") orelse return null;
                if (cb_type == .string and std.mem.eql(u8, cb_type.string, "tool_use")) {
                    const id = if (cb.object.get("id")) |v| (if (v == .string) v.string else "") else "";
                    const name = if (cb.object.get("name")) |v| (if (v == .string) v.string else "") else "";
                    return .{ .tool_use_start = .{ .id = id, .name = name } };
                }
            } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
                return .tool_use_end;
            } else if (std.mem.eql(u8, event_type, "message_stop")) {
                return .message_stop;
            } else if (std.mem.eql(u8, event_type, "error")) {
                return .{ .error_event = json_str };
            }
        },
        .openai => {
            const choices = root.object.get("choices") orelse return null;
            if (choices != .array or choices.array.items.len == 0) return null;
            const choice = choices.array.items[0];
            if (choice != .object) return null;
            const delta = choice.object.get("delta") orelse return null;
            if (delta != .object) return null;
            if (delta.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    return .{ .text_delta = content.string };
                }
            }
            const finish = choice.object.get("finish_reason") orelse return null;
            if (finish == .string and std.mem.eql(u8, finish.string, "stop")) {
                return .message_stop;
            }
        },
        .ollama => {
            if (root.object.get("done")) |done| {
                if (done == .bool and done.bool) return .message_stop;
            }
            const msg = root.object.get("message") orelse return null;
            if (msg != .object) return null;
            if (msg.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    return .{ .text_delta = content.string };
                }
            }
        },
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "SseParser claude text_delta" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var parser = SseParser.init(.claude);
    const data = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n";
    const events = try parser.feed(a, data);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("Hello", events[0].text_delta);
}

test "SseParser claude message_stop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var parser = SseParser.init(.claude);
    const data = "data: {\"type\":\"message_stop\"}\n";
    const events = try parser.feed(a, data);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0] == .message_stop);
}

test "SseParser openai text_delta" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var parser = SseParser.init(.openai);
    const data = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":null}]}\n";
    const events = try parser.feed(a, data);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("Hi", events[0].text_delta);
}

test "SseParser openai done" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var parser = SseParser.init(.openai);
    const data = "data: [DONE]\n";
    const events = try parser.feed(a, data);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0] == .message_stop);
}

test "SseParser ollama text_delta" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var parser = SseParser.init(.ollama);
    const data = "{\"message\":{\"content\":\"World\"},\"done\":false}\n";
    const events = try parser.feed(a, data);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("World", events[0].text_delta);
}
