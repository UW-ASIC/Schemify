const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addPythonPlugin(
        b,
        "CircuitVision",
        sdk_dep,
        &.{
            "src/plugin.py",
            "src/circuit_extract.py",
            "src/circuit_graph.py",
            "src/detector.py",
            "src/wire_tracer.py",
            "src/mosfet_resolver.py",
            "src/label_reader.py",
            "src/style_classifier.py",
            "src/topology.py",
            "src/vlm_verify.py",
            "src/crossing_classifier.py",
            "src/__init__.py",
            "src/preprocessors/__init__.py",
            "src/preprocessors/handdrawn.py",
            "src/preprocessors/textbook.py",
            "src/preprocessors/datasheet.py",
        },
        "requirements.txt",
        "CircuitVision",
    );
}
