const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── litehtml C++ library + bundled gumbo HTML5 parser ────────────────────
    const litehtml_dep = b.dependency("litehtml", .{});

    // Always build litehtml in ReleaseFast — Zig's debug safety checks catch
    // C++ patterns (enum loads from union fields) that are technically UB but
    // work correctly in practice across all mainstream compilers.
    const litehtml_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libcpp = true,
    });

    // Include paths for litehtml headers — added to the root module so they
    // propagate to all C/C++ source files compiled within this library.
    litehtml_mod.addIncludePath(litehtml_dep.path("include"));
    litehtml_mod.addIncludePath(litehtml_dep.path("include/litehtml"));
    litehtml_mod.addIncludePath(litehtml_dep.path("src/gumbo/include"));
    litehtml_mod.addIncludePath(litehtml_dep.path("src/gumbo/include/gumbo"));
    // c_bridge.h is in our src/ directory
    litehtml_mod.addIncludePath(b.path("src"));

    const litehtml_lib = b.addLibrary(.{
        .name = "litehtml",
        .root_module = litehtml_mod,
    });

    // litehtml C++ sources
    litehtml_mod.addCSourceFiles(.{
        .root = litehtml_dep.path(""),
        .files = &litehtml_cpp_sources,
        .flags = &.{ "-std=c++11", "-DLITEHTML_UTF8" },
        .language = .cpp,
    });

    // Gumbo C sources (bundled HTML5 parser)
    litehtml_mod.addCSourceFiles(.{
        .root = litehtml_dep.path(""),
        .files = &gumbo_c_sources,
        .flags = &.{"-std=c99"},
        .language = .c,
    });

    // C bridge — our extern "C" wrapper around litehtml for Zig interop
    litehtml_mod.addCSourceFile(.{
        .file = b.path("src/c_bridge.cpp"),
        .flags = &.{ "-std=c++11", "-DLITEHTML_UTF8" },
        .language = .cpp,
    });

    // ── html2dvui Zig module ─────────────────────────────────────────────────
    const html2dvui_mod = b.addModule("html2dvui", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    html2dvui_mod.addIncludePath(b.path("src"));
    html2dvui_mod.linkLibrary(litehtml_lib);

    // ── Unit tests ───────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/basic_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const html2dvui_test = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    html2dvui_test.addIncludePath(b.path("src"));
    html2dvui_test.linkLibrary(litehtml_lib);
    test_mod.addImport("html2dvui", html2dvui_test);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.linkLibrary(litehtml_lib);
    unit_tests.linkLibCpp();
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run html2dvui unit tests").dependOn(&run_tests.step);

    // ── Check step ───────────────────────────────────────────────────────────
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addIncludePath(b.path("src"));
    check_mod.linkLibrary(litehtml_lib);
    const check_tests = b.addTest(.{ .root_module = check_mod });
    check_tests.linkLibCpp();
    check_tests.linkLibrary(litehtml_lib);
    b.step("check", "Verify compilation").dependOn(&check_tests.step);
}

// ── litehtml C++ source file list ────────────────────────────────────────────

const litehtml_cpp_sources = [_][]const u8{
    "src/codepoint.cpp",
    "src/css_borders.cpp",
    "src/css_length.cpp",
    "src/css_properties.cpp",
    "src/css_selector.cpp",
    "src/document.cpp",
    "src/document_container.cpp",
    "src/el_anchor.cpp",
    "src/el_base.cpp",
    "src/el_before_after.cpp",
    "src/el_body.cpp",
    "src/el_break.cpp",
    "src/el_cdata.cpp",
    "src/el_comment.cpp",
    "src/el_div.cpp",
    "src/el_font.cpp",
    "src/el_image.cpp",
    "src/el_link.cpp",
    "src/el_para.cpp",
    "src/el_script.cpp",
    "src/el_space.cpp",
    "src/el_style.cpp",
    "src/el_table.cpp",
    "src/el_td.cpp",
    "src/el_text.cpp",
    "src/el_title.cpp",
    "src/el_tr.cpp",
    "src/element.cpp",
    "src/flex_item.cpp",
    "src/flex_line.cpp",
    "src/formatting_context.cpp",
    "src/html.cpp",
    "src/html_tag.cpp",
    "src/iterators.cpp",
    "src/line_box.cpp",
    "src/media_query.cpp",
    "src/num_cvt.cpp",
    "src/render_block.cpp",
    "src/render_block_context.cpp",
    "src/render_flex.cpp",
    "src/render_image.cpp",
    "src/render_inline_context.cpp",
    "src/render_item.cpp",
    "src/render_table.cpp",
    "src/string_id.cpp",
    "src/strtod.cpp",
    "src/style.cpp",
    "src/stylesheet.cpp",
    "src/table.cpp",
    "src/tstring_view.cpp",
    "src/url.cpp",
    "src/url_path.cpp",
    "src/utf8_strings.cpp",
    "src/web_color.cpp",
};

// ── Gumbo (bundled HTML5 parser) C source file list ──────────────────────────

const gumbo_c_sources = [_][]const u8{
    "src/gumbo/attribute.c",
    "src/gumbo/char_ref.c",
    "src/gumbo/error.c",
    "src/gumbo/parser.c",
    "src/gumbo/string_buffer.c",
    "src/gumbo/string_piece.c",
    "src/gumbo/tag.c",
    "src/gumbo/tokenizer.c",
    "src/gumbo/utf8.c",
    "src/gumbo/util.c",
    "src/gumbo/vector.c",
};
