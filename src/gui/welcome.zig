//! Welcome screen — shown when no documents are open.
//! Renders a centered start page with quick actions, recent files, and hints.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const theme = @import("theme_config");
const command = @import("commands");
const helpers = @import("helpers.zig");

// ── Helpers ──────────────────────────────────────────────────────────────────

const toDvui = helpers.toDvui;
const baseName = helpers.baseName;

// ── Public API ───────────────────────────────────────────────────────────────

/// Render the welcome screen within the given rectangle.
/// Called from gui/lib.zig when `app.documents.items.len == 0`.
pub fn draw(app: *AppState, x: f32, y: f32, w: f32, h: f32) void {
    _ = x;
    _ = y;
    _ = h;

    const canvas_bg = toDvui(theme.Palette.dark().canvas_bg);
    const card_bg = toDvui(theme.chromeToolbarBg());
    const text_bright = toDvui(theme.chromeTextPrimary());
    const text_dim = toDvui(theme.chromeTextSecondary());
    const accent = toDvui(theme.chromeAccent());
    const separator_col = toDvui(theme.chromeSeparator());

    // Outer container — fills the canvas area with the dark background.
    const outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .color_fill = canvas_bg,
        .background = true,
    });
    defer outer.deinit();

    // Vertical centering: top spacer
    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    // Horizontally centered content column
    {
        const hcenter = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer hcenter.deinit();

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Main content column — constrained width
        {
            const content_w: f32 = @min(520, w - 80);
            const content = dvui.box(@src(), .{ .dir = .vertical }, .{
                .min_size_content = .{ .w = content_w },
                .max_size_content = .width(content_w),
            });
            defer content.deinit();

            // ── Title section ────────────────────────────────────────────
            drawTitle(text_bright, text_dim);

            // Spacing
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 32 } });

            // ── Quick Actions ────────────────────────────────────────────
            drawQuickActions(app, card_bg, text_bright, text_dim, accent);

            // Spacing
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 24 } });

            // ── Separator ────────────────────────────────────────────────
            _ = dvui.separator(@src(), .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 1 },
                .color_fill = separator_col,
            });

            // Spacing
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 24 } });

            // ── Recent Files ─────────────────────────────────────────────
            drawRecentFiles(app, card_bg, text_bright, text_dim, accent);

            // Spacing
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 32 } });

            // ── Keyboard hints ───────────────────────────────────────────
            drawHints(text_dim);
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    }

    // Vertical centering: bottom spacer
    _ = dvui.spacer(@src(), .{ .expand = .vertical });
}

// ── Section renderers ────────────────────────────────────────────────────────

fn drawTitle(text_bright: dvui.Color, text_dim: dvui.Color) void {
    const title_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 32 });
    const subtitle_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 14 });

    // App title — centered
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.label(@src(), "Schemify", .{}, .{
            .color_text = text_bright,
            .font = title_font,
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 } });

    // Subtitle — centered
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.label(@src(), "Schematic Editor", .{}, .{
            .color_text = text_dim,
            .font = subtitle_font,
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    }
}

fn drawQuickActions(
    app: *AppState,
    card_bg: dvui.Color,
    text_bright: dvui.Color,
    text_dim: dvui.Color,
    accent: dvui.Color,
) void {
    const section_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 13 });

    // Section header
    dvui.label(@src(), "Quick Actions", .{}, .{
        .color_text = text_dim,
        .font = section_font,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });

    // Buttons row
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
    });
    defer row.deinit();

    const alloc = app.allocator();

    // New Schematic
    if (dvui.button(@src(), "New Schematic  Ctrl+N", .{}, .{
        .padding = .{ .x = 16, .y = 10, .w = 16, .h = 10 },
        .color_fill = card_bg,
        .color_text = text_bright,
        .corner_radius = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
    })) {
        app.queue.push(alloc, .{ .immediate = .file_new }) catch {};
    }

    // Open File
    if (dvui.button(@src(), "Open File  Ctrl+O", .{}, .{
        .padding = .{ .x = 16, .y = 10, .w = 16, .h = 10 },
        .color_fill = card_bg,
        .color_text = accent,
        .corner_radius = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
    })) {
        app.open_file_explorer = true;
    }

    // Import Project — open the built-in import dialog
    if (dvui.button(@src(), "Import Project", .{}, .{
        .padding = .{ .x = 16, .y = 10, .w = 16, .h = 10 },
        .color_fill = card_bg,
        .color_text = text_bright,
        .corner_radius = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
    })) {
        app.gui.cold.import_project.is_open = true;
    }
}

fn drawRecentFiles(
    app: *AppState,
    card_bg: dvui.Color,
    text_bright: dvui.Color,
    text_dim: dvui.Color,
    accent: dvui.Color,
) void {
    _ = text_bright;
    const section_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 13 });
    const body_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 12 });
    const small_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 10 });

    // Section header
    dvui.label(@src(), "Recent Files", .{}, .{
        .color_text = text_dim,
        .font = section_font,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });

    const ct = &app.closed_tabs;
    const CAP = st.ClosedTabs.CAP;

    if (ct.len == 0) {
        dvui.label(@src(), "No recent files", .{}, .{
            .color_text = text_dim,
            .font = body_font,
            .padding = .{ .x = 8, .y = 12, .w = 0, .h = 12 },
        });
        return;
    }

    // List container with card background
    const list_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .color_fill = card_bg,
        .background = true,
        .corner_radius = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer list_box.deinit();

    // Show up to 8 most recent files
    const display_count: u8 = @min(ct.len, 8);
    for (0..display_count) |i| {
        const idx = (ct.head + CAP - 1 - @as(u8, @intCast(i))) % CAP;
        const path = ct.buf[idx];
        const name = baseName(path);

        if (dvui.button(@src(), name, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .color_fill = card_bg,
            .color_text = accent,
            .corner_radius = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            app.openPath(path) catch {
                app.status_msg = "Failed to open file";
            };
        }

        // Full path below filename
        dvui.labelNoFmt(@src(), path, .{}, .{
            .id_extra = i,
            .color_text = text_dim,
            .font = small_font,
            .padding = .{ .x = 12, .y = 0, .w = 12, .h = 4 },
        });

        // Separator between entries (not after the last one)
        if (i < display_count - 1) {
            _ = dvui.separator(@src(), .{
                .id_extra = i,
                .expand = .horizontal,
                .min_size_content = .{ .h = 1 },
                .color_fill = .{
                    .r = card_bg.r +| 15,
                    .g = card_bg.g +| 15,
                    .b = card_bg.b +| 15,
                    .a = 255,
                },
                .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
            });
        }
    }

    // Indicator if more files exist
    if (ct.len > 8) {
        var more_buf: [32]u8 = undefined;
        const more_text = std.fmt.bufPrint(&more_buf, "... and {d} more", .{ct.len - 8}) catch "";
        dvui.labelNoFmt(@src(), more_text, .{}, .{
            .color_text = text_dim,
            .font = small_font,
            .padding = .{ .x = 12, .y = 4, .w = 0, .h = 4 },
        });
    }
}

fn drawHints(text_dim: dvui.Color) void {
    const hint_font = dvui.Font.find(.{ .family = "Vera Sans", .size = 11 });
    const hint_col = dvui.Color{
        .r = text_dim.r -| 30,
        .g = text_dim.g -| 30,
        .b = text_dim.b -| 30,
        .a = text_dim.a,
    };

    // Centered hint row
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
    });
    defer row.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    dvui.label(@src(), "Press : for command mode  |  Ctrl+O to open  |  ? for help", .{}, .{
        .color_text = hint_col,
        .font = hint_font,
    });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
}
