// Schemify Plugin — Zig build (no build.zig.zon required)
//
// Copy lib.zig (tools/api/zig/src/lib.zig) next to this file as "schemify.zig",
// then implement your plugin in src/plugin.zig.
//
// Build native: zig build
// Build WASM:   zig build -Dbackend=web

const std = @import("std");

const Backend = enum { native, web };

pub fn build(b: *std.Build) void {
    const backend  = b.option(Backend, "backend", "native or web") orelse .native;
    const optimize = b.standardOptimizeOption(.{});

    // SDK module — local file, no package fetch needed.
    const sdk = b.createModule(.{ .root_source_file = b.path("schemify.zig") });

    if (backend == .native) {
        const target = b.standardTargetOptions(.{});
        const lib = b.addLibrary(.{
            .name    = "plugin",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/plugin.zig"),
                .target           = target,
                .optimize         = optimize,
            }),
        });
        lib.root_module.addImport("schemify", sdk);
        b.installArtifact(lib);

        // zig build install-plugin → copies .so to ~/.config/Schemify/<name>/
        const copy = b.addSystemCommand(&.{ "sh", "-c",
            "NAME=$(grep -o 'name.*\"[^\"]*\"' src/plugin.zig | head -1 | grep -o '\"[^\"]*\"' | tr -d '\"' || echo plugin);" ++
            "mkdir -p \"$HOME/.config/Schemify/$NAME\";" ++
            "cp zig-out/lib/*.so \"$HOME/.config/Schemify/$NAME/\";" ++
            "echo \"Installed $NAME\"",
        });
        copy.step.dependOn(b.getInstallStep());
        const install_step = b.step("install-plugin", "Install .so to ~/.config/Schemify/");
        install_step.dependOn(&copy.step);
    } else {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32, .os_tag = .freestanding,
        });
        const wasm = b.addExecutable(.{
            .name = "plugin",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/plugin.zig"),
                .target           = wasm_target,
                .optimize         = optimize,
            }),
        });
        wasm.entry    = .disabled;
        wasm.rdynamic = true;
        wasm.root_module.addImport("schemify", sdk);
        const install = b.addInstallArtifact(wasm, .{
            .dest_dir = .{ .override = .{ .custom = "plugins" } },
        });
        b.getInstallStep().dependOn(&install.step);
    }
}
