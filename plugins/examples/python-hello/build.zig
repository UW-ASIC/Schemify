const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addPythonPlugin(
        b,
        "python-hello",
        sdk_dep,
        &.{"plugin.py"},
        null,           // no requirements.txt
        "python-hello",
    );
}
