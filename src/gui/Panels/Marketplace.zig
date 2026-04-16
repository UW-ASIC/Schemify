//! Plugin Marketplace — VS-Code-style panel with modal overlay.
//!
//! Layout (floating modal window):
//!   +--------------------------------------------------------------+
//!   |  Plugin Marketplace                                     [x]  |
//!   +-------------------+------------------------------------------+
//!   | search [         ]|  <selected plugin detail + README>       |
//!   |-------------------|                                          |
//!   |  Card: name       |  Name      Author   vX.Y.Z              |
//!   |        author v   |  tags: ui themes                        |
//!   |        desc...    |  [Install]                               |
//!   |  Card: ...        |  ----------------------------------------|
//!   |                   |  <README rendered line-by-line>          |
//!   +-------------------+------------------------------------------+

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const utility = @import("utility");

const components = @import("../Components/lib.zig");

const AppState = st.AppState;
const MktStatus = st.MktStatus;
const MarketplaceEntry = st.MarketplaceEntry;

const REGISTRY_URL = "https://raw.githubusercontent.com/UW-ASIC/Schemify/main/plugins/registry.json";

// ── Layout constants ───────────────────────────────────────────────────────

const MODAL_MIN_WIDTH: f32 = 680;
const MODAL_MIN_HEIGHT: f32 = 480;
const LEFT_PANEL_MIN_WIDTH: f32 = 250;

// ── Registry fetch (background thread) ───────────────────────────────────── //

/// Minimal JSON schema for parsing registry entries (heap-allocated slices).
const RegistryDownloadJson = struct {
    linux: []const u8 = "",
    macos: []const u8 = "",
    wasm: []const u8 = "",
};

const RegistryEntryJson = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    author: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    tags: [][]const u8 = &.{},
    repo: []const u8 = "",
    readme_url: []const u8 = "",
    download: RegistryDownloadJson = .{},
};

const RegistryJson = struct {
    version: u32 = 0,
    plugins: []RegistryEntryJson = &.{},
};

const FetchCtx = struct {
    mkt: *st.MarketplaceState,
    alloc: std.mem.Allocator,
};

