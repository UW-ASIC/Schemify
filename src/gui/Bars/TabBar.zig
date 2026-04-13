//! Tab bar — horizontal row of open schematic tabs with view-mode switcher.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("../Actions.zig");
const SymbolRenderer = @import("../Canvas/SymbolRenderer.zig");
const components = @import("../Components/lib.zig");
const tc = @import("theme_config");

const FileType = SymbolRenderer.FileType;
const classifyFile = SymbolRenderer.classifyFile;

const TabBar = components.HorizontalBar(.{ .height = 30 });

/// Draw the tab bar showing all open schematics and view-mode buttons.
pub fn draw(app: *AppState) void {
    TabBar.draw(@src(), drawContents, app, 0);
}

fn drawContents(app: *AppState) void {
    const shape = tc.getTabShape();
    const r = tc.getCornerRadius();

    // Corner radius per shape:
    //   0 = rect      — fully sharp
    //   1 = rounded   — uniform radius (current default)
    //   2 = arrow     — uniform radius + chevron suffix >> on each tab
    //   3 = angled    — rounded top corners only (trapezoid feel)
    //   4 = underline — rounded top corners only (same as angled, minimal)
    const cr: dvui.Rect = switch (shape) {
        0 => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        1 => .{ .x = r, .y = r, .w = r, .h = r },
        2 => .{ .x = r, .y = r, .w = r, .h = r },
        3 => .{ .x = r, .y = r, .w = 0, .h = 0 },
        4 => .{ .x = r, .y = r, .w = 0, .h = 0 },
        else => .{ .x = r, .y = r, .w = r, .h = r },
    };

    // Arrow (shape 2) appends a right-pointing chevron to each tab label.
    const arrow_suffix: []const u8 = if (shape == 2) " \xc2\xbb" else "";

    // ── Document tabs ────────────────────────────────────────────────────── //
    for (app.documents.items, 0..) |*doc, idx| {
        const is_active = idx == @as(usize, app.active_idx);
        var buf: [80]u8 = undefined;
        const prefix: []const u8 = if (doc.dirty) "\xe2\x97\x8f " else "";
        // Show the full filename including extension (e.g. "untitled.comp")
        const label = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ prefix, doc.name, arrow_suffix }) catch doc.name;

        if (is_active) {
            _ = dvui.button(@src(), label, .{}, .{ .style = .highlight, .id_extra = idx, .corner_radius = cr });
        } else {
            if (dvui.button(@src(), label, .{}, .{ .id_extra = idx, .corner_radius = cr })) {
                app.active_idx = @intCast(idx);
                app.status_msg = "Switched tab";
            }
        }
    }

    // ── New-tab button ───────────────────────────────────────────────────── //
    if (dvui.button(@src(), "+", .{}, .{ .id_extra = 9000, .corner_radius = cr })) {
        actions.enqueue(app, .{ .immediate = .new_tab }, "New tab");
    }

    // Push Sch/Sym to the far right.
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // ── View-mode toggle (far right, pill pair) ──────────────────────────── //
    // Determine which buttons to show based on file type:
    //   .full      -> show both SCH and SYM
    //   .prim_only -> hide SCH (symbol only)
    //   .tb_only   -> hide SYM (schematic only)
    const file_type: FileType = if (app.active_idx < app.documents.items.len)
        classifyFile(app.documents.items[app.active_idx].origin)
    else
        .full;

    const show_sch = file_type != .prim_only;
    const show_sym = file_type != .tb_only;

    const sch_active = app.gui.hot.view_mode == .schematic;
    const sym_active = app.gui.hot.view_mode == .symbol;
    const sch_style: dvui.Theme.Style.Name = if (sch_active) .highlight else .control;
    const sym_style: dvui.Theme.Style.Name = if (sym_active) .highlight else .control;

    if (show_sch) {
        if (dvui.button(@src(), "SCH", .{}, .{ .style = sch_style, .id_extra = 9001, .corner_radius = cr }))
            actions.runGuiCommand(app, .view_schematic);
    }
    if (show_sym) {
        if (dvui.button(@src(), "SYM", .{}, .{ .style = sym_style, .id_extra = 9002, .corner_radius = cr }))
            actions.runGuiCommand(app, .view_symbol);
    }

    // ── Close tab (only with >1 tab) ─────────────────────────────────────── //
    if (app.documents.items.len > 1) {
        if (dvui.button(@src(), "\xe2\x9c\x95", .{}, .{ .style = .err, .id_extra = 9003, .corner_radius = cr })) {
            actions.enqueue(app, .{ .immediate = .close_tab }, "Close tab");
        }
    }
}
