//! FileExplorer — modal file browser with sections + file list + symbol preview.
//! Simplified: substring match instead of fuzzy scoring, on-demand preview loading.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");
const theme = @import("theme_config");
const helpers = @import("../helpers.zig");
const AppState = st.AppState;

const toDvui = helpers.toDvui;

// ── Theme-derived colors ─────────────────────────────────────────────────────

fn search_bar_bg() dvui.Color { const pal = theme.Palette.dark(); return toDvui(pal.canvas_bg); }
fn section_bg() dvui.Color { return toDvui(theme.chromeTabbarBg()); }
fn selected_bg() dvui.Color { const a = theme.chromeAccent(); return .{ .r = a.r / 4, .g = a.g / 4, .b = a.b / 2, .a = 255 }; }
fn hover_bg() dvui.Color { return toDvui(theme.chromeHoverBg()); }
fn file_hover_bg() dvui.Color { const h2 = theme.chromeHoverBg(); return .{ .r = h2.r -| 8, .g = h2.g -| 8, .b = h2.b -| 8, .a = 180 }; }
const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
fn muted() dvui.Color { return toDvui(theme.chromeTextSecondary()); }
fn badge_dir() dvui.Color { return toDvui(theme.chromeAccent()); }
fn badge_chn() dvui.Color { const pal = theme.Palette.dark(); return toDvui(pal.wire_endpoint); }
fn badge_other() dvui.Color { const s = theme.chromeSeparator(); return .{ .r = s.r +| 62, .g = s.g +| 64, .b = s.b +| 68, .a = 255 }; }

// ── Section / File models ────────────────────────────────────────────────────

const SectionKind = enum { components, testbenches, primitives, pdk };

const Section = struct { label: []const u8, kind: SectionKind };

const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    kind: SectionKind,
    is_dir: bool,
};

// ── Module state ─────────────────────────────────────────────────────────────

var sections: std.ArrayListUnmanaged(Section) = .{};
var files: std.ArrayListUnmanaged(FileEntry) = .{};
var filtered: std.ArrayListUnmanaged(u32) = .{};
var prev_query_len: usize = 0;
var prev_section: i32 = -2;
var preview_arena_state: ?std.heap.ArenaAllocator = null;

// ── Text input API (called from Input/lib.zig) ───────────────────────────────

pub fn onKeyChar(app: *AppState, ch: u8) bool {
    if (!app.open_file_explorer or ch == 0) return false;
    const fe = &app.gui.cold.file_explorer;
    if (fe.query_len >= fe.query_buf.len - 1) return true;
    fe.query_buf[fe.query_len] = ch;
    fe.query_len += 1;
    fe.selected_file = -1;
    return true;
}

pub fn onKeyBackspace(app: *AppState) bool {
    if (!app.open_file_explorer) return false;
    const fe = &app.gui.cold.file_explorer;
    if (fe.query_len == 0) return true;
    fe.query_len -= 1;
    fe.query_buf[fe.query_len] = 0;
    fe.selected_file = -1;
    return true;
}

pub fn onKeyEscape(app: *AppState) bool {
    if (!app.open_file_explorer) return false;
    const fe = &app.gui.cold.file_explorer;
    if (fe.query_len > 0) {
        fe.query_len = 0;
        @memset(&fe.query_buf, 0);
        return true;
    }
    app.open_file_explorer = false;
    return true;
}

// ── Public draw ──────────────────────────────────────────────────────────────

