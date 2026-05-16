//! Missing-symbols overlay — pops up whenever the active document references
//! subcircuits that couldn't be resolved on disk. Listed names are populated
//! by Canvas/SymbolRenderer.draw each frame. The panel has a header with a
//! close button; once dismissed, it stays hidden until the set of missing
//! symbols changes (new unresolved symbol appears, or one gets resolved).

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// Module-level state: whether the overlay is currently shown and what count
// it was last shown at. When the count changes, we automatically re-show it
// so the user can't miss a newly-appeared unresolved symbol.
var open: bool = true;
var last_count: usize = 0;

/// Render the overlay if there are unresolved symbols and it hasn't been
/// dismissed. Call once per frame, after the canvas has drawn.
pub fn draw(app: *AppState) void {
    const doc = app.active() orelse return;
    const count = doc.missing_symbols.count();

    // Re-open whenever the set of missing symbols changes — new unresolved
    // symbol appearing shouldn't be silently suppressed because the user
    // previously dismissed the panel for a different set.
    if (count != last_count) {
        last_count = count;
        open = (count > 0);
    }

    if (count == 0 or !open) return;

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = false,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 320, .h = 180 },
        .max_size_content = .{ .w = 520, .h = 420 },
    });
    defer fwin.deinit();

    // windowHeader with a non-null open flag renders a close ✕ button that
    // flips the flag when clicked.
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "Missing Symbols ({d})", .{count}) catch "Missing Symbols";
    fwin.dragAreaSet(dvui.windowHeader(title, "", &open));

    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .all(6),
        });
        defer hdr.deinit();
        dvui.labelNoFmt(
            @src(),
            "These instance symbols could not be found on disk:",
            .{},
            .{ .style = .err },
        );
    }

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        for (doc.missing_symbols.keys(), 0..) |name, i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .all(2),
                .id_extra = i,
            });
            defer row.deinit();

            dvui.labelNoFmt(@src(), "•", .{}, .{ .id_extra = i });
            dvui.labelNoFmt(@src(), name, .{}, .{
                .expand = .horizontal,
                .id_extra = i + 100_000,
            });
        }
    }
}
