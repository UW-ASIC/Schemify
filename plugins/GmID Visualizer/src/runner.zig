const std = @import("std");
const Plugin = @import("PluginIF");
const state = @import("state.zig");

const TAG = "GmIDVisualizer";

var g_plugin_dir: [std.fs.max_path_bytes]u8 = undefined;
var g_plugin_dir_len: usize = 0;

pub fn init(plugin_dir: []const u8) void {
    const n = @min(plugin_dir.len, g_plugin_dir.len - 1);
    @memcpy(g_plugin_dir[0..n], plugin_dir[0..n]);
    g_plugin_dir_len = n;
}

pub fn pickModelFile() ?[]const u8 {
    const alloc = std.heap.page_allocator;
    const zenity = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "zenity", "--file-selection", "--title=Select MOSFET/BJT model file" },
    }) catch return pickViaKdialog();
    defer alloc.free(zenity.stdout);
    defer alloc.free(zenity.stderr);

    const ok = switch (zenity.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return pickViaKdialog();
    return dupAndTrim(zenity.stdout);
}

fn pickViaKdialog() ?[]const u8 {
    const alloc = std.heap.page_allocator;
    const res = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "kdialog", "--getopenfilename", ".", "Model files (*.spice *.spi *.lib *.model *.mod *.cir *.scs)" },
    }) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;
    return dupAndTrim(res.stdout);
}

fn dupAndTrim(text: []const u8) ?[]u8 {
    const alloc = std.heap.page_allocator;
    const trimmed = std.mem.trim(u8, text, " \n\r\t");
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

pub fn validateModelFile(path: []const u8) state.ModelKind {
    const alloc = std.heap.page_allocator;
    const data = std.fs.cwd().readFileAlloc(alloc, path, 2 * 1024 * 1024) catch return .unknown;
    defer alloc.free(data);

    const lower = alloc.alloc(u8, data.len) catch return .unknown;
    defer alloc.free(lower);
    _ = std.ascii.lowerString(lower, data);

    const has_mos = containsAny(lower, &.{
        " nmos", " pmos", "mosfet", "level=",
        "nfet",  "pfet",  "vth0",   "tox",
    });
    const has_bjt = containsAny(lower, &.{
        " npn", " pnp", " bjt", "is=",
        "bf=",  "br=",  "vaf=", "ikf=",
    });

    if (has_mos and !has_bjt) return .mosfet;
    if (has_bjt and !has_mos) return .bjt;
    if (has_mos and has_bjt) return .mosfet;
    return .unknown;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

pub fn runSweep() void {
    const s = &state.g;
    const model_path = s.selectedPath();
    if (model_path.len == 0) {
        s.setError("No model selected");
        return;
    }
    if (s.selected_model_kind == .unknown) {
        s.setError("Selected model format is not recognized");
        return;
    }

    s.status = .running;
    s.clearError();
    s.clearPlots();
    s.setStatus("Running Gm/Id sweep...");
    Plugin.requestRefresh();

    var script_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const script_path = std.fmt.bufPrint(
        &script_path_buf,
        "{s}/src/gmid_runner.py",
        .{g_plugin_dir[0..g_plugin_dir_len]},
    ) catch {
        s.setError("Failed to resolve runner script path");
        return;
    };

    var out_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_dir = std.fmt.bufPrint(
        &out_dir_buf,
        "{s}/figures",
        .{g_plugin_dir[0..g_plugin_dir_len]},
    ) catch {
        s.setError("Failed to resolve output directory");
        return;
    };

    std.fs.cwd().makePath(out_dir) catch {};

    const kind_label = s.selected_model_kind.label();
    const alloc = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{
            "python3",
            script_path,
            "--model-file",
            model_path,
            "--kind",
            kind_label,
            "--out-dir",
            out_dir,
        },
    }) catch {
        s.setError("Failed to launch python3");
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        const msg = if (result.stderr.len > 0) result.stderr else "Sweep command failed";
        s.setError(std.mem.trim(u8, msg, " \n\r\t"));
        Plugin.logWarn(TAG, "python runner exited with failure");
        Plugin.requestRefresh();
        return;
    }

    parseSvgLines(result.stdout);
    if (s.plot_count == 0) {
        s.setError("No SVG plots were produced");
        Plugin.requestRefresh();
        return;
    }

    s.status = .done;
    var msg_buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Generated {d} SVG plots", .{s.plot_count}) catch "Generated SVG plots";
    s.setStatus(msg);
    Plugin.requestRefresh();
}

fn parseSvgLines(stdout: []const u8) void {
    const s = &state.g;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "SVG:")) continue;
        const path = std.mem.trim(u8, trimmed[4..], " \t");
        if (path.len == 0) continue;
        s.addPlot(path);
    }
}

pub fn openSvg(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "xdg-open", path },
    }) catch {
        Plugin.logWarn(TAG, "xdg-open failed for SVG");
        return;
    };
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}
