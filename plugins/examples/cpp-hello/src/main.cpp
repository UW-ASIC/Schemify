/**
 * cpp-hello — minimal C++ plugin example for Schemify ABI v6.
 *
 * Demonstrates the header-only C++ SDK: SpReader, SpWriter, and the
 * SCHEMIFY_PLUGIN macro.  Compile with addCppPlugin() from the Zig SDK.
 */

#include "schemify_plugin.h"

extern "C" {

static size_t cpp_hello_process(
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
                "cpp-hello",  9,   /* id       */
                "C++ Hello",  9,   /* title    */
                "cpphello",   8,   /* vim_cmd  */
                SP_LAYOUT_OVERLAY, /* layout   */
                'h');              /* keybind  */
            sp_write_set_status(&w, "Hello from C++!", 15);
            break;

        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello from C++!",        15, 0);
            sp_write_ui_label(&w, "Built with the C++ SDK.", 23, 1);
            break;

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("CppHello", "0.1.0", cpp_hello_process)

} /* extern "C" */
