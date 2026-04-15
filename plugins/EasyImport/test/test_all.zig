// test_all.zig - Umbrella test file that imports all test modules.
//
// Running `zig build test` compiles and executes tests from all modules:
// props, reader, tcl, xschemrc.

comptime {
    _ = @import("test_xschem.zig");
    _ = @import("test_TCL.zig");
    _ = @import("xschem_roundtrip.zig");
}
