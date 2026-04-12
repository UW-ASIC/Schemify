/*
 * Schemify Plugin SDK — C demo
 *
 * Registers four panels and draws a widget gallery on every draw_panel call.
 *
 * Build:  zig build
 * Run:    zig build run
 */
#include "schemify_plugin.h"
#include <string.h>

static float  slider_val   = 0.5f;
static int    checkbox_val = 1;
static unsigned tick_count = 0;

static void draw_widgets(SpWriter* w) {
    sp_write_ui_label(w, "Selected: R1", 12, 0);
    sp_write_ui_separator(w, 1);
    sp_write_ui_label(w, "Value (kOhm)", 12, 2);
    sp_write_ui_slider(w, slider_val, 0.0f, 100.0f, 3);
    sp_write_ui_checkbox(w, (uint8_t)checkbox_val, "Show in netlist", 15, 4);
    sp_write_ui_button(w, "Apply", 5, 5);
    sp_write_ui_separator(w, 6);
    sp_write_ui_collapsible_start(w, "Component Browser", 17, 1, 7);
    sp_write_ui_label(w, "  Resistors: R1, R2, R3", 23, 8);
    sp_write_ui_label(w, "  Capacitors: C1", 16, 9);
    sp_write_ui_label(w, "  Transistors: M1, M2", 21, 10);
    sp_write_ui_collapsible_end(w, 7);
    sp_write_ui_separator(w, 11);
    sp_write_ui_label(w, "Design Stats", 12, 12);
    sp_write_ui_progress(w, 0.75f, 13);
    sp_write_ui_begin_row(w, 14);
    sp_write_ui_label(w, "Nets: 12", 8, 15);
    sp_write_ui_label(w, "Comps: 8", 8, 16);
    sp_write_ui_button(w, "Simulate", 8, 17);
    sp_write_ui_end_row(w, 14);
}

static size_t c_demo_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "c-demo-overlay", 15, "Properties",   10, "cdprop",   6, SP_LAYOUT_OVERLAY,       0);
            sp_write_register_panel(&w,
                "c-demo-left",    11, "Components",   10, "cdcomp",   6, SP_LAYOUT_LEFT_SIDEBAR,  0);
            sp_write_register_panel(&w,
                "c-demo-right",   12, "Design Stats", 12, "cdstats",  7, SP_LAYOUT_RIGHT_SIDEBAR, 0);
            sp_write_register_panel(&w,
                "c-demo-bottom",  13, "Status",        6, "cdstatus", 8, SP_LAYOUT_BOTTOM_BAR,    0);
            sp_write_set_status(&w, "C Demo loaded", 13);
            break;
        case SP_TAG_TICK:
            tick_count++;
            break;
        case SP_TAG_DRAW_PANEL:
            /* panel_id = msg.u.draw_panel.panel_id — switch on it when host
             * assigns distinct IDs per registration. Currently always 0. */
            draw_widgets(&w);
            break;
        case SP_TAG_SLIDER_CHANGED:
            if (msg.u.slider_changed.widget_id == 3)
                slider_val = msg.u.slider_changed.val;
            break;
        case SP_TAG_CHECKBOX_CHANGED:
            if (msg.u.checkbox_changed.widget_id == 4)
                checkbox_val = msg.u.checkbox_changed.val;
            break;
        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("c-demo", "0.1.0", c_demo_process)
