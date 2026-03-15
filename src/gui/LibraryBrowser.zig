//! Library browser — browse and place/open cells from PDK dirs and config paths.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("state").AppState;

const SearchBuf = struct {
    buffer: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    pub fn slice(self: *const @This()) []const u8 { return self.buffer[0..self.len]; }
};

pub const EntryKind = enum(u8) {
    chn,     // schematic  → open in new tab
    chn_sym, // symbol     → place as instance
    chn_tb,  // testbench  → open in new tab
};

/// Library entry with heap-owned strings.  Freed by `freeEntries()`.
pub const Entry = struct {
    kind: EntryKind,
    stem: []const u8, // display name (basename, no ext) — heap-owned by gpa
    path: []const u8, // absolute path — heap-owned by gpa
};

// ── Comptime lookup tables ────────────────────────────────────────────────── //

const KindInfo = struct {
    label:     []const u8,
    color:     dvui.Color,
    extension: []const u8,
};

const kind_info: [@typeInfo(EntryKind).@"enum".fields.len]KindInfo = blk: {
    var table: [@typeInfo(EntryKind).@"enum".fields.len]KindInfo = undefined;
    table[@intFromEnum(EntryKind.chn)] = .{
        .label     = "SCH",
        .color     = .{ .r = 120, .g = 210, .b = 120, .a = 255 },
        .extension = ".chn",
    };
    table[@intFromEnum(EntryKind.chn_sym)] = .{
        .label     = "SYM",
        .color     = .{ .r = 120, .g = 160, .b = 230, .a = 255 },
        .extension = ".chn_sym",
    };
    table[@intFromEnum(EntryKind.chn_tb)] = .{
        .label     = "TB ",
        .color     = .{ .r = 230, .g = 185, .b = 80, .a = 255 },
        .extension = ".chn_tb",
    };
    break :blk table;
};

fn infoFor(kind: EntryKind) KindInfo {
    return kind_info[@intFromEnum(kind)];
}

/// Match a file path to an EntryKind by extension, longest match first.
fn classifyExtension(path: []const u8) ?EntryKind {
    const check_order = [_]EntryKind{ .chn_sym, .chn_tb, .chn };
    for (check_order) |kind| {
        if (std.mem.endsWith(u8, path, infoFor(kind).extension)) return kind;
    }
    return null;
}

// ── Module-level storage ──────────────────────────────────────────────────── //

var gpa = std.heap.page_allocator;
var entry_list: std.ArrayListUnmanaged(Entry) = .{};
var filtered:   std.ArrayListUnmanaged(u32)   = .{};

// ── Dialog state ──────────────────────────────────────────────────────────── //

pub const LibraryBrowser = struct {
    open:         bool = false,
    search:       SearchBuf = .{},
    filter_kind:  ?EntryKind = null,
    selected:     i32 = -1,
    scanned:      bool = false,
    filter_dirty: bool = true,
    win_rect:     dvui.Rect = .{ .x = 80, .y = 60, .w = 500, .h = 540 },
};

