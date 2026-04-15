// xschem_roundtrip.zig - XSchem roundtrip and SPICE comparison tests.
const std = @import("std");
const testing = std.testing;
const XSchem = @import("xschem");
const easyimport = @import("easyimport");
const core = @import("core");

const convert = XSchem.convert;
const reader = XSchem.fileio.reader;
const writer = XSchem.fileio.writer;
const types = XSchem.types;

/// Pinned commit of xschem_library submodule.
const XSCHEM_LIBRARY_COMMIT = "92fc6e06cbb0d3785a29d261b1b40490c502ec7a";

/// Fixture root: absolute path to xschem_library within the repo.
/// xschem_library files (devices/, ngspice/, etc.) are at:
/// plugins/EasyImport/test/fixtures/xschem_library/xschem_library/
const FIXTURE_ROOT = "plugins/EasyImport/test/fixtures/xschem_library/xschem_library";

test "xschem: roundtrip all fixtures" {
    // skeleton: just print "TODO" for now
    try testing.expect(true);
}

test "xschem: spice comparison" {
    // skeleton: just print "TODO" for now
    try testing.expect(true);
}
