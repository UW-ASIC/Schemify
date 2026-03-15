/* c-hello — minimal Schemify C plugin (ABI v6) */

#include "schemify_plugin.h"

static size_t c_hello_process(
    const uint8_t* in_ptr,  size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "c-hello", 7,
                "C Hello", 7,
                "chello",  6,
                SP_LAYOUT_OVERLAY,
                'c');
            sp_write_set_status(&w, "Hello from C!", 13);
            break;

        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello from C!",  13, 0);
            sp_write_ui_label(&w, "Built with the C SDK.", 21, 1);
            break;

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("CHello", "0.1.0", c_hello_process)
