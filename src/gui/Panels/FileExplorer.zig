//! FileExplorer — modal file browser with corner symbol-preview hint.
//!
//! Layout:
//!   +----------+----------------------------+
//!   |          |  Files in section          |
//!   | Sections |                            |
//!   | (PDK,    |                            |
//!   |  dirs)   |                            |
//!   |          |              +-----------+ |
//!   |          |              |  symbol   | |
//!   |          |              |  preview  | |
//!   |          |              +-----------+ |
//!   +----------+----------------------------+
//!
//! Modal behaviour:
//!   - Translucent dark overlay covers the canvas (dvui modal = true).
//!   - Clicking the overlay closes the dialog (handled by dvui modal).
//!   - The window cannot be dragged (we never call `fwin.dragAreaSet`).
//!   - The window is re-centered on the OS window every frame.
//!   - `windowHeader` with a non-null `open_flag` renders an ✕ close button.
//!
//! Symbol preview hint:
//!   - When a `.chn` file is selected, the parsed schematic's symbol view is
//!     drawn in a small floating panel pinned to the bottom-right corner of
//!     the dialog body. The preview is fit-to-bounds (85% margin) and reuses
//!     the canvas SymbolRenderer so the hint matches the actual canvas
//!     rendering pixel-for-pixel.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const core = @import("core");
const theme = @import("theme_config");
const utility = @import("utility");
const Vfs = utility.Vfs;
const components = @import("../Components/lib.zig");

const AppState = st.AppState;

// Canvas sub-modules (read-only — we never modify them).
const canvas_types = @import("../Canvas/types.zig");
const symbol_renderer = @import("../Canvas/SymbolRenderer.zig");
const RenderContext = canvas_types.RenderContext;
const RenderViewport = canvas_types.RenderViewport;
const Palette = canvas_types.Palette;

// ── Theme constants ──────────────────────────────────────────────────────── //

const search_bar_bg = dvui.Color{ .r = 22, .g = 22, .b = 28, .a = 255 };
const section_bg = dvui.Color{ .r = 30, .g = 30, .b = 38, .a = 255 };
const section_bg_transparent = dvui.Color{ .r = 30, .g = 30, .b = 38, .a = 0 };
const selected_bg = dvui.Color{ .r = 45, .g = 95, .b = 175, .a = 255 };
const hover_bg = dvui.Color{ .r = 50, .g = 55, .b = 75, .a = 220 };
const file_hover_bg = dvui.Color{ .r = 50, .g = 55, .b = 75, .a = 180 };
const transparent_bg = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
const muted_text = dvui.Color{ .r = 140, .g = 140, .b = 160, .a = 255 };
const header_text = dvui.Color{ .r = 180, .g = 180, .b = 200, .a = 255 };
const badge_dir = dvui.Color{ .r = 120, .g = 160, .b = 230, .a = 255 };
const badge_chn = dvui.Color{ .r = 120, .g = 210, .b = 120, .a = 255 };
const badge_other = dvui.Color{ .r = 160, .g = 160, .b = 180, .a = 255 };

// ── Section model ────────────────────────────────────────────────────────── //

const SectionKind = enum { components, testbenches, primitives, pdk };

const Section = struct {
    label: []const u8,
    kind: SectionKind,
};

const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    /// Which file-list section this entry belongs to. Used so the fuzzy
    /// search bar can filter across Components, Testbenches and Primitives
    /// simultaneously while still knowing which section header each matched
    /// row belongs under in the right column.
    kind: SectionKind,
    is_dir: bool,
};

// ── Module-level allocation containers (private types, persist across frames) ─

var sections: std.ArrayListUnmanaged(Section) = .{};
var files: std.ArrayListUnmanaged(FileEntry) = .{};

var prev_query_len: usize = 0;
var prev_selected_section: i32 = -2; // -2 = never matched

/// Indices into `files.items` after applying the current fuzzy-search query.
/// When the query is empty this is a pass-through 0..files.len in natural
/// order. When the query is non-empty this is only the matching indices,
/// sorted ascending by score (lower = better). Rebuilt each frame by
/// `refreshFilter()`.
var filtered: std.ArrayListUnmanaged(FilteredEntry) = .{};

const FilteredEntry = struct {
    index: u32,
    score: i32,
};

// Arena for the cached preview Schemify. Reset whenever we load a new file.
var preview_arena_state: ?std.heap.ArenaAllocator = null;

fn previewArena(backing: std.mem.Allocator) std.mem.Allocator {
    if (preview_arena_state == null) {
        preview_arena_state = std.heap.ArenaAllocator.init(backing);
    }
    return preview_arena_state.?.allocator();
}

