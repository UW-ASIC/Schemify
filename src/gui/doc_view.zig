const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const tc = @import("theme_config");
const actions = @import("actions.zig");
const command = @import("commands");
const md_render = @import("md_render.zig");
const settings = @import("settings.zig");
const platform = @import("utility").platform;

pub fn draw(app: *AppState) void {
    const is_theme_mode = app.gui.cold.dialogs.settings.editing_theme_json;
    var editor = &app.gui.cold.doc_editor;

    if (!is_theme_mode) {
        // Normal documentation mode: load from schematic on first view
        const doc = app.active() orelse return;
        if (!editor.loaded) {
            {
                const text = doc.sch.str(doc.sch.documentation);
                if (text.len > 0) editor.setText(text);
            }
            editor.loaded = true;
        }
    }

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 6000,
        .expand = .both,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    defer outer.deinit();

    // ── Theme JSON banner ────────────────────────────────────────────────────
    if (is_theme_mode) {
        {
            var banner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 5990,
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            });
            defer banner.deinit();

            dvui.labelNoFmt(@src(), "Editing: theme.json", .{}, .{
                .id_extra = 5991,
                .color_text = tc.chromeAccent(),
            });

            _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 5992 });

            if (dvui.button(@src(), "Done", .{}, .{
                .id_extra = 5993,
                .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
                .corner_radius = dvui.Rect.all(4),
            })) {
                exitThemeJsonMode(app);
            }
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 5994 });
    }

    // ── Toolbar ──────────────────────────────────────────────────────────────
    {
        var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 6001,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        });
        defer toolbar.deinit();

        // Edit button
        if (dvui.button(@src(), "Edit", .{}, .{
            .id_extra = 6002,
            .style = if (editor.mode == .edit) .highlight else .control,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .corner_radius = dvui.Rect.all(4),
        })) {
            editor.mode = .edit;
        }

        // Preview button (hidden in theme mode -- JSON preview not useful)
        if (!is_theme_mode) {
            if (dvui.button(@src(), "Preview", .{}, .{
                .id_extra = 6003,
                .style = if (editor.mode == .preview) .highlight else .control,
                .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
                .corner_radius = dvui.Rect.all(4),
            })) {
                if (editor.mode == .edit) {
                    const doc = app.active() orelse return;
                    syncBuffer(app, editor, doc);
                }
                editor.mode = .preview;
            }
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 6004 });

        // Word count (only for documentation mode)
        if (!is_theme_mode) {
            var buf: [32]u8 = undefined;
            const wc = editor.wordCount();
            const wc_text = std.fmt.bufPrint(&buf, "words: {d}", .{wc}) catch "words: ?";
            dvui.labelNoFmt(@src(), wc_text, .{}, .{
                .id_extra = 6005,
                .gravity_y = 0.5,
                .color_text = tc.chromeTextSecondary(),
            });

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 }, .id_extra = 6006 });
        }

        // Save button
        if (dvui.button(@src(), "Save", .{}, .{
            .id_extra = 6007,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .corner_radius = dvui.Rect.all(4),
        })) {
            if (is_theme_mode) {
                saveThemeJson(app, editor);
            } else {
                const doc = app.active() orelse return;
                syncBuffer(app, editor, doc);
                actions.enqueue(app, .{ .immediate = .file_save }, "Saving...");
            }
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 6010 });

    // ── Content area ─────────────────────────────────────────────────────────
    switch (editor.mode) {
        .edit => {
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = &editor.edit_buf },
                .placeholder = if (is_theme_mode) "{ }" else "(empty -- start typing documentation)",
                .multiline = true,
            }, .{ .id_extra = 6020, .expand = .both });
            te.deinit();
        },
        .preview => {
            var scroll = dvui.scrollArea(@src(), .{}, .{
                .id_extra = 6030,
                .expand = .both,
                .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
            });
            defer scroll.deinit();

            const text = editor.getText();
            if (text.len > 0) {
                md_render.render(text);
            } else {
                dvui.labelNoFmt(@src(), "(no documentation)", .{}, .{
                    .id_extra = 6031,
                    .color_text = tc.chromeTextSecondary(),
                });
            }
        },
    }
}

fn saveThemeJson(app: *AppState, editor: *st.DocEditorState) void {
    const a = app.allocator();
    const dir = settings.configDir();
    if (dir.len == 0) {
        app.setStatusBuf("Config directory not initialized");
        return;
    }

    const json_text = editor.getText();

    // Write JSON to theme.json
    var path_buf: [520]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/theme.json", .{dir}) catch {
        app.setStatusBuf("Path too long");
        return;
    };
    const file = platform.fs.cwd().createFile(path, .{}) catch {
        app.setStatusBuf("Failed to write theme.json");
        return;
    };
    defer file.close();
    file.writeAll(json_text) catch {
        app.setStatusBuf("Failed to write theme.json");
        return;
    };

    // Reload theme from disk and apply
    settings.reload(a);
    const theme_json = settings.getActiveThemeJson(a) orelse {
        app.setStatusBuf("Theme saved (reload failed)");
        return;
    };
    defer a.free(theme_json);
    tc.applyJson(a, theme_json);

    // Update dark_mode flag from the applied theme
    app.cmd_flags.dark_mode = tc.active_config.dark;

    app.setStatusBuf("theme.json saved and applied");
}

fn exitThemeJsonMode(app: *AppState) void {
    app.gui.cold.dialogs.settings.editing_theme_json = false;
    app.gui.cold.doc_editor.loaded = false;
    app.gui.hot.view_mode = .schematic;
}

fn syncBuffer(app: *AppState, editor: *st.DocEditorState, doc: *st.Document) void {
    const text = editor.getText();
    doc.sch.setDocumentation(doc.alloc, text) catch {};
    doc.dirty = true;
    _ = app;
}
