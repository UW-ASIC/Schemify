const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    // PDKLoader requires filesystem and subprocess access — native only.
    if (!ctx.is_web) {
        // ── EasyImport sub-modules (XSchem parser + converter) ─────────────
        const ei_dep = b.dependency("easyimport", .{});

        const ct_mod = b.createModule(.{
            .root_source_file = ei_dep.path("src/convert_types.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        });
        ct_mod.addImport("core", ctx.core_mod);

        const tcl_mod = b.createModule(.{
            .root_source_file = ei_dep.path("src/TCL/mod.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        });

        const xschem_mod = b.createModule(.{
            .root_source_file = ei_dep.path("src/XSchem/mod.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        });
        xschem_mod.addImport("tcl", tcl_mod);
        xschem_mod.addImport("core", ctx.core_mod);
        xschem_mod.addImport("utility", ctx.utility_mod);
        xschem_mod.addImport("convert_types", ct_mod);

        // ── Plugin library ─────────────────────────────────────────────────
        const lib = helper.addNativePluginLibrary(b, ctx, "PDKLoader", "src/main.zig");
        lib.root_module.addImport("xschem", xschem_mod);
        lib.root_module.addImport("core", ctx.core_mod);
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "PDKLoader", sdk_dep, "PDKLoader");

        // ── Tests ─────────────────────────────────────────────────────────────
        const test_step = b.step("test", "Run PDKLoader unit tests");

        // remap.zig transitively imports lut.zig — one compile covers both.
        const remap_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/remap.zig"),
                .target = ctx.target,
                .optimize = ctx.optimize,
            }),
        });

        // lut.zig standalone tests (parsing, LUT lookup, helpers)
        const lut_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lut.zig"),
                .target = ctx.target,
                .optimize = ctx.optimize,
            }),
        });

        const run_remap = b.addRunArtifact(remap_tests);
        const run_lut = b.addRunArtifact(lut_tests);
        test_step.dependOn(&run_remap.step);
        test_step.dependOn(&run_lut.step);

        // Integration tests — exercises real volare/ngspice/PDK pipeline.
        // Run with: zig build integration-test
        const integ_step = b.step("integration-test", "Run PDKLoader integration tests (requires volare + ngspice + installed PDK)");
        const integ_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/integration_test.zig"),
                .target = ctx.target,
                .optimize = ctx.optimize,
            }),
        });
        const run_integ = b.addRunArtifact(integ_tests);
        integ_step.dependOn(&run_integ.step);

        // Copy bundled dep/volare/ into ~/.config/Schemify/PDKLoader/dep/volare/
        // so the plugin can run it as `python3 <path>/volare/__main__.py`.
        // The copy is skipped silently when dep/volare/ has not been cloned yet.
        const home = std.process.getEnvVarOwned(b.allocator, "HOME") catch null;
        if (home) |h| {
            const dest = std.fmt.allocPrint(
                b.allocator,
                "{s}/.config/Schemify/PDKLoader",
                .{h},
            ) catch return;
            const cmd_str = std.fmt.allocPrint(
                b.allocator,
                "[ -d dep/volare ] && mkdir -p '{s}/dep' && cp -r --no-preserve=mode dep/volare '{s}/dep/' || true",
                .{ dest, dest },
            ) catch return;
            const copy_dep = b.addSystemCommand(&.{ "sh", "-c", cmd_str });
            b.getInstallStep().dependOn(&copy_dep.step);
        }
    }
}
