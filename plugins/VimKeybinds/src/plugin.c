/* Enable POSIX extensions. */
#define _POSIX_C_SOURCE 200809L

/*
 * VimKeybinds — Schemify Plugin (ABI v7, C99)
 *
 * Adds vim-style modal keybindings to Schemify.
 *
 * Modes:
 *   NORMAL  — hjkl navigation, single-key actions (d, y, p, r, x, u, etc.)
 *   INSERT  — all keys pass through to Schemify (text editing, wire placement)
 *   VISUAL  — selection mode (v to enter, operates on selection)
 *
 * Press 'i' to enter INSERT mode, Escape to return to NORMAL.
 * Press 'v' to enter VISUAL mode, Escape to return to NORMAL.
 * Press ':' to enter Schemify's built-in command mode (already handled by host).
 *
 * Build:  make
 * Install: make install
 */

#include "lib.h"
#include <stdio.h>
#include <string.h>

/* ── Modes ───────────────────────────────────────────────────────────────── */

enum Mode { MODE_NORMAL = 0, MODE_INSERT = 1, MODE_VISUAL = 2 };

/* ── Modifier bit packing (matches KeyMapping.zig packMods) ──────────────── */

#define MOD_CTRL  (1 << 0)
#define MOD_SHIFT (1 << 1)
#define MOD_ALT   (1 << 2)

/* Key action values (matches Input.zig) */
#define ACTION_DOWN   0
#define ACTION_UP     1
#define ACTION_REPEAT 2

/* ── Plugin state ────────────────────────────────────────────────────────── */

static enum Mode g_mode = MODE_NORMAL;
static int       g_count = 0;     /* numeric prefix (e.g. 3j = move down 3) */
static int       g_pending_g = 0; /* waiting for second char after 'g'      */

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static void set_status(SpWriter *w, const char *msg) {
    sp_write_set_status(w, msg, strlen(msg));
}

static void push_cmd(SpWriter *w, const char *tag) {
    sp_write_push_command(w, tag, strlen(tag), "", 0);
}

/* Repeat a command `count` times (minimum 1). */
static void push_cmd_n(SpWriter *w, const char *tag, int count) {
    if (count < 1) count = 1;
    for (int i = 0; i < count; i++)
        push_cmd(w, tag);
}

/* ── Status line showing current mode ────────────────────────────────────── */

static void show_mode(SpWriter *w) {
    switch (g_mode) {
    case MODE_NORMAL: set_status(w, "-- NORMAL --"); break;
    case MODE_INSERT: set_status(w, "-- INSERT --"); break;
    case MODE_VISUAL: set_status(w, "-- VISUAL --"); break;
    }
}

/* ── Normal-mode key handler ─────────────────────────────────────────────── */
/*
 * Returns 1 if the key was handled (consume_event), 0 to pass through.
 *
 * Vim mappings (Schemify-adapted):
 *
 *   Navigation:
 *     h/j/k/l       — pan left/down/up/right (or nudge if selection)
 *     H/J/K/L       — pan by larger amount
 *     gg            — zoom fit (top of file analog)
 *     G             — zoom fit (bottom analog — same action, schematic)
 *     zz            — zoom reset (center view)
 *     zi/zo         — zoom in / zoom out
 *     Ctrl+d/Ctrl+u — large pan down/up
 *
 *   Editing:
 *     i             — INSERT mode (pass-through for text/wire interaction)
 *     v             — VISUAL mode (selection)
 *     a             — make symbol from schematic (append analog)
 *     o             — open file explorer
 *     d / dd / x    — delete selected
 *     y / yy        — copy selected (yank)
 *     p             — paste
 *     u             — undo
 *     Ctrl+r        — redo
 *     r             — rotate CW
 *     R             — rotate CCW
 *     .             — duplicate (repeat last action analog)
 *
 *   Tools:
 *     w             — wire mode
 *     W             — wire snap mode
 *     e             — descend into schematic
 *     E             — ascend to parent
 *     q             — edit properties
 *     /             — find/select dialog
 *     n             — netlist hierarchical
 *     m             — move mode
 *     c             — copy mode
 *     f             — zoom fit
 *     s             — view schematic
 *     S             — view symbol
 *     X             — flip horizontal
 *     Y             — flip vertical
 *     F5            — run simulation (pass through)
 *     Ins           — insert from library (pass through)
 *
 *   Other:
 *     Escape        — escape mode / clear
 *     :             — command mode (handled by host Shift+;)
 *     0-9           — numeric prefix for count
 */