pub fn draw(app: *AppState) void {
    if (!app.open_file_explorer) return;
    const fe = &app.gui.cold.file_explorer;

    if (!fe.scanned) { scanSections(app); fe.scanned = true; }

    if (fe.query_len != prev_query_len or fe.selected_section != prev_section) {
        refreshFilter(app.allocator(), fe);
        prev_query_len = fe.query_len;
        prev_section = fe.selected_section;
    }

    // Center and size modal to 80% of window
    const win = dvui.windowRect();
    fe.win_rect.w = win.w * 0.80;
    fe.win_rect.h = win.h * 0.80;
    fe.win_rect.x = (win.w - fe.win_rect.w) / 2.0;
    fe.win_rect.y = (win.h - fe.win_rect.h) / 2.0;

    var dialog_phys: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    {
        var fwin = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &app.open_file_explorer,
            .rect = @ptrCast(&fe.win_rect),
            .resize = .none,
        }, .{ .min_size_content = .{ .w = 480, .h = 320 } });
        defer fwin.deinit();
        dialog_phys = fwin.data().rectScale().r;
        _ = dvui.windowHeader("File Explorer", "", &app.open_file_explorer);

        drawSearchBar(fe);
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();
        drawSections(app);
        _ = dvui.separator(@src(), .{ .id_extra = 100 });
        drawFileList(app);
    }

    // Outside-click dismissal
    if (app.open_file_explorer) {
        for (dvui.events()) |*ev| {
            if (ev.handled) continue;
            switch (ev.evt) {
                .mouse => |me| {
                    if (me.action != .press or !me.button.pointer()) continue;
                    if (dialog_phys.contains(me.p)) continue;
                    app.open_file_explorer = false;
                    ev.handled = true;
                    break;
                },
                else => {},
            }
        }
    }
}

// ── Search bar ───────────────────────────────────────────────────────────────

fn drawSearchBar(fe: *st.FileExplorerState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .background = true, .color_fill = search_bar_bg(),
    });
    defer bar.deinit();

    dvui.labelNoFmt(@src(), "Search:", .{}, .{ .id_extra = 900, .gravity_y = 0.5, .color_text = muted() });
    _ = dvui.spacer(@src(), .{ .id_extra = 901, .min_size_content = .{ .w = 6 } });

    var buf: [148]u8 = undefined;
    const q = fe.query_buf[0..fe.query_len];
    const rendered = if (q.len == 0)
        std.fmt.bufPrint(&buf, "(type to filter)\xe2\x96\x8c", .{}) catch "(type to filter)"
    else
        std.fmt.bufPrint(&buf, "{s}\xe2\x96\x8c", .{q}) catch q;
    dvui.labelNoFmt(@src(), rendered, .{}, .{
        .id_extra = 902, .expand = .horizontal, .gravity_y = 0.5,
        .style = if (q.len == 0) .control else .content,
    });
}

// ── Sections (left column) ───────────────────────────────────────────────────

fn drawSections(app: *AppState) void {
    const fe = &app.gui.cold.file_explorer;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 160 }, .padding = .all(6),
        .background = true, .color_fill = section_bg(),
    });
    defer col.deinit();

    dvui.labelNoFmt(@src(), "SECTIONS", .{}, .{ .id_extra = 200, .style = .control, .color_text = muted() });
    _ = dvui.spacer(@src(), .{ .id_extra = 201, .min_size_content = .{ .h = 4 } });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 202 });
    defer scroll.deinit();

    for (sections.items, 0..) |sec, si| {
        const is_sel = fe.selected_section == @as(i32, @intCast(si));
        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = si * 2, .expand = .horizontal, .background = true,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 }, .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .color_fill = if (is_sel) selected_bg() else transparent, .color_fill_hover = hover_bg(),
        });
        defer card.deinit();
        dvui.labelNoFmt(@src(), sec.label, .{}, .{ .id_extra = si * 10 + 3, .expand = .horizontal, .gravity_y = 0.5 });
        if (dvui.clicked(&card.wd, .{})) {
            if (fe.selected_section != @as(i32, @intCast(si))) {
                fe.selected_section = @intCast(si);
                fe.selected_file = -1;
                fe.preview_name = "";
                clearPreviewCache(fe);
            }
        }
    }
}

// ── File list (right column) ─────────────────────────────────────────────────

