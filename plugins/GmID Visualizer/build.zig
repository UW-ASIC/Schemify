const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addPythonPlugin(
        b,
        "GmIDVisualizer",
        sdk_dep,
        &.{ "src/plugin.py", "src/gmid_runner.py" },
        null,
        "GmIDVisualizer",
    );
}
