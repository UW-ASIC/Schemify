//! Keybind data and types — no drawing, no dvui dependency beyond key enum.
//! gui.zig owns dispatch; this file owns the table, the Keybind type, and
//! the binary-search lookup over the comptime-sorted static table.
//!
//! All single-key and modifier+key bindings live here.  gui.zig's
//! handleNormalMode only handles the three cases that mutate GUI state
//! directly: grid toggle, command-mode entry, and the `:` prompt.

const std   = @import("std");
const dvui  = @import("dvui");
const command = @import("commands");
const actions = @import("Actions.zig");

// ── Types ─────────────────────────────────────────────────────────────────── //

/// Discriminated union: either enqueue a command or run a GUI command directly.
pub const KeybindAction = union(enum) {
    queue: struct { cmd: command.Command, msg: []const u8 },
    gui:   actions.GuiCommand,
};

pub const Keybind = struct {
    key:    dvui.enums.Key,
    ctrl:   bool,
    shift:  bool,
    alt:    bool,
    action: KeybindAction,
};

// ── Comptime helpers (file-scope only) ────────────────────────────────────── //

fn imm(comptime tag: command.Immediate) command.Command { return .{ .immediate = tag }; }
fn und(comptime tag: command.Undoable)  command.Command { return .{ .undoable  = tag }; }

/// Encode (key_int, ctrl, shift, alt) into a u32 sort key.
/// Layout: [31..3 = key_int][2 = ctrl][1 = shift][0 = alt]
/// Gives a strict total order over all (key, modifier) tuples.
fn sortKey(kb: Keybind) u32 {
    return (@as(u32, @intFromEnum(kb.key)) << 3) |
           (@as(u32, @intFromBool(kb.ctrl))  << 2) |
           (@as(u32, @intFromBool(kb.shift)) << 1) |
           (@as(u32, @intFromBool(kb.alt))   << 0);
}

fn sortKeyRaw(key: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) u32 {
    return (@as(u32, @intFromEnum(key)) << 3) |
           (@as(u32, @intFromBool(ctrl))  << 2) |
           (@as(u32, @intFromBool(shift)) << 1) |
           (@as(u32, @intFromBool(alt))   << 0);
}

const f = false;
const t = true;

// ── Static keybind table (sorted by sortKey for O(log n) lookup) ──────────── //

