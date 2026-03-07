//! Python Bridge — embeds CPython to run the CircuitVision pipeline.
//!
//! Uses @cImport("Python.h") to call the CPython C API directly from Zig.
//! The same pattern as plugins/example_python/src/shim.c but in Zig.
//!
//! Lifecycle:
//!   main.zig on_load  → init()       (Py_Initialize, add src/ to sys.path)
//!   panel.zig button  → runPipeline() (import circuit_extract, call Pipeline.run)
//!   main.zig on_unload→ deinit()     (Py_FinalizeEx)

const std   = @import("std");
const state = @import("state.zig");
const py    = @cImport(@cInclude("Python.h"));

const Plugin = @import("PluginIF");

const TAG = "CircuitVision";

var g_initialized: bool = false;
var g_src_dir: [std.fs.max_path_bytes]u8 = undefined;
var g_src_dir_len: usize = 0;

// ── Lifecycle ─────────────────────────────────────────────────────────────── //

pub fn init(so_dir: []const u8) bool {
    if (g_initialized) return true;

    py.Py_Initialize();
    if (py.Py_IsInitialized() == 0) {
        Plugin.logErr(TAG, "Py_Initialize failed");
        return false;
    }
    g_initialized = true;

    // Locate the Python source directory (src/ relative to the .so).
    // The build installs Python files alongside the .so under lib/ or bin/.
    // We try several candidate paths.
    const candidates = [_][]const u8{ "/src", "" };
    var found = false;
    for (candidates) |suffix| {
        const total = so_dir.len + suffix.len;
        if (total >= g_src_dir.len) continue;
        @memcpy(g_src_dir[0..so_dir.len], so_dir);
        @memcpy(g_src_dir[so_dir.len..total], suffix);
        g_src_dir[total] = 0;
        g_src_dir_len = total;

        // Verify circuit_extract.py exists there
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const probe = std.fmt.bufPrint(&path_buf, "{s}/circuit_extract.py", .{g_src_dir[0..g_src_dir_len]}) catch continue;
        if (std.fs.cwd().access(probe, .{})) |_| {
            found = true;
            break;
        } else |_| {}
    }

    if (!found) {
        // Fallback: try the plugin source tree directly
        @memcpy(g_src_dir[0..so_dir.len], so_dir);
        g_src_dir_len = so_dir.len;
    }

    // Add source dir to sys.path
    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "import sys; sys.path.insert(0, '{s}')\x00", .{g_src_dir[0..g_src_dir_len]}) catch {
        Plugin.logErr(TAG, "sys.path command too long");
        return false;
    };
    if (py.PyRun_SimpleString(@ptrCast(cmd.ptr)) != 0) {
        Plugin.logErr(TAG, "failed to add src to sys.path");
        py.PyErr_Print();
        return false;
    }

    Plugin.logInfo(TAG, "Python initialized");
    return true;
}

pub fn deinit() void {
    if (!g_initialized) return;
    _ = py.Py_FinalizeEx();
    g_initialized = false;
    Plugin.logInfo(TAG, "Python finalized");
}

// ── Pipeline execution ────────────────────────────────────────────────────── //

