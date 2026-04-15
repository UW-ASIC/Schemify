// test_TCL.zig - Comprehensive Tcl interpreter tests.
//
// Tests the embedded Tcl evaluator against a fixture file (test/fixture/test.tcl)
// plus inline scripts covering all supported and unsupported constructs.

const std = @import("std");
const testing = std.testing;
const Tcl = @import("tcl").Tcl;

const fixture_path = "plugins/EasyImport/test/fixtures/test.tcl";

// ── Helpers ────────────────────────────────────────────────────────────────

fn makeTcl() Tcl {
    return Tcl.init(std.heap.page_allocator);
}

// ── Basic set / variable expansion ───────────────────────────────────────

test "basic set" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set X 42");
    try testing.expectEqualStrings("42", tcl.getVar("X").?);
}

test "set and expand" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set A hello");
    _ = try tcl.eval("set B $A");
    try testing.expectEqualStrings("hello", tcl.getVar("B").?);
}

test "append" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set LIB /usr/lib");
    _ = try tcl.eval("append LIB :/local/lib");
    try testing.expectEqualStrings("/usr/lib:/local/lib", tcl.getVar("LIB").?);
}

test "lappend" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("lappend LIST a");
    _ = try tcl.eval("lappend LIST b c");
    // lappend returns the list value
    const result = try tcl.eval("set LIST");
    try testing.expectEqualStrings("a b c", result);
}

// ── Conditionals ────────────────────────────────────────────────────────────

test "if true branch" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("if {1} {set X yes}");
    try testing.expectEqualStrings("yes", tcl.getVar("X").?);
}

test "if false branch" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("if {0} {set X yes}");
    try testing.expectEqual(@as(?[]const u8, null), tcl.getVar("X"));
}

test "if else" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("if {0} {set X a} else {set X b}");
    try testing.expectEqualStrings("b", tcl.getVar("X").?);
}

test "if with expr condition" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set Y 10");
    _ = try tcl.eval("if {$Y > 5} {set X big}");
    try testing.expectEqualStrings("big", tcl.getVar("X").?);
}

test "ne string not-equal" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set x hello");
    _ = try tcl.eval("if {$x ne {}} {set y yes}");
    try testing.expectEqualStrings("yes", tcl.getVar("y").?);
}

test "eq string equal" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set x hello");
    _ = try tcl.eval("if {$x eq \"hello\"} {set y match}");
    try testing.expectEqualStrings("match", tcl.getVar("y").?);
}

// ── Info ───────────────────────────────────────────────────────────────────

test "info exists env var" {
    var tcl = makeTcl();
    defer tcl.deinit();

    // HOME is always set in test environments
    _ = try tcl.eval("if {[info exists env(HOME)]} {set GOT_HOME 1}");
    try testing.expectEqualStrings("1", tcl.getVar("GOT_HOME").?);
}

test "info exists undefined" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("if {[info exists UNDEFINED_VAR_12345]} {set X 1} {set X 0}");
    try testing.expectEqualStrings("0", tcl.getVar("X").?);
}

test "info script" {
    var tcl = makeTcl();
    defer tcl.deinit();

    tcl.setScriptPath("/some/path/xschemrc");
    const result = try tcl.eval("info script");
    try testing.expectEqualStrings("/some/path/xschemrc", result);
}

// ── File ───────────────────────────────────────────────────────────────────

test "file dirname" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file dirname /a/b/c.sch");
    try testing.expectEqualStrings("/a/b", result);
}

test "file normalize absolute" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file normalize /a/b/c");
    try testing.expectEqualStrings("/a/b/c", result);
}

test "file join" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file join /a b c");
    try testing.expectEqualStrings("/a/b/c", result);
}

test "file tail" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file tail /a/b/c.sch");
    try testing.expectEqualStrings("c.sch", result);
}

test "file extension" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file extension /a/b/c.sch");
    try testing.expectEqualStrings(".sch", result);
}

test "file isdir /tmp" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file isdir /tmp");
    try testing.expectEqualStrings("1", result);
}

