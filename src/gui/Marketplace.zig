//! Plugin Marketplace — VS-Code-style panel with Discord-style modal overlay.
//!
//! Layout (floating modal window):
//!   ┌──────────────────────────────────────────────────────────────┐
//!   │  Plugin Marketplace                                     [×]  │
//!   ├───────────────────┬──────────────────────────────────────────┤
//!   │ 🔍 [search      ] │  <selected plugin detail + README>       │
//!   │───────────────────│                                          │
//!   │  Card: name       │  Name      Author   vX.Y.Z              │
//!   │        author v   │  tags: ai  vision                       │
//!   │        desc…      │  [Install]  [Open on GitHub]            │
//!   │  [Details]        │  ──────────────────────────────────────  │
//!   │  Card: …          │  <README.md rendered line-by-line>       │
//!   │  …                │                                          │
//!   ├───────────────────┴──────────────────────────────────────────┤
//!   │  Custom plugin:  [https://github.com/…    ]  [Add]          │
//!   └──────────────────────────────────────────────────────────────┘
//!
//! Native: background threads (registry, readme, install).
//! WASM:   Platform.AsyncGet polling model — polled every frame in draw().

const std      = @import("std");
const builtin  = @import("builtin");
const dvui     = @import("dvui");
const st       = @import("state");
const core     = @import("core");
const AppState  = st.AppState;
const MktStatus = st.MktStatus;
const Platform  = core.Platform;

const is_wasm = builtin.cpu.arch == .wasm32;

const REGISTRY_URL = "https://raw.githubusercontent.com/UWASIC/Schemify/main/plugins/registry.json";

// ── Module-level persistent state ─────────────────────────────────────────────

var win_rect = dvui.Rect{ .x = 80, .y = 50, .w = 820, .h = 560 };

// Mutexes — used by native threads; trivial no-ops on single-threaded WASM.
var fetch_mutex:   std.Thread.Mutex = .{};
var readme_mutex:  std.Thread.Mutex = .{};
var install_mutex: std.Thread.Mutex = .{};

// Native background thread handles (never touched on WASM).
var fetch_thread:   ?std.Thread = null;
var readme_thread:  ?std.Thread = null;
var install_thread: ?std.Thread = null;

// WASM async HTTP state — polled every frame; Platform.AsyncGet is a no-op type
// on native so these variables are valid (and always null) in both builds.
var wasm_registry_get: ?Platform.AsyncGet = null;
var wasm_readme_get:   ?Platform.AsyncGet = null;
var wasm_req_id: i32 = 0;

// ── Layout constants ───────────────────────────────────────────────────────

const MODAL_MIN_WIDTH:      f32   = 680;
const MODAL_MIN_HEIGHT:     f32   = 480;
const LEFT_PANEL_MIN_WIDTH: f32   = 250;
const DESC_TRUNCATE_LEN:    usize = 38;

// ── Public API ────────────────────────────────────────────────────────────── //

/// Join any in-flight background threads (native only). Call on app shutdown.
pub fn joinAll() void {
    if (comptime !is_wasm) {
        if (fetch_thread)   |t| t.join();
        if (readme_thread)  |t| t.join();
        if (install_thread) |t| t.join();
        fetch_thread   = null;
        readme_thread  = null;
        install_thread = null;
    }
}

/// Called every frame from Gui.zig. No-ops when marketplace is hidden.
pub fn draw(app: *AppState) void {
    const mkt = &app.gui.marketplace;
    if (!mkt.visible) return;

    if (mkt.registry_status == .idle) startFetchRegistry(app);

    if (comptime is_wasm) {
        // Poll ongoing WASM async fetches each frame.
        pollWasm(app);
    } else {
        // Native: join completed threads so handles don't accumulate.
        if (fetch_thread != null and
            (mkt.registry_status == .done or mkt.registry_status == .failed))
        {
            if (fetch_thread) |t| { t.join(); fetch_thread = null; }
        }
        if (readme_thread != null and
            (mkt.readme_status == .done or mkt.readme_status == .failed))
        {
            if (readme_thread) |t| { t.join(); readme_thread = null; }
        }
        if (install_thread != null and
            (mkt.install_status == .done or mkt.install_status == .failed))
        {
            if (install_thread) |t| { t.join(); install_thread = null; }
        }
    }

    var fwin = dvui.floatingWindow(@src(), .{
        .modal     = true,
        .open_flag = &mkt.visible,
        .rect      = &win_rect,
    }, .{
        .min_size_content = .{ .w = MODAL_MIN_WIDTH, .h = MODAL_MIN_HEIGHT },
    });
    defer fwin.deinit();

    fwin.dragAreaSet(dvui.windowHeader("  Plugin Marketplace", "", &mkt.visible));

    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer body.deinit();

        {
            var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer cols.deinit();
            drawLeftPanel(app);
            _ = dvui.separator(@src(), .{ .id_extra = 1 });
            drawRightPanel(app);
        }

        _ = dvui.separator(@src(), .{ .id_extra = 2 });
        drawFooter(app);
    }
}