fn freePreviewArena() void {
    if (preview_arena_state) |*a| {
        a.deinit();
        preview_arena_state = null;
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────── //

inline fn previewSchPtr(fe_state: *const st.FileExplorerState) ?*core.Schemify {
    if (fe_state.preview_sch) |raw| {
        return @ptrCast(@alignCast(raw));
    }
    return null;
}


// ── Fuzzy match ──────────────────────────────────────────────────────────── //

/// Lower-case an ASCII byte. Non-ASCII passes through unchanged.
inline fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// True if a byte is a fuzzy-match word boundary separator.
inline fn isSep(c: u8) bool {
    return c == '_' or c == '-' or c == '.' or c == '/' or c == ' ';
}

/// Subsequence fuzzy matcher: each byte of `query` must appear in `name`
/// in order, case-insensitive. Returns null on no match. Lower score = better.
///
/// Scoring (lower is better):
///   +gap size between each consecutive matched pair
///   -3 bonus for matching at the very start of the filename
///   -2 bonus per match that lands at a word-boundary (after `_ - . / ' '`
///      or a camelCase transition)
///   -1 bonus per consecutive-match run (gap == 0)
fn fuzzyScore(name: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (query.len > name.len) return null;

    var score: i32 = 0;
    var n_i: usize = 0;
    var prev_match: ?usize = null;

    for (query) |qc| {
        const qlo = toLowerAscii(qc);
        var found: ?usize = null;
        while (n_i < name.len) : (n_i += 1) {
            if (toLowerAscii(name[n_i]) == qlo) {
                found = n_i;
                n_i += 1;
                break;
            }
        }
        const mi = found orelse return null;

        // Gap penalty.
        if (prev_match) |pm| {
            const gap: i32 = @intCast(mi - pm - 1);
            score += gap;
            if (gap == 0) score -= 1;
        } else {
            if (mi == 0) score -= 3;
        }

        // Word-boundary bonus.
        if (mi > 0) {
            const prev_c = name[mi - 1];
            const cur_c = name[mi];
            const boundary = isSep(prev_c) or
                (prev_c >= 'a' and prev_c <= 'z' and cur_c >= 'A' and cur_c <= 'Z');
            if (boundary) score -= 2;
        }

        prev_match = mi;
    }

    return score;
}

/// Rebuild the `filtered` list from the current `files` list and the
/// query buffer in `fe_state`. Called at the top of `draw()`.
///
/// Behaviour:
///   - If the query is empty and the active section is one of the three
///     file-list sections (components/testbenches/primitives), only rows
///     with that section kind are emitted, in natural (scan) order.
///   - If the query is non-empty, rows from ALL three file-list sections
///     are considered and sorted ascending by fuzzy score (the fuzzy bar
///     intentionally cuts across sections so the user can search the
///     whole project).
///   - The PDK section is a read-only info display and is never added to
///     the filtered list.
fn refreshFilter(alloc: std.mem.Allocator, fe_state: *const st.FileExplorerState) void {
    filtered.clearRetainingCapacity();
    const query = fe_state.query_buf[0..fe_state.query_len];

    const sel = fe_state.selected_section;
    const active_kind: ?SectionKind = if (sel >= 0 and
        @as(usize, @intCast(sel)) < sections.items.len)
        sections.items[@intCast(sel)].kind
    else
        null;

    if (query.len == 0) {
        for (files.items, 0..) |fe, i| {
            if (active_kind) |k| if (fe.kind != k) continue;
            filtered.append(alloc, .{ .index = @intCast(i), .score = 0 }) catch return;
        }
        return;
    }

    // When a query is live, search across all file-list sections (skip PDK).
    for (files.items, 0..) |fe, i| {
        if (fe.kind == .pdk) continue;
        if (fuzzyScore(fe.name, query)) |s| {
            filtered.append(alloc, .{ .index = @intCast(i), .score = s }) catch return;
        }
    }

    // Sort ascending by score. Stable so equal scores keep natural order.
    const Ctx = struct {
        fn lessThan(_: void, a: FilteredEntry, b: FilteredEntry) bool {
            return a.score < b.score;
        }
    };
    std.sort.block(FilteredEntry, filtered.items, {}, Ctx.lessThan);
}

// ── Text input (the search bar receives characters via lib.zig) ──────────── //

/// Append a single ASCII byte to the fuzzy-search query buffer. Returns
/// `true` if the character was consumed. Called from the top-level key
/// handler in `gui/lib.zig` when the File Explorer has focus.
pub fn onKeyChar(app: *AppState, ch: u8) bool {
    if (!app.open_file_explorer) return false;
    if (ch == 0) return false;
    const fe_state = &app.gui.cold.file_explorer;
    if (fe_state.query_len >= fe_state.query_buf.len - 1) return true;
    fe_state.query_buf[fe_state.query_len] = ch;
    fe_state.query_len += 1;
    // New query → clear any stale selection so the first filtered match is
    // highlighted on the next click.
    fe_state.selected_file = -1;
    return true;
}

/// Delete the last byte of the fuzzy-search query buffer.
pub fn onKeyBackspace(app: *AppState) bool {
    if (!app.open_file_explorer) return false;
    const fe_state = &app.gui.cold.file_explorer;
    if (fe_state.query_len == 0) return true;
    fe_state.query_len -= 1;
    fe_state.query_buf[fe_state.query_len] = 0;
    fe_state.selected_file = -1;
    return true;
}

/// Clear the query buffer (Escape inside the FileExplorer clears the query
/// first, then closes the dialog on a second press).
pub fn onKeyEscape(app: *AppState) bool {
    if (!app.open_file_explorer) return false;
    const fe_state = &app.gui.cold.file_explorer;
    if (fe_state.query_len > 0) {
        fe_state.query_len = 0;
        @memset(&fe_state.query_buf, 0);
        return true;
    }
    app.open_file_explorer = false;
    return true;
}

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!app.open_file_explorer) return;

    const fe_state = &app.gui.cold.file_explorer;

    if (!fe_state.scanned) {
        scanSections(app);
        fe_state.scanned = true;
    }

    // Only rebuild filtered list when the query or section changed.
    if (fe_state.query_len != prev_query_len or fe_state.selected_section != prev_selected_section) {
        refreshFilter(app.allocator(), fe_state);
        prev_query_len = fe_state.query_len;
        prev_selected_section = fe_state.selected_section;
    }

    // Resize and center on the OS window every frame so the dialog tracks
    // window resizes. The modal is sized to 80% of the natural window size
    // and pinned dead-center; this is the "large modal" sizing required by
    // the FileExplorer redesign.
    const win = dvui.windowRect();
    fe_state.win_rect.w = win.w * 0.80;
    fe_state.win_rect.h = win.h * 0.80;
    fe_state.win_rect.x = (win.w - fe_state.win_rect.w) / 2.0;
    fe_state.win_rect.y = (win.h - fe_state.win_rect.h) / 2.0;

    // Snapshot of the dialog rect in physical pixels, captured inside the
    // floatingWindow scope before its defer fires. Used by the outside-click
    // scanner that runs after the floatingWindow has been deinit-ed.
    var dialog_phys: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    {
        var fwin = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &app.open_file_explorer,
            .rect = components.winRectPtr(&fe_state.win_rect),
            // Disable resize handles — dialog must be fixed-size and
            // unmoveable. We also never call fwin.dragAreaSet() so the
            // header cannot start a drag either.
            .resize = .none,
        }, .{
            .min_size_content = .{ .w = 480, .h = 320 },
        });
        defer fwin.deinit();

        dialog_phys = fwin.data().rectScale().r;

        // windowHeader with a non-null open_flag renders the ✕ close button.
        // We deliberately do NOT call fwin.dragAreaSet() so the window cannot
        // be dragged by the user.
        _ = dvui.windowHeader("File Explorer", "", &app.open_file_explorer);

        // Search bar pinned to the top of the body.
        drawSearchBar(fe_state);

        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer body.deinit();

        // Left column: sections.
        drawSections(app);

        // Vertical separator.
        _ = dvui.separator(@src(), .{ .id_extra = 100 });

        // Right column: file list (preview floats over the bottom-right corner).
        drawFileList(app);

        // Symbol preview hint, anchored to the bottom-right of the dialog body.
        drawPreviewHint(app, body.data().contentRectScale().r);
    }

    // Outside-click dismissal: scan all unhandled mouse press events that
    // landed outside the dialog rect. The dvui modal floatingWindow already
    // paints a translucent fade over everything below us (using the theme's
    // `.text` color with alpha 60/80), so this implements the "click the
    // shadow to close" affordance referenced in TODO.md.
    //
    // Why this works: the modal's `processEventsAfter` only consumes presses
    // whose physical position lies inside the floatingWindow's drag_area
    // (defaults to the full window rect). Presses outside the rect are left
    // unhandled, and we catch them here.
    if (app.open_file_explorer) {
        for (dvui.events()) |*ev| {
            if (ev.handled) continue;
            switch (ev.evt) {
                .mouse => |me| {
                    if (me.action != .press) continue;
                    if (!me.button.pointer()) continue;
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

// ── Search bar ───────────────────────────────────────────────────────────── //

/// Draw a vim-style search bar at the top of the dialog body. Because
/// `dvui.textEntry` is not yet stable in this project, the bar is rendered
/// as a simple label and the characters are fed in from
/// `gui/lib.zig`'s keyboard handler via `onKeyChar` / `onKeyBackspace`.
fn drawSearchBar(fe_state: *st.FileExplorerState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .background = true,
        .color_fill = search_bar_bg,
    });
    defer bar.deinit();

    dvui.labelNoFmt(@src(), "Search:", .{}, .{
        .id_extra = 900,
        .gravity_y = 0.5,
        .color_text = muted_text,
    });
    _ = dvui.spacer(@src(), .{ .id_extra = 901, .min_size_content = .{ .w = 6 } });

    var buf: [148]u8 = undefined;
    const q = fe_state.query_buf[0..fe_state.query_len];
    const rendered = if (q.len == 0)
        std.fmt.bufPrint(&buf, "(type to filter)▌", .{}) catch "(type to filter)▌"
    else
        std.fmt.bufPrint(&buf, "{s}▌", .{q}) catch q;

    dvui.labelNoFmt(@src(), rendered, .{}, .{
        .id_extra = 902,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .style = if (q.len == 0) .control else .content,
    });
}

// ── Left column: sections ────────────────────────────────────────────────── //

fn drawSections(app: *AppState) void {
    const fe_state = &app.gui.cold.file_explorer;

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 160 },
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .background = true,
        .color_fill = section_bg,
    });
    defer col.deinit();

    // Header.
    dvui.labelNoFmt(@src(), "SECTIONS", .{}, .{
        .id_extra = 200,
        .style = .control,
        .color_text = muted_text,
    });
    _ = dvui.spacer(@src(), .{ .id_extra = 201, .min_size_content = .{ .h = 4 } });

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .id_extra = 202,
    });
    defer scroll.deinit();

    for (sections.items, 0..) |sec, si| {
        const is_sel = fe_state.selected_section == @as(i32, @intCast(si));

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = si * 2,
            .expand = .horizontal,
            .background = true,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .color_fill = if (is_sel) selected_bg else section_bg_transparent,
            .color_fill_hover = hover_bg,
        });
        defer card.deinit();

        dvui.labelNoFmt(@src(), sec.label, .{}, .{
            .id_extra = si * 10 + 3,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (dvui.clicked(&card.wd, .{})) {
            if (fe_state.selected_section != @as(i32, @intCast(si))) {
                fe_state.selected_section = @intCast(si);
                fe_state.selected_file = -1;
                fe_state.preview_name = "";
                clearPreviewCache(fe_state);
            }
        }
    }
}

