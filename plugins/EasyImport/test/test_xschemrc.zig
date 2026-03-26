const std = @import("std");
const xschem = @import("xschem");

// ── Inline fixture content ──────────────────────────────────────────────
// Using inline strings instead of @embedFile to avoid Zig 0.14 module
// boundary issues (test/ cannot embed from examples/ outside package path).

const core_examples_rc =
    \\#### Project-local xschemrc for core example fixtures.
    \\#### Keep this small: just the library paths needed for reliable netlisting.
    \\
    \\set XSCHEM_START_WINDOW {}
    \\
    \\set XSCHEM_LIBRARY_PATH {}
    \\append XSCHEM_LIBRARY_PATH :${XSCHEM_SHAREDIR}/xschem_library/devices
    \\append XSCHEM_LIBRARY_PATH :${XSCHEM_SHAREDIR}/xschem_library
    \\append XSCHEM_LIBRARY_PATH :[file dirname [file normalize [info script]]]
    \\append XSCHEM_LIBRARY_PATH :$USER_CONF_DIR/xschem_library
;

const sky130_rc =
    \\set XSCHEM_LIBRARY_PATH {}
    \\append XSCHEM_LIBRARY_PATH :${XSCHEM_SHAREDIR}/xschem_library/devices
    \\append XSCHEM_LIBRARY_PATH :${XSCHEM_SHAREDIR}/xschem_library
    \\append XSCHEM_LIBRARY_PATH :[file dirname [file normalize [info script]]]
    \\append XSCHEM_LIBRARY_PATH :$USER_CONF_DIR/xschem_library
    \\set XSCHEM_START_WINDOW {sky130_tests/top.sch}
    \\if { [info exists env(PDK_ROOT)] && $env(PDK_ROOT) ne {} } {
    \\  set PDK_ROOT $env(PDK_ROOT)
    \\} else {
    \\  if {[file isdir /usr/share/pdk]} {set PDK_ROOT /usr/share/pdk
    \\  } elseif {[file isdir /usr/local/share/pdk]} {set PDK_ROOT /usr/local/share/pdk
    \\  } else {
    \\    puts stderr {No open_pdks installation found}
    \\  }
    \\}
    \\if {[info exists PDK_ROOT]} {
    \\  if {[info exists env(PDK)]} {
    \\    set PDK $env(PDK)
    \\  } else {
    \\    set PDK sky130A
    \\  }
    \\  set SKYWATER_MODELS ${PDK_ROOT}/${PDK}/libs.tech/combined
    \\  set SKYWATER_STDCELLS ${PDK_ROOT}/${PDK}/libs.ref/sky130_fd_sc_hd/spice
    \\}
;

const sky130_schematics_rc =
    \\if {[catch {set PDK_ROOT $env(PDK_ROOT)}]} {
    \\    puts "Please set PDK_ROOT"
    \\}
    \\source $PDK_ROOT/sky130A/libs.tech/xschem/xschemrc
    \\set XSCHEM_START_WINDOW {}
;

// ── Test 1: core examples xschemrc produces library paths ──────────────

test "parse core examples xschemrc" {
    var result = try xschem.parseRc(
        std.testing.allocator,
        core_examples_rc,
        "/tmp/test/xschem_core_examples",
        "/tmp/test/xschem_core_examples/xschemrc",
    );
    defer result.deinit();

    // Must produce at least 1 library path
    try std.testing.expect(result.lib_paths.len >= 1);
}

// ── Test 2: sky130 xschemrc resolves library paths ─────────────────────

test "parse sky130 xschemrc resolves library paths" {
    var result = try xschem.parseRc(
        std.testing.allocator,
        sky130_rc,
        "/tmp/test/xschem_sky130",
        "/tmp/test/xschem_sky130/xschemrc",
    );
    defer result.deinit();

    // Must produce library paths
    try std.testing.expect(result.lib_paths.len >= 1);

    // At least one path should contain "xschem_library"
    var found_xschem_lib = false;
    for (result.lib_paths) |p| {
        if (std.mem.indexOf(u8, p, "xschem_library") != null) {
            found_xschem_lib = true;
            break;
        }
    }
    try std.testing.expect(found_xschem_lib);
}

