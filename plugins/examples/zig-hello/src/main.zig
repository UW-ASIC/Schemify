const std = @import("std");
const Plugin = @import("PluginIF");

export fn schemify_process(
    in_ptr:  [*]const u8,
    in_len:  usize,
    out_ptr: [*]u8,
    out_cap: usize,
) usize {
    var r = Plugin.Reader.init(in_ptr[0..in_len]);
    var w = Plugin.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel(.{
                    .id       = "zig-hello",
                    .title    = "Zig Hello",
                    .vim_cmd  = "zhello",
                    .layout   = .overlay,
                    .keybind  = 'z',
                });
                w.setStatus("Hello from Zig!");
            },
            .draw_panel => {
                w.label("Hello from Zig!", 0);
                w.label("Built with the Zig SDK.", 1);
            },
            else => {},
        }
    }

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "ZigHello",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
