const std = @import("std");
const tcl_mod = @import("../src/TCL/root.zig");

test "set variable and retrieve" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set VAR value");
    try std.testing.expectEqualStrings("value", tcl.getVar("VAR").?);
}

test "append to variable" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set VAR initial");
    _ = try tcl.eval("append VAR :path");
    try std.testing.expectEqualStrings("initial:path", tcl.getVar("VAR").?);
}

test "lappend creates space-separated list" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("lappend VAR a b c");
    try std.testing.expectEqualStrings("a b c", tcl.getVar("VAR").?);
}

test "env(HOME) substitution returns non-empty" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set X $env(HOME)");
    const val = tcl.getVar("X").?;
    try std.testing.expect(val.len > 0);
}

test "braced variable substitution" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set FOO bar");
    _ = try tcl.eval("set Y ${FOO}");
    try std.testing.expectEqualStrings("bar", tcl.getVar("Y").?);
}

test "file dirname" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set D [file dirname /a/b/c]");
    try std.testing.expectEqualStrings("/a/b", tcl.getVar("D").?);
}

test "info exists returns 1 for set var and 0 for unset" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set MYVAR 42");
    _ = try tcl.eval("set E1 [info exists MYVAR]");
    _ = try tcl.eval("set E2 [info exists NOSUCHVAR]");
    try std.testing.expectEqualStrings("1", tcl.getVar("E1").?);
    try std.testing.expectEqualStrings("0", tcl.getVar("E2").?);
}

test "info exists env(HOME) returns 1" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set R [info exists env(HOME)]");
    try std.testing.expectEqualStrings("1", tcl.getVar("R").?);
}

test "if with brace-delimited bodies" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("if {1} {set X yes} else {set X no}");
    try std.testing.expectEqualStrings("yes", tcl.getVar("X").?);
}

test "expr ne on non-empty var returns 1" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set var hello");
    _ = try tcl.eval("set R [expr {$var ne {}}]");
    try std.testing.expectEqualStrings("1", tcl.getVar("R").?);
}

test "expr eq on empty var returns 1" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set var {}");
    _ = try tcl.eval("set R [expr {$var eq {}}]");
    try std.testing.expectEqualStrings("1", tcl.getVar("R").?);
}

test "puts is a no-op" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    // puts should not error
    _ = try tcl.eval("puts stderr \"test message\"");
    _ = try tcl.eval("puts \"hello\"");
}

test "proc produces UnsupportedConstruct error" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    const result = tcl.eval("proc myproc {} {}");
    try std.testing.expectError(error.UnsupportedConstruct, result);
}

test "source with non-existent file does not crash" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    // Source a file that doesn't exist -- should emit diagnostic but not crash
    _ = try tcl.eval("source /tmp/nonexistent_tcl_file_12345.tcl");
}

test "if false branch" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("if {0} {set X yes} else {set X no}");
    try std.testing.expectEqualStrings("no", tcl.getVar("X").?);
}

test "nested bracket command in append" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set PATH {}");
    _ = try tcl.eval("append PATH :[file dirname /a/b/c]");
    try std.testing.expectEqualStrings(":/a/b", tcl.getVar("PATH").?);
}

test "expr arithmetic" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set R [expr {2 + 3 * 4}]");
    const val = tcl.getVar("R").?;
    // Should be 14 (multiplication has higher precedence)
    const f = std.fmt.parseFloat(f64, val) catch 0;
    try std.testing.expectEqual(@as(f64, 14.0), f);
}

test "info script returns empty when not set" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    _ = try tcl.eval("set S [info script]");
    try std.testing.expectEqualStrings("", tcl.getVar("S").?);
}

test "info script returns path when set" {
    var tcl = tcl_mod.Tcl.init(std.testing.allocator);
    defer tcl.deinit();
    tcl.setScriptPath("/some/path/xschemrc");
    _ = try tcl.eval("set S [info script]");
    try std.testing.expectEqualStrings("/some/path/xschemrc", tcl.getVar("S").?);
}