// ── Right column: file list ─────────────────────────────────────────────── //

fn drawFileList(app: *AppState) void {
    const fe_state = &app.gui.cold.file_explorer;

    var area = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
    });
    defer area.deinit();

    // Header with section name.
    const active_kind: ?SectionKind = blk: {
        const sel = fe_state.selected_section;
        if (sel < 0 or @as(usize, @intCast(sel)) >= sections.items.len) break :blk null;
        break :blk sections.items[@intCast(sel)].kind;
    };

    {
        const path_label: []const u8 = if (fe_state.selected_section >= 0 and
            @as(usize, @intCast(fe_state.selected_section)) < sections.items.len)
            sections.items[@intCast(fe_state.selected_section)].label
        else
            "Select a section";

        dvui.labelNoFmt(@src(), path_label, .{}, .{
            .id_extra = 301,
            .style = .control,
            .color_text = header_text,
        });
    }
    _ = dvui.spacer(@src(), .{ .id_extra = 302, .min_size_content = .{ .h = 2 } });

    // PDK section is an info display, not a file list.
    if (active_kind != null and active_kind.? == .pdk) {
        drawPdkInfo(app);
        return;
    }

    if (filtered.items.len == 0) {
        const q_len = fe_state.query_len;
        const msg: []const u8 = if (fe_state.selected_section < 0)
            "Select a section to browse files."
        else if (q_len > 0)
            "No matches for query."
        else
            "No files found.";
        dvui.labelNoFmt(@src(), msg, .{}, .{
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

    for (filtered.items) |fent| {
        const fi: usize = @intCast(fent.index);
        if (fi >= files.items.len) continue;
        const fe = files.items[fi];
        const is_sel = fe_state.selected_file == @as(i32, @intCast(fi));

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi * 2,
            .expand = .horizontal,
            .background = true,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .color_fill = if (is_sel) selected_bg else transparent_bg,
            .color_fill_hover = file_hover_bg,
        });
        defer card.deinit();

        // File type badge.
        const badge: []const u8 = if (fe.is_dir) "DIR" else classifyBadge(fe.name);
        const badge_color: dvui.Color = if (fe.is_dir)
            badge_dir
        else if (std.mem.endsWith(u8, fe.name, ".chn"))
            badge_chn
        else
            badge_other;

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
                fe_state.selected_file = @intCast(fi);
                fe_state.preview_name = fe.name;
                // Invalidate preview cache so the preview-hint reloads next frame.
                clearPreviewCache(fe_state);
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

// ── PDK info panel ────────────────────────────────────────────────────── //

/// Render the PDK section body — a small, read-only info panel showing
/// the currently configured PDK name (if any) and the live PDK cell
/// counts from `core.pdk`. Non-interactive.
fn drawPdkInfo(app: *AppState) void {
    const pdk_name: ?[]const u8 = app.config.pdk;

    var info = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .background = true,
        .color_fill = search_bar_bg,
        .id_extra = 700,
    });
    defer info.deinit();

    // Header
    dvui.labelNoFmt(@src(), "PROCESS DESIGN KIT", .{}, .{
        .id_extra = 701,
        .style = .control,
        .color_text = muted_text,
    });
    _ = dvui.spacer(@src(), .{ .id_extra = 702, .min_size_content = .{ .h = 6 } });

    if (pdk_name) |nm| {
        if (nm.len == 0) {
            drawPdkEmpty();
            return;
        }

        // PDK name row.
        drawInfoRow("Name:", nm, 710);

        // Runtime-loaded PDK metadata (from the global singleton). If the
        // PDK wasn't actually loaded by the PDKLoader plugin yet, these
        // counts will be zero and we still show the configured name.
        const loaded = core.pdk;
        if (loaded.name.len > 0 and !std.mem.eql(u8, loaded.name, nm)) {
            drawInfoRow("Loaded:", loaded.name, 711);
        }

        var count_buf: [64]u8 = undefined;
        const comps_s = std.fmt.bufPrint(&count_buf, "{d}", .{loaded.comps.len}) catch "0";
        var count_buf2: [64]u8 = undefined;
        const prims_s = std.fmt.bufPrint(&count_buf2, "{d}", .{loaded.prims.len}) catch "0";
        var count_buf3: [64]u8 = undefined;
        const tbs_s = std.fmt.bufPrint(&count_buf3, "{d}", .{loaded.tbs.len}) catch "0";

        drawInfoRow("Components:", comps_s, 712);
        drawInfoRow("Primitives:", prims_s, 713);
        drawInfoRow("Testbenches:", tbs_s, 714);

        if (loaded.default_corner.len > 0)
            drawInfoRow("Corner:", loaded.default_corner, 715);
    } else {
        drawPdkEmpty();
    }
}

