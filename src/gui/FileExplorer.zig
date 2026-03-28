//! FileExplorer — three-panel file browser.
//!
//! Layout:
//!   +----------+----------------------+
//!   |          |  Files in folder     |
//!   | Sections +----------------------+
//!   | (PDK,    |  Preview (zoom-fit   |
//!   |  dirs)   |  schematic render)   |
//!   +----------+----------------------+
//!
//! Left column: sections from Config.toml (schematics, testbenches).
//! Top-right: file list for selected section.
//! Bottom-right: zoom-fit preview of the selected .chn file.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// ── Section model ────────────────────────────────────────────────────────── //

const SectionKind = enum { schematics, testbenches };

const Section = struct {
    label: []const u8,
    kind: SectionKind,
};

const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
};

// ── Module-level state ───────────────────────────────────────────────────── //

const gpa = std.heap.page_allocator;

var sections: std.ArrayListUnmanaged(Section) = .{};
var files: std.ArrayListUnmanaged(FileEntry) = .{};
var selected_section: i32 = -1;
var selected_file: i32 = -1;
var scanned: bool = false;
var preview_name: []const u8 = "";
var win_rect: dvui.Rect = .{ .x = 60, .y = 40, .w = 720, .h = 500 };

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!app.open_file_explorer) return;

    if (!scanned) {
        scanSections(app);
        scanned = true;
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = false,
        .open_flag = &app.open_file_explorer,
        .rect = &win_rect,
    }, .{
        .min_size_content = .{ .w = 640, .h = 420 },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("File Explorer", "", &app.open_file_explorer));

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer body.deinit();

    // Left column: sections.
    drawSections(app);

    // Vertical separator.
    _ = dvui.separator(@src(), .{ .id_extra = 100 });

    // Right column: files + preview.
    {
        var right = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
        });
        defer right.deinit();

        drawFileList(app);
        _ = dvui.separator(@src(), .{ .id_extra = 101 });
        drawPreview();
    }
}

// ── Left column: sections ────────────────────────────────────────────────── //

fn drawSections(app: *AppState) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 160 },
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .background = true,
        .color_fill = .{ .r = 30, .g = 30, .b = 38, .a = 255 },
    });
    defer col.deinit();

    // Header.
    dvui.labelNoFmt(@src(), "SECTIONS", .{}, .{
        .id_extra = 200,
        .style = .control,
        .color_text = .{ .r = 140, .g = 140, .b = 160, .a = 255 },
    });
    _ = dvui.spacer(@src(), .{ .id_extra = 201, .min_size_content = .{ .h = 4 } });

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .id_extra = 202,
    });
    defer scroll.deinit();

    for (sections.items, 0..) |sec, si| {
        const is_sel = selected_section == @as(i32, @intCast(si));

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = si * 2,
            .expand = .horizontal,
            .background = true,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .color_fill = if (is_sel)
                dvui.Color{ .r = 45, .g = 95, .b = 175, .a = 255 }
            else
                dvui.Color{ .r = 30, .g = 30, .b = 38, .a = 0 },
            .color_fill_hover = .{ .r = 50, .g = 55, .b = 75, .a = 220 },
        });
        defer card.deinit();

        dvui.labelNoFmt(@src(), sec.label, .{}, .{
            .id_extra = si * 10 + 3,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (dvui.clicked(&card.wd, .{})) {
            if (selected_section != @as(i32, @intCast(si))) {
                selected_section = @intCast(si);
                selected_file = -1;
                clearPreview();
                scanFiles(app, sec.kind);
            }
        }
    }
}

// ── Top-right: file list ─────────────────────────────────────────────────── //