// ── WASM per-frame polling ─────────────────────────────────────────────────

fn pollWasm(app: *AppState) void {
    const alloc = app.allocator();
    const mkt = &app.gui.marketplace;

    if (wasm_registry_get) |*g| {
        if (g.poll()) |data| {
            if (data.len > 0) parseRegistry(app, data) else mkt.registry_status = .failed;
            g.deinit(alloc);
            wasm_registry_get = null;
        }
    }

    if (wasm_readme_get) |*g| {
        if (g.poll()) |data| {
            if (data.len > 0) {
                mkt.readme_text.clearRetainingCapacity();
                mkt.readme_text.appendSlice(alloc, data) catch {};
                mkt.readme_status = .done;
            } else {
                mkt.readme_status = .failed;
            }
            g.deinit(alloc);
            wasm_readme_get = null;
        }
    }
}

// ── Left panel: search + plugin cards ─────────────────────────────────────

fn drawLeftPanel(app: *AppState) void {
    const mkt = &app.gui.marketplace;

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = LEFT_PANEL_MIN_WIDTH },
        .expand           = .vertical,
        .background       = true,
        .color_fill       = .{ .r = 28, .g = 28, .b = 32, .a = 255 },
        .padding          = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    defer panel.deinit();

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Search:", .{}, .{ .gravity_y = 0.5 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = mkt.search_buf[0..127] },
        }, .{ .expand = .horizontal });
        defer te.deinit();
    }

    _ = dvui.separator(@src(), .{ .id_extra = 10 });

    switch (mkt.registry_status) {
        .idle    => {},
        .fetching => dvui.labelNoFmt(@src(), "Fetching registry\xe2\x80\xa6", .{}, .{ .style = .control }),
        .done    => {},
        .failed  => dvui.labelNoFmt(@src(), "Registry fetch failed", .{}, .{ .style = .err }),
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const search_text = std.mem.sliceTo(&mkt.search_buf, 0);

    if (mkt.entries.items.len == 0 and mkt.registry_status == .done) {
        dvui.labelNoFmt(@src(), "No plugins found.", .{}, .{});
    }

    for (mkt.entries.items, 0..) |*entry, i| {
        const entry_name   = std.mem.sliceTo(&entry.name,   0);
        const entry_author = std.mem.sliceTo(&entry.author, 0);
        const entry_ver    = std.mem.sliceTo(&entry.version, 0);
        const entry_desc   = std.mem.sliceTo(&entry.desc,   0);

        if (search_text.len > 0) {
            const hit_name = caseContains(entry_name, search_text);
            const hit_desc = caseContains(entry_desc, search_text);
            const hit_tags = caseContains(std.mem.sliceTo(&entry.tags, 0), search_text);
            if (!hit_name and !hit_desc and !hit_tags) continue;
        }

        const is_selected = mkt.selected == @as(i16, @intCast(i));

        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra      = i,
            .background    = true,
            .expand        = .horizontal,
            .border        = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
            .corner_radius = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .padding       = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin        = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            .color_fill    = if (is_selected)
                .{ .r = 38, .g = 52, .b = 90, .a = 255 }
            else
                .{ .r = 36, .g = 36, .b = 42, .a = 255 },
        });
        defer card.deinit();

        drawCardHeader(entry_name, entry_author, entry_ver, entry_desc, i);

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i * 20 + 4,
                .expand   = .horizontal,
                .margin   = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
            });
            defer row.deinit();

            if (dvui.button(@src(), "Details", .{}, .{ .id_extra = i * 20 + 5 })) {
                selectPlugin(app, @intCast(i));
            }
            _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = i * 20 + 6 });

            if (entry.installed) {
                dvui.labelNoFmt(@src(), "\xe2\x9c\x93", .{}, .{
                    .id_extra  = i * 20 + 7,
                    .style     = .highlight,
                    .gravity_y = 0.5,
                });
            } else {
                if (dvui.button(@src(), "Install", .{}, .{ .id_extra = i * 20 + 8, .style = .highlight })) {
                    selectPlugin(app, @intCast(i));
                    startInstall(app, i);
                }
            }
        }
    }
}