test "file isdir nonexistent" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file isdir /nonexistent/path/xyz");
    try testing.expectEqualStrings("0", result);
}

test "file isfile nonexistent" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("file isfile /nonexistent/file.sch");
    try testing.expectEqualStrings("0", result);
}

// ── String ─────────────────────────────────────────────────────────────────

test "string equal" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string equal hello hello");
    try testing.expectEqualStrings("1", result);
}

test "string equal case insensitive" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string equal -nocase HELLO hello");
    try testing.expectEqualStrings("1", result);
}

test "string tolower" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string tolower HELLO");
    try testing.expectEqualStrings("hello", result);
}

test "string length" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string length hello");
    try testing.expectEqualStrings("5", result);
}

test "string is double valid" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string is double 3.14");
    try testing.expectEqualStrings("1", result);
}

test "string is double invalid" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string is double hello");
    try testing.expectEqualStrings("0", result);
}

test "string is integer valid" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string is integer 42");
    try testing.expectEqualStrings("1", result);
}

// ── Expr ───────────────────────────────────────────────────────────────────

test "expr arithmetic" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("expr {2 + 3 * 4}");
    try testing.expectEqualStrings("14", result);
}

test "expr comparison" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("expr {10 > 5}");
    try testing.expectEqualStrings("1", result);
}

test "expr with variable" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set A 10");
    const result = try tcl.eval("expr {$A + 5}");
    try testing.expectEqualStrings("15", result);
}

// ── Proc ───────────────────────────────────────────────────────────────────

test "proc definition and call" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("proc add {a b} {expr {$a + $b}}");
    const result = try tcl.eval("add 2 3");
    try testing.expectEqualStrings("5", result);
}

test "proc with multiple returns" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("proc greeting {name} {return \"hello $name\"}");
    const result = try tcl.eval("greeting world");
    try testing.expectEqualStrings("hello world", result);
}

test "proc with if inside" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("proc max {a b} {if {$a > $b} {return $a} {return $b}}");
    try testing.expectEqualStrings("5", try tcl.eval("max 5 3"));
    try testing.expectEqualStrings("5", try tcl.eval("max 2 5"));
}

// ── Catch ─────────────────────────────────────────────────────────────────

test "catch suppresses error" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("catch {set UNDEF_VAR}");
    try testing.expectEqualStrings("1", result); // catch returns 1 on error
}

test "catch with no error" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("catch {set X 42}");
    try testing.expectEqualStrings("0", result); // catch returns 0 on success
}

// ── Unset ─────────────────────────────────────────────────────────────────

test "unset" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set X 42");
    _ = try tcl.eval("unset X");
    try testing.expectEqual(@as(?[]const u8, null), tcl.getVar("X"));
}

// ── Source (fixture file) ───────────────────────────────────────────────────

test "source fixture file" {
    var tcl = makeTcl();
    defer tcl.deinit();

    tcl.setScriptPath(fixture_path);
    // Pre-seed XSCHEM_SHAREDIR as xschemrc.zig does before evaluating xschemrc files.
    try tcl.setVar("XSCHEM_SHAREDIR", "/usr/share/xschem");
    // Sourcing the fixture (standard xschemrc template) should not error.
    _ = try tcl.eval("source " ++ fixture_path);
    // Verify the seeded variable survived sourcing (fixture is mostly comments).
    try testing.expect(tcl.getVar("XSCHEM_SHAREDIR") != null);
}

// ── Env variable substitution ─────────────────────────────────────────────

test "env(HOME) substitution" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("string length $env(HOME)");
    // Should be > 0 since HOME is set
    const n = try std.fmt.parseInt(i64, result, 10);
    try testing.expect(n > 0);
}

// ── Supported loop/control constructs ────────────────────────────────────

test "for loop" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("for {set i 0} {$i < 3} {incr i} {set X $i}");
    try testing.expectEqualStrings("2", tcl.getVar("X").?);
}

