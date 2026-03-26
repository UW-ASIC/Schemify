// test_props.zig - Tests for PropertyTokenizer and parseProps.
//
// Covers all XSchem property escaping variants: bare, quoted, brace-escaped,
// backslash-escaped, single-quoted, multi-line quoted, empty braces.

const std = @import("std");
const testing = std.testing;
const props_mod = @import("props");
const PropertyTokenizer = props_mod.PropertyTokenizer;
const parseProps = props_mod.parseProps;

// ── Test helpers ─────────────────────────────────────────────────────────

fn expectProp(result: anytype, idx: usize, expected_key: []const u8, expected_value: []const u8) !void {
    if (idx >= result.len) {
        std.debug.print("Expected prop at index {d} but only got {d} props\n", .{ idx, result.len });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(expected_key, result[idx].key);
    try testing.expectEqualStrings(expected_value, result[idx].value);
}

// All parseProps tests use an ArenaAllocator backed by testing.allocator.
// This matches the real usage pattern (arena-per-stage) and avoids leak
// detection noise from individual string allocations.

// ── Test 1: bare value ───────────────────────────────────────────────────

test "bare value name=R1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "name=R1");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "name", "R1");
}

// ── Test 2: quoted value ─────────────────────────────────────────────────

test "quoted value value=\"1k\"" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "value=\"1k\"");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "1k");
}

// ── Test 3: brace-escaped value ──────────────────────────────────────────

test "brace-escaped value=\\{hello\\}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "value=\\{hello\\}");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "{hello}");
}

// ── Test 4: backslash-escaped quote in quoted value ──────────────────────

test "backslash-escaped quote value=\"line1\\\"line2\"" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "value=\"line1\\\"line2\"");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "line1\"line2");
}

// ── Test 5: single-quoted value (no escape processing) ───────────────────

test "single-quoted value='raw\\nstuff'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "value='raw\\nstuff'");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "raw\\nstuff");
}

// ── Test 6: empty braces ─────────────────────────────────────────────────

test "empty braces {}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "{}");
    try testing.expectEqual(@as(u16, 0), result.count);
}

// ── Test 7: multiple props ───────────────────────────────────────────────

test "multiple props name=R1 value=1k model=res" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "name=R1 value=1k model=res");
    try testing.expectEqual(@as(u16, 3), result.count);
    try expectProp(result.props, 0, "name", "R1");
    try expectProp(result.props, 1, "value", "1k");
    try expectProp(result.props, 2, "model", "res");
}

// ── Test 8: multi-line quoted value with embedded newline ────────────────

test "multi-line quoted value with embedded newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "value=\"line1\nline2\"";
    const result = try parseProps(arena.allocator(), input);
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "line1\nline2");
}

// ── Test 9: space in quoted value ────────────────────────────────────────

test "space in quoted value lab=\"net name\"" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "lab=\"net name\"");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "lab", "net name");
}

// ── Test 10: backslash-brace mixed ───────────────────────────────────────

test "backslash-brace mixed value=test\\{inner\\}end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "value=test\\{inner\\}end");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "test{inner}end");
}

// ── Additional edge cases ────────────────────────────────────────────────

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "");
    try testing.expectEqual(@as(u16, 0), result.count);
}

test "whitespace only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "   \t  ");
    try testing.expectEqual(@as(u16, 0), result.count);
}

test "PropertyTokenizer bare iteration" {
    var tok = PropertyTokenizer.init("name=R1 value=1k");
    const first = tok.next().?;
    try testing.expectEqualStrings("name", first.key);
    try testing.expectEqualStrings("R1", first.value);
    const second = tok.next().?;
    try testing.expectEqualStrings("value", second.key);
    try testing.expectEqualStrings("1k", second.value);
    try testing.expect(tok.next() == null);
}

test "backslash-backslash in quoted value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseProps(arena.allocator(), "value=\"path\\\\dir\"");
    try testing.expectEqual(@as(u16, 1), result.count);
    try expectProp(result.props, 0, "value", "path\\dir");
}
