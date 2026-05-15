const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        eof,
        newline,
        semicolon,
        whitespace,
        word,
        quoted_string,
        braced_string,
        variable,
        bracket_cmd,
        comment,
    };
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize,
    at_command_start: bool,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .pos = 0, .at_command_start = true };
    }

    pub fn slice(self: *const Tokenizer, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }

    pub fn next(self: *Tokenizer) Token {
        // Handle backslash-newline continuation: consume `\<newline>` and following whitespace
        while (self.pos + 1 < self.source.len and
            self.source[self.pos] == '\\' and self.source[self.pos + 1] == '\n')
        {
            self.pos += 2;
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
            {
                self.pos += 1;
            }
        }

        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .start = self.source.len, .end = self.source.len };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '\n' => {
                self.pos += 1;
                self.at_command_start = true;
                return .{ .tag = .newline, .start = start, .end = self.pos };
            },
            ';' => {
                self.pos += 1;
                self.at_command_start = true;
                return .{ .tag = .semicolon, .start = start, .end = self.pos };
            },
            ' ', '\t', '\r' => {
                self.pos += 1;
                while (self.pos < self.source.len) {
                    const n = self.source[self.pos];
                    if (n != ' ' and n != '\t' and n != '\r') break;
                    self.pos += 1;
                }
                return .{ .tag = .whitespace, .start = start, .end = self.pos };
            },
            '#' => {
                if (self.at_command_start) {
                    self.pos += 1;
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        // Handle backslash-newline continuation within comments
                        if (self.source[self.pos] == '\\' and
                            self.pos + 1 < self.source.len and
                            self.source[self.pos + 1] == '\n')
                        {
                            self.pos += 2;
                            continue;
                        }
                        self.pos += 1;
                    }
                    return .{ .tag = .comment, .start = start, .end = self.pos };
                }
                return self.readWord(start);
            },
            '"' => {
                self.pos += 1;
                while (self.pos < self.source.len) {
                    if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                        self.pos += 2;
                        continue;
                    }
                    if (self.source[self.pos] == '"') {
                        self.pos += 1;
                        break;
                    }
                    self.pos += 1;
                }
                self.at_command_start = false;
                return .{ .tag = .quoted_string, .start = start, .end = self.pos };
            },
            '{' => {
                self.pos += 1;
                var depth: usize = 1;
                while (self.pos < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                        self.pos += 2;
                        continue;
                    }
                    if (self.source[self.pos] == '{') {
                        depth += 1;
                    } else if (self.source[self.pos] == '}') {
                        depth -= 1;
                    }
                    if (depth > 0) self.pos += 1;
                }
                if (self.pos < self.source.len) self.pos += 1; // consume closing '}'
                self.at_command_start = false;
                return .{ .tag = .braced_string, .start = start, .end = self.pos };
            },
            '$' => {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    // ${name} form
                    self.pos += 1;
                    while (self.pos < self.source.len and self.source[self.pos] != '}') {
                        self.pos += 1;
                    }
                    if (self.pos < self.source.len) self.pos += 1;
                } else {
                    // $name or $env(NAME) form
                    while (self.pos < self.source.len) {
                        const n = self.source[self.pos];
                        if (std.ascii.isAlphanumeric(n) or n == '_' or n == ':') {
                            self.pos += 1;
                            continue;
                        }
                        if (n == '(' and self.pos > start + 1) {
                            // $env(NAME) -- consume through closing paren
                            self.pos += 1;
                            while (self.pos < self.source.len and self.source[self.pos] != ')') {
                                self.pos += 1;
                            }
                            if (self.pos < self.source.len) self.pos += 1;
                        }
                        break;
                    }
                }
                self.at_command_start = false;
                return .{ .tag = .variable, .start = start, .end = self.pos };
            },
            '[' => {
                self.pos += 1;
                var depth: usize = 1;
                while (self.pos < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                        self.pos += 2;
                        continue;
                    }
                    if (self.source[self.pos] == '[') {
                        depth += 1;
                    } else if (self.source[self.pos] == ']') {
                        depth -= 1;
                    }
                    if (depth > 0) self.pos += 1;
                }
                if (self.pos < self.source.len) self.pos += 1;
                self.at_command_start = false;
                return .{ .tag = .bracket_cmd, .start = start, .end = self.pos };
            },
            else => return self.readWord(start),
        }
    }

    fn readWord(self: *Tokenizer, start: usize) Token {
        while (self.pos < self.source.len) {
            const n = self.source[self.pos];
            if (n == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2;
                continue;
            }
            if (isWordBoundary(n)) break;
            self.pos += 1;
        }
        self.at_command_start = false;
        return .{ .tag = .word, .start = start, .end = self.pos };
    }

    fn isWordBoundary(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\r', '\n', ';', '{', '}', '[', ']', '"', '$' => true,
            else => false,
        };
    }
};

