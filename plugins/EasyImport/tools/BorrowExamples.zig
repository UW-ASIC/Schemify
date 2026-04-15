// BorrowExamples.zig — Convert xschem fixture examples into schemify .chn files.
//
// Usage: zig build borrow-examples
// Expects CWD = project root (set by build.zig run step).
//
// Creates a temporary project directory containing:
//   - A minimal xschemrc
//   - Symlinks to .sch/.sym files from the xschem_library fixture
// Then runs convertProject against it and writes .chn output to examples/.

const std = @import("std");
const core = @import("core");
const XSchem = @import("xschem");
const ct = @import("convert_types");

const FIXTURE_EXAMPLES = "plugins/EasyImport/test/fixtures/xschem_library/xschem_library/examples";
const FIXTURE_NGSPICE = "plugins/EasyImport/test/fixtures/xschem_library/xschem_library/ngspice";
const FIXTURE_DEVICES = "plugins/EasyImport/test/fixtures/xschem_library/xschem_library/devices";

const xschemrc_content =
    \\set XSCHEM_START_WINDOW {}
    \\set XSCHEM_LIBRARY_PATH {}
    \\append XSCHEM_LIBRARY_PATH :[file dirname [file normalize [info script]]]
    \\
;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build a temp project dir with xschemrc + copied .sch/.sym files.
    const tmp_dir = "/tmp/schemify_borrow_examples";
    // Clean previous run.
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    std.fs.cwd().makePath(tmp_dir) catch |err| {
        std.debug.print("makePath({s}) failed: {}\n", .{ tmp_dir, err });
        return err;
    };

    // Write xschemrc.
    const rc_path = try std.fmt.allocPrint(alloc, "{s}/xschemrc", .{tmp_dir});
    defer alloc.free(rc_path);
    std.fs.cwd().writeFile(.{ .sub_path = rc_path, .data = xschemrc_content }) catch |err| {
        std.debug.print("Failed to write xschemrc: {}\n", .{err});
        return err;
    };

    // Copy all .sch and .sym files from fixture dirs into tmp project.
    // We copy instead of symlink because dir.walk() skips symlinks.
    const fixture_dirs = [_][]const u8{ FIXTURE_EXAMPLES, FIXTURE_NGSPICE };
    var copy_count: usize = 0;
    for (fixture_dirs) |fdir| {
        var src_dir = std.fs.cwd().openDir(fdir, .{ .iterate = true }) catch continue;
        defer src_dir.close();
        var fiter = src_dir.iterate();
        while (fiter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (!std.mem.endsWith(u8, name, ".sch") and !std.mem.endsWith(u8, name, ".sym")) continue;

            const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ tmp_dir, name }) catch continue;
            defer alloc.free(dst);

            // Read source, write to dest.
            const data = src_dir.readFileAlloc(alloc, name, 4 << 20) catch continue;
            defer alloc.free(data);
            std.fs.cwd().writeFile(.{ .sub_path = dst, .data = data }) catch continue;
            copy_count += 1;
        }
    }

    std.debug.print("Copied {d} files into {s}\n", .{ copy_count, tmp_dir });

    // Convert.
    var backend = XSchem.Backend.init(alloc);
    defer backend.deinit();

    var result_list = backend.convertProject(tmp_dir) catch |err| {
        std.debug.print("convertProject failed: {}\n", .{err});
        return err;
    };
    defer result_list.deinit();

    // Remap sky130 PDK references to generic primitives.
    for (result_list.results) |*r| {
        XSchem.remapSky130(&r.schemify);
    }

    // Write output.
    std.fs.cwd().makePath("examples") catch |err| {
        std.debug.print("makePath(examples) failed: {}\n", .{err});
        return err;
    };

    var written: usize = 0;
    var failed: usize = 0;

    for (result_list.results) |*r| {
        const ext: []const u8 = switch (r.schemify.stype) {
            .primitive => ".chn_prim",
            .testbench => ".chn_tb",
            .component => ".chn",
        };

        const filename = std.fmt.allocPrint(alloc, "examples/{s}{s}", .{ r.name, ext }) catch continue;
        defer alloc.free(filename);

        const data = r.schemify.writeFile(alloc, null) orelse {
            std.debug.print("FAIL: {s} — writeFile returned null\n", .{r.name});
            failed += 1;
            continue;
        };
        defer alloc.free(data);

        std.fs.cwd().writeFile(.{ .sub_path = filename, .data = data }) catch |err| {
            std.debug.print("FAIL: {s} — write error: {}\n", .{ r.name, err });
            failed += 1;
            continue;
        };

        std.debug.print("OK: {s}\n", .{filename});
        written += 1;
    }

    std.debug.print("\nDone. {d} written, {d} failed out of {d} total.\n", .{
        written,
        failed,
        result_list.results.len,
    });

    // Cleanup temp dir.
    std.fs.cwd().deleteTree(tmp_dir) catch {};

    if (failed > 0) return error.SomeConversionsFailed;
}
