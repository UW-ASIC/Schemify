// Schemify Plugin — Zig demo build
//
// Build native: zig build
// Build WASM:   zig build -Dbackend=web

const std = @import("std");

const Backend = enum { native, web };

pub fn build(b: *std.Build) void {
    const backend = b.option(Backend, "backend", "native or web") orelse .native;
    const optimize = b.standardOptimizeOption(.{});

    // SDK module — local file, no package fetch needed.
    const sdk = b.createModule(.{ .root_source_file = b.path("../../../tools/api/zig/src/lib.zig") });

    if (backend == .native) {
        const target = b.standardTargetOptions(.{});
        const lib = b.addLibrary(.{
            .name = "zig-demo",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        lib.root_module.addImport("schemify", sdk);
        b.installArtifact(lib);

        // install-plugin step: copies .so to ~/.config/Schemify/zig-demo/
        const copy = b.addSystemCommand(&.{ "sh", "-c",
            "mkdir -p \"$HOME/.config/Schemify/zig-demo\";" ++
                "cp zig-out/lib/*.so \"$HOME/.config/Schemify/zig-demo/\";" ++
                "echo \"Installed zig-demo\"",
        });
        copy.step.dependOn(b.getInstallStep());
        const install_step = b.step("install-plugin", "Install .so to ~/.config/Schemify/");
        install_step.dependOn(&copy.step);
    } else {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });
        const wasm = b.addExecutable(.{
            .name = "zig-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = wasm_target,
                .optimize = optimize,
            }),
        });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        wasm.root_module.addImport("schemify", sdk);
        const install = b.addInstallArtifact(wasm, .{
            .dest_dir = .{ .override = .{ .custom = "plugins" } },
        });
        b.getInstallStep().dependOn(&install.step);
    }
}