/// Every built-in keybind.  Sorted ascending by sortKey() at comptime so
/// lookup() can use binarySearch.  Add new entries anywhere — the sort fixes
/// the order.
pub const static_keybinds = blk: {
    const table = [_]Keybind{
        // ── File ────────────────────────────────────────────────────────────
        .{ .key = .n, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_new           } },
        .{ .key = .o, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_open          } },
        .{ .key = .s, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_save          } },
        .{ .key = .s, .ctrl = t, .shift = t, .alt = f, .action = .{ .gui = .file_save_as       } },
        .{ .key = .s, .ctrl = f, .shift = f, .alt = t, .action = .{ .gui = .file_reload        } },
        .{ .key = .l, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_view_logs     } },
        .{ .key = .n, .ctrl = t, .shift = t, .alt = f, .action = .{ .gui = .file_start_process } },
        .{ .key = .q, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_exit          } },

        // ── Tab management ───────────────────────────────────────────────────
        .{ .key = .t,     .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.new_tab),            .msg = "New tab"            } } },
        .{ .key = .w,     .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.close_tab),          .msg = "Close tab"          } } },
        .{ .key = .t,     .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.reopen_last_closed), .msg = "Reopen last closed" } } },
        .{ .key = .left,  .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.prev_tab),           .msg = "Previous tab"       } } },
        .{ .key = .right, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.next_tab),           .msg = "Next tab"           } } },

        // ── Simulation ───────────────────────────────────────────────────────
        .{ .key = .f5, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.{ .run_sim = .{ .sim = .ngspice } }), .msg = "Queued simulation"      } } },
        .{ .key = .f6, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.plugins_refresh),                     .msg = "Queued plugin refresh" } } },

        // ── Zoom ─────────────────────────────────────────────────────────────
        .{ .key = .equal, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_in),           .msg = "Zoom in"           } } },
        .{ .key = .minus, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_out),          .msg = "Zoom out"          } } },
        .{ .key = .zero,  .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_reset),        .msg = "Zoom reset"        } } },
        .{ .key = .f,     .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit_selected), .msg = "Zoom fit selected" } } },

        // ── Undo / Redo ──────────────────────────────────────────────────────
        .{ .key = .z, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.undo), .msg = "Undo" } } },
        .{ .key = .y, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.redo), .msg = "Redo" } } },

        // ── Selection ────────────────────────────────────────────────────────
        .{ .key = .a, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.select_all),         .msg = "Select all"  } } },
        .{ .key = .a, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.select_none),        .msg = "Select none" } } },
        .{ .key = .f, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.find_select_dialog), .msg = "Find/select" } } },

        // ── Clipboard ────────────────────────────────────────────────────────
        .{ .key = .c, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.clipboard_copy),  .msg = "Copied" } } },
        .{ .key = .x, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.clipboard_cut),   .msg = "Cut"    } } },
        .{ .key = .v, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.clipboard_paste), .msg = "Pasted" } } },

        // ── Net highlight ────────────────────────────────────────────────────
        .{ .key = .k, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.unhighlight_selected_nets), .msg = "Unhighlighting nets" } } },
        .{ .key = .k, .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.select_attached_nets),      .msg = "Selecting nets"      } } },

        // ── Move / stretch ───────────────────────────────────────────────────
        .{ .key = .m, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.move_interactive_stretch), .msg = "Move stretch mode" } } },
        .{ .key = .u, .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.align_to_grid),            .msg = "Aligned to grid"  } } },

        // ── Snap ─────────────────────────────────────────────────────────────
        .{ .key = .g, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.snap_halve), .msg = "Snap halved" } } },

        // ── Hierarchy ────────────────────────────────────────────────────────
        .{ .key = .e, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.ascend),                    .msg = "Ascend"                     } } },
        .{ .key = .l, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.make_schematic_from_symbol), .msg = "Make schematic from symbol" } } },
        .{ .key = .h, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.make_schem_and_sym),         .msg = "Make both"                  } } },

        // ── View toggles ─────────────────────────────────────────────────────
        .{ .key = .b, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_text_in_symbols), .msg = "Toggle text in symbols" } } },
        .{ .key = .b, .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.toggle_symbol_details),  .msg = "Toggle symbol details"  } } },
        .{ .key = .x, .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.toggle_crosshair),       .msg = "Toggle crosshair"       } } },

        // ── Wires ────────────────────────────────────────────────────────────
        .{ .key = .l, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_orthogonal_routing), .msg = "Toggle ortho routing" } } },

        // ── Export ───────────────────────────────────────────────────────────
        .{ .key = .p, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.export_pdf), .msg = "Export PDF" } } },

        // ── Properties ───────────────────────────────────────────────────────
        .{ .key = .q, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.view_properties), .msg = "View properties" } } },

        // ── Symbol ───────────────────────────────────────────────────────────
        .{ .key = .p, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.make_symbol_from_schematic), .msg = "Make symbol" } } },

        // ── Netlisting ───────────────────────────────────────────────────────
        .{ .key = .n, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.netlist_top_only), .msg = "Top netlist" } } },

        // ── Plain single-key bindings ────────────────────────────────────────
        // These were previously in gui.zig's handleNormalMode switch.  Moving
        // them here lets lookup() handle them via the same O(log n) path and
        // eliminates the giant switch block.
        .{ .key = .a,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.make_symbol_from_schematic), .msg = "Making symbol"          } } },
        .{ .key = .b,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.merge_file_dialog),          .msg = "Merge file"             } } },
        .{ .key = .c,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.copy_selected),              .msg = "Copy mode"              } } },
        .{ .key = .d,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.duplicate_selected),         .msg = "Queued duplicate"       } } },
        .{ .key = .e,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.descend_schematic),          .msg = "Descend"                } } },
        .{ .key = .e,         .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.edit_in_new_tab),            .msg = "Edit in new tab"        } } },
        .{ .key = .f,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit),                   .msg = "Zoom fit"               } } },
        .{ .key = .i,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.descend_symbol),             .msg = "Descend symbol"         } } },
        .{ .key = .k,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.highlight_selected_nets),    .msg = "Highlighting nets"      } } },
        .{ .key = .k,         .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.unhighlight_all),            .msg = "Unhighlighting all"     } } },
        .{ .key = .l,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_line),                 .msg = "Line draw mode"         } } },
        .{ .key = .m,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.move_interactive),           .msg = "Move mode"              } } },
        .{ .key = .n,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.netlist_hierarchical),       .msg = "Generating netlist"     } } },
        .{ .key = .o,         .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_colorscheme),         .msg = "Toggle colorscheme"     } } },
        .{ .key = .p,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_polygon),              .msg = "Polygon draw mode"      } } },
        .{ .key = .q,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.edit_properties),            .msg = "Edit properties"        } } },
        .{ .key = .r,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.rotate_cw),                  .msg = "Queued rotate CW"       } } },
        .{ .key = .r,         .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = und(.rotate_ccw),                 .msg = "Queued rotate CCW"      } } },
        .{ .key = .s,         .ctrl = f, .shift = f, .alt = f, .action = .{ .gui = .view_schematic                                                                 } },
        .{ .key = .t,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.place_text),                 .msg = "Place text"             } } },
        .{ .key = .v,         .ctrl = f, .shift = t, .alt = f, .action = .{ .gui = .view_symbol                                                                    } },
        .{ .key = .w,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_wire),                 .msg = "Wire mode"              } } },
        .{ .key = .w,         .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_wire_snap),            .msg = "Wire mode (snap)"       } } },
        .{ .key = .x,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.flip_horizontal),            .msg = "Queued flip horizontal" } } },
        .{ .key = .x,         .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = und(.flip_vertical),              .msg = "Queued flip vertical"   } } },
        .{ .key = .z,         .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit),                   .msg = "Zoom fit"               } } },
        .{ .key = .g,         .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.snap_double),                .msg = "Snap doubled"           } } },
        .{ .key = .insert,    .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.insert_from_library),        .msg = "Opening library"        } } },
        .{ .key = .backslash, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_fullscreen),          .msg = "Toggle fullscreen"      } } },
        .{ .key = .delete,    .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.delete_selected),            .msg = "Queued delete"          } } },
        .{ .key = .backspace, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.ascend),                     .msg = "Ascend"                 } } },
    };

    // Insertion sort is O(n^2) branches at comptime; raise quota beyond the
    // default 1000 to accommodate the ~70-entry table (~4900 branches worst case).
    @setEvalBranchQuota(10000);
    const lessThan = struct {
        fn f_(_: void, a: Keybind, b: Keybind) bool {
            return sortKey(a) < sortKey(b);
        }
    }.f_;
    var sorted = table;
    std.sort.insertion(Keybind, &sorted, {}, lessThan);

    break :blk sorted;
};

// ── O(log n) lookup ───────────────────────────────────────────────────────── //

/// Return a pointer into static_keybinds for the given key+modifier combo,
/// or null if no binding exists.  O(log n) binary search.
pub fn lookup(key: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) ?*const Keybind {
    const needle = sortKeyRaw(key, ctrl, shift, alt);
    // Zig 0.15: binarySearch(T, items, context, compareFn) — context passed as 1st arg to compareFn
    const idx = std.sort.binarySearch(Keybind, &static_keybinds, needle, struct {
        fn order(k: u32, entry: Keybind) std.math.Order {
            return std.math.order(k, sortKey(entry));
        }
    }.order) orelse return null;
    return &static_keybinds[idx];

    // Note: if above fails to compile (API changed further), use lowerBound fallback below.
}

// ── Size test ─────────────────────────────────────────────────────────────── //

test "Expose struct size for keybinds" {
    const print = @import("std").debug.print;
    print("Keybind: {d}B\n", .{@sizeOf(Keybind)});
}
