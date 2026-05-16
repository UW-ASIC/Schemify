//! Startup plugin download overlay — shown when Config.toml lists plugins
//! that aren't installed on disk.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

pub fn draw(app: *st.AppState) void {
    const dl = &app.startup_dl;
    if (!dl.active) return;

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
    }, .{ .min_size_content = .{ .w = 400, .h = 200 } });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Installing Plugins", "", null));

    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both, .padding = .all(16),
        });
        defer body.deinit();

        if (dl.failed) {
            // Error state — show message + Retry / Continue buttons
            const err_msg = dl.error_msg[0..dl.error_len];
            dvui.labelNoFmt(@src(), if (err_msg.len > 0) err_msg else "Download failed", .{}, .{
                .id_extra = 1,
            });
            _ = dvui.separator(@src(), .{ .id_extra = 2 });

            {
                var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal, .id_extra = 3,
                });
                defer btn_row.deinit();

                if (dvui.button(@src(), "Retry", .{}, .{ .id_extra = 4 })) {
                    dl.failed = false;
                    dl.done = 0;
                    dl.error_len = 0;
                    dl.retry_requested = true;
                }
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = 5 });
                if (dvui.button(@src(), "Continue Anyway", .{}, .{ .id_extra = 6 })) {
                    dl.active = false;
                }
            }
        } else {
            // Progress state
            const current = dl.current_name[0..dl.current_name_len];
            if (current.len > 0) {
                dvui.labelNoFmt(@src(), current, .{}, .{ .id_extra = 10, .style = .highlight });
            }

            // Progress text: "2/5 plugins installed"
            var progress_buf: [64]u8 = undefined;
            const progress_text = std.fmt.bufPrint(&progress_buf, "{d}/{d} plugins installed", .{ dl.done, dl.total }) catch "...";
            dvui.labelNoFmt(@src(), progress_text, .{}, .{ .id_extra = 11 });

            // Progress bar
            const frac: f32 = if (dl.total > 0) @as(f32, @floatFromInt(dl.done)) / @as(f32, @floatFromInt(dl.total)) else 0;
            dvui.progress(@src(), .{ .percent = frac }, .{
                .expand = .horizontal, .id_extra = 12,
                .min_size_content = .{ .h = 16 },
            });

            if (dl.done >= dl.total and dl.total > 0) {
                // All done — auto-close
                dl.active = false;
            }
        }
    }
}
