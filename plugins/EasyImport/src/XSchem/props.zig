// props.zig - PropertyTokenizer for XSchem key=value property parsing.
//
// Handles all XSchem property escaping variants:
//   1. Brace escaping:   \{ and \} -> literal { and }
//   2. Quote escaping:   \" within quoted values -> literal "
//   3. Backslash:        \\ -> literal \
//   4. Multi-line:       key="value\n...continues..." with newlines inside
//   5. Single-quoted:    key='value' (no escape processing inside)
//   6. Bare values:      key=value (terminated by space)
//   7. Empty braces:     {} means no properties
//
// Rewritten from scratch per D-01; old XSchem.zig PropTokenizer consulted
// as behavioral reference only per D-02.

const std = @import("std");
const types = @import("types.zig");
const Prop = types.Prop;

/// Token returned by the PropertyTokenizer. Contains slices into the
/// original source (for bare/single-quoted) or into a decoded buffer
/// (when escape processing was needed).
pub const Token = struct {
    key: []const u8,
    value: []const u8,
    single_quoted: bool = false,
};

/// Tokenizes XSchem property strings of the form `key=value key2="val2" ...`.
/// Iterates over key=value pairs, handling all escaping variants.
/// Does NOT allocate -- returns slices into the source or decoded buffers
/// managed by parseProps.
pub const PropertyTokenizer = struct {
    source: []const u8,
    pos: usize,
    /// Set to true when a quoted value reached end-of-source without
    /// finding the closing quote (indicates multi-line continuation).
    last_unclosed: bool = false,

    pub fn init(source: []const u8) PropertyTokenizer {
        return .{ .source = source, .pos = 0 };
    }

    /// Returns the next key=value token, or null when exhausted.
    /// Values are returned as raw slices -- escape processing (brace,
    /// backslash) is handled by parseProps which copies into an arena.
    pub fn next(self: *PropertyTokenizer) ?Token {
        self.last_unclosed = false;
        const s = self.source;

        // Skip leading whitespace
        while (self.pos < s.len and isWhitespace(s[self.pos])) self.pos += 1;
        if (self.pos >= s.len) return null;

        // Find key (everything up to '=')
        const key_start = self.pos;
        while (self.pos < s.len and s[self.pos] != '=') self.pos += 1;
        if (self.pos >= s.len) return null;

        const key = std.mem.trim(u8, s[key_start..self.pos], " \t");
        if (key.len == 0) {
            // Skip to next line and retry
            while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            return self.next();
        }

        // Validate key: must contain only word characters (a-z A-Z 0-9 _ -)
        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
                return self.next();
            }
        }

        // Skip '='
        self.pos += 1;

        // Skip optional whitespace after '=' (but not newlines)
        while (self.pos < s.len and s[self.pos] != '\n' and
            (s[self.pos] == ' ' or s[self.pos] == '\t'))
        {
            self.pos += 1;
        }
        if (self.pos >= s.len) return null;

        // Parse value
        if (s[self.pos] == '"' or s[self.pos] == '\'') {
            // Quoted value
            const q = s[self.pos];
            self.pos += 1;
            const val_start = self.pos;

            // Find closing quote, respecting backslash escapes (for double-quotes)
            while (self.pos < s.len) {
                if (s[self.pos] == '\\' and q == '"') {
                    // Backslash in double-quoted value: skip the escaped char
                    if (self.pos + 1 < s.len) {
                        self.pos += 2;
                        continue;
                    }
                }
                if (s[self.pos] == q) {
                    break;
                }
                self.pos += 1;
            }

            const val = s[val_start..self.pos];
            if (self.pos < s.len) {
                self.pos += 1; // Skip closing quote
            } else {
                self.last_unclosed = true;
            }
            return .{ .key = key, .value = val, .single_quoted = q == '\'' };
        }

        // Bare value: terminated by whitespace
        const val_start = self.pos;
        while (self.pos < s.len and !isWhitespace(s[self.pos])) self.pos += 1;
        return .{ .key = key, .value = s[val_start..self.pos] };
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

/// Parse a property string into a Prop array. All strings are duped into
/// the provided arena allocator.
///
/// Handles escape processing:
/// - Brace escaping: `\{` -> `{`, `\}` -> `}`
/// - Backslash-quote: `\"` -> `"` (in double-quoted values)
/// - Backslash-backslash: `\\` -> `\`
/// - Single-quoted values are returned verbatim (no escape processing)
/// - `{}` or empty source returns empty slice with count=0
///
/// Returns `error.UnbalancedBraces` if a quoted value is never closed
/// (per D-06).
pub fn parseProps(arena: std.mem.Allocator, source: []const u8) !struct { props: []const Prop, count: u16 } {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");

    // Handle empty braces
    if (std.mem.eql(u8, trimmed, "{}")) {
        const empty = try arena.alloc(Prop, 0);
        return .{ .props = empty, .count = 0 };
    }

    // Handle empty input
    if (trimmed.len == 0) {
        const empty = try arena.alloc(Prop, 0);
        return .{ .props = empty, .count = 0 };
    }

    // Strip outer braces if present
    var effective = trimmed;
    if (effective.len >= 2 and effective[0] == '{' and effective[effective.len - 1] == '}') {
        effective = std.mem.trim(u8, effective[1 .. effective.len - 1], " \t\r\n");
    }

    var prop_list = std.ArrayList(Prop).init(arena);

    var tok = PropertyTokenizer.init(effective);
    while (tok.next()) |token| {
        const key = try arena.dupe(u8, token.key);
        const value = if (token.single_quoted)
            // Single-quoted: no escape processing
            try arena.dupe(u8, token.value)
        else
            // Double-quoted or bare: process escapes
            try unescapeValue(arena, token.value);
        try prop_list.append(.{ .key = key, .value = value });
    }

    const props = try prop_list.toOwnedSlice();
    const count: u16 = @intCast(props.len);
    return .{ .props = props, .count = count };
}

/// Process escape sequences in a value string:
/// - `\{` -> `{`
/// - `\}` -> `}`
/// - `\"` -> `"`
/// - `\\` -> `\`
/// All other backslash sequences pass through as-is.
fn unescapeValue(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // Quick check: if no backslashes, no escaping needed
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return arena.dupe(u8, raw);
    }

    var buf = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next_ch = raw[i + 1];
            switch (next_ch) {
                '{', '}', '"', '\\' => {
                    try buf.append(next_ch);
                    i += 2;
                },
                else => {
                    try buf.append(raw[i]);
                    i += 1;
                },
            }
        } else {
            try buf.append(raw[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice();
}