fn drawPdkEmpty() void {
    dvui.labelNoFmt(@src(), "(no PDK loaded)", .{}, .{
        .id_extra = 720,
        .style = .control,
        .color_text = .{ .r = 160, .g = 140, .b = 140, .a = 255 },
    });
}

fn drawInfoRow(label: []const u8, value: []const u8, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
    });
    defer row.deinit();

    dvui.labelNoFmt(@src(), label, .{}, .{
        .id_extra = id_extra + 1,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 96 },
        .color_text = muted_text,
    });
    dvui.labelNoFmt(@src(), value, .{}, .{
        .id_extra = id_extra + 2,
        .gravity_y = 0.5,
        .expand = .horizontal,
        .color_text = .{ .r = 220, .g = 220, .b = 230, .a = 255 },
    });
}

// ── Bottom-right floating preview hint ───────────────────────────────────── //

/// Draw a small symbol-preview floating panel pinned to the bottom-right
/// corner of the dialog body. `body_rect` is the physical bounds of the
/// horizontal body box (sections + file list). The hint is sized as a
/// fraction of the dialog body, never larger than `max_*` and never smaller
/// than `min_*`.
fn drawPreviewHint(app: *AppState, body_rect: dvui.Rect.Physical) void {
    const fe_state = &app.gui.cold.file_explorer;
    if (fe_state.preview_name.len == 0) return;
    if (fe_state.selected_file < 0) return;
    if (@as(usize, @intCast(fe_state.selected_file)) >= files.items.len) return;

    // Hint dimensions in physical pixels.
    const min_w: f32 = 160;
    const min_h: f32 = 110;
    const max_w: f32 = 260;
    const max_h: f32 = 200;
    const margin: f32 = 12;

    var hint_w = @min(max_w, @max(min_w, body_rect.w * 0.32));
    var hint_h = @min(max_h, @max(min_h, body_rect.h * 0.36));
    if (hint_w > body_rect.w - 2 * margin) hint_w = body_rect.w - 2 * margin;
    if (hint_h > body_rect.h - 2 * margin) hint_h = body_rect.h - 2 * margin;

    const hint_rect = dvui.Rect.Physical{
        .x = body_rect.x + body_rect.w - hint_w - margin,
        .y = body_rect.y + body_rect.h - hint_h - margin,
        .w = hint_w,
        .h = hint_h,
    };

    // Pull the parent window's natural rect-scale and override its rect with
    // our absolute hint rect, so the manual box below sits at the corner of
    // the dialog body regardless of the surrounding layout flow.
    const cw = dvui.currentWindow();
    _ = cw;

    // Draw a translucent rounded panel as the hint background.
    dvui.Path.fillConvex(.{
        .points = &.{
            .{ .x = hint_rect.x, .y = hint_rect.y },
            .{ .x = hint_rect.x + hint_rect.w, .y = hint_rect.y },
            .{ .x = hint_rect.x + hint_rect.w, .y = hint_rect.y + hint_rect.h },
            .{ .x = hint_rect.x, .y = hint_rect.y + hint_rect.h },
        },
    }, .{ .color = .{ .r = 14, .g = 14, .b = 20, .a = 235 } });

    // Subtle border.
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = hint_rect.x, .y = hint_rect.y },
            .{ .x = hint_rect.x + hint_rect.w, .y = hint_rect.y },
            .{ .x = hint_rect.x + hint_rect.w, .y = hint_rect.y + hint_rect.h },
            .{ .x = hint_rect.x, .y = hint_rect.y + hint_rect.h },
            .{ .x = hint_rect.x, .y = hint_rect.y },
        },
    }, .{
        .thickness = 1.0,
        .color = .{ .r = 80, .g = 90, .b = 110, .a = 200 },
    });

    // Header strip area at the top of the hint for the file name.
    const header_h: f32 = 18;
    const inner_pad: f32 = 4;
    const preview_rect = dvui.Rect.Physical{
        .x = hint_rect.x + inner_pad,
        .y = hint_rect.y + header_h,
        .w = hint_rect.w - 2 * inner_pad,
        .h = hint_rect.h - header_h - inner_pad,
    };

    drawPreviewSchematic(app, preview_rect);
}