fn drawFileList(app: *AppState) void {
    var area = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .min_size_content = .{ .h = 120 },
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
    });
    defer area.deinit();

    // Header with path.
    {
        const path_label: []const u8 = if (selected_section >= 0 and
            @as(usize, @intCast(selected_section)) < sections.items.len)
            sections.items[@intCast(selected_section)].label
        else
            "Select a section";

        dvui.labelNoFmt(@src(), path_label, .{}, .{
            .id_extra = 301,
            .style = .control,
            .color_text = .{ .r = 180, .g = 180, .b = 200, .a = 255 },
        });
    }
    _ = dvui.spacer(@src(), .{ .id_extra = 302, .min_size_content = .{ .h = 2 } });

    if (files.items.len == 0) {
        dvui.labelNoFmt(@src(), if (selected_section < 0)
            "Select a section to browse files."
        else
            "No files found.", .{}, .{
            .id_extra = 303,
            .style = .control,
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .id_extra = 304,
    });
    defer scroll.deinit();

    for (files.items, 0..) |fe, fi| {
        const is_sel = selected_file == @as(i32, @intCast(fi));

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi * 2,
            .expand = .horizontal,
            .background = true,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .color_fill = if (is_sel)
                dvui.Color{ .r = 45, .g = 95, .b = 175, .a = 255 }
            else
                dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_fill_hover = .{ .r = 50, .g = 55, .b = 75, .a = 180 },
        });
        defer card.deinit();

        // File type badge.
        const badge: []const u8 = if (fe.is_dir) "DIR" else classifyBadge(fe.name);
        const badge_color: dvui.Color = if (fe.is_dir)
            .{ .r = 120, .g = 160, .b = 230, .a = 255 }
        else if (std.mem.endsWith(u8, fe.name, ".chn"))
            dvui.Color{ .r = 120, .g = 210, .b = 120, .a = 255 }
        else
            dvui.Color{ .r = 160, .g = 160, .b = 180, .a = 255 };

        dvui.labelNoFmt(@src(), badge, .{}, .{
            .id_extra = fi * 10 + 1,
            .gravity_y = 0.5,
            .color_text = badge_color,
            .min_size_content = .{ .w = 30 },
        });
        _ = dvui.spacer(@src(), .{ .id_extra = fi * 10 + 2, .min_size_content = .{ .w = 4 } });
        dvui.labelNoFmt(@src(), fe.name, .{}, .{
            .id_extra = fi * 10 + 3,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (dvui.clicked(&card.wd, .{})) {
            if (is_sel) {
                // Second click on selected file: open it in a new tab.
                var path_buf: [512]u8 = undefined;
                const full_path = if (std.fs.path.isAbsolute(fe.path))
                    fe.path
                else
                    std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ app.project_dir, fe.path }) catch fe.path;
                app.openPath(full_path) catch {
                    app.status_msg = "Failed to open file";
                    return;
                };
                app.open_file_explorer = false;
            } else {
                selected_file = @intCast(fi);
                clearPreview();
                preview_name = fe.name;
            }
        }
    }
}

fn classifyBadge(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".chn_tb")) return "TB";
    if (std.mem.endsWith(u8, name, ".chn_sym")) return "SYM";
    if (std.mem.endsWith(u8, name, ".chn_prim")) return "PRM";
    if (std.mem.endsWith(u8, name, ".chn")) return "SCH";
    return "---";
}

// ── Bottom-right: preview ────────────────────────────────────────────────── //

fn drawPreview() void {
    var area = dvui.box(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .h = 160 },
        .background = true,
        .color_fill = .{ .r = 18, .g = 18, .b = 24, .a = 255 },
    });
    defer area.deinit();

    if (preview_name.len == 0) {
        dvui.labelNoFmt(@src(), "Select a file to preview.", .{}, .{
            .id_extra = 500,
            .style = .control,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        return;
    }

    dvui.labelNoFmt(@src(), preview_name, .{}, .{
        .id_extra = 502,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .style = .control,
    });
    dvui.labelNoFmt(@src(), "(Preview rendering not yet connected)", .{}, .{
        .id_extra = 503,
        .gravity_x = 0.5,
        .gravity_y = 0.6,
        .color_text = .{ .r = 120, .g = 120, .b = 140, .a = 200 },
    });
}

// ── Section scanning ─────────────────────────────────────────────────────── //

fn scanSections(app: *AppState) void {
    clearSections();

    const chn_n = app.config.paths.chn.len;
    const tb_n = app.config.paths.chn_tb.len;

    if (chn_n > 0) {
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Schematics ({d})", .{chn_n}) catch "Schematics";
        const dup = gpa.dupe(u8, label) catch return;
        sections.append(gpa, .{ .label = dup, .kind = .schematics }) catch {
            gpa.free(dup);
        };
    }

    if (tb_n > 0) {
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Testbenches ({d})", .{tb_n}) catch "Testbenches";
        const dup = gpa.dupe(u8, label) catch return;
        sections.append(gpa, .{ .label = dup, .kind = .testbenches }) catch {
            gpa.free(dup);
        };
    }

    // Auto-select first section and scan its files.
    if (sections.items.len > 0) {
        selected_section = 0;
        scanFiles(app, sections.items[0].kind);
    }
}

fn scanFiles(app: *AppState, kind: SectionKind) void {
    clearFiles();
    const paths: []const []const u8 = switch (kind) {
        .schematics => app.config.paths.chn,
        .testbenches => app.config.paths.chn_tb,
    };
    for (paths) |p| {
        const name = std.fs.path.basename(p);
        const name_dup = gpa.dupe(u8, name) catch continue;
        const path_dup = gpa.dupe(u8, p) catch {
            gpa.free(name_dup);
            continue;
        };
        files.append(gpa, .{ .name = name_dup, .path = path_dup, .is_dir = false }) catch {
            gpa.free(name_dup);
            gpa.free(path_dup);
        };
    }
}

fn clearPreview() void {
    preview_name = "";
}

// ── Cleanup ──────────────────────────────────────────────────────────────── //

fn clearFiles() void {
    for (files.items) |fe| {
        gpa.free(fe.name);
        gpa.free(fe.path);
    }
    files.clearRetainingCapacity();
}

fn clearSections() void {
    for (sections.items) |sec| {
        gpa.free(sec.label);
    }
    sections.clearRetainingCapacity();
}

pub fn reset() void {
    clearPreview();
    clearFiles();
    clearSections();
    scanned = false;
    selected_section = -1;
    selected_file = -1;
}