pub var state: LibraryBrowser = .{};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!state.scanned) {
        scanAll(app);
        state.scanned      = true;
        state.filter_dirty = true;
        state.selected     = -1;
    }

    if (state.filter_dirty) {
        rebuildFilter(state.search.slice());
        state.filter_dirty = false;
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &state.open,
        .rect      = &state.win_rect,
    }, .{
        .min_size_content = .{ .w = 380, .h = 400 },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("Library Browser", "", &state.open));

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand  = .both,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
    });
    defer body.deinit();

    // ── Search bar ────────────────────────────────────────────────────────── //
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        const prev_len = state.search.len;
        var te = dvui.textEntry(@src(), .{
            .text        = .{ .buffer = state.search.buffer[0..127] },
            .placeholder = "Search\xe2\x80\xa6",
        }, .{ .expand = .horizontal });
        defer te.deinit();
        state.search.len = @intCast(std.mem.indexOfScalar(u8, &state.search.buffer, 0) orelse 127);

        if (state.search.len != prev_len) {
            state.filter_dirty = true;
            state.selected     = -1;
        }
    }

    // ── Kind filter toggles ───────────────────────────────────────────────── //
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        });
        defer row.deinit();

        const all_active = state.filter_kind == null;
        if (dvui.button(@src(), "All", .{}, .{
            .id_extra = 10,
            .style    = if (all_active) .highlight else .control,
        })) {
            if (!all_active) { state.filter_kind = null; state.filter_dirty = true; }
        }

        const toggle_kinds = [_]struct { kind: EntryKind, id: usize }{
            .{ .kind = .chn,     .id = 11 },
            .{ .kind = .chn_sym, .id = 12 },
            .{ .kind = .chn_tb,  .id = 13 },
        };
        for (toggle_kinds) |t| {
            const info = infoFor(t.kind);
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4 } });
            if (dvui.button(@src(), info.label, .{}, .{
                .id_extra   = t.id,
                .style      = if (state.filter_kind == t.kind) .highlight else .control,
                .color_text = info.color,
            })) {
                state.filter_kind = if (state.filter_kind == t.kind) null else t.kind;
                state.filter_dirty = true;
            }
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        var cnt_buf: [32]u8 = undefined;
        const cnt_label = std.fmt.bufPrint(&cnt_buf, "{d} / {d}", .{
            filtered.items.len, entry_list.items.len,
        }) catch "?";
        dvui.labelNoFmt(@src(), cnt_label, .{}, .{
            .id_extra  = 14,
            .gravity_y = 0.5,
            .style     = .control,
        });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 1 });

    // ── Entry list ────────────────────────────────────────────────────────── //
    {
        if (filtered.items.len == 0) {
            const msg = if (entry_list.items.len == 0)
                "No .chn / .chn_sym / .chn_tb files found."
            else
                "No results match your filter.";
            dvui.labelNoFmt(@src(), msg, .{}, .{ .style = .control });
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        for (0..filtered.items.len) |fi| {
            const i     = filtered.items[fi];
            const entry = &entry_list.items[i];
            const is_selected = state.selected == @as(i32, @intCast(i));
            const info = infoFor(entry.kind);

            var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra         = fi * 2,
                .expand           = .horizontal,
                .background       = true,
                .border           = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .padding          = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
                .margin           = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .color_fill       = if (is_selected)
                    .{ .r = 45, .g = 95, .b = 175, .a = 255 }
                else
                    .{ .r = 28, .g = 28, .b = 36, .a = 0 },
                .color_fill_hover = .{ .r = 55, .g = 65, .b = 90, .a = 220 },
            });
            defer card.deinit();

            dvui.labelNoFmt(@src(), info.label, .{}, .{
                .id_extra         = fi * 10 + 1,
                .gravity_y        = 0.5,
                .color_text       = info.color,
                .min_size_content = .{ .w = 28 },
            });
            _ = dvui.spacer(@src(), .{ .id_extra = fi * 10 + 2, .min_size_content = .{ .w = 8 } });
            dvui.labelNoFmt(@src(), entry.stem, .{}, .{
                .id_extra  = fi * 10 + 3,
                .expand    = .horizontal,
                .gravity_y = 0.5,
            });

            if (dvui.clicked(&card.wd, .{})) {
                if (state.selected == @as(i32, @intCast(i))) {
                    doAction(app, i);
                    return;
                }
                state.selected = @intCast(i);
            }
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 20 });

    // ── Bottom bar ────────────────────────────────────────────────────────── //
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
        defer btn_row.deinit();

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        const action_label: []const u8 = lbl: {
            if (state.selected < 0) break :lbl "Place / Open";
            const idx: usize = @intCast(state.selected);
            if (idx >= entry_list.items.len) break :lbl "Place / Open";
            break :lbl switch (entry_list.items[idx].kind) {
                .chn_sym      => "Place",
                .chn, .chn_tb => "Open",
            };
        };

        if (dvui.button(@src(), action_label, .{}, .{
            .id_extra = 200,
            .style    = if (state.selected >= 0) .highlight else .control,
        })) {
            if (state.selected >= 0) {
                doAction(app, @intCast(state.selected));
                return;
            } else {
                app.setStatus("Select an entry first");
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });

        if (dvui.button(@src(), "Refresh", .{}, .{ .id_extra = 202 })) {
            state.scanned = false;
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });

        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 201 })) {
            state.open = false;
        }
    }
}