fn drawFileList(app: *AppState) void {
    const fe = &app.gui.cold.file_explorer;
    var area = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 } });
    defer area.deinit();

    // Header
    const ak: ?SectionKind = if (fe.selected_section >= 0 and @as(usize, @intCast(fe.selected_section)) < sections.items.len)
        sections.items[@intCast(fe.selected_section)].kind else null;
    {
        const label: []const u8 = if (fe.selected_section >= 0 and @as(usize, @intCast(fe.selected_section)) < sections.items.len)
            sections.items[@intCast(fe.selected_section)].label else "Select a section";
        dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = 301, .style = .control, .color_text = muted() });
    }
    _ = dvui.spacer(@src(), .{ .id_extra = 302, .min_size_content = .{ .h = 2 } });

    if (ak != null and ak.? == .pdk) { drawPdkInfo(app); return; }

    if (filtered.items.len == 0) {
        const msg: []const u8 = if (fe.selected_section < 0) "Select a section to browse files."
            else if (fe.query_len > 0) "No matches for query."
            else "No files found.";
        dvui.labelNoFmt(@src(), msg, .{}, .{ .id_extra = 303, .style = .control });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 304 });
    defer scroll.deinit();

    for (filtered.items) |fi_u32| {
        const fi: usize = fi_u32;
        if (fi >= files.items.len) continue;
        const fe_entry = files.items[fi];
        const is_sel = fe.selected_file == @as(i32, @intCast(fi));

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi * 2, .expand = .horizontal, .background = true,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .color_fill = if (is_sel) selected_bg() else transparent, .color_fill_hover = file_hover_bg(),
        });
        defer card.deinit();

        // Badge
        const badge: []const u8 = if (fe_entry.is_dir) "DIR" else classifyBadge(fe_entry.name);
        const bc: dvui.Color = if (fe_entry.is_dir) badge_dir()
            else if (std.mem.endsWith(u8, fe_entry.name, ".chn")) badge_chn()
            else badge_other();
        dvui.labelNoFmt(@src(), badge, .{}, .{ .id_extra = fi * 10 + 1, .gravity_y = 0.5, .color_text = bc, .min_size_content = .{ .w = 30 } });
        _ = dvui.spacer(@src(), .{ .id_extra = fi * 10 + 2, .min_size_content = .{ .w = 4 } });
        dvui.labelNoFmt(@src(), fe_entry.name, .{}, .{ .id_extra = fi * 10 + 3, .expand = .horizontal, .gravity_y = 0.5 });

        if (dvui.clicked(&card.wd, .{})) {
            if (is_sel) {
                var pb: [512]u8 = undefined;
                const fp = if (std.fs.path.isAbsolute(fe_entry.path)) fe_entry.path
                    else std.fmt.bufPrint(&pb, "{s}/{s}", .{ app.project_dir, fe_entry.path }) catch fe_entry.path;
                app.openPath(fp) catch { app.status_msg = "Failed to open file"; return; };
                app.open_file_explorer = false;
            } else {
                fe.selected_file = @intCast(fi);
                fe.preview_name = fe_entry.name;
                clearPreviewCache(fe);
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

// ── PDK info panel ───────────────────────────────────────────────────────────

fn drawPdkInfo(app: *AppState) void {
    const Devices = core.devices.Devices;
    const pdk = &Devices.global_pdk;

    var info = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both, .padding = .all(6), .background = true, .color_fill = search_bar_bg(), .id_extra = 700,
    });
    defer info.deinit();

    dvui.labelNoFmt(@src(), "PROCESS DESIGN KIT", .{}, .{ .id_extra = 701, .style = .control, .color_text = muted() });
    _ = dvui.spacer(@src(), .{ .id_extra = 702, .min_size_content = .{ .h = 6 } });

    if (app.config.pdk) |nm| {
        if (nm.len == 0) { dvui.labelNoFmt(@src(), "(no PDK loaded)", .{}, .{ .id_extra = 720, .style = .control }); return; }
        infoRow("Name:", nm, 710);
    } else {
        dvui.labelNoFmt(@src(), "(no PDK loaded)", .{}, .{ .id_extra = 720, .style = .control });
        return;
    }

    // Show PDK metadata from the global PDK singleton
    if (!pdk.isEmpty()) {
        infoRow("Corner:", pdk.default_corner, 712);
        infoRow("Dialect:", @tagName(pdk.dialect), 714);

        _ = dvui.spacer(@src(), .{ .id_extra = 703, .min_size_content = .{ .h = 4 } });

        var count_buf: [32]u8 = undefined;
        const prim_label = std.fmt.bufPrint(&count_buf, "{d}", .{pdk.prims.len}) catch "?";
        infoRow("Primitives:", prim_label, 716);

        var count_buf2: [32]u8 = undefined;
        const comp_label = std.fmt.bufPrint(&count_buf2, "{d}", .{pdk.comps.len}) catch "?";
        infoRow("Components:", comp_label, 718);

        var count_buf3: [32]u8 = undefined;
        const tb_label = std.fmt.bufPrint(&count_buf3, "{d}", .{pdk.tbs.len}) catch "?";
        infoRow("Testbenches:", tb_label, 722);

        _ = dvui.spacer(@src(), .{ .id_extra = 704, .min_size_content = .{ .h = 6 } });
        dvui.labelNoFmt(@src(), "CELLS", .{}, .{ .id_extra = 730, .style = .control, .color_text = muted() });
        _ = dvui.spacer(@src(), .{ .id_extra = 731, .min_size_content = .{ .h = 2 } });

        // Scrollable list of PDK cell names
        drawPdkCellList(app, pdk);
    } else {
        _ = dvui.spacer(@src(), .{ .id_extra = 703, .min_size_content = .{ .h = 4 } });
        dvui.labelNoFmt(@src(), "(PDK registered but no cells loaded)", .{}, .{ .id_extra = 721, .style = .control });
    }
}