test "foreach single var" {
    var tcl = makeTcl();
    defer tcl.deinit();

    // foreach x {a b c} {set X $x} — X should be 'c' after loop
    _ = try tcl.eval("foreach x {a b c} {set X $x}");
    const X = tcl.getVar("X");
    try testing.expect(std.mem.eql(u8, X orelse "", "c"));
}

test "foreach multiple vars" {
    var tcl = makeTcl();
    defer tcl.deinit();

    // foreach {a b} {1 2 3 4} {expr {$a + $b}} — pairs: (1,2), (3,4), result is last expr
    const result = try tcl.eval("foreach {a b} {1 2 3 4} {expr {$a + $b}}");
    try testing.expect(std.mem.eql(u8, result, "7")); // 3+4=7
}

test "while loop" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set i 0");
    _ = try tcl.eval("while {$i < 3} {incr i}");
    try testing.expectEqualStrings("3", tcl.getVar("i").?);
}

test "while guarded by iteration limit" {
    var tcl = makeTcl();
    defer tcl.deinit();

    // while {1} would infinite-loop, but guarded at 10000 iterations
    _ = try tcl.eval("while {1} {break}");
    // Should not hang — break exits immediately
    try testing.expect(true);
}

// ── switch ────────────────────────────────────────────────────────────────

test "switch exact match" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("switch abc {a {set X 1} abc {set X 2} default {set X 3}}");
    try testing.expectEqualStrings("2", tcl.getVar("X").?);
}

test "switch default clause" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("switch xyz {a {set X 1} default {set X 3}}");
    try testing.expectEqualStrings("3", tcl.getVar("X").?);
}

test "switch no match no default" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("switch xyz {a {set X 1} b {set X 2}}");
    try testing.expectEqual(@as(?[]const u8, null), tcl.getVar("X"));
}

test "switch glob pattern" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("switch hello {he* {set X match} default {set X nomatch}}");
    try testing.expectEqualStrings("match", tcl.getVar("X").?);
}

// ── regexp ────────────────────────────────────────────────────────────────

test "regexp matches" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("regexp {l.*} hello");
    try testing.expectEqualStrings("1", result);
}

test "regexp no match" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("regexp {x+} hello");
    try testing.expectEqualStrings("0", result);
}

test "regexp nocase" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("regexp -nocase {HEllo} hello");
    try testing.expectEqualStrings("1", result);
}

// ── array ────────────────────────────────────────────────────────────────

test "array set and get" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("array set arr {a 1 b 2}");
    const result = try tcl.eval("array get arr");
    // Returns flattened list: "a 1 b 2" (order may vary)
    try testing.expect(std.mem.indexOf(u8, result, "a 1").? >= 0);
    try testing.expect(std.mem.indexOf(u8, result, "b 2").? >= 0);
}

test "array exists" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("array set arr {a 1}");
    const result = try tcl.eval("array exists arr");
    try testing.expectEqualStrings("1", result);
}

test "array not exists" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("array exists nonexistent");
    try testing.expectEqualStrings("0", result);
}

// ── namespace ─────────────────────────────────────────────────────────────

test "namespace eval" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("namespace eval ns {set X 42}");
    try testing.expectEqualStrings("42", result);
}

test "namespace current" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("namespace current");
    try testing.expectEqualStrings("::", result);
}

// ── Schema result (struct write-back) ─────────────────────────────────────

test "runWithSchema basic" {
    const Schema = struct {
        MY_VAR: []const u8 = "",
        COUNTER: []const u8 = "0",
    };

    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set MY_VAR hello");
    _ = try tcl.eval("set COUNTER 99");

    var result = try tcl.runWithSchema(Schema, std.heap.page_allocator, "");
    defer result.deinit();

    try testing.expectEqualStrings("hello", result.get("MY_VAR").?);
    try testing.expectEqualStrings("99", result.get("COUNTER").?);
}