static int handle_normal(uint8_t key, uint8_t mods, SpWriter *w) {
    int ctrl  = (mods & MOD_CTRL)  != 0;
    int shift = (mods & MOD_SHIFT) != 0;
    /* int alt = (mods & MOD_ALT)   != 0; */

    /* ── Numeric prefix ──────────────────────────────────────────────── */
    if (key >= '0' && key <= '9' && !ctrl && !shift) {
        /* Don't allow leading zero as count (0 could be a motion later) */
        if (key == '0' && g_count == 0) {
            /* '0' with no count — could map to beginning-of-line, pass for now */
            return 0;
        }
        g_count = g_count * 10 + (key - '0');
        return 1;
    }

    int count = g_count > 0 ? g_count : 1;
    g_count = 0;

    /* ── Pending 'g' sequences ───────────────────────────────────────── */
    if (g_pending_g) {
        g_pending_g = 0;
        switch (key) {
        case 'g': push_cmd(w, "zoom_fit"); return 1;  /* gg = zoom fit */
        case 'd': push_cmd(w, "descend_schematic"); return 1;  /* gd = descend */
        default: return 0;
        }
    }

    /* ── Ctrl combinations ───────────────────────────────────────────── */
    if (ctrl) {
        switch (key) {
        case 'r': push_cmd_n(w, "redo", count);    return 1;
        case 'd': /* large pan down */
            for (int i = 0; i < count * 5; i++) push_cmd(w, "nudge_down");
            return 1;
        case 'u': /* large pan up */
            for (int i = 0; i < count * 5; i++) push_cmd(w, "nudge_up");
            return 1;
        case 's':  return 0; /* let host handle Ctrl+S natively */
        default: return 0; /* pass through other Ctrl combos */
        }
    }

    /* ── Shifted keys ────────────────────────────────────────────────── */
    if (shift) {
        switch (key) {
        case 'H': for (int i = 0; i < count * 5; i++) push_cmd(w, "nudge_left");  return 1;
        case 'J': for (int i = 0; i < count * 5; i++) push_cmd(w, "nudge_down");  return 1;
        case 'K': for (int i = 0; i < count * 5; i++) push_cmd(w, "nudge_up");    return 1;
        case 'L': for (int i = 0; i < count * 5; i++) push_cmd(w, "nudge_right"); return 1;
        case 'R': push_cmd_n(w, "rotate_ccw", count); return 1;
        case 'S': push_cmd(w, "descend_symbol");  return 1;  /* S = view symbol */
        case 'W': push_cmd(w, "start_wire_snap"); return 1;
        case 'X': push_cmd_n(w, "flip_horizontal", count); return 1;
        case 'Y': push_cmd_n(w, "flip_vertical", count); return 1;
        case 'G': push_cmd(w, "zoom_fit"); return 1;  /* G = zoom fit */
        case 'O': push_cmd(w, "toggle_colorscheme"); return 1;
        default: return 0;
        }
    }

    /* ── Plain keys ──────────────────────────────────────────────────── */
    switch (key) {
    /* Navigation — hjkl */
    case 'h': push_cmd_n(w, "nudge_left",  count); return 1;
    case 'j': push_cmd_n(w, "nudge_down",  count); return 1;
    case 'k': push_cmd_n(w, "nudge_up",    count); return 1;
    case 'l': push_cmd_n(w, "nudge_right", count); return 1;

    /* Mode switches */
    case 'i':
        g_mode = MODE_INSERT;
        show_mode(w);
        return 1;
    case 'v':
        g_mode = MODE_VISUAL;
        push_cmd(w, "select_none");
        show_mode(w);
        return 1;

    /* Editing */
    case 'd': push_cmd(w, "delete_selected");    return 1;
    case 'x': push_cmd(w, "delete_selected");    return 1;
    case 'y': push_cmd(w, "clipboard_copy");     return 1;
    case 'p': push_cmd(w, "clipboard_paste");    return 1;
    case 'u': push_cmd_n(w, "undo", count);      return 1;
    case 'r': push_cmd_n(w, "rotate_cw", count); return 1;
    case '.': push_cmd(w, "duplicate_selected");  return 1;

    /* Tools */
    case 'w': push_cmd(w, "start_wire");                  return 1;
    case 'e': push_cmd(w, "descend_schematic");            return 1;
    case 'a': push_cmd(w, "make_symbol_from_schematic");   return 1;
    case 'o': push_cmd(w, "open_file_explorer");           return 1;
    case 'q': push_cmd(w, "edit_properties");              return 1;
    case '/': push_cmd(w, "find_select_dialog");           return 1;
    case 'n': push_cmd(w, "netlist_hierarchical");         return 1;
    case 'm': push_cmd(w, "move_interactive");             return 1;
    case 'c': push_cmd(w, "copy_selected");                return 1;
    case 't': push_cmd(w, "place_text");                   return 1;
    case 's': push_cmd(w, "descend_schematic");            return 1;
    case 'f': push_cmd(w, "zoom_fit");                     return 1;

    /* Zoom */
    case 'z': /* z is a prefix — but for simplicity map zz-like to zoom reset */
        push_cmd(w, "zoom_reset");
        return 1;

    /* g-prefix */
    case 'g':
        g_pending_g = 1;
        return 1;

    /* Backspace = ascend to parent */
    case '\b':
        push_cmd(w, "ascend");
        return 1;

    default:
        return 0; /* pass through */
    }
}