/// Resolve and (re)load the preview schematic for the currently selected
/// file, then render its symbol view inside `bounds`. Bails out gracefully
/// (drawing a small status string) if the file fails to load or is empty.
fn drawPreviewSchematic(app: *AppState, bounds: dvui.Rect.Physical) void {
    const fe_state = &app.gui.cold.file_explorer;
    const sel_idx = fe_state.selected_file;
    if (sel_idx < 0 or @as(usize, @intCast(sel_idx)) >= files.items.len) return;
    const fe = files.items[@intCast(sel_idx)];

    var path_buf: [512]u8 = undefined;
    const full_path: []const u8 = if (std.fs.path.isAbsolute(fe.path))
        fe.path
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ app.project_dir, fe.path }) catch fe.path;

    // (Re)load the cached Schemify for this file.
    if (previewSchPtr(fe_state) == null or
        !std.mem.eql(u8, fe_state.preview_path, full_path))
    {
        freePreviewArena();
        fe_state.preview_sch = null;
        fe_state.preview_path = "";

        const arena = previewArena(app.allocator());
        const data = Vfs.readAlloc(arena, full_path) catch return;

        const sch_ptr = arena.create(core.Schemify) catch return;
        sch_ptr.* = core.Schemify.readFile(data, arena, null);
        fe_state.preview_sch = @ptrCast(sch_ptr);
        fe_state.preview_path = arena.dupe(u8, full_path) catch full_path;
    }

    const sch = previewSchPtr(fe_state) orelse return;
    const sch_is_empty = sch.lines.len == 0 and sch.rects.len == 0 and
        sch.circles.len == 0 and sch.arcs.len == 0 and sch.pins.len == 0 and
        sch.wires.len == 0 and sch.instances.len == 0 and sch.texts.len == 0;
    if (sch_is_empty) return;

    // Compute world-space bounding box only from the elements that
    // drawSymbol actually renders: lines, rects, circles, arcs, pins,
    // texts. Instances and wires live in the SCHEMATIC section of .chn
    // files and are not drawn by drawSymbol — including them would push
    // the computed center far from the visible symbol geometry.
    var b_min_x: f32 = std.math.floatMax(f32);
    var b_max_x: f32 = -std.math.floatMax(f32);
    var b_min_y: f32 = std.math.floatMax(f32);
    var b_max_y: f32 = -std.math.floatMax(f32);
    var b_has_data = false;
    const bumpPt = struct {
        fn f(x: f32, y: f32, mnx: *f32, mxx: *f32, mny: *f32, mxy: *f32, hd: *bool) void {
            if (x < mnx.*) mnx.* = x;
            if (x > mxx.*) mxx.* = x;
            if (y < mny.*) mny.* = y;
            if (y > mxy.*) mxy.* = y;
            hd.* = true;
        }
    }.f;
    for (0..sch.lines.len) |i| {
        bumpPt(@floatFromInt(sch.lines.items(.x0)[i]), @floatFromInt(sch.lines.items(.y0)[i]), &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
        bumpPt(@floatFromInt(sch.lines.items(.x1)[i]), @floatFromInt(sch.lines.items(.y1)[i]), &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
    }
    for (0..sch.rects.len) |i| {
        bumpPt(@floatFromInt(sch.rects.items(.x0)[i]), @floatFromInt(sch.rects.items(.y0)[i]), &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
        bumpPt(@floatFromInt(sch.rects.items(.x1)[i]), @floatFromInt(sch.rects.items(.y1)[i]), &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
    }
    for (0..sch.circles.len) |i| {
        const cx: f32 = @floatFromInt(sch.circles.items(.cx)[i]);
        const cy: f32 = @floatFromInt(sch.circles.items(.cy)[i]);
        const cr: f32 = @floatFromInt(sch.circles.items(.radius)[i]);
        bumpPt(cx - cr, cy - cr, &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
        bumpPt(cx + cr, cy + cr, &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
    }
    for (0..sch.arcs.len) |i| {
        const ax: f32 = @floatFromInt(sch.arcs.items(.cx)[i]);
        const ay: f32 = @floatFromInt(sch.arcs.items(.cy)[i]);
        const ar: f32 = @floatFromInt(sch.arcs.items(.radius)[i]);
        bumpPt(ax - ar, ay - ar, &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
        bumpPt(ax + ar, ay + ar, &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
    }
    for (0..sch.pins.len) |i| {
        bumpPt(@floatFromInt(sch.pins.items(.x)[i]), @floatFromInt(sch.pins.items(.y)[i]), &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
    }
    for (0..sch.texts.len) |i| {
        bumpPt(@floatFromInt(sch.texts.items(.x)[i]), @floatFromInt(sch.texts.items(.y)[i]), &b_min_x, &b_max_x, &b_min_y, &b_max_y, &b_has_data);
    }

    const pad_default: f32 = 50.0;
    var min_x = b_min_x;
    var max_x = b_max_x;
    var min_y = b_min_y;
    var max_y = b_max_y;
    if (!b_has_data) {
        min_x = -pad_default;
        max_x = pad_default;
        min_y = -pad_default;
        max_y = pad_default;
    }

    const world_cx = (min_x + max_x) * 0.5;
    const world_cy = (min_y + max_y) * 0.5;

    var bbox_w = max_x - min_x;
    var bbox_h = max_y - min_y;
    if (bbox_w <= 0.0001) bbox_w = pad_default;
    if (bbox_h <= 0.0001) bbox_h = pad_default;

    const scale_x = bounds.w / bbox_w;
    const scale_y = bounds.h / bbox_h;
    const fit_scale = @min(scale_x, scale_y) * 0.85;

    // Compose the render viewport so that `pan` (the world-space point
    // drawn at the screen-space (cx, cy)) is the bbox center. This is the
    // "center the symbol in the preview pane" fix: both the geometric
    // center (`pan = world_cx/world_cy`) AND the screen center (`cx =
    // bounds.x + w/2`) line up exactly.
    const mini_vp = RenderViewport{
        .cx = bounds.x + bounds.w / 2.0,
        .cy = bounds.y + bounds.h / 2.0,
        .scale = fit_scale,
        // Thumbnail render — no parent canvas rect scale handy and no text
        // labels are drawn at this fit_scale anyway. 1.0 is the right
        // identity value for `font.size` -> physical interpretation if a
        // future change ever does start drawing labels here.
        .rs_s = 1.0,
        .pan = .{ world_cx, world_cy },
        .bounds = bounds,
    };

    const pal = Palette.fromDvui(dvui.themeGet());
    const ctx = RenderContext{
        .allocator = app.allocator(),
        .vp = mini_vp,
        .pal = pal,
        .cmd_flags = app.cmd_flags,
    };

    symbol_renderer.drawSymbol(&ctx, sch);
}

// ── Preview cache helpers ─────────────────────────────────────────────────── //

fn clearPreviewCache(fe_state: *st.FileExplorerState) void {
    freePreviewArena();
    fe_state.preview_sch = null;
    fe_state.preview_path = "";
}

// ── Section scanning ─────────────────────────────────────────────────────── //

/// Build the static four-section list and pre-scan the file entries for
/// the three file-list sections (Components / Testbenches / Primitives).
/// All four sections are always present in the sidebar, even if empty, so
/// the user can see the full layout at a glance. The PDK section is a
/// read-only info display — its file list is empty.
fn scanSections(app: *AppState) void {
    const alloc = app.allocator();
    clearSections(alloc);
    clearFiles(alloc);

    const fe_state = &app.gui.cold.file_explorer;
    const chn_n = app.config.paths.chn.len;
    const tb_n = app.config.paths.chn_tb.len;
    const prim_n = app.config.paths.chn_prim.len;

    appendSection(alloc, "Components", .components, chn_n);
    appendSection(alloc, "Testbenches", .testbenches, tb_n);
    appendSection(alloc, "Primitives", .primitives, prim_n);
    appendSection(alloc, "PDK", .pdk, 0);

    // Collect file entries from all three file-list sections. These live
    // in a single `files` list so the fuzzy search bar at the top can
    // filter across every section at once; `kind` on each FileEntry tells
    // the right-column renderer which header to group the row under.
    appendPaths(alloc, app.config.paths.chn, .components);
    appendPaths(alloc, app.config.paths.chn_tb, .testbenches);
    appendPaths(alloc, app.config.paths.chn_prim, .primitives);

    // Auto-select Components so the right pane has something to show.
    if (sections.items.len > 0) {
        fe_state.selected_section = 0;
    }
}

fn appendSection(alloc: std.mem.Allocator, name: []const u8, kind: SectionKind, count: usize) void {
    var buf: [64]u8 = undefined;
    const label = if (kind == .pdk)
        std.fmt.bufPrint(&buf, "{s}", .{name}) catch name
    else
        std.fmt.bufPrint(&buf, "{s} ({d})", .{ name, count }) catch name;
    const dup = alloc.dupe(u8, label) catch return;
    sections.append(alloc, .{ .label = dup, .kind = kind }) catch {
        alloc.free(dup);
    };
}

fn appendPaths(alloc: std.mem.Allocator, paths: []const []const u8, kind: SectionKind) void {
    for (paths) |p| {
        const name = std.fs.path.basename(p);
        const name_dup = alloc.dupe(u8, name) catch continue;
        const path_dup = alloc.dupe(u8, p) catch {
            alloc.free(name_dup);
            continue;
        };
        files.append(alloc, .{
            .name = name_dup,
            .path = path_dup,
            .kind = kind,
            .is_dir = false,
        }) catch {
            alloc.free(name_dup);
            alloc.free(path_dup);
        };
    }
}

// ── Cleanup ──────────────────────────────────────────────────────────────── //

fn clearFiles(alloc: std.mem.Allocator) void {
    for (files.items) |fe| {
        alloc.free(fe.name);
        alloc.free(fe.path);
    }
    files.clearRetainingCapacity();
    // Stale filtered indices would point into the wrong entries; reset them
    // here. `refreshFilter()` rebuilds on the next frame.
    filtered.clearRetainingCapacity();
}

fn clearSections(alloc: std.mem.Allocator) void {
    for (sections.items) |sec| {
        alloc.free(sec.label);
    }
    sections.clearRetainingCapacity();
}

pub fn reset(app: *AppState) void {
    const alloc = app.allocator();
    const fe_state = &app.gui.cold.file_explorer;
    fe_state.preview_name = "";
    clearPreviewCache(fe_state);
    // Free owned strings, then fully release the backing buffers of the
    // module-level ArrayLists. `clearRetainingCapacity` would leak them on
    // shutdown because the allocated capacity is never returned.
    clearFiles(alloc);
    clearSections(alloc);
    files.deinit(alloc);
    sections.deinit(alloc);
    filtered.deinit(alloc);
    fe_state.scanned = false;
    fe_state.selected_section = -1;
    fe_state.selected_file = -1;
    fe_state.query_len = 0;
    @memset(&fe_state.query_buf, 0);
}