fn fetchRegistryThread(ctx: FetchCtx) void {
    const body = utility.platform.httpGetSync(ctx.alloc, REGISTRY_URL) catch {
        @atomicStore(MktStatus, &ctx.mkt.registry_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(body);

    const parsed = std.json.parseFromSlice(RegistryJson, ctx.alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        @atomicStore(MktStatus, &ctx.mkt.registry_status, .failed, .seq_cst);
        return;
    };
    defer parsed.deinit();

    // Copy each JSON entry into a fixed-buffer MarketplaceEntry.
    for (parsed.value.plugins) |src| {
        var dst = MarketplaceEntry{};
        copyStr(src.name, &dst.name);
        copyStr(src.id, &dst.id);
        copyStr(src.author, &dst.author);
        copyStr(src.version, &dst.version);
        copyStr(src.description, &dst.desc);
        copyStr(src.repo, &dst.repo_url);
        copyStr(src.readme_url, &dst.readme_url);
        copyStr(src.download.linux, &dst.dl_linux);
        // Join tags array into space-separated string.
        var tags_pos: usize = 0;
        for (src.tags, 0..) |tag, ti| {
            if (ti > 0 and tags_pos + 1 < dst.tags.len - 1) {
                dst.tags[tags_pos] = ' ';
                tags_pos += 1;
            }
            const n = @min(tag.len, dst.tags.len - 1 - tags_pos);
            @memcpy(dst.tags[tags_pos..][0..n], tag[0..n]);
            tags_pos += n;
        }
        dst.tags[tags_pos] = 0;
        ctx.mkt.entries.append(ctx.alloc, dst) catch break;
    }

    // Write status last — main thread reads entries only after seeing .done.
    @atomicStore(MktStatus, &ctx.mkt.registry_status, .done, .seq_cst);
}

/// Copy `src` into fixed-size `dst` buffer, null-terminating at the end.
fn copyStr(src: []const u8, dst: []u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

// ── Public API ────────────────────────────────────────────────────────────── //

/// Called every frame from lib.zig. No-ops when marketplace is hidden.
pub fn draw(app: *AppState) void {
    const mkt = &app.gui.cold.marketplace;
    if (!mkt.visible) return;

    // Kick off registry fetch on first open.
    if (mkt.registry_status == .idle) {
        mkt.registry_status = .fetching;
        const ctx = FetchCtx{ .mkt = mkt, .alloc = app.allocator() };
        const thread = std.Thread.spawn(.{}, fetchRegistryThread, .{ctx}) catch {
            mkt.registry_status = .failed;
            return;
        };
        thread.detach();
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &mkt.visible,
        .rect = components.winRectPtr(&app.gui.cold.marketplace_win.win_rect),
    }, .{
        .min_size_content = .{ .w = MODAL_MIN_WIDTH, .h = MODAL_MIN_HEIGHT },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Plugin Marketplace", "", &mkt.visible));

    // Main body: left panel (list) + right panel (detail).
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    // Left panel: search + entry list.
    drawLeftPanel(mkt);

    // Separator.
    _ = dvui.separator(@src(), .{ .id_extra = 500 });

    // Right panel: detail + readme.
    drawRightPanel(mkt);
}

// ── Left panel ────────────────────────────────────────────────────────────── //

fn drawLeftPanel(mkt: *st.MarketplaceState) void {
    var left = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = LEFT_PANEL_MIN_WIDTH },
        .expand = .vertical,
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
    });
    defer left.deinit();

    // Search bar.
    dvui.labelNoFmt(@src(), "Search plugins:", .{}, .{ .id_extra = 600 });
    // TODO: text entry for mkt.search_buf when dvui text entry API stabilises.

    _ = dvui.separator(@src(), .{ .id_extra = 601 });

    // Status indicator.
    switch (mkt.registry_status) {
        .idle => {
            dvui.labelNoFmt(@src(), "No registry configured.", .{}, .{ .id_extra = 602, .style = .control });
        },
        .fetching => {
            dvui.labelNoFmt(@src(), "Loading registry...", .{}, .{ .id_extra = 602, .style = .control });
        },
        .failed => {
            dvui.labelNoFmt(@src(), "Failed to load registry.", .{}, .{ .id_extra = 602, .style = .err });
        },
        .done => {
            // Entry list.
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 603 });
            defer scroll.deinit();

            if (mkt.entries.items.len == 0) {
                dvui.labelNoFmt(@src(), "No plugins found.", .{}, .{ .id_extra = 604 });
            }

            for (mkt.entries.items, 0..) |entry, i| {
                const name = fixedStr(&entry.name);
                const author = fixedStr(&entry.author);
                const is_sel = mkt.selected == @as(i16, @intCast(i));

                var card = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = i,
                    .expand = .horizontal,
                    .background = true,
                    .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
                    .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                    .color_fill = if (is_sel)
                        dvui.Color{ .r = 45, .g = 95, .b = 175, .a = 255 }
                    else
                        dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_fill_hover = .{ .r = 50, .g = 55, .b = 75, .a = 180 },
                });
                defer card.deinit();

                dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = i * 3, .style = .highlight });
                dvui.labelNoFmt(@src(), author, .{}, .{ .id_extra = i * 3 + 1 });

                if (dvui.clicked(&card.wd, .{})) {
                    mkt.selected = @intCast(i);
                }
            }
        },
    }
}

// ── Right panel ───────────────────────────────────────────────────────────── //

fn drawRightPanel(mkt: *st.MarketplaceState) void {
    var right = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer right.deinit();

    if (mkt.selected < 0 or @as(usize, @intCast(mkt.selected)) >= mkt.entries.items.len) {
        dvui.labelNoFmt(@src(), "Select a plugin to view details.", .{}, .{
            .id_extra = 700,
            .style = .control,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        return;
    }

    const entry = &mkt.entries.items[@intCast(mkt.selected)];
    const name = fixedStr(&entry.name);
    const author = fixedStr(&entry.author);
    const version = fixedStr(&entry.version);
    const desc = fixedStr(&entry.desc);

    // Header.
    dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = 701, .style = .highlight });
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 702 });
        defer hdr.deinit();
        dvui.labelNoFmt(@src(), author, .{}, .{ .id_extra = 703 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });
        dvui.labelNoFmt(@src(), version, .{}, .{ .id_extra = 704 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 705 });

    // Description.
    dvui.labelNoFmt(@src(), desc, .{}, .{ .id_extra = 706 });

    _ = dvui.separator(@src(), .{ .id_extra = 707 });

    // Action buttons.
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 708 });
        defer btn_row.deinit();

        if (entry.installed) {
            dvui.labelNoFmt(@src(), "Installed", .{}, .{ .id_extra = 709, .style = .control });
        } else {
            if (dvui.button(@src(), "Install", .{}, .{ .id_extra = 710 })) {
                mkt.install_status = .fetching;
            }
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 711 });

    // README placeholder.
    dvui.labelNoFmt(@src(), "(README content will appear here)", .{}, .{
        .id_extra = 712,
        .style = .control,
    });
}

// ── Helpers ───────────────────────────────────────────────────────────────── //

/// Extract a zero-terminated string from a fixed-size buffer.
fn fixedStr(buf: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..len];
}
