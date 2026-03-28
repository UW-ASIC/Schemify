const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    // ── EasyImport modules (XSchem parser & converter) ──────────────────────
    const xschem_mod = buildXSchemModule(b, ctx, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "EasyPDKLoader", "src/main.zig");
        lib.root_module.addImport("core", ctx.core_mod);
        lib.root_module.addImport("xschem", xschem_mod);
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "EasyPDKLoader", sdk_dep, "EasyPDKLoader");

        addTests(b, ctx, xschem_mod);
    }

    // PDK scanning requires filesystem access — no WASM plugin.
}

/// Build the xschem module from EasyImport's source files, along with its
/// dependencies (tcl, convert_types).  All source paths resolved via sdk_dep.
fn buildXSchemModule(
    b: *std.Build,
    ctx: anytype,
    sdk_dep: *std.Build.Dependency,
) *std.Build.Module {
    // Tcl module (tokenizer, expr, evaluator, commands)
    const tcl_mod = b.createModule(.{
        .root_source_file = sdk_dep.path("plugins/EasyImport/src/TCL/mod.zig"),
        .target   = ctx.target,
        .optimize = ctx.optimize,
    });

    // Shared conversion result types
    const ct_mod = b.createModule(.{
        .root_source_file = sdk_dep.path("plugins/EasyImport/src/convert_types.zig"),
        .target   = ctx.target,
        .optimize = ctx.optimize,
    });
    ct_mod.addImport("core", ctx.core_mod);

    // XSchem module (types, props, reader, xschemrc, converter, backend)
    const xschem_mod = b.createModule(.{
        .root_source_file = sdk_dep.path("plugins/EasyImport/src/XSchem/mod.zig"),
        .target   = ctx.target,
        .optimize = ctx.optimize,
    });
    xschem_mod.addImport("tcl", tcl_mod);
    xschem_mod.addImport("core", ctx.core_mod);
    xschem_mod.addImport("utility", ctx.utility_mod);
    xschem_mod.addImport("convert_types", ct_mod);

    return xschem_mod;
}

fn addTests(b: *std.Build, ctx: anytype, xschem_mod: *std.Build.Module) void {
    // volare.zig is the module under test; it needs "core" and "xschem".
    const volare_mod = b.createModule(.{
        .root_source_file = b.path("src/volare.zig"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    volare_mod.addImport("core", ctx.core_mod);
    volare_mod.addImport("xschem", xschem_mod);

    // ── integration tests (tests/test_volare_pdks.zig) ─────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_volare_pdks.zig"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    test_mod.addImport("volare", volare_mod);

    const tests    = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(tests);
    run_test.setCwd(b.path("."));

    const test_step = b.step("test", "Run EasyPDKLoader tests");
    test_step.dependOn(&run_test.step);

    // ── unit tests (src/tests.zig) ──────────────────────────────────────────
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    unit_mod.addImport("volare", volare_mod);

    const unit_tests    = b.addTest(.{ .root_module = unit_mod });
    const run_unit_test = b.addRunArtifact(unit_tests);
    run_unit_test.setCwd(b.path("."));

    const unit_test_step = b.step("test-unit", "Run PDKLoader unit tests (src/tests.zig)");
    unit_test_step.dependOn(&run_unit_test.step);

    // Also wire unit tests into the main "test" step so `zig build test` runs all.
    test_step.dependOn(&run_unit_test.step);
}
