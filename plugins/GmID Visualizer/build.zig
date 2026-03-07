const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "GmIDVisualizer", "src/main.zig");
        lib.linkLibC();

        b.installArtifact(lib);
        installPluginFiles(b);
        helper.addNativeAutoInstallRunStep(b, "GmIDVisualizer", sdk_dep, "GmIDVisualizer");
    }

    if (ctx.is_web) {
        helper.addWasmPlugin(b, ctx, "GmIDVisualizer", "src/main.zig");
    }
}

fn installPluginFiles(b: *std.Build) void {
    const files = [_][]const u8{
        "plugin.toml",
        "README.md",
        "src/gmid_runner.py",
    };
    helper.addInstallFiles(b, .lib, &files);
}
