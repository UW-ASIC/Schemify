const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SpanKind = enum {
    text,
    bold,
    italic,
    code,
    link,
};

pub const Span = struct {
    kind: SpanKind = .text,
    text: []const u8 = "",
    href: []const u8 = "",
};

pub const BlockKind = enum {
    heading1,
    heading2,
    heading3,
    paragraph,
    code_block,
    list_item,
    blockquote,
    horizontal_rule,
};

pub const Block = struct {
    kind: BlockKind = .paragraph,
    raw: []const u8 = "",
    spans: []const Span = &.{},
    language: []const u8 = "",
};

/// Parse Markdown input into an array of Blocks.
/// All output slices point into the input buffer (zero-copy).
/// Arena is used for the Block and Span arrays only.
pub fn parse(arena: Allocator, input: []const u8) []const Block {
    var blocks: std.ArrayList(Block) = .{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_code_block = false;
    var code_start: usize = 0;
    var code_lang: []const u8 = "";
    var para_start: ?usize = null;
    var para_end: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_code_block) {
                const fence_offset = @intFromPtr(trimmed.ptr) - @intFromPtr(input.ptr);
                const code_content = if (code_start < fence_offset)
                    input[code_start..fence_offset]
                else
                    "";
                blocks.append(arena, .{
                    .kind = .code_block,
                    .raw = std.mem.trimRight(u8, code_content, "\n"),
                    .language = code_lang,
                }) catch {};
                in_code_block = false;
                continue;
            } else {
                flushParagraph(&blocks, arena, input, &para_start, para_end);
                in_code_block = true;
                code_lang = if (trimmed.len > 3) trimmed[3..] else "";
                const line_end = @intFromPtr(trimmed.ptr) + trimmed.len - @intFromPtr(input.ptr);
                code_start = if (line_end < input.len) line_end + 1 else input.len;
                continue;
            }
        }

        if (in_code_block) continue;

        if (trimmed.len == 0) {
            flushParagraph(&blocks, arena, input, &para_start, para_end);
            continue;
        }

        if (isHorizontalRule(trimmed)) {
            flushParagraph(&blocks, arena, input, &para_start, para_end);
            blocks.append(arena, .{ .kind = .horizontal_rule, .raw = trimmed }) catch {};
            continue;
        }

        if (trimmed.len > 0 and trimmed[0] == '#') {
            flushParagraph(&blocks, arena, input, &para_start, para_end);
            const level = countPrefix(trimmed, '#');
            if (level >= 1 and level <= 3 and level < trimmed.len and trimmed[level] == ' ') {
                const content = std.mem.trimLeft(u8, trimmed[level..], " ");
                const kind: BlockKind = switch (level) {
                    1 => .heading1,
                    2 => .heading2,
                    3 => .heading3,
                    else => .paragraph,
                };
                blocks.append(arena, .{
                    .kind = kind,
                    .raw = content,
                    .spans = parseInlineSpans(arena, content),
                }) catch {};
                continue;
            }
        }

        if (trimmed.len > 1 and trimmed[0] == '>' and trimmed[1] == ' ') {
            flushParagraph(&blocks, arena, input, &para_start, para_end);
            const content = trimmed[2..];
            blocks.append(arena, .{
                .kind = .blockquote,
                .raw = content,
                .spans = parseInlineSpans(arena, content),
            }) catch {};
            continue;
        }

        if (isListItem(trimmed)) |content| {
            flushParagraph(&blocks, arena, input, &para_start, para_end);
            blocks.append(arena, .{
                .kind = .list_item,
                .raw = content,
                .spans = parseInlineSpans(arena, content),
            }) catch {};
            continue;
        }

        const line_start = @intFromPtr(trimmed.ptr) - @intFromPtr(input.ptr);
        if (para_start == null) para_start = line_start;
        para_end = line_start + trimmed.len;
    }

    flushParagraph(&blocks, arena, input, &para_start, para_end);

    return blocks.toOwnedSlice(arena) catch &.{};
}

fn flushParagraph(blocks: *std.ArrayList(Block), arena: Allocator, input: []const u8, start: *?usize, end: usize) void {
    if (start.*) |s| {
        if (s <= end and end <= input.len) {
            const raw = std.mem.trim(u8, input[s..end], " \t\r\n");
            if (raw.len > 0) {
                blocks.append(arena, .{
                    .kind = .paragraph,
                    .raw = raw,
                    .spans = parseInlineSpans(arena, raw),
                }) catch {};
            }
        }
        start.* = null;
    }
}

fn countPrefix(s: []const u8, ch: u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ch) n += 1;
    return n;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    var count: usize = 0;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |c| {
        if (c == ch) count += 1 else if (c != ' ') return false;
    }
    return count >= 3;
}