// ── Card header helper ─────────────────────────────────────────────────────

fn drawCardHeader(
    name:    []const u8,
    author:  []const u8,
    ver:     []const u8,
    desc:    []const u8,
    id_base: usize,
) void {
    dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = id_base * 20 + 1 });

    var meta_buf: [128]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s}  v{s}", .{ author, ver }) catch author;
    dvui.labelNoFmt(@src(), meta, .{}, .{ .id_extra = id_base * 20 + 2, .style = .control });

    const first_nl   = std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len;
    const first_line = desc[0..first_nl];
    const shown_len  = @min(first_line.len, DESC_TRUNCATE_LEN);
    const ellipsis   = if (first_line.len > DESC_TRUNCATE_LEN) "\xe2\x80\xa6" else "";
    var desc_buf: [48]u8 = undefined;
    const short_desc = std.fmt.bufPrint(&desc_buf, "{s}{s}", .{ first_line[0..shown_len], ellipsis })
        catch first_line[0..shown_len];
    dvui.labelNoFmt(@src(), short_desc, .{}, .{ .id_extra = id_base * 20 + 3, .style = .control });
}

// ── Right panel: selected plugin detail + README ───────────────────────────

fn drawRightPanel(app: *AppState) void {
    const mkt = &app.gui.marketplace;

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand  = .both,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
    });
    defer panel.deinit();

    if (mkt.selected < 0 or @as(usize, @intCast(mkt.selected)) >= mkt.entries.items.len) {
        dvui.labelNoFmt(@src(), "Select a plugin to view details.", .{}, .{ .gravity_y = 0.5 });
        return;
    }

    const idx   = @as(usize, @intCast(mkt.selected));
    const entry = &mkt.entries.items[idx];

    const entry_name   = std.mem.sliceTo(&entry.name,     0);
    const entry_author = std.mem.sliceTo(&entry.author,   0);
    const entry_ver    = std.mem.sliceTo(&entry.version,  0);
    const entry_tags   = std.mem.sliceTo(&entry.tags,     0);
    const entry_repo   = std.mem.sliceTo(&entry.repo_url, 0);

    dvui.labelNoFmt(@src(), entry_name, .{}, .{ .id_extra = 1 });

    {
        var meta_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 4 },
        });
        defer meta_row.deinit();
        var meta_buf: [128]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "by {s}  \xc2\xb7  v{s}", .{ entry_author, entry_ver })
            catch entry_author;
        dvui.labelNoFmt(@src(), meta, .{}, .{ .id_extra = 2, .style = .control, .gravity_y = 0.5 });
    }

    if (entry_tags.len > 0) {
        var tags_buf: [120]u8 = undefined;
        const tags_label = std.fmt.bufPrint(&tags_buf, "Tags: {s}", .{entry_tags}) catch entry_tags;
        dvui.labelNoFmt(@src(), tags_label, .{}, .{ .id_extra = 3, .style = .control });
    }

    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
        });
        defer btns.deinit();

        switch (mkt.install_status) {
            .idle, .done => {
                const btn_label = if (entry.installed) "Reinstall" else "Install";
                if (dvui.button(@src(), btn_label, .{}, .{ .id_extra = 10, .style = .highlight })) {
                    startInstall(app, idx);
                }
            },
            .fetching => dvui.labelNoFmt(@src(), "Installing\xe2\x80\xa6", .{}, .{ .id_extra = 11, .gravity_y = 0.5 }),
            .failed => {
                dvui.labelNoFmt(@src(), "Install failed!", .{}, .{ .id_extra = 12, .style = .err, .gravity_y = 0.5 });
                if (dvui.button(@src(), "Retry", .{}, .{ .id_extra = 13 })) {
                    startInstall(app, idx);
                }
            },
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });

        if (entry_repo.len > 0) {
            if (dvui.button(@src(), "View on GitHub", .{}, .{ .id_extra = 14 })) {
                Platform.openUrl(app.allocator(), entry_repo) catch {};
            }
        }
    }

    if (mkt.install_msg_len > 0) {
        dvui.labelNoFmt(@src(), mkt.install_msg[0..mkt.install_msg_len], .{}, .{
            .id_extra = 20,
            .style    = if (mkt.install_status == .failed) .err else .highlight,
        });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 30 });

    dvui.labelNoFmt(@src(), "README", .{}, .{ .id_extra = 40 });
    _ = dvui.separator(@src(), .{ .id_extra = 41 });

    switch (mkt.readme_status) {
        .idle     => dvui.labelNoFmt(@src(), "No description loaded.", .{}, .{ .id_extra = 50 }),
        .fetching => dvui.labelNoFmt(@src(), "Loading README\xe2\x80\xa6", .{}, .{ .id_extra = 50 }),
        .failed   => dvui.labelNoFmt(@src(), "Failed to load README.", .{}, .{ .style = .err, .id_extra = 50 }),
        .done => {
            var readme_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer readme_scroll.deinit();
            var lines  = std.mem.splitScalar(u8, mkt.readme_text.items, '\n');
            var line_i: u32 = 0;
            while (lines.next()) |line| {
                dvui.labelNoFmt(@src(), line, .{}, .{ .id_extra = 100 + line_i });
                line_i += 1;
            }
        },
    }
}