test "tokenizer: basic word and whitespace" {
    var t = Tokenizer.init("set x 42");
    const t1 = t.next();
    try std.testing.expectEqual(Token.Tag.word, t1.tag);
    try std.testing.expectEqualStrings("set", t.slice(t1));

    const t2 = t.next();
    try std.testing.expectEqual(Token.Tag.whitespace, t2.tag);

    const t3 = t.next();
    try std.testing.expectEqual(Token.Tag.word, t3.tag);
    try std.testing.expectEqualStrings("x", t.slice(t3));
}

test "tokenizer: braced string with depth tracking" {
    var t = Tokenizer.init("{hello {world}}");
    const tok = t.next();
    try std.testing.expectEqual(Token.Tag.braced_string, tok.tag);
    try std.testing.expectEqualStrings("{hello {world}}", t.slice(tok));
}

test "tokenizer: variable references" {
    var t = Tokenizer.init("$foo ${bar} $env(HOME)");
    const t1 = t.next();
    try std.testing.expectEqual(Token.Tag.variable, t1.tag);
    try std.testing.expectEqualStrings("$foo", t.slice(t1));

    _ = t.next(); // whitespace
    const t2 = t.next();
    try std.testing.expectEqual(Token.Tag.variable, t2.tag);
    try std.testing.expectEqualStrings("${bar}", t.slice(t2));

    _ = t.next(); // whitespace
    const t3 = t.next();
    try std.testing.expectEqual(Token.Tag.variable, t3.tag);
    try std.testing.expectEqualStrings("$env(HOME)", t.slice(t3));
}

test "tokenizer: bracket command with nesting" {
    var t = Tokenizer.init("[file dirname [file normalize x]]");
    const tok = t.next();
    try std.testing.expectEqual(Token.Tag.bracket_cmd, tok.tag);
    try std.testing.expectEqualStrings("[file dirname [file normalize x]]", t.slice(tok));
}

test "tokenizer: comment at command position" {
    var t = Tokenizer.init("# this is a comment\nset x 1");
    const t1 = t.next();
    try std.testing.expectEqual(Token.Tag.comment, t1.tag);
    const t2 = t.next();
    try std.testing.expectEqual(Token.Tag.newline, t2.tag);
    const t3 = t.next();
    try std.testing.expectEqual(Token.Tag.word, t3.tag);
    try std.testing.expectEqualStrings("set", t.slice(t3));
}

test "tokenizer: quoted string" {
    var t = Tokenizer.init("\"hello \\\"world\\\"\"");
    const tok = t.next();
    try std.testing.expectEqual(Token.Tag.quoted_string, tok.tag);
}

test "tokenizer: backslash-newline continuation" {
    var t = Tokenizer.init("set x \\\n  42");
    const t1 = t.next();
    try std.testing.expectEqual(Token.Tag.word, t1.tag);
    try std.testing.expectEqualStrings("set", t.slice(t1));
    _ = t.next(); // whitespace
    const t2 = t.next();
    try std.testing.expectEqual(Token.Tag.word, t2.tag);
    try std.testing.expectEqualStrings("x", t.slice(t2));
    _ = t.next(); // whitespace
    const t3 = t.next();
    try std.testing.expectEqual(Token.Tag.word, t3.tag);
    try std.testing.expectEqualStrings("42", t.slice(t3));
}
