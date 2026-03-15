const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});

    // Deploy plugin.py via the standard Python plugin helper.
    helper.addPythonPlugin(
        b,
        "Themes",
        sdk_dep,
        &.{"src/plugin.py"},
        null,
        "Themes",
    );

    // Also copy the bundled themes directory alongside plugin.py so that
    // plugin.py can resolve them relative to __file__ at runtime.
    // addPythonPlugin puts plugin.py at $SCRIPTS/Themes/plugin.py, so we place
    // themes/ at $SCRIPTS/Themes/themes/*.json.
    const copy_themes = b.addSystemCommand(&.{
        "sh", "-c",
        "set -e\n" ++
        "SCRIPTS=\"$HOME/.config/Schemify/SchemifyPython/scripts/Themes\"\n" ++
        "mkdir -p \"$SCRIPTS/themes\"\n" ++
        "cp themes/*.json \"$SCRIPTS/themes/\"\n" ++
        "echo \"[Themes] Copied bundled themes to $SCRIPTS/themes/\"\n",
    });
    b.getInstallStep().dependOn(&copy_themes.step);
}