// ── Footer: custom GitHub URL ──────────────────────────────────────────────

fn drawFooter(app: *AppState) void {
    const mkt = &app.gui.marketplace;

    var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand  = .horizontal,
        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
    });
    defer footer.deinit();

    dvui.labelNoFmt(@src(), "Custom plugin (GitHub URL):", .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = mkt.custom_url_buf[0..511] },
    }, .{ .expand = .horizontal });
    defer te.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });

    if (dvui.button(@src(), "Add", .{}, .{})) {
        const url = std.mem.sliceTo(&mkt.custom_url_buf, 0);
        if (url.len > 0) startFetchCustom(app);
    }
}

// ── Plugin selection ───────────────────────────────────────────────────────

fn selectPlugin(app: *AppState, idx: i16) void {
    const mkt = &app.gui.marketplace;
    if (mkt.selected == idx) return;
    mkt.selected      = idx;
    mkt.readme_status = .idle;
    mkt.readme_text.clearRetainingCapacity();
    if (idx >= 0 and @as(usize, @intCast(idx)) < mkt.entries.items.len) {
        startFetchReadme(app, @intCast(idx));
    }
}

// ── Fetch registry ─────────────────────────────────────────────────────────

fn startFetchRegistry(app: *AppState) void {
    app.gui.marketplace.registry_status = .fetching;

    if (comptime is_wasm) {
        wasm_req_id += 1;
        wasm_registry_get = Platform.AsyncGet.start(app.allocator(), REGISTRY_URL, wasm_req_id, 256 * 1024)
            catch {
                app.gui.marketplace.registry_status = .failed;
                return;
            };
    } else {
        if (fetch_thread != null) return;
        const ctx = allocCtx(app, REGISTRY_URL) catch {
            app.gui.marketplace.registry_status = .failed;
            return;
        };
        fetch_thread = std.Thread.spawn(.{}, fetchRegistryThread, .{ctx})
            catch |e| blk: {
                std.log.err("marketplace: spawn fetch thread: {}", .{e});
                app.gui.marketplace.registry_status = .failed;
                break :blk null;
            };
    }
}