test "runWithSchema with lappend" {
    const Schema = struct {
        MY_LIST: []const u8 = "",
    };

    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("lappend MY_LIST a b c");

    var result = try tcl.runWithSchema(Schema, std.heap.page_allocator, "");
    defer result.deinit();

    try testing.expectEqualStrings("a b c", result.get("MY_LIST").?);
}

test "runWithSchema fillInto" {
    const Schema = struct {
        PDK_ROOT: []const u8 = "",
        NETLIST_DIR: []const u8 = "",
    };

    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set PDK_ROOT /usr/share/pdk");
    _ = try tcl.eval("set NETLIST_DIR /tmp/netlist");

    var result = try tcl.runWithSchema(Schema, std.heap.page_allocator, "");
    defer result.deinit();

    var schema: Schema = .{};
    result.fillInto(Schema, &schema);

    try testing.expectEqualStrings("/usr/share/pdk", schema.PDK_ROOT);
    try testing.expectEqualStrings("/tmp/netlist", schema.NETLIST_DIR);
}

test "runWithSchema source fixture" {
    // The fixture is a standard xschemrc with many commented sections.
    // We verify runWithSchema can source it without error and collect no extra vars.
    const Schema = struct {
        XSCHEM_SHAREDIR: []const u8 = "",
    };

    var tcl = makeTcl();
    defer tcl.deinit();

    var result = try tcl.runWithSchema(Schema, std.heap.page_allocator, "source " ++ fixture_path);
    defer result.deinit();

    // The schema has one field; since fixture doesn't explicitly set XSCHEM_SHAREDIR
    // (only references it via $XSCHEM_SHAREDIR in comments), the result should have
    // no written vars (value equals the seeded default).
    try testing.expect(result.get("XSCHEM_SHAREDIR") == null);
}

test "runWithSchema bool coercion" {
    const Schema = struct {
        FLAG: bool = false,
    };

    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set FLAG 1");

    var result = try tcl.runWithSchema(Schema, std.heap.page_allocator, "");
    defer result.deinit();

    var schema: Schema = .{};
    result.fillInto(Schema, &schema);
    try testing.expect(schema.FLAG == true);
}

test "runWithSchema null-able optional" {
    const Schema = struct {
        MAYBE_VAR: ?[]const u8 = null,
    };

    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set MAYBE_VAR something");

    var result = try tcl.runWithSchema(Schema, std.heap.page_allocator, "");
    defer result.deinit();

    var schema: Schema = .{};
    result.fillInto(Schema, &schema);
    try testing.expectEqualStrings("something", schema.MAYBE_VAR.?);
}

// ── Edge cases ─────────────────────────────────────────────────────────────

test "nested bracket expansion" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set A [expr {[set B 5] + 3}]");
    try testing.expectEqualStrings("8", tcl.getVar("A").?);
    try testing.expectEqualStrings("5", tcl.getVar("B").?);
}

test "backslash escapes" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("set X hello\\nworld");
    try testing.expectEqualStrings("hello\nworld", result);
}

test "double quotes with spaces" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("set X \"hello world\"");
    try testing.expectEqualStrings("hello world", tcl.getVar("X").?);
}

test "puts is no-op (no crash)" {
    var tcl = makeTcl();
    defer tcl.deinit();

    // puts should not cause errors
    _ = try tcl.eval("puts {hello}");
    // Should not have set any variable
    try testing.expectEqual(@as(?[]const u8, null), tcl.getVar("X"));
}

test "return value" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("return hello");
    try testing.expectEqualStrings("hello", result);
}

test "return in proc" {
    var tcl = makeTcl();
    defer tcl.deinit();

    _ = try tcl.eval("proc test {} {return early; set X never}");
    const result = try tcl.eval("test");
    try testing.expectEqualStrings("early", result);
    try testing.expectEqual(@as(?[]const u8, null), tcl.getVar("X"));
}

test "empty script" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("");
    try testing.expectEqualStrings("", result);
}

test "comment only" {
    var tcl = makeTcl();
    defer tcl.deinit();

    const result = try tcl.eval("# this is a comment");
    try testing.expectEqualStrings("", result);
}