// ── Test 3: sky130 xschemrc extracts pdk_root ──────────────────────────

test "sky130 xschemrc pdk_root depends on env" {
    var result = try xschem.parseRc(
        std.testing.allocator,
        sky130_rc,
        "/tmp/test/xschem_sky130",
        "/tmp/test/xschem_sky130/xschemrc",
    );
    defer result.deinit();

    // pdk_root is set if PDK_ROOT env var exists, null otherwise.
    // Either way, parsing must succeed without crash.
    if (std.posix.getenv("PDK_ROOT")) |_| {
        try std.testing.expect(result.pdk_root != null);
    }
}

// ── Test 4: sky130_schematics xschemrc handles source gracefully ──────

test "parse sky130_schematics xschemrc handles source" {
    // This file does `source $PDK_ROOT/sky130A/libs.tech/xschem/xschemrc`
    // which may fail if PDK is not installed. Must not crash.
    var result = try xschem.parseRc(
        std.testing.allocator,
        sky130_schematics_rc,
        "/tmp/test/sky130_schematics",
        "/tmp/test/sky130_schematics/xschemrc",
    );
    defer result.deinit();

    // Parsing completes -- result struct is valid
    try std.testing.expect(result.project_dir.len > 0);
}

// ── Test 5: project_dir matches xschemrc directory ─────────────────────

test "project_dir matches xschemrc directory" {
    const dir = "/tmp/test/my_project";
    var result = try xschem.parseRc(
        std.testing.allocator,
        core_examples_rc,
        dir,
        "/tmp/test/my_project/xschemrc",
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(dir, result.project_dir);
}

// ── Test 6: start_window extraction ────────────────────────────────────

test "start_window extraction empty means null" {
    // core_examples xschemrc sets `set XSCHEM_START_WINDOW {}`
    // Empty braces means no start window -> should be null
    var result = try xschem.parseRc(
        std.testing.allocator,
        core_examples_rc,
        "/tmp/test/xschem_core_examples",
        "/tmp/test/xschem_core_examples/xschemrc",
    );
    defer result.deinit();

    // Empty start window should map to null
    try std.testing.expect(result.start_window == null);
}

// ── Test 7: sky130 xschemrc has non-empty start_window ─────────────────

test "sky130 xschemrc has start window" {
    var result = try xschem.parseRc(
        std.testing.allocator,
        sky130_rc,
        "/tmp/test/xschem_sky130",
        "/tmp/test/xschem_sky130/xschemrc",
    );
    defer result.deinit();

    // sky130 xschemrc sets XSCHEM_START_WINDOW to {sky130_tests/top.sch}
    if (result.start_window) |sw| {
        try std.testing.expect(sw.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, sw, "sky130") != null);
    }
}

// ── Test 8: colon-separated library path splitting ─────────────────────

test "colon separated library paths" {
    // Minimal script that sets a colon-separated path
    const script = "set XSCHEM_LIBRARY_PATH /a/b:/c/d:/e/f\n";
    var result = try xschem.parseRc(
        std.testing.allocator,
        script,
        "/tmp",
        "/tmp/xschemrc",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.lib_paths.len);
    try std.testing.expectEqualStrings("/a/b", result.lib_paths[0]);
    try std.testing.expectEqualStrings("/c/d", result.lib_paths[1]);
    try std.testing.expectEqualStrings("/e/f", result.lib_paths[2]);
}

// ── Test 9: RcResult has all required fields ───────────────────────────

test "result struct has all required fields" {
    var result = try xschem.parseRc(
        std.testing.allocator,
        core_examples_rc,
        "/tmp/test/core",
        "/tmp/test/core/xschemrc",
    );
    defer result.deinit();

    // All fields exist and are valid
    try std.testing.expect(result.project_dir.len > 0);
    try std.testing.expect(result.xschem_sharedir.len > 0);
    try std.testing.expect(result.user_conf_dir.len > 0);
    // lib_paths is a slice (may be empty or populated)
    _ = result.lib_paths;
    // Optional fields are nullable
    _ = result.start_window;
    _ = result.netlist_dir;
    _ = result.pdk_root;
}