pub fn runPipeline() void {
    if (!g_initialized) {
        state.g.setError("Python not initialized");
        return;
    }

    state.g.status = .running;

    const image_path = state.g.imagePath();
    if (image_path.len == 0) {
        state.g.setError("No image path set");
        return;
    }

    // Build Python command:
    //   from circuit_extract import Pipeline
    //   p = Pipeline(style_override=<style>)
    //   g = p.run("<image_path>")
    //   result = g.to_json()
    var cmd_buf: [4096]u8 = undefined;

    const style_arg = state.g.selected_style.pyArg();
    const style_part = if (style_arg) |s|
        std.fmt.bufPrint(cmd_buf[0..256], "style_override=\"{s}\"", .{std.mem.span(s)}) catch "style_override=None"
    else
        "style_override=None";

    // Use a global variable __cv_result__ to pass the JSON back
    const cmd = std.fmt.bufPrint(&cmd_buf,
        \\import json as __json
        \\from circuit_extract import Pipeline as __Pipeline
        \\try:
        \\    __p = __Pipeline({s})
        \\    __g = __p.run("{s}")
        \\    __cv_result__ = __g.to_json()
        \\    __cv_error__ = None
        \\except Exception as __e:
        \\    __cv_result__ = None
        \\    __cv_error__ = str(__e)
        \\
    ++ "\x00",
        .{ style_part, image_path },
    ) catch {
        state.g.setError("Command buffer overflow");
        return;
    };

    if (py.PyRun_SimpleString(@ptrCast(cmd.ptr)) != 0) {
        py.PyErr_Print();
        state.g.setError("Pipeline script execution failed");
        return;
    }

    // Read __cv_error__
    if (readPyGlobal("__cv_error__")) |err_str| {
        state.g.setError(err_str);
        return;
    }

    // Read __cv_result__
    const json = readPyGlobal("__cv_result__") orelse {
        state.g.setError("No result from pipeline");
        return;
    };

    // Parse key fields from JSON for the panel display
    parseResultSummary(json);

    // Store full JSON for the host to consume
    const alloc = std.heap.page_allocator;
    if (state.g.result_json) |old| alloc.free(old);
    const owned = alloc.alloc(u8, json.len) catch {
        state.g.setError("OOM storing result");
        return;
    };
    @memcpy(owned, json);
    state.g.result_json = owned;

    state.g.status = .done;
    Plugin.logInfo(TAG, "Pipeline complete");
    Plugin.requestRefresh();
}

// ── Helpers ───────────────────────────────────────────────────────────────── //

fn readPyGlobal(name: [*:0]const u8) ?[]const u8 {
    const main_mod = py.PyImport_AddModule("__main__") orelse return null;
    const globals = py.PyModule_GetDict(main_mod) orelse return null;
    const obj = py.PyDict_GetItemString(globals, name) orelse return null;
    if (obj == py.Py_None()) return null;
    var size: py.Py_ssize_t = 0;
    const ptr = py.PyUnicode_AsUTF8AndSize(obj, &size) orelse return null;
    if (size <= 0) return null;
    return ptr[0..@intCast(size)];
}

fn parseResultSummary(json: []const u8) void {
    // Quick-and-dirty extraction of key fields without a full JSON parser.
    // We count "comp_" occurrences for components, "net_" for nets,
    // and extract "overall_confidence" and "detected_style".
    state.g.n_components = countOccurrences(json, "\"id\": \"comp_");
    if (state.g.n_components == 0)
        state.g.n_components = countOccurrences(json, "\"id\":\"comp_");

    state.g.n_nets = countOccurrences(json, "\"id\": \"net_");
    if (state.g.n_nets == 0)
        state.g.n_nets = countOccurrences(json, "\"id\":\"net_");

    // Extract overall_confidence
    if (extractFloat(json, "overall_confidence")) |conf| {
        state.g.overall_confidence = @floatCast(conf);
    }

    // Extract detected_style
    if (extractString(json, "detected_style")) |style| {
        const n = @min(style.len, state.g.detected_style_buf.len);
        @memcpy(state.g.detected_style_buf[0..n], style[0..n]);
        state.g.detected_style_len = @intCast(n);
    }

    // Count warnings
    state.g.warning_count = @intCast(@min(
        countOccurrences(json, "\"type\":") - state.g.n_components,
        state.MAX_WARNINGS,
    ));
}

fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) {
            count += 1;
            pos += needle.len;
        } else {
            pos += 1;
        }
    }
    return count;
}

fn extractFloat(json: []const u8, key: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = idx + key.len;
    // Skip to the colon, then whitespace
    while (pos < json.len and json[pos] != ':') pos += 1;
    pos += 1; // skip ':'
    while (pos < json.len and json[pos] == ' ') pos += 1;
    // Parse the float
    var end = pos;
    while (end < json.len and (json[end] == '.' or (json[end] >= '0' and json[end] <= '9'))) end += 1;
    if (end == pos) return null;
    return std.fmt.parseFloat(f64, json[pos..end]) catch null;
}

fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = idx + key.len;
    while (pos < json.len and json[pos] != '"') pos += 1;
    pos += 1; // opening quote
    const start = pos;
    while (pos < json.len and json[pos] != '"') pos += 1;
    if (pos == start) return null;
    return json[start..pos];
}
