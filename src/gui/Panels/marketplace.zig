//! Plugin Marketplace — VS-Code-style modal panel with registry fetch.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const utility = @import("utility");

const AppState = st.AppState;
const MktStatus = st.MktStatus;
const MarketplaceEntry = st.MarketplaceEntry;

const REGISTRY_URL = "https://raw.githubusercontent.com/UW-ASIC/Schemify/main/plugins/registry.json";

// ── Registry fetch (background thread) ───────────────────────────────────────

const RegistryDownloadJson = struct { linux: []const u8 = "", macos: []const u8 = "", wasm: []const u8 = "" };
const RegistryEntryJson = struct {
    id: []const u8 = "", name: []const u8 = "", author: []const u8 = "", version: []const u8 = "",
    description: []const u8 = "", tags: [][]const u8 = &.{}, repo: []const u8 = "",
    readme_url: []const u8 = "", logo_url: []const u8 = "", download: RegistryDownloadJson = .{},
};
const RegistryJson = struct { version: u32 = 0, plugins: []RegistryEntryJson = &.{} };
const FetchCtx = struct { mkt: *st.MarketplaceState, alloc: std.mem.Allocator };

fn fetchRegistryThread(ctx: FetchCtx) void {
    const body = utility.platform.httpGetSync(ctx.alloc, REGISTRY_URL) catch {
        @atomicStore(MktStatus, &ctx.mkt.registry_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(body);
    const parsed = std.json.parseFromSlice(RegistryJson, ctx.alloc, body, .{ .ignore_unknown_fields = true }) catch {
        @atomicStore(MktStatus, &ctx.mkt.registry_status, .failed, .seq_cst);
        return;
    };
    defer parsed.deinit();

    for (parsed.value.plugins) |src| {
        var dst = MarketplaceEntry{};
        copyStr(src.name, &dst.name);
        copyStr(src.id, &dst.id);
        copyStr(src.author, &dst.author);
        copyStr(src.version, &dst.version);
        copyStr(src.description, &dst.desc);
        copyStr(src.repo, &dst.repo_url);
        copyStr(src.readme_url, &dst.readme_url);
        copyStr(src.logo_url, &dst.logo_url);
        copyStr(src.download.linux, &dst.dl_linux);
        var tp: usize = 0;
        for (src.tags, 0..) |tag, ti| {
            if (ti > 0 and tp + 1 < dst.tags.len - 1) { dst.tags[tp] = ' '; tp += 1; }
            const n = @min(tag.len, dst.tags.len - 1 - tp);
            @memcpy(dst.tags[tp..][0..n], tag[0..n]);
            tp += n;
        }
        dst.tags[tp] = 0;
        ctx.mkt.entries.append(ctx.alloc, dst) catch break;
    }
    @atomicStore(MktStatus, &ctx.mkt.registry_status, .done, .seq_cst);
}

fn copyStr(src: []const u8, dst: []u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

// ── Public API ───────────────────────────────────────────────────────────────

pub fn draw(app: *AppState) void {
    const mkt = &app.gui.cold.marketplace;
    if (!mkt.visible) return;

    if (mkt.registry_status == .idle) {
        mkt.registry_status = .fetching;
        const ctx = FetchCtx{ .mkt = mkt, .alloc = app.allocator() };
        const thread = std.Thread.spawn(.{}, fetchRegistryThread, .{ctx}) catch { mkt.registry_status = .failed; return; };
        thread.detach();
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true, .open_flag = &mkt.visible,
        .rect = @ptrCast(&app.gui.cold.marketplace_win.win_rect),
    }, .{ .min_size_content = .{ .w = 680, .h = 480 } });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Plugin Marketplace", "", &mkt.visible));

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();
    drawLeftPanel(mkt);
    _ = dvui.separator(@src(), .{ .id_extra = 500 });
    drawRightPanel(mkt);
}

fn drawLeftPanel(mkt: *st.MarketplaceState) void {
    var left = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 250 }, .expand = .vertical, .padding = .all(6),
    });
    defer left.deinit();

    dvui.labelNoFmt(@src(), "Search plugins:", .{}, .{ .id_extra = 600 });
    _ = dvui.separator(@src(), .{ .id_extra = 601 });

    switch (mkt.registry_status) {
        .idle => dvui.labelNoFmt(@src(), "No registry configured.", .{}, .{ .id_extra = 602, .style = .control }),
        .fetching => dvui.labelNoFmt(@src(), "Loading registry...", .{}, .{ .id_extra = 602, .style = .control }),
        .failed => dvui.labelNoFmt(@src(), "Failed to load registry.", .{}, .{ .id_extra = 602, .style = .err }),
        .done => {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 603 });
            defer scroll.deinit();
            if (mkt.entries.items.len == 0) dvui.labelNoFmt(@src(), "No plugins found.", .{}, .{ .id_extra = 604 });
            for (mkt.entries.items, 0..) |entry, i| {
                const is_sel = mkt.selected == @as(i16, @intCast(i));
                var card = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = i, .expand = .horizontal, .background = true,
                    .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 }, .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                    .color_fill = if (is_sel) dvui.Color{ .r = 30, .g = 58, .b = 110, .a = 255 } else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_fill_hover = .{ .r = 42, .g = 44, .b = 54, .a = 180 },
                });
                defer card.deinit();
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i * 3 + 2 });
                    defer row.deinit();
                    // Small brand-color square (placeholder for logo)
                    var icon_box = dvui.box(@src(), .{}, .{
                        .min_size_content = .{ .w = 24, .h = 24 },
                        .background = true,
                        .corner_radius = .all(4),
                        .color_fill = dvui.Color{ .r = 91, .g = 140, .b = 220, .a = 255 },
                        .id_extra = i * 3 + 100,
                    });
                    icon_box.deinit();
                    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 }, .id_extra = i * 3 + 200 });
                    var text_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = i * 3 + 300 });
                    defer text_col.deinit();
                    dvui.labelNoFmt(@src(), fixedStr(&entry.name), .{}, .{ .id_extra = i * 3, .style = .highlight });
                    dvui.labelNoFmt(@src(), fixedStr(&entry.author), .{}, .{ .id_extra = i * 3 + 1 });
                }
                if (dvui.clicked(&card.wd, .{})) mkt.selected = @intCast(i);
            }
        },
    }
}

