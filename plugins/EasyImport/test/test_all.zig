// test_all.zig - Umbrella test file that imports all test modules.
//
// Running `zig build test` compiles and executes tests from all modules:
// props, reader, tcl, xschemrc.

comptime {
    _ = @import("test_xschem.zig");
}
