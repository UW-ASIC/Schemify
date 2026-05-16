const std = @import("std");

pub const Provider = enum {
    claude,
    openai,
    ollama,

    pub fn displayName(self: Provider) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .openai => "ChatGPT",
            .ollama => "Ollama",
        };
    }

    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude-sonnet-4-20250514",
            .openai => "gpt-4o",
            .ollama => "llama3",
        };
    }

    pub fn defaultBaseUrl(self: Provider) []const u8 {
        return switch (self) {
            .claude => "https://api.anthropic.com",
            .openai => "https://api.openai.com",
            .ollama => "http://localhost:11434",
        };
    }
};

pub const LlmConfig = struct {
    provider: Provider = .claude,
    api_key: [128]u8 = [_]u8{0} ** 128,
    api_key_len: u8 = 0,
    base_url: [256]u8 = [_]u8{0} ** 256,
    base_url_len: u16 = 0,
    model: [64]u8 = [_]u8{0} ** 64,
    model_len: u8 = 0,

    pub fn apiKeySlice(self: *const LlmConfig) []const u8 {
        return self.api_key[0..self.api_key_len];
    }

    pub fn baseUrlSlice(self: *const LlmConfig) []const u8 {
        if (self.base_url_len > 0) return self.base_url[0..self.base_url_len];
        return self.provider.defaultBaseUrl();
    }

    pub fn modelSlice(self: *const LlmConfig) []const u8 {
        if (self.model_len > 0) return self.model[0..self.model_len];
        return self.provider.defaultModel();
    }

    pub fn setApiKey(self: *LlmConfig, key: []const u8) void {
        const n: u8 = @intCast(@min(key.len, self.api_key.len));
        @memcpy(self.api_key[0..n], key[0..n]);
        self.api_key_len = n;
    }

    pub fn setBaseUrl(self: *LlmConfig, url: []const u8) void {
        const n: u16 = @intCast(@min(url.len, self.base_url.len));
        @memcpy(self.base_url[0..n], url[0..n]);
        self.base_url_len = n;
    }

    pub fn setModel(self: *LlmConfig, m: []const u8) void {
        const n: u8 = @intCast(@min(m.len, self.model.len));
        @memcpy(self.model[0..n], m[0..n]);
        self.model_len = n;
    }
};

/// Build a JSON request body for the given provider.
/// Returns arena-allocated JSON string.
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    config: *const LlmConfig,
    messages_json: []const u8,
    system_prompt: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(arena);

    switch (config.provider) {
        .claude => {
            try w.writeAll("{\"model\":\"");
            try w.writeAll(config.modelSlice());
            try w.writeAll("\",\"max_tokens\":4096,\"stream\":true");
            if (system_prompt) |sp| {
                try w.writeAll(",\"system\":\"");
                try writeEscaped(w, sp);
                try w.writeByte('"');
            }
            try w.writeAll(",\"messages\":");
            try w.writeAll(messages_json);
            try w.writeByte('}');
        },
        .openai => {
            try w.writeAll("{\"model\":\"");
            try w.writeAll(config.modelSlice());
            try w.writeAll("\",\"stream\":true,\"messages\":[");
            if (system_prompt) |sp| {
                try w.writeAll("{\"role\":\"system\",\"content\":\"");
                try writeEscaped(w, sp);
                try w.writeAll("\"},");
            }
            if (messages_json.len > 2) {
                try w.writeAll(messages_json[1 .. messages_json.len - 1]);
            }
            try w.writeAll("]}");
        },
        .ollama => {
            try w.writeAll("{\"model\":\"");
            try w.writeAll(config.modelSlice());
            try w.writeAll("\",\"stream\":true,\"messages\":[");
            if (system_prompt) |sp| {
                try w.writeAll("{\"role\":\"system\",\"content\":\"");
                try writeEscaped(w, sp);
                try w.writeAll("\"},");
            }
            if (messages_json.len > 2) {
                try w.writeAll(messages_json[1 .. messages_json.len - 1]);
            }
            try w.writeAll("]}");
        },
    }

    return buf.items;
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Provider defaults" {
    try std.testing.expectEqualStrings("Claude", Provider.claude.displayName());
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", Provider.claude.defaultModel());
    try std.testing.expectEqualStrings("https://api.anthropic.com", Provider.claude.defaultBaseUrl());
}

test "LlmConfig setters and getters" {
    var config = LlmConfig{};
    config.setApiKey("sk-test-key-123");
    try std.testing.expectEqualStrings("sk-test-key-123", config.apiKeySlice());

    config.setModel("gpt-4o-mini");
    try std.testing.expectEqualStrings("gpt-4o-mini", config.modelSlice());

    // Default base URL when none set
    try std.testing.expectEqualStrings("https://api.anthropic.com", config.baseUrlSlice());

    config.setBaseUrl("http://localhost:8080");
    try std.testing.expectEqualStrings("http://localhost:8080", config.baseUrlSlice());
}

test "buildRequestBody claude" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var config = LlmConfig{ .provider = .claude };
    const body = try buildRequestBody(a, &config, "[{\"role\":\"user\",\"content\":\"hello\"}]", "You are helpful");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-sonnet-4-20250514\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"You are helpful\"") != null);
}

test "buildRequestBody openai" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var config = LlmConfig{ .provider = .openai };
    const body = try buildRequestBody(a, &config, "[{\"role\":\"user\",\"content\":\"hello\"}]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}
