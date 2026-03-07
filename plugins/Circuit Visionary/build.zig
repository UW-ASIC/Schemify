const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "CircuitVision", "src/main.zig");
        helper.linkPythonC(b, lib);
        lib.linkLibC();
        if (ctx.target.result.os.tag == .linux) lib.linkSystemLibrary("dl");

        b.installArtifact(lib);
        helper.addInstallFiles(b, .lib, &install_files);
        helper.addNativeAutoInstallRunStep(b, "CircuitVision", sdk_dep, "CircuitVision");
    }

    if (ctx.is_web) {
        helper.addWasmPlugin(b, ctx, "CircuitVision", "src/main.zig");
        helper.addWasmAutoServeStep(b, sdk_dep, "CircuitVision", "CircuitVision");
    }
}

const install_files = [_][]const u8{
    "plugin.toml",
    "requirements.txt",
    "schemas/circuit_graph.schema.json",
    "src/__init__.py",
    "src/circuit_extract.py",
    "src/circuit_graph.py",
    "src/style_classifier.py",
    "src/detector.py",
    "src/crossing_classifier.py",
    "src/wire_tracer.py",
    "src/mosfet_resolver.py",
    "src/label_reader.py",
    "src/topology.py",
    "src/vlm_verify.py",
    "src/preprocessors/__init__.py",
    "src/preprocessors/handdrawn.py",
    "src/preprocessors/textbook.py",
    "src/preprocessors/datasheet.py",
};