fn drawPdkCellList(app: *AppState, pdk: *const core.devices.Devices.Pdk) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 740 });
    defer scroll.deinit();

    const fe = &app.gui.cold.file_explorer;
    const query = fe.query_buf[0..fe.query_len];

    for (pdk.name_idx.items, 0..) |entry, i| {
        // Apply search filter if query is active
        if (query.len > 0 and !substringMatch(entry.name, query)) continue;

        const tier_label: []const u8 = switch (entry.ref.tier) {
            .prim => "PRM",
            .comp => "SCH",
            .tb => "TB",
            .unregistered => "---",
        };
        const tier_color: dvui.Color = switch (entry.ref.tier) {
            .prim => badge_other(),
            .comp => badge_chn(),
            .tb => badge_dir(),
            .unregistered => muted(),
        };

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i * 2, .expand = .horizontal, .background = true,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .color_fill = transparent, .color_fill_hover = file_hover_bg(),
        });
        defer card.deinit();

        dvui.labelNoFmt(@src(), tier_label, .{}, .{
            .id_extra = i * 10 + 1, .gravity_y = 0.5, .color_text = tier_color,
            .min_size_content = .{ .w = 30 },
        });
        _ = dvui.spacer(@src(), .{ .id_extra = i * 10 + 2, .min_size_content = .{ .w = 4 } });
        dvui.labelNoFmt(@src(), entry.name, .{}, .{ .id_extra = i * 10 + 3, .expand = .horizontal, .gravity_y = 0.5 });

        // On click, open the associated file if the cell has one
        if (dvui.clicked(&card.wd, .{})) {
            const file_path: []const u8 = switch (entry.ref.tier) {
                .prim => if (entry.ref.idx < pdk.prims.len) pdk.prims.slice().items(.file)[entry.ref.idx] else "",
                .comp => if (entry.ref.idx < pdk.comps.len) pdk.comps.slice().items(.file)[entry.ref.idx] else "",
                .tb => if (entry.ref.idx < pdk.tbs.len) pdk.tbs.slice().items(.file)[entry.ref.idx] else "",
                .unregistered => "",
            };
            if (file_path.len > 0) {
                app.openPath(file_path) catch {
                    app.status_msg = "Failed to open PDK cell file";
                };
            }
        }
    }
}

fn infoRow(label: []const u8, value: []const u8, id: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = id + 1, .gravity_y = 0.5, .min_size_content = .{ .w = 96 }, .color_text = muted() });
    dvui.labelNoFmt(@src(), value, .{}, .{ .id_extra = id + 2, .gravity_y = 0.5, .expand = .horizontal });
}

// ── Filter (substring match) ─────────────────────────────────────────────────

