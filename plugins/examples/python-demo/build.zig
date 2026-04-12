const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    // `addPythonPlugin` copies plugin.py to
    // ~/.config/Schemify/SchemifyPython/scripts/python-demo/
    helper.addPythonPlugin(
        b,
        "python-demo",
        sdk_dep,
        &.{"plugin.py"},
        null, // no requirements.txt
        "python-demo",
    );
}
