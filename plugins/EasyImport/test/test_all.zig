// test_all.zig - Umbrella test file that imports all test modules.
//
// Running `zig build test` compiles and executes tests from all modules:
// props, reader, tcl, xschemrc.

comptime {
    _ = @import("test_props.zig");
    _ = @import("test_reader.zig");
    _ = @import("test_tcl.zig");
    _ = @import("test_xschemrc.zig");
}
