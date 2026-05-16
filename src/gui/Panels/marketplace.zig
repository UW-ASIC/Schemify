//! Plugin Marketplace — VS-Code-style modal panel with registry fetch.
//! Native: background threads for HTTP + install/uninstall.
//! WASM: frame-tick polling for registry, install/uninstall disabled.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const utility = @import("utility");
const builtin = @import("builtin");

const theme = @import("theme_config");
const AppState = st.AppState;
const MktStatus = st.MktStatus;
const MarketplaceEntry = st.MarketplaceEntry;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const REGISTRY_URL = "https://raw.githubusercontent.com/UW-ASIC/Schemify/main/plugins/registry.json";

/// File-level flag to distinguish install vs uninstall when install_status is .fetching.
/// true = uninstall requested, false = install requested.
var pending_uninstall: bool = false;

// WASM async registry fetch state.
var wasm_http: ?utility.platform.AsyncHttpGet = null;
var wasm_http_buf: [256 * 1024]u8 = undefined; // 256 KB for registry.json

// ── Registry fetch ────────────────────────────────────────────────────────────

const RegistryDownloadJson = struct { linux: []const u8 = "", macos: []const u8 = "", wasm: []const u8 = "" };
const RegistryEntryJson = struct {
    id: []const u8 = "", name: []const u8 = "", author: []const u8 = "", version: []const u8 = "",
    description: []const u8 = "", tags: [][]const u8 = &.{}, repo: []const u8 = "",
    readme_url: []const u8 = "", logo_url: []const u8 = "", download: RegistryDownloadJson = .{},
};
const RegistryJson = struct { version: u32 = 0, plugins: []RegistryEntryJson = &.{} };

fn parseRegistryInto(mkt: *st.MarketplaceState, alloc: std.mem.Allocator, body: []const u8) void {
    const parsed = std.json.parseFromSlice(RegistryJson, alloc, body, .{ .ignore_unknown_fields = true }) catch {
        @atomicStore(MktStatus, &mkt.registry_status, .failed, .seq_cst);
        return;
    };
    defer parsed.deinit();

    // Detect already-installed plugins (native only).
    const config_dir = if (comptime !is_wasm) (utility.platform.pluginConfigDir(alloc) catch "") else "";
    defer if (comptime !is_wasm) { if (config_dir.len > 0) alloc.free(config_dir); };

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

        // Check if plugin exists on disk (native only).
        if (comptime !is_wasm) {
            if (config_dir.len > 0 and src.id.len > 0) {
                const probe = std.fmt.allocPrint(alloc, "{s}/{s}/plugin.toml", .{ config_dir, src.id }) catch null;
                if (probe) |p| {
                    defer alloc.free(p);
                    dst.installed = if (std.fs.cwd().access(p, .{})) true else |_| false;
                }
            }
        }

        mkt.entries.append(alloc, dst) catch break;
    }
    @atomicStore(MktStatus, &mkt.registry_status, .done, .seq_cst);
}

