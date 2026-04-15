// utils.zig - XSchem property parsing and escape handling.
//
// PropertyTokenizer and parseProps handle all XSchem property escaping:
//   1. Brace escaping:   \{ and \} -> literal { and }
//   2. Quote escaping:   \" within quoted values -> literal "
//   3. Backslash:        \\ -> literal \
//   4. Multi-line:       key="value\n...continues..." with newlines inside
//   5. Single-quoted:    key='value' (no escape processing inside)
//   6. Bare values:      key=value (terminated by space)
//   7. Empty braces:     {} means no properties

const std = @import("std");
const types = @import("../types.zig");
const Prop = types.Prop;

pub const Token = struct {
    key: []const u8,
    value: []const u8,
    single_quoted: bool = false,
};

pub const PropertyTokenizer = struct {
    source: []const u8,
    pos: usize,
    last_unclosed: bool = false,

    pub fn init(source: []const u8) PropertyTokenizer {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *PropertyTokenizer) ?Token {
        self.last_unclosed = false;
        const s = self.source;

        while (self.pos < s.len and isWhitespace(s[self.pos])) self.pos += 1;
        if (self.pos >= s.len) return null;

        const key_start = self.pos;
        while (self.pos < s.len and s[self.pos] != '=') self.pos += 1;
        if (self.pos >= s.len) return null;

        const key = std.mem.trim(u8, s[key_start..self.pos], " \t");
        if (key.len == 0) {
            while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            return self.next();
        }

        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
                return self.next();
            }
        }

        self.pos += 1;
        while (self.pos < s.len and s[self.pos] != '\n' and
            (s[self.pos] == ' ' or s[self.pos] == '\t')) self.pos += 1;
        if (self.pos >= s.len) return null;

        if (s[self.pos] == '"' or s[self.pos] == '\'') {
            const q = s[self.pos];
            self.pos += 1;
            const val_start = self.pos;

            while (self.pos < s.len) {
                if (s[self.pos] == '\\' and q == '"') {
                    if (self.pos + 2 < s.len and s[self.pos + 1] == '\\' and s[self.pos + 2] == '"') {
                        self.pos += 3;
                        continue;
                    }
                    if (self.pos + 1 < s.len) {
                        self.pos += 2;
                        continue;
                    }
                }
                if (s[self.pos] == q) break;
                self.pos += 1;
            }

            const val = s[val_start..self.pos];
            if (self.pos < s.len) { self.pos += 1; }
            else { self.last_unclosed = true; }
            return .{ .key = key, .value = val, .single_quoted = q == '\'' };
        }

        const val_start = self.pos;
        while (self.pos < s.len and !isWhitespace(s[self.pos])) self.pos += 1;
        return .{ .key = key, .value = s[val_start..self.pos] };
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

pub fn parseProps(arena: std.mem.Allocator, source: []const u8) !struct { props: []const Prop, count: u16 } {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");

    if (std.mem.eql(u8, trimmed, "{}")) {
        const empty = try arena.alloc(Prop, 0);
        return .{ .props = empty, .count = 0 };
    }
    if (trimmed.len == 0) {
        const empty = try arena.alloc(Prop, 0);
        return .{ .props = empty, .count = 0 };
    }

    var effective = trimmed;
    if (effective.len >= 2 and effective[0] == '{' and effective[effective.len - 1] == '}') {
        effective = std.mem.trim(u8, effective[1 .. effective.len - 1], " \t\r\n");
    }

    var prop_list: std.ArrayListUnmanaged(Prop) = .{};

    var tok = PropertyTokenizer.init(effective);
    while (tok.next()) |token| {
        const key = try arena.dupe(u8, token.key);
        const value = if (token.single_quoted)
            try std.fmt.allocPrint(arena, "'{s}'", .{token.value})
        else
            try unescapeValue(arena, token.value);
        try prop_list.append(arena, .{ .key = key, .value = value });
    }

    const props = try prop_list.toOwnedSlice(arena);
    const count: u16 = @intCast(props.len);
    return .{ .props = props, .count = count };
}

fn unescapeValue(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return arena.dupe(u8, raw);
    }

    var buf: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            if (raw[i + 1] == '\\' and i + 2 < raw.len and raw[i + 2] == '"') {
                try buf.append(arena, '"');
                i += 3;
                continue;
            }
            const next_ch = raw[i + 1];
            switch (next_ch) {
                '{', '}', '"', '\\' => {
                    try buf.append(arena, next_ch);
                    i += 2;
                },
                else => {
                    try buf.append(arena, raw[i]);
                    i += 1;
                },
            }
        } else {
            try buf.append(arena, raw[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice(arena);
}