fn drawRightPanel(mkt: *st.MarketplaceState) void {
    var right = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 } });
    defer right.deinit();

    if (mkt.selected < 0 or @as(usize, @intCast(mkt.selected)) >= mkt.entries.items.len) {
        dvui.labelNoFmt(@src(), "Select a plugin to view details.", .{}, .{ .id_extra = 700, .style = .control, .gravity_x = 0.5, .gravity_y = 0.5 });
        return;
    }
    const entry = &mkt.entries.items[@intCast(mkt.selected)];
    dvui.labelNoFmt(@src(), fixedStr(&entry.name), .{}, .{ .id_extra = 701, .style = .highlight });
    { var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 702 }); defer hdr.deinit();
      dvui.labelNoFmt(@src(), fixedStr(&entry.author), .{}, .{ .id_extra = 703 });
      _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });
      dvui.labelNoFmt(@src(), fixedStr(&entry.version), .{}, .{ .id_extra = 704 }); }
    _ = dvui.separator(@src(), .{ .id_extra = 705 });
    dvui.labelNoFmt(@src(), fixedStr(&entry.desc), .{}, .{ .id_extra = 706 });
    _ = dvui.separator(@src(), .{ .id_extra = 707 });

    { var br = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 708 }); defer br.deinit();
      if (entry.installed) { dvui.labelNoFmt(@src(), "Installed", .{}, .{ .id_extra = 709, .style = .control }); }
      else { if (dvui.button(@src(), "Install", .{}, .{ .id_extra = 710 })) mkt.install_status = .fetching; } }

    _ = dvui.separator(@src(), .{ .id_extra = 711 });
    dvui.labelNoFmt(@src(), "(README content will appear here)", .{}, .{ .id_extra = 712, .style = .control });
}

fn fixedStr(buf: []const u8) []const u8 {
    return buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse buf.len)];
}