fn fetchRegistryThread(ctx_ptr: *FetchCtx) void {
    defer std.heap.page_allocator.destroy(ctx_ptr);
    const app = ctx_ptr.app;
    const url = ctx_ptr.url[0..ctx_ptr.url_len];

    const bytes = Platform.httpGetSync(std.heap.page_allocator, url) catch {
        fetch_mutex.lock();
        app.gui.marketplace.registry_status = .failed;
        fetch_mutex.unlock();
        return;
    };
    defer std.heap.page_allocator.free(bytes);
    parseRegistry(app, bytes);
}

// ── Parse registry JSON ────────────────────────────────────────────────────

fn parseRegistry(app: *AppState, json_bytes: []const u8) void {
    const Schema = struct {
        version: u32 = 0,
        plugins: []const PluginSchema,

        const PluginSchema = struct {
            id:          []const u8 = "",
            name:        []const u8 = "",
            author:      []const u8 = "",
            version:     []const u8 = "0.0.0",
            description: []const u8 = "",
            tags:        []const []const u8 = &.{},
            repo:        []const u8 = "",
            readme_url:  []const u8 = "",
            download:    DownloadSchema = .{},

            const DownloadSchema = struct {
                linux: []const u8 = "",
                macos: []const u8 = "",
            };
        };
    };

    const list_alloc = app.allocator();

    // Arena for the JSON parse tree only — freed when this function returns.
    var arena = std.heap.ArenaAllocator.init(list_alloc);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(Schema, arena.allocator(), json_bytes, .{
        .ignore_unknown_fields = true,
        .allocate              = .alloc_always,
    }) catch |e| {
        std.log.warn("marketplace: json parse error: {}", .{e});
        if (!is_wasm) fetch_mutex.lock();
        app.gui.marketplace.registry_status = .failed;
        if (!is_wasm) fetch_mutex.unlock();
        return;
    };

    if (!is_wasm) fetch_mutex.lock();
    defer if (!is_wasm) fetch_mutex.unlock();

    const mkt = &app.gui.marketplace;
    mkt.entries.clearRetainingCapacity();

    for (parsed.value.plugins) |p| {
        var entry: st.MarketplaceEntry = .{};
        copyStr(&entry.id,         p.id);
        copyStr(&entry.name,       p.name);
        copyStr(&entry.author,     p.author);
        copyStr(&entry.version,    p.version);
        copyStr(&entry.desc,       p.description);
        copyStr(&entry.repo_url,   p.repo);
        copyStr(&entry.readme_url, p.readme_url);
        copyStr(&entry.dl_linux,   p.download.linux);

        var tags_buf: [96]u8 = [_]u8{0} ** 96;
        var tags_pos: usize = 0;
        for (p.tags, 0..) |tag, ti| {
            if (ti > 0 and tags_pos + 2 < tags_buf.len) {
                tags_buf[tags_pos]     = ',';
                tags_buf[tags_pos + 1] = ' ';
                tags_pos += 2;
            }
            const remaining = tags_buf.len -| tags_pos -| 1;
            const copy_len  = @min(tag.len, remaining);
            @memcpy(tags_buf[tags_pos..][0..copy_len], tag[0..copy_len]);
            tags_pos += copy_len;
        }
        @memcpy(&entry.tags, &tags_buf);

        entry.installed = isPluginLoaded(app, p.id);
        mkt.entries.append(list_alloc, entry) catch break;
    }

    mkt.registry_status = .done;
}

// ── Fetch README ───────────────────────────────────────────────────────────

fn startFetchReadme(app: *AppState, idx: usize) void {
    const url_src = std.mem.sliceTo(&app.gui.marketplace.entries.items[idx].readme_url, 0);
    if (url_src.len == 0) return;

    app.gui.marketplace.readme_status = .fetching;
    app.gui.marketplace.readme_text.clearRetainingCapacity();

    if (comptime is_wasm) {
        if (wasm_readme_get) |*g| { g.deinit(app.allocator()); wasm_readme_get = null; }
        wasm_req_id += 1;
        wasm_readme_get = Platform.AsyncGet.start(app.allocator(), url_src, wasm_req_id, 512 * 1024)
            catch {
                app.gui.marketplace.readme_status = .failed;
                return;
            };
    } else {
        if (readme_thread) |t| { t.join(); readme_thread = null; }
        const ctx = allocCtx(app, url_src) catch {
            app.gui.marketplace.readme_status = .failed;
            return;
        };
        readme_thread = std.Thread.spawn(.{}, fetchReadmeThread, .{ctx})
            catch |e| blk: {
                std.log.err("marketplace: spawn readme thread: {}", .{e});
                app.gui.marketplace.readme_status = .failed;
                break :blk null;
            };
    }
}