fn refreshFilter(alloc: std.mem.Allocator, fe: *const st.FileExplorerState) void {
    filtered.clearRetainingCapacity();
    const query = fe.query_buf[0..fe.query_len];
    const sel = fe.selected_section;
    const ak: ?SectionKind = if (sel >= 0 and @as(usize, @intCast(sel)) < sections.items.len) sections.items[@intCast(sel)].kind else null;

    for (files.items, 0..) |fe_entry, i| {
        if (query.len == 0) {
            if (ak) |k| if (fe_entry.kind != k) continue;
        } else {
            if (fe_entry.kind == .pdk) continue;
            if (!substringMatch(fe_entry.name, query)) continue;
        }
        filtered.append(alloc, @intCast(i)) catch return;
    }
}

fn substringMatch(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |i| {
        var ok = true;
        for (query, 0..) |qc, j| {
            const nc = name[i + j];
            if (toLower(nc) != toLower(qc)) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

inline fn toLower(c: u8) u8 { return if (c >= 'A' and c <= 'Z') c + 32 else c; }

// ── Preview cache ────────────────────────────────────────────────────────────

fn clearPreviewCache(fe: *st.FileExplorerState) void {
    if (preview_arena_state) |*a| { a.deinit(); preview_arena_state = null; }
    fe.preview_sch = null;
    fe.preview_path = "";
}

// ── Section scanning ─────────────────────────────────────────────────────────

fn scanSections(app: *AppState) void {
    const alloc = app.allocator();
    clearAll(alloc);
    const fe = &app.gui.cold.file_explorer;

    const Devices = core.devices.Devices;
    const pdk = &Devices.global_pdk;
    const pdk_cell_count = pdk.prims.len + pdk.comps.len + pdk.tbs.len;

    appendSection(alloc, "Components", .components, app.config.paths.chn.len);
    appendSection(alloc, "Testbenches", .testbenches, app.config.paths.chn_tb.len);
    appendSection(alloc, "Primitives", .primitives, app.config.paths.chn_prim.len);
    appendSection(alloc, "PDK", .pdk, pdk_cell_count);

    appendPaths(alloc, app.config.paths.chn, .components);
    appendPaths(alloc, app.config.paths.chn_tb, .testbenches);
    appendPaths(alloc, app.config.paths.chn_prim, .primitives);

    if (sections.items.len > 0) fe.selected_section = 0;
}

fn appendSection(alloc: std.mem.Allocator, name: []const u8, kind: SectionKind, count: usize) void {
    var buf: [64]u8 = undefined;
    const label = if (kind == .pdk and count == 0)
        std.fmt.bufPrint(&buf, "{s}", .{name}) catch name
    else
        std.fmt.bufPrint(&buf, "{s} ({d})", .{ name, count }) catch name;
    const dup = alloc.dupe(u8, label) catch return;
    sections.append(alloc, .{ .label = dup, .kind = kind }) catch alloc.free(dup);
}

fn appendPaths(alloc: std.mem.Allocator, paths: []const []const u8, kind: SectionKind) void {
    for (paths) |p| {
        const name = std.fs.path.basename(p);
        const nd = alloc.dupe(u8, name) catch continue;
        const pd = alloc.dupe(u8, p) catch { alloc.free(nd); continue; };
        files.append(alloc, .{ .name = nd, .path = pd, .kind = kind, .is_dir = false }) catch { alloc.free(nd); alloc.free(pd); };
    }
}

// ── Cleanup ──────────────────────────────────────────────────────────────────

fn clearAll(alloc: std.mem.Allocator) void {
    for (files.items) |fe| { alloc.free(fe.name); alloc.free(fe.path); }
    files.clearRetainingCapacity();
    for (sections.items) |sec| alloc.free(sec.label);
    sections.clearRetainingCapacity();
    filtered.clearRetainingCapacity();
}

pub fn reset(app: *AppState) void {
    const alloc = app.allocator();
    const fe = &app.gui.cold.file_explorer;
    fe.preview_name = "";
    clearPreviewCache(fe);
    clearAll(alloc);
    files.deinit(alloc);
    sections.deinit(alloc);
    filtered.deinit(alloc);
    fe.scanned = false;
    fe.selected_section = -1;
    fe.selected_file = -1;
    fe.query_len = 0;
    @memset(&fe.query_buf, 0);
}