fn copyStr(src: []const u8, dst: []u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

// ── Native: background thread registry fetch ─────────────────────────────────

const FetchCtx = struct { mkt: *st.MarketplaceState, alloc: std.mem.Allocator };

fn fetchRegistryThread(ctx: FetchCtx) void {
    const body = utility.platform.httpGetSync(ctx.alloc, REGISTRY_URL) catch {
        @atomicStore(MktStatus, &ctx.mkt.registry_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(body);
    parseRegistryInto(ctx.mkt, ctx.alloc, body);
}

// ── Native: plugin install (background thread) ───────────────────────────────

const InstallCtx = struct {
    mkt: *st.MarketplaceState,
    entry: *MarketplaceEntry,
    alloc: std.mem.Allocator,
    refresh_flag: *bool,
};

fn installPluginThread(ctx: InstallCtx) void {
    const url = fixedStr(&ctx.entry.dl_linux);
    if (url.len == 0) {
        setInstallMsg(ctx.mkt, "No download URL for this platform");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    }

    const plugin_id = fixedStr(&ctx.entry.id);

    const config_dir = utility.platform.pluginConfigDir(ctx.alloc) catch {
        setInstallMsg(ctx.mkt, "Cannot determine config directory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(config_dir);

    const plugin_dir = std.fmt.allocPrint(ctx.alloc, "{s}/{s}", .{ config_dir, plugin_id }) catch {
        setInstallMsg(ctx.mkt, "Out of memory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(plugin_dir);

    std.fs.cwd().makePath(plugin_dir) catch {
        setInstallMsg(ctx.mkt, "Cannot create plugin directory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };

    const dest_path = std.fmt.allocPrint(ctx.alloc, "{s}/{s}.tar.gz", .{ plugin_dir, plugin_id }) catch {
        setInstallMsg(ctx.mkt, "Out of memory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(dest_path);

    // Download the plugin bundle via curl.
    var child = std.process.Child.init(&.{ "curl", "-sfL", "-o", dest_path, url }, ctx.alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        setInstallMsg(ctx.mkt, "Failed to start download (is curl installed?)");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    const term = child.wait() catch {
        setInstallMsg(ctx.mkt, "Download interrupted");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    if (term.Exited != 0) {
        setInstallMsg(ctx.mkt, "Download failed (curl error, check URL)");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    }

    // Extract tarball.
    var tar = std.process.Child.init(&.{ "tar", "-xzf", dest_path, "-C", plugin_dir, "--strip-components=1" }, ctx.alloc);
    tar.stdin_behavior = .Ignore;
    tar.stdout_behavior = .Ignore;
    tar.stderr_behavior = .Ignore;
    tar.spawn() catch {};
    _ = tar.wait() catch {};

    // Write a minimal plugin.toml so the plugin system has metadata.
    writePluginManifest(ctx.alloc, plugin_dir, ctx.entry);

    ctx.entry.installed = true;
    @atomicStore(bool, ctx.refresh_flag, true, .seq_cst);
    setInstallMsg(ctx.mkt, "Installed successfully");
    @atomicStore(MktStatus, &ctx.mkt.install_status, .idle, .seq_cst);
}

fn writePluginManifest(alloc: std.mem.Allocator, plugin_dir: []const u8, entry: *const MarketplaceEntry) void {
    const toml_path = std.fmt.allocPrint(alloc, "{s}/plugin.toml", .{plugin_dir}) catch return;
    defer alloc.free(toml_path);

    const id = fixedStr(&entry.id);
    const name = fixedStr(&entry.name);
    const ver = fixedStr(&entry.version);
    const author = fixedStr(&entry.author);
    const desc = fixedStr(&entry.desc);

    const content = std.fmt.allocPrint(alloc,
        \\[plugin]
        \\name        = "{s}"
        \\version     = "{s}"
        \\author      = "{s}"
        \\command     = "python3 src/plugin.py"
        \\description = "{s}"
        \\runtime     = "subprocess"
        \\api         = 1
        \\
    , .{ name, ver, author, desc }) catch return;
    defer alloc.free(content);

    std.fs.cwd().writeFile(.{ .sub_path = toml_path, .data = content }) catch {};
    _ = id;
}

// ── Native: plugin uninstall (background thread) ─────────────────────────────

const UninstallCtx = struct {
    mkt: *st.MarketplaceState,
    entry: *MarketplaceEntry,
    alloc: std.mem.Allocator,
    refresh_flag: *bool,
};

fn uninstallPluginThread(ctx: UninstallCtx) void {
    const plugin_id = fixedStr(&ctx.entry.id);

    const config_dir = utility.platform.pluginConfigDir(ctx.alloc) catch {
        setInstallMsg(ctx.mkt, "Cannot determine config directory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(config_dir);

    const plugin_dir = std.fmt.allocPrint(ctx.alloc, "{s}/{s}", .{ config_dir, plugin_id }) catch {
        setInstallMsg(ctx.mkt, "Out of memory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };
    defer ctx.alloc.free(plugin_dir);

    std.fs.cwd().deleteTree(plugin_dir) catch {
        setInstallMsg(ctx.mkt, "Failed to remove plugin directory");
        @atomicStore(MktStatus, &ctx.mkt.install_status, .failed, .seq_cst);
        return;
    };

    ctx.entry.installed = false;
    @atomicStore(bool, ctx.refresh_flag, true, .seq_cst);
    setInstallMsg(ctx.mkt, "Uninstalled successfully");
    @atomicStore(MktStatus, &ctx.mkt.install_status, .idle, .seq_cst);
}

fn setInstallMsg(mkt: *st.MarketplaceState, msg: []const u8) void {
    const n = @min(msg.len, mkt.install_msg.len - 1);
    @memcpy(mkt.install_msg[0..n], msg[0..n]);
    mkt.install_msg[n] = 0;
    mkt.install_msg_len = @intCast(n);
}

// ── Public API ───────────────────────────────────────────────────────────────

pub fn draw(app: *AppState) void {
    const mkt = &app.gui.cold.marketplace;
    if (!mkt.visible) return;

    // -- Registry fetch logic -------------------------------------------------
    if (mkt.registry_status == .idle) {
        mkt.registry_status = .fetching;
        if (comptime is_wasm) {
            wasm_http = utility.platform.AsyncHttpGet.start(REGISTRY_URL);
        } else {
            const ctx = FetchCtx{ .mkt = mkt, .alloc = app.allocator() };
            const thread = std.Thread.spawn(.{}, fetchRegistryThread, .{ctx}) catch { mkt.registry_status = .failed; return; };
            thread.detach();
        }
    }

    // WASM: poll async HTTP each frame.
    if (comptime is_wasm) {
        if (mkt.registry_status == .fetching) {
            if (wasm_http) |http| {
                switch (http.poll(&wasm_http_buf)) {
                    .pending => {},
                    .failed => { mkt.registry_status = .failed; wasm_http = null; },
                    .done => |body| {
                        parseRegistryInto(mkt, app.allocator(), body);
                        wasm_http = null;
                    },
                }
            }
        }
    }

    // -- Install/uninstall logic (native only) --------------------------------
    if (comptime !is_wasm) {
        if (mkt.install_status == .fetching) {
            if (mkt.selected >= 0 and @as(usize, @intCast(mkt.selected)) < mkt.entries.items.len) {
                const entry = &mkt.entries.items[@intCast(mkt.selected)];
                mkt.install_status = .done;

                if (pending_uninstall) {
                    pending_uninstall = false;
                    setInstallMsg(mkt, "Uninstalling...");
                    const ctx = UninstallCtx{
                        .mkt = mkt,
                        .entry = entry,
                        .alloc = app.allocator(),
                        .refresh_flag = &app.plugin_refresh_requested,
                    };
                    const thread = std.Thread.spawn(.{}, uninstallPluginThread, .{ctx}) catch {
                        setInstallMsg(mkt, "Failed to start uninstall thread");
                        mkt.install_status = .failed;
                        return;
                    };
                    thread.detach();
                } else {
                    {
                        var msg_buf: [128]u8 = undefined;
                        const plugin_name = fixedStr(&entry.name);
                        const dl_msg = std.fmt.bufPrint(&msg_buf, "Downloading {s}...", .{plugin_name}) catch "Downloading...";
                        setInstallMsg(mkt, dl_msg);
                    }
                    const ctx = InstallCtx{
                        .mkt = mkt,
                        .entry = entry,
                        .alloc = app.allocator(),
                        .refresh_flag = &app.plugin_refresh_requested,
                    };
                    const thread = std.Thread.spawn(.{}, installPluginThread, .{ctx}) catch {
                        setInstallMsg(mkt, "Failed to start install thread");
                        mkt.install_status = .failed;
                        return;
                    };
                    thread.detach();
                }
            } else {
                mkt.install_status = .idle;
            }
        }
    }

    const bg = theme.chromeToolbarBg();
    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true, .open_flag = &mkt.visible,
        .rect = @ptrCast(&app.gui.cold.marketplace_win.win_rect),
    }, .{
        .min_size_content = .{ .w = 680, .h = 480 }, .background = true,
        .color_fill = .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 220 },
        .color_border = .{ .r = bg.r +| 30, .g = bg.g +| 30, .b = bg.b +| 30, .a = 255 },
    });
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
      if (comptime is_wasm) {
          // WASM: plugins are bundled at build time, no runtime install.
          dvui.labelNoFmt(@src(), "Web plugins are pre-bundled.", .{}, .{ .id_extra = 709, .style = .control });
      } else {
          if (mkt.install_status == .done) {
              dvui.labelNoFmt(@src(), "Working...", .{}, .{ .id_extra = 709, .style = .control });
          } else if (entry.installed) {
              dvui.labelNoFmt(@src(), "Installed", .{}, .{ .id_extra = 709, .style = .control });
              _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 }, .id_extra = 715 });
              if (dvui.button(@src(), "Uninstall", .{}, .{ .id_extra = 716 })) {
                  pending_uninstall = true;
                  mkt.install_status = .fetching;
              }
          } else {
              if (dvui.button(@src(), "Install", .{}, .{ .id_extra = 710 })) {
                  pending_uninstall = false;
                  mkt.install_status = .fetching;
              }
          }
      }
    }

    // Show install status message (native only).
    if (comptime !is_wasm) {
        const msg = mkt.install_msg[0..mkt.install_msg_len];
        if (msg.len > 0) {
            dvui.labelNoFmt(@src(), msg, .{}, .{ .id_extra = 713, .style = .control });
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 711 });
    dvui.labelNoFmt(@src(), "Visit the plugin repository for documentation.", .{}, .{ .id_extra = 712, .style = .control });
    const repo = fixedStr(&entry.repo_url);
    if (repo.len > 0) {
        dvui.labelNoFmt(@src(), repo, .{}, .{ .id_extra = 714, .style = .control });
    }
}

fn fixedStr(buf: []const u8) []const u8 {
    return buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse buf.len)];
}