/* ── Visual-mode key handler ─────────────────────────────────────────────── */

static int handle_visual(uint8_t key, uint8_t mods, SpWriter *w) {
    int shift = (mods & MOD_SHIFT) != 0;
    int ctrl  = (mods & MOD_CTRL)  != 0;
    (void)shift; (void)ctrl;

    switch (key) {
    /* hjkl nudge selection */
    case 'h': push_cmd(w, "nudge_left");  return 1;
    case 'j': push_cmd(w, "nudge_down");  return 1;
    case 'k': push_cmd(w, "nudge_up");    return 1;
    case 'l': push_cmd(w, "nudge_right"); return 1;

    /* Operations on selection */
    case 'd': case 'x':
        push_cmd(w, "delete_selected");
        g_mode = MODE_NORMAL; show_mode(w);
        return 1;
    case 'y':
        push_cmd(w, "clipboard_copy");
        g_mode = MODE_NORMAL; show_mode(w);
        return 1;
    case 'r':
        push_cmd(w, "rotate_cw");
        return 1;
    case 'a':
        push_cmd(w, "select_all");
        return 1;

    default:
        return 0;
    }
}

/* ── Draw panel (settings/status) ────────────────────────────────────────── */

static void draw_panel(SpWriter *w) {
    const char *mode_str;
    switch (g_mode) {
    case MODE_NORMAL: mode_str = "NORMAL"; break;
    case MODE_INSERT: mode_str = "INSERT"; break;
    case MODE_VISUAL: mode_str = "VISUAL"; break;
    default:          mode_str = "???";    break;
    }

    char buf[80];
    snprintf(buf, sizeof(buf), "Mode: %s", mode_str);
    sp_write_ui_label(w, buf, strlen(buf), 1);
    sp_write_ui_separator(w, 2);
    sp_write_ui_label(w, "Esc = NORMAL, i = INSERT, v = VISUAL", 36, 3);
    sp_write_ui_label(w, "hjkl = navigate, d = delete, u = undo", 38, 4);
    sp_write_ui_label(w, "w = wire, r = rotate, p = paste", 31, 5);
    sp_write_ui_label(w, ": = command mode (built-in)", 27, 6);
}

/* ── Process ─────────────────────────────────────────────────────────────── */

static size_t vim_process(
    const uint8_t *in_ptr, size_t in_len,
    uint8_t       *out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg    msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {

        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "vim", 3,
                "Vim", 3,
                "vim", 3,
                SP_LAYOUT_RIGHT_SIDEBAR, 0);
            sp_write_subscribe_events(&w, SP_EVENT_KEYS);
            g_mode = MODE_NORMAL;
            set_status(&w, "-- NORMAL --");
            break;

        case SP_TAG_DRAW_PANEL:
            draw_panel(&w);
            break;

        case SP_TAG_KEY_EVENT: {
            uint8_t key    = msg.u.key_event.key;
            uint8_t mods   = msg.u.key_event.mods;
            uint8_t action = msg.u.key_event.action;

            /* Only handle key-down and repeat, not key-up. */
            if (action == ACTION_UP) break;

            /* Escape always returns to NORMAL from any mode. */
            if (key == 0x1B && mods == 0) { /* 0x1B = ESC */
                if (g_mode != MODE_NORMAL) {
                    g_mode = MODE_NORMAL;
                    g_count = 0;
                    g_pending_g = 0;
                    show_mode(&w);
                    sp_write_consume_event(&w);
                } else {
                    /* In normal mode, let Escape pass to host for escape_mode */
                    push_cmd(&w, "select_none");
                    sp_write_consume_event(&w);
                }
                break;
            }

            int consumed = 0;
            switch (g_mode) {
            case MODE_NORMAL:
                consumed = handle_normal(key, mods, &w);
                break;
            case MODE_INSERT:
                /* INSERT mode: pass everything through to host. */
                consumed = 0;
                break;
            case MODE_VISUAL:
                consumed = handle_visual(key, mods, &w);
                break;
            }

            if (consumed)
                sp_write_consume_event(&w);

            break;
        }

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("vim-keybinds", "0.1.0", vim_process)