fn isListItem(line: []const u8) ?[]const u8 {
    if (line.len >= 2) {
        if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
            return line[2..];
        }
    }
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') {
        return line[i + 2 ..];
    }
    return null;
}

fn parseInlineSpans(arena: Allocator, text: []const u8) []const Span {
    var spans: std.ArrayList(Span) = .{};
    var pos: usize = 0;
    var text_start: usize = 0;

    while (pos < text.len) {
        // Bold **text**
        if (pos + 1 < text.len and text[pos] == '*' and text[pos + 1] == '*') {
            if (pos > text_start) {
                spans.append(arena, .{ .kind = .text, .text = text[text_start..pos] }) catch {};
            }
            const end = std.mem.indexOfPos(u8, text, pos + 2, "**") orelse {
                pos += 2;
                text_start = pos;
                continue;
            };
            spans.append(arena, .{ .kind = .bold, .text = text[pos + 2 .. end] }) catch {};
            pos = end + 2;
            text_start = pos;
            continue;
        }

        // Italic *text*
        if (text[pos] == '*' and (pos + 1 >= text.len or text[pos + 1] != '*')) {
            if (pos > text_start) {
                spans.append(arena, .{ .kind = .text, .text = text[text_start..pos] }) catch {};
            }
            const end = std.mem.indexOfScalarPos(u8, text, pos + 1, '*') orelse {
                pos += 1;
                text_start = pos;
                continue;
            };
            spans.append(arena, .{ .kind = .italic, .text = text[pos + 1 .. end] }) catch {};
            pos = end + 1;
            text_start = pos;
            continue;
        }

        // Inline code `text`
        if (text[pos] == '`') {
            if (pos > text_start) {
                spans.append(arena, .{ .kind = .text, .text = text[text_start..pos] }) catch {};
            }
            const end = std.mem.indexOfScalarPos(u8, text, pos + 1, '`') orelse {
                pos += 1;
                text_start = pos;
                continue;
            };
            spans.append(arena, .{ .kind = .code, .text = text[pos + 1 .. end] }) catch {};
            pos = end + 1;
            text_start = pos;
            continue;
        }

        // Link [text](url)
        if (text[pos] == '[') {
            const close_bracket = std.mem.indexOfScalarPos(u8, text, pos + 1, ']') orelse {
                pos += 1;
                continue;
            };
            if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse {
                    pos += 1;
                    continue;
                };
                if (pos > text_start) {
                    spans.append(arena, .{ .kind = .text, .text = text[text_start..pos] }) catch {};
                }
                spans.append(arena, .{
                    .kind = .link,
                    .text = text[pos + 1 .. close_bracket],
                    .href = text[close_bracket + 2 .. close_paren],
                }) catch {};
                pos = close_paren + 1;
                text_start = pos;
                continue;
            }
        }

        pos += 1;
    }

    if (text_start < text.len) {
        spans.append(arena, .{ .kind = .text, .text = text[text_start..] }) catch {};
    }

    return spans.toOwnedSlice(arena) catch &.{};
}

// -- Tests --

test "parse headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "# Hello\n## World\n### Three");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(BlockKind.heading1, blocks[0].kind);
    try std.testing.expectEqual(BlockKind.heading2, blocks[1].kind);
    try std.testing.expectEqual(BlockKind.heading3, blocks[2].kind);
}

test "parse paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "Hello world\nSecond line");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
}

test "parse code block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "```python\nprint('hi')\n```");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.code_block, blocks[0].kind);
    try std.testing.expectEqualStrings("python", blocks[0].language);
}

test "parse inline bold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "Hello **bold** world");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].spans.len >= 3);
    try std.testing.expectEqual(SpanKind.bold, blocks[0].spans[1].kind);
    try std.testing.expectEqualStrings("bold", blocks[0].spans[1].text);
}

test "parse list items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "- item 1\n- item 2\n* item 3");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    for (blocks) |b| try std.testing.expectEqual(BlockKind.list_item, b.kind);
}

test "parse blockquote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "> quoted text");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.blockquote, blocks[0].kind);
    try std.testing.expectEqualStrings("quoted text", blocks[0].raw);
}

test "parse horizontal rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "---");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.horizontal_rule, blocks[0].kind);
}

test "parse inline link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "See [click here](https://example.com) now");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const spans = blocks[0].spans;
    try std.testing.expect(spans.len >= 3);
    try std.testing.expectEqual(SpanKind.link, spans[1].kind);
    try std.testing.expectEqualStrings("click here", spans[1].text);
    try std.testing.expectEqualStrings("https://example.com", spans[1].href);
}

test "parse inline code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "Use `foo()` here");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const spans = blocks[0].spans;
    try std.testing.expect(spans.len >= 3);
    try std.testing.expectEqual(SpanKind.code, spans[1].kind);
    try std.testing.expectEqualStrings("foo()", spans[1].text);
}

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), blocks.len);
}
