//! Import command handler — auto-detect and import external schematic formats.
//!
//! Validates the path, detects the format from extension, stores the import
//! request in state, and opens the import dialog. The GUI layer (which has
//! the `external` module dependency) performs the actual conversion.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("../types.zig");

pub fn handleRunImport(p: types.RunImport, state: anytype) void {
    if (is_wasm) { state.setStatus("Import not available in browser"); return; }

    const path = p.path;
    if (path.len == 0) {
        state.setStatus("import requires a file path");
        return;
    }

    // Validate the file exists
    @import("utility").platform.fs.cwd().access(path, .{}) catch {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "File not found: {s}", .{path}) catch "File not found";
        state.setStatusBuf(msg);
        return;
    };

    const imp = &state.gui.cold.import_project;

    // Detect format from extension / filename and store import request
    if (std.mem.endsWith(u8, path, ".sch") or std.mem.endsWith(u8, path, ".sym")) {
        imp.format = .xschem;
        imp.setPath(path);
        imp.is_open = true;
        storeImportStatus(state, path, "xschem");
    } else if (std.mem.endsWith(u8, path, ".sp") or
        std.mem.endsWith(u8, path, ".spice") or
        std.mem.endsWith(u8, path, ".cir"))
    {
        imp.format = .spice;
        imp.setPath(path);
        imp.is_open = true;
        storeImportStatus(state, path, "spice");
    } else if (std.mem.endsWith(u8, path, "xschemrc")) {
        imp.format = .xschem;
        imp.setPath(path);
        imp.is_open = true;
        storeImportStatus(state, path, "xschem");
    } else if (std.mem.endsWith(u8, path, "cds.lib") or std.mem.endsWith(u8, path, ".oa")) {
        imp.format = .virtuoso;
        imp.setPath(path);
        imp.is_open = true;
        storeImportStatus(state, path, "virtuoso");
    } else {
        state.setStatus("Unknown format. Supported: .sch .sym .sp .spice .cir xschemrc cds.lib");
    }
}

fn storeImportStatus(state: anytype, path: []const u8, format: []const u8) void {
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Importing {s}: {s}", .{ format, path }) catch "Importing...";
    state.setStatusBuf(msg);
}
