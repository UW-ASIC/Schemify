//! XSchemDropIN — Schemify native plugin (ABI v6).
//!
//! Provides an overlay panel for importing XSchem and Virtuoso projects
//! into Schemify format.  Uses the EasyImport library for conversion.
//!
//! Uses the Framework comptime layer — no manual ABI switch or widget ID math.

const std = @import("std");
const P = @import("PluginIF");
const F = P.Framework;
const ei = @import("easyimport");
const core = @import("core");

const Allocator = std.mem.Allocator;

// ── Constants ─────────────────────────────────────────────────────────────── //

const MAX_PATH = 512;
const MAX_MSG = 256;

// ── Widget IDs ────────────────────────────────────────────────────────────── //

const WID_TITLE = 0;
const WID_SEP1 = 1;
const WID_PATH_LBL = 2;
const WID_PATH_VAL = 3;
const WID_BROWSE = 10;
const WID_BACKEND_LBL = 11;
const WID_TOGGLE_BACK = 12;
const WID_SEP2 = 15;
const WID_CONVERT = 20;
const WID_STATUS_LBL = 30;
const WID_MSG_LBL = 31;

// ── Plugin state ──────────────────────────────────────────────────────────── //

const ImportStatus = enum(u3) { idle, converting, done, err };

const State = struct {
    path_buf: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    backend: ei.BackendKind = .xschem,
    auto_detected: bool = false,
    status: ImportStatus = .idle,
    msg_buf: [MAX_MSG]u8 = [_]u8{0} ** MAX_MSG,
    msg_len: u16 = 0,
    converted_count: u32 = 0,

    fn pathSlice(s: *const State) []const u8 {
        return s.path_buf[0..s.path_len];
    }

    fn setPath(s: *State, len: usize) void {
        s.path_len = @intCast(len);
    }

    fn setMsg(s: *State, msg: []const u8) void {
        const n: u16 = @intCast(@min(msg.len, MAX_MSG));
        @memcpy(s.msg_buf[0..n], msg[0..n]);
        s.msg_len = n;
    }

    fn setMsgFmt(s: *State, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&s.msg_buf, fmt, args) catch {
            s.msg_len = 0;
            return;
        };
        s.msg_len = @intCast(msg.len);
    }

    fn msgSlice(s: *const State) []const u8 {
        return s.msg_buf[0..s.msg_len];
    }
};

var state = State{};

// ── Helpers ───────────────────────────────────────────────────────────────── //