// ── Action dispatch ───────────────────────────────────────────────────────── //

fn doAction(app: *AppState, idx: usize) void {
    if (idx >= entry_list.items.len) return;
    const entry = &entry_list.items[idx];
    switch (entry.kind) {
        .chn_sym => {
            app.queue.push(app.allocator(), .{ .undoable = .{ .place_device = .{
                .sym_path = entry.path,
                .name     = entry.stem,
                .pos      = .{ 0, 0 },
            } } }) catch {};
            app.setStatus("Placing symbol \xe2\x80\x94 click to set position");
            state.open = false;
        },
        .chn, .chn_tb => {
            app.openPath(entry.path) catch |err| {
                app.log.err("BROWSER", "open {s}: {}", .{ entry.path, err });
                app.setStatusErr("Failed to open file");
                return;
            };
            app.setStatus("Opened");
            state.open = false;
        },
    }
}

// ── Filter ────────────────────────────────────────────────────────────────── //

fn rebuildFilter(search: []const u8) void {
    filtered.clearRetainingCapacity();
    for (entry_list.items, 0..) |*entry, i| {
        if (state.filter_kind) |fk| {
            if (entry.kind != fk) continue;
        }
        if (search.len > 0) {
            if (std.ascii.indexOfIgnoreCase(entry.stem, search) == null) continue;
        }
        filtered.append(gpa, @intCast(i)) catch break;
    }
}

// ── Scanning ──────────────────────────────────────────────────────────────── //

pub fn scanAll(app: *AppState) void {
    freeEntries();
    if (comptime @import("builtin").target.cpu.arch == .wasm32) return;

    if (std.posix.getenv("HOME")) |home| {
        if (std.fs.path.join(gpa, &.{ home, ".config", "Schemify", "pdks" }) catch null) |root| {
            defer gpa.free(root);
            walkDir(root, &entry_list);
        }
    }
    for (app.config.paths.chn_sym) |dir| walkDir(dir, &entry_list);
    for (app.config.paths.chn) |fp| {
        if (std.fs.path.dirname(fp)) |dir| walkDir(dir, &entry_list);
    }
    for (app.config.paths.chn_tb) |fp| {
        if (std.fs.path.dirname(fp)) |dir| walkDir(dir, &entry_list);
    }
}

pub fn scanSymbols(chn_sym_dirs: []const []const u8) void {
    freeEntries();
    if (comptime @import("builtin").target.cpu.arch == .wasm32) return;

    if (std.posix.getenv("HOME")) |home| {
        if (std.fs.path.join(gpa, &.{ home, ".config", "Schemify", "pdks" }) catch null) |root| {
            defer gpa.free(root);
            walkDir(root, &entry_list);
        }
    }
    for (chn_sym_dirs) |dir| walkDir(dir, &entry_list);
}

fn freeEntries() void {
    for (entry_list.items) |entry| {
        gpa.free(entry.stem);
        gpa.free(entry.path);
    }
    entry_list.clearRetainingCapacity();
    filtered.clearRetainingCapacity();
}

fn walkDir(dir_path: []const u8, list: *std.ArrayListUnmanaged(Entry)) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();
    while (walker.next() catch null) |e| {
        if (e.kind != .file) continue;
        const kind = classifyExtension(e.path) orelse continue;
        if (list.items.len >= 512) return;

        const full = std.fs.path.join(gpa, &.{ dir_path, e.path }) catch continue;

        const base     = std.fs.path.basename(e.path);
        const ext_len  = infoFor(kind).extension.len;
        const stem_raw = if (base.len > ext_len) base[0..base.len - ext_len] else base;
        const stem     = gpa.dupe(u8, stem_raw) catch { gpa.free(full); continue; };

        list.append(gpa, .{ .kind = kind, .stem = stem, .path = full }) catch {
            gpa.free(full);
            gpa.free(stem);
        };
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────── //

test "Expose struct size for library_browser" {
    const print = @import("std").debug.print;
    print("LibraryBrowser: {d}B\n", .{@sizeOf(LibraryBrowser)});
    print("Entry: {d}B\n", .{@sizeOf(Entry)});
}