fn fetchReadmeThread(ctx_ptr: *FetchCtx) void {
    defer std.heap.page_allocator.destroy(ctx_ptr);
    const app = ctx_ptr.app;
    const url = ctx_ptr.url[0..ctx_ptr.url_len];

    const bytes = Platform.httpGetSync(std.heap.page_allocator, url) catch {
        readme_mutex.lock();
        app.gui.marketplace.readme_status = .failed;
        readme_mutex.unlock();
        return;
    };
    defer std.heap.page_allocator.free(bytes);

    readme_mutex.lock();
    defer readme_mutex.unlock();

    const mkt = &app.gui.marketplace;
    mkt.readme_text.clearRetainingCapacity();
    mkt.readme_text.appendSlice(app.allocator(), bytes) catch {};
    mkt.readme_status = .done;
}

// ── Install plugin ─────────────────────────────────────────────────────────

const InstallCtx = struct {
    app:       *AppState,
    url:       [512]u8,
    url_len:   usize,
    dest_dir:  [512]u8,
    filename:  [128]u8,
    fname_len: usize,
};

fn startInstall(app: *AppState, idx: usize) void {
    if (comptime is_wasm) {
        setInstallMsg(app, "Install not supported on web.", .failed);
        return;
    }

    if (install_thread) |t| { t.join(); install_thread = null; }

    const entry   = &app.gui.marketplace.entries.items[idx];
    const url_src = std.mem.sliceTo(&entry.dl_linux, 0);
    if (url_src.len == 0) {
        setInstallMsg(app, "No download URL for this platform.", .failed);
        return;
    }

    const plugin_id = std.mem.sliceTo(&entry.id, 0);
    var home_buf: [512]u8 = undefined;
    const home = Platform.getEnvVar(std.heap.page_allocator, "HOME") catch
        std.heap.page_allocator.dupe(u8, "/tmp") catch "/tmp";
    defer std.heap.page_allocator.free(home);
    const dest = std.fmt.bufPrint(&home_buf, "{s}/.config/Schemify/{s}", .{ home, plugin_id })
        catch "/tmp";

    const ctx = std.heap.page_allocator.create(InstallCtx) catch return;
    ctx.* = .{
        .app       = app,
        .url       = [_]u8{0} ** 512,
        .url_len   = @min(url_src.len, 511),
        .dest_dir  = [_]u8{0} ** 512,
        .filename  = [_]u8{0} ** 128,
        .fname_len = 0,
    };
    @memcpy(ctx.url[0..ctx.url_len], url_src[0..ctx.url_len]);
    const dest_len = @min(dest.len, 511);
    @memcpy(ctx.dest_dir[0..dest_len], dest[0..dest_len]);

    const slash_pos = std.mem.lastIndexOfScalar(u8, url_src, '/') orelse 0;
    const fname     = if (slash_pos + 1 < url_src.len) url_src[slash_pos + 1..] else url_src;
    ctx.fname_len = @min(fname.len, 127);
    @memcpy(ctx.filename[0..ctx.fname_len], fname[0..ctx.fname_len]);

    app.gui.marketplace.install_status = .fetching;
    setInstallMsg(app, "Downloading\xe2\x80\xa6", .fetching);

    install_thread = std.Thread.spawn(.{}, installThread, .{ctx})
        catch |e| blk: {
            std.log.err("marketplace: spawn install thread: {}", .{e});
            setInstallMsg(app, "Failed to start download thread.", .failed);
            break :blk null;
        };
}