fn fileExists(a: Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(a, &.{ dir, name }) catch return false;
    defer a.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn autoDetect(s: *State) void {
    const a = std.heap.page_allocator;
    const path = s.pathSlice();
    if (path.len == 0) return;

    if (fileExists(a, path, "cds.lib")) {
        s.backend = .virtuoso;
        s.auto_detected = true;
    } else if (fileExists(a, path, "xschemrc")) {
        s.backend = .xschem;
        s.auto_detected = true;
    }
}

fn runDialog(a: Allocator, argv: []const []const u8, buf: []u8) ?usize {
    var child = std.process.Child.init(argv, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var total: usize = 0;
    while (total < buf.len) {
        const n = stdout.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = child.wait() catch {};

    while (total > 0) {
        const c = buf[total - 1];
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') {
            total -= 1;
        } else break;
    }

    return if (total > 0) total else null;
}

// ── Panel draw ────────────────────────────────────────────────────────────── //

fn drawPanel(s: *State, w: *P.Writer) void {
    w.label("Import Project", WID_TITLE);
    w.separator(WID_SEP1);

    w.label("Project Directory:", WID_PATH_LBL);
    if (s.path_len > 0) {
        w.label(s.pathSlice(), WID_PATH_VAL);
    } else {
        w.label("(none selected)", WID_PATH_VAL);
    }
    w.button("Browse...", WID_BROWSE);

    var back_buf: [64]u8 = undefined;
    const tag_str: []const u8 = if (s.auto_detected) " (auto)" else "";
    const back_name: []const u8 = switch (s.backend) {
        .xschem => "XSchem",
        .virtuoso => "Virtuoso",
    };
    const back_label = std.fmt.bufPrint(&back_buf, "Backend: {s}{s}", .{ back_name, tag_str }) catch "Backend: ?";
    w.label(back_label, WID_BACKEND_LBL);
    w.button("Toggle Backend", WID_TOGGLE_BACK);

    w.separator(WID_SEP2);

    switch (s.status) {
        .idle => w.button("Convert", WID_CONVERT),
        .converting => w.label("Converting...", WID_STATUS_LBL),
        .done => {
            var buf: [64]u8 = undefined;
            const lbl = std.fmt.bufPrint(&buf, "Done: {d} schematics converted", .{s.converted_count}) catch "Done";
            w.label(lbl, WID_STATUS_LBL);
            w.button("Convert Again", WID_CONVERT);
        },
        .err => {
            w.label("Error:", WID_STATUS_LBL);
            if (s.msg_len > 0) w.label(s.msgSlice(), WID_MSG_LBL);
            w.button("Retry", WID_CONVERT);
        },
    }

    if (s.msg_len > 0 and s.status != .err) {
        w.label(s.msgSlice(), WID_MSG_LBL);
    }
}

// ── Button routing ────────────────────────────────────────────────────────── //

fn onButton(s: *State, widget_id: u32, w: *P.Writer) void {
    switch (widget_id) {
        WID_BROWSE => handleBrowse(s, w),
        WID_TOGGLE_BACK => {
            s.backend = switch (s.backend) {
                .xschem => .virtuoso,
                .virtuoso => .xschem,
            };
            s.auto_detected = false;
            w.requestRefresh();
        },
        WID_CONVERT => handleConvert(s, w),
        else => {},
    }
}

fn handleBrowse(s: *State, w: *P.Writer) void {
    const a = std.heap.page_allocator;

    if (runDialog(a, &.{ "zenity", "--file-selection", "--directory", "--title=Select project to import" }, &s.path_buf)) |n| {
        s.setPath(n);
        autoDetect(s);
        w.requestRefresh();
        return;
    }
    if (runDialog(a, &.{ "kdialog", "--getexistingdirectory", "." }, &s.path_buf)) |n| {
        s.setPath(n);
        autoDetect(s);
        w.requestRefresh();
        return;
    }

    s.setMsg("No file dialog found (install zenity or kdialog)");
    w.requestRefresh();
}

/// Write one converted result to disk as a .chn file.
/// Adds a PLUGIN EasyImport block recording the original source paths,
/// then serialises the Schemify and writes it alongside the .sch file.
fn writeResultToChn(a: Allocator, project_dir: []const u8, r: *ei.ConvertResult) bool {
    const rel_sch = r.sch_path orelse return false;

    // Strip .sch extension; output extension depends on stype
    const base = if (std.mem.endsWith(u8, rel_sch, ".sch"))
        rel_sch[0 .. rel_sch.len - 4]
    else
        rel_sch;
    const ext: []const u8 = switch (r.schemify.stype) {
        .primitive => ".chn_prim",
        .testbench => ".chn_tb",
        .component => ".chn",
    };
    const rel_out = std.fmt.allocPrint(a, "{s}{s}", .{ base, ext }) catch return false;
    defer a.free(rel_out);
    const out_path = std.fs.path.join(a, &.{ project_dir, rel_out }) catch return false;
    defer a.free(out_path);

    // Ensure parent directory exists
    if (std.fs.path.dirname(out_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Record provenance in a PLUGIN EasyImport block
    var entries_buf: [2]core.Prop = undefined;
    var entry_count: usize = 0;
    if (r.sch_path) |sp| {
        entries_buf[entry_count] = .{ .key = "sch_path", .val = sp };
        entry_count += 1;
    }
    if (r.sym_path) |sp| {
        entries_buf[entry_count] = .{ .key = "sym_path", .val = sp };
        entry_count += 1;
    }
    r.schemify.addPluginBlock("EasyImport", entries_buf[0..entry_count]) catch return false;

    // Serialise and write
    const bytes = r.schemify.writeFile(a, null) orelse return false;
    defer a.free(bytes);
    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = bytes }) catch return false;
    return true;
}

fn handleConvert(s: *State, w: *P.Writer) void {
    const a = std.heap.page_allocator;

    if (s.path_len == 0) {
        s.status = .err;
        s.setMsg("No project directory selected");
        w.requestRefresh();
        return;
    }

    s.status = .converting;
    s.setMsg("Converting...");

    const importer = ei.EasyImport.init(a, s.pathSlice(), s.backend);
    var results = importer.convertProject() catch |err| {
        s.status = .err;
        s.setMsgFmt("Conversion failed: {s}", .{@errorName(err)});
        w.requestRefresh();
        return;
    };
    defer results.deinit();

    var written: u32 = 0;
    for (results.results) |*r| {
        if (writeResultToChn(a, s.pathSlice(), r)) written += 1;
    }

    s.converted_count = written;
    s.status = .done;
    s.setMsgFmt("Converted {d} schematics", .{written});
    w.setStatus("EasyImport: conversion complete");
    w.requestRefresh();
}

// ── Lifecycle ─────────────────────────────────────────────────────────────── //

fn onLoad(_: *State, w: *P.Writer) void {
    w.setStatus("EasyImport ready");
    w.log(.info, "EasyImport", "on_load");
}

fn onUnload(s: *State, _: *P.Writer) void {
    s.* = .{};
}

// ── Plugin definition ─────────────────────────────────────────────────────── //

const MyPlugin = F.define(State, &state, .{
    .name = "XSchemDropIN",
    .version = "0.1.0",
    .panels = &.{
        F.PanelSpec{
            .id = "easyimport",
            .title = "Import Project",
            .vim_cmd = "import",
            .layout = .overlay,
            .keybind = 'I',
            .draw_fn = F.wrapDrawFn(State, drawPanel),
            .on_button = F.wrapOnButton(State, onButton),
        },
    },
    .on_load = F.wrapWriterHook(State, onLoad),
    .on_unload = F.wrapWriterHook(State, onUnload),
});

comptime {
    MyPlugin.export_plugin();
}