fn installThread(ctx_ptr: *InstallCtx) void {
    defer std.heap.page_allocator.destroy(ctx_ptr);
    const app          = ctx_ptr.app;
    const url          = ctx_ptr.url[0..ctx_ptr.url_len];
    const dest_dir_str = std.mem.sliceTo(&ctx_ptr.dest_dir, 0);
    const filename     = ctx_ptr.filename[0..ctx_ptr.fname_len];

    std.fs.makeDirAbsolute(dest_dir_str) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.log.warn("marketplace: mkdir {s}: {}", .{ dest_dir_str, e });
            setInstallMsg(app, "Failed to create install directory.", .failed);
            return;
        },
    };

    const downloaded = Platform.httpGetSync(std.heap.page_allocator, url) catch {
        setInstallMsg(app, "Download failed (network error).", .failed);
        return;
    };
    defer std.heap.page_allocator.free(downloaded);

    var path_buf: [640]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dest_dir_str, filename })
        catch {
            setInstallMsg(app, "Path too long.", .failed);
            return;
        };

    const file = std.fs.createFileAbsolute(full_path, .{}) catch |e| {
        std.log.warn("marketplace: createFile {s}: {}", .{ full_path, e });
        setInstallMsg(app, "Failed to write plugin file.", .failed);
        return;
    };
    defer file.close();
    file.writeAll(downloaded) catch {
        setInstallMsg(app, "Write error.", .failed);
        return;
    };
    file.chmod(0o755) catch {};

    install_mutex.lock();
    defer install_mutex.unlock();
    setInstallMsg(app, "Installed! Reload plugins to activate.", .done);
}

// ── Fetch custom plugin registry ───────────────────────────────────────────

fn startFetchCustom(app: *AppState) void {
    const raw_url = std.mem.sliceTo(&app.gui.marketplace.custom_url_buf, 0);
    if (raw_url.len == 0) return;

    var url_buf: [512]u8 = undefined;
    const base    = std.mem.trimRight(u8, raw_url, "/");
    const api_url = if (std.mem.startsWith(u8, base, "https://github.com/"))
        std.fmt.bufPrint(&url_buf,
            "https://raw.githubusercontent.com/{s}/main/schemify-plugin.json",
            .{base["https://github.com/".len..]}) catch base
    else
        base;

    app.gui.marketplace.registry_status = .fetching;

    if (comptime is_wasm) {
        if (wasm_registry_get) |*g| { g.deinit(app.allocator()); wasm_registry_get = null; }
        wasm_req_id += 1;
        wasm_registry_get = Platform.AsyncGet.start(app.allocator(), api_url, wasm_req_id, 256 * 1024)
            catch {
                app.gui.marketplace.registry_status = .failed;
                return;
            };
    } else {
        if (fetch_thread) |t| { t.join(); fetch_thread = null; }
        const ctx = allocCtx(app, api_url) catch {
            app.gui.marketplace.registry_status = .failed;
            return;
        };
        fetch_thread = std.Thread.spawn(.{}, fetchRegistryThread, .{ctx})
            catch |e| blk: {
                std.log.err("marketplace: spawn custom fetch: {}", .{e});
                app.gui.marketplace.registry_status = .failed;
                break :blk null;
            };
    }
}

// ── Utilities ──────────────────────────────────────────────────────────────

const FetchCtx = struct { app: *AppState, url: [512]u8, url_len: usize };

fn allocCtx(app: *AppState, url: []const u8) !*FetchCtx {
    const ctx = try std.heap.page_allocator.create(FetchCtx);
    ctx.* = .{ .app = app, .url = [_]u8{0} ** 512, .url_len = @min(url.len, 511) };
    @memcpy(ctx.url[0..ctx.url_len], url[0..ctx.url_len]);
    return ctx;
}

fn copyStr(dest: []u8, src: []const u8) void {
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
}

fn setInstallMsg(app: *AppState, msg: []const u8, status: MktStatus) void {
    const mkt = &app.gui.marketplace;
    const n   = @min(msg.len, mkt.install_msg.len - 1);
    @memcpy(mkt.install_msg[0..n], msg[0..n]);
    mkt.install_msg[n]  = 0;
    mkt.install_msg_len = @intCast(n);
    mkt.install_status  = status;
}

fn isPluginLoaded(app: *AppState, id: []const u8) bool {
    for (app.gui.plugin_panels.items) |panel| {
        if (std.mem.eql(u8, panel.id, id)) return true;
    }
    return false;
}

fn caseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}
