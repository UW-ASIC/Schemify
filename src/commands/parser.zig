const std = @import("std");
const types = @import("types.zig");
const Command = types.Command;
const Immediate = types.Immediate;
const Undoable = types.Undoable;
const PrimitiveKind = types.PrimitiveKind;

// ── Result types ─────────────────────────────────────────────────────────────

pub const MetaCommand = enum {
    quit,
    save,
    list_instances,
    list_wires,
    info,
    print_netlist,
    list_commands,
};

pub const MetaArg = union(enum) {
    saveas: []const u8,
    open_file: []const u8,
    set_snap: f32,
    select_instance: u32,
    select_wire: u32,
    deselect_instance: u32,
    deselect_wire: u32,
};

pub const Result = union(enum) {
    command: Command,
    meta: MetaCommand,
    meta_arg: MetaArg,
    /// Error message.  Empty string → skip silently (comment / blank line).
    err: []const u8,
};

// ── Public API ───────────────────────────────────────────────────────────────

/// Parse a single text command line into a Result.
/// Supports underscore names (`zoom_in`), kebab-case (`zoom-in`),
/// short aliases (`zoomin`), and leading `:` for vim-bar compat.
pub fn parse(line: []const u8) Result {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return .{ .err = "" };

    // Strip leading ':' for vim-bar compatibility.
    const effective = if (trimmed[0] == ':') trimmed[1..] else trimmed;
    if (effective.len == 0) return .{ .err = "" };

    var it = std.mem.splitScalar(u8, effective, ' ');
    const name = it.next() orelse return .{ .err = "" };
    const rest = std.mem.trim(u8, it.rest(), " \t");

    // 1. No-arg command (exact tag, kebab alias, or short alias)
    if (resolveNoArg(name)) |cmd| return .{ .command = cmd };

    // 2. Meta (no-arg)
    if (meta_map.get(name)) |m| return .{ .meta = m };

    // 3. Arg-bearing commands
    return parseWithArgs(name, rest);
}

// ── No-arg resolution ────────────────────────────────────────────────────────

fn resolveNoArg(name: []const u8) ?Command {
    // Direct match (underscore names from union tags).
    if (tryTagLookup(name)) |cmd| return cmd;

    // Kebab → underscore conversion.
    var buf: [128]u8 = undefined;
    if (name.len <= buf.len) {
        var differs = false;
        for (name, 0..) |c, i| {
            buf[i] = if (c == '-') blk: {
                differs = true;
                break :blk '_';
            } else c;
        }
        if (differs) {
            if (tryTagLookup(buf[0..name.len])) |cmd| return cmd;
        }
    }

    // Short alias table.
    if (alias_map.get(name)) |canonical| {
        if (tryTagLookup(canonical)) |cmd| return cmd;
    }

    return null;
}

pub fn tryTagLookup(name: []const u8) ?Command {
    if (std.meta.stringToEnum(std.meta.Tag(Immediate), name)) |tag| {
        if (tagToImmediate(tag)) |imm| return .{ .immediate = imm };
    }
    if (std.meta.stringToEnum(std.meta.Tag(Undoable), name)) |tag| {
        if (tagToUndoable(tag)) |und| return .{ .undoable = und };
    }
    return null;
}

fn tagToImmediate(tag: std.meta.Tag(Immediate)) ?Immediate {
    switch (tag) {
        inline else => |t| {
            const field = @typeInfo(Immediate).@"union".fields[@intFromEnum(t)];
            if (comptime field.type == void) {
                return @unionInit(Immediate, field.name, {});
            } else {
                return null;
            }
        },
    }
}

fn tagToUndoable(tag: std.meta.Tag(Undoable)) ?Undoable {
    switch (tag) {
        inline else => |t| {
            const field = @typeInfo(Undoable).@"union".fields[@intFromEnum(t)];
            if (comptime field.type == void) {
                return @unionInit(Undoable, field.name, {});
            } else {
                return null;
            }
        },
    }
}

// ── Alias map (vim-bar short names → canonical underscore names) ─────────────

const alias_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "rotcw", "rotate_cw" },
    .{ "rotccw", "rotate_ccw" },
    .{ "fliph", "flip_horizontal" },
    .{ "flipv", "flip_vertical" },
    .{ "zoomin", "zoom_in" },
    .{ "zoomout", "zoom_out" },
    .{ "zoomfit", "zoom_fit" },
    .{ "zoomreset", "zoom_reset" },
    .{ "zoomfitsel", "zoom_fit_selected" },
    .{ "tabnew", "new_tab" },
    .{ "tabclose", "close_tab" },
    .{ "tabnext", "next_tab" },
    .{ "tabprev", "prev_tab" },
    .{ "clipcopy", "clipboard_copy" },
    .{ "clipcut", "clipboard_cut" },
    .{ "clippaste", "clipboard_paste" },
    .{ "selectall", "select_all" },
    .{ "selectnone", "select_none" },
    .{ "invertsel", "invert_selection" },
    .{ "delete", "delete_selected" },
    .{ "del", "delete_selected" },
    .{ "duplicate", "duplicate_selected" },
    .{ "dup", "duplicate_selected" },
    .{ "wire", "start_wire" },
    .{ "netlist", "netlist_hierarchical" },
    .{ "descend", "descend_schematic" },
    .{ "back", "ascend" },
    .{ "props", "edit_properties" },
    .{ "explorer", "open_file_explorer" },
    .{ "files", "open_file_explorer" },
    .{ "find", "find_select_dialog" },
    .{ "library", "insert_from_library" },
    .{ "fullscreen", "toggle_fullscreen" },
    .{ "keybinds", "show_keybinds" },
    .{ "exportpdf", "export_pdf" },
    .{ "exportpng", "export_png" },
    .{ "exportsvg", "export_svg" },
    .{ "reload", "reload_from_disk" },
    .{ "e!", "reload_from_disk" },
    .{ "pluginsreload", "plugins_refresh" },
    .{ "marketplace", "open_marketplace" },
    .{ "imp", "open_import_project" },
    .{ "clearcache", "clear_sim_cache" },
    .{ "darkmode", "toggle_colorscheme" },
    .{ "grid", "toggle_grid" },
    .{ "crosshair", "toggle_crosshair" },
    .{ "escape", "escape_mode" },
    .{ "esc", "escape_mode" },
    .{ "new", "file_new" },
    .{ "aligngrid", "align_to_grid" },
    .{ "schematic", "descend_schematic" },
    .{ "symbol", "descend_symbol" },
    // ALLOWED_CMDS aliases (plugins use these names)
    .{ "copy_selected", "clipboard_copy" },
    .{ "move_interactive", "tool_move" },
    .{ "place_text", "tool_text" },
    .{ "start_wire_snap", "start_wire" },
    .{ "start_line", "tool_line" },
    .{ "start_rect", "tool_rect" },
    .{ "start_polygon", "tool_polygon" },
    .{ "view_properties", "edit_properties" },
    .{ "toggle_flat_netlist", "netlist_flat" },
    .{ "unhighlight_selected_nets", "unhighlight_all" },
});

// ── Meta map ─────────────────────────────────────────────────────────────────

const meta_map = std.StaticStringMap(MetaCommand).initComptime(.{
    .{ "quit", .quit },
    .{ "q", .quit },
    .{ "exit", .quit },
    .{ "save", .save },
    .{ "w", .save },
    .{ "list-instances", .list_instances },
    .{ "list_instances", .list_instances },
    .{ "li", .list_instances },
    .{ "instances", .list_instances },
    .{ "list-wires", .list_wires },
    .{ "list_wires", .list_wires },
    .{ "lw", .list_wires },
    .{ "wires", .list_wires },
    .{ "info", .info },
    .{ "print-netlist", .print_netlist },
    .{ "print_netlist", .print_netlist },
    .{ "nl", .print_netlist },
    .{ "commands", .list_commands },
    .{ "list-commands", .list_commands },
});

// ── Arg-bearing command parsers ──────────────────────────────────────────────

fn parseWithArgs(name: []const u8, rest: []const u8) Result {
    // place <sym> <name> <x> <y>
    if (eql(name, "place") or eql(name, "place-device") or eql(name, "place_device"))
        return parsePlaceDevice(rest);

    // add-wire <x0> <y0> <x1> <y1> [net_name]
    if (eql(name, "add-wire") or eql(name, "add_wire"))
        return parseAddWire(rest);

    // delete-instance <idx>
    if (eql(name, "delete-instance") or eql(name, "delete_instance") or eql(name, "di"))
        return parseDeleteInstance(rest);

    // delete-wire <idx>
    if (eql(name, "delete-wire") or eql(name, "delete_wire") or eql(name, "dw"))
        return parseDeleteWire(rest);

    // move-instance <idx> <dx> <dy>
    if (eql(name, "move-instance") or eql(name, "move_instance") or eql(name, "mi"))
        return parseMoveInstance(rest);

    // move-wire <idx> <dx> <dy>
    if (eql(name, "move-wire") or eql(name, "move_wire") or eql(name, "mw"))
        return parseMoveWire(rest);

    // set-prop <idx> <key> <value>
    if (eql(name, "set-prop") or eql(name, "set_instance_prop") or eql(name, "sp"))
        return parseSetProp(rest);

    // rename <idx> <new_name>
    if (eql(name, "rename") or eql(name, "rename-instance") or eql(name, "rename_instance"))
        return parseRename(rest);

    // rename-net <wire_idx> <new_name>
    if (eql(name, "rename-net") or eql(name, "rename_net"))
        return parseRenameNet(rest);

    // set-spice-code <code...>
    if (eql(name, "set-spice-code") or eql(name, "set_spice_code") or eql(name, "spice-code"))
        return if (rest.len > 0) .{ .command = .{ .undoable = .{ .set_spice_code = .{ .code = rest } } } }
    else
        .{ .err = "set-spice-code requires <code>" };

    // sim [ngspice|xyce|vacask]
    if (eql(name, "sim") or eql(name, "simulate") or eql(name, "run-sim") or eql(name, "run_sim"))
        return parseSim(rest);

    // insert <primitive_kind>
    if (eql(name, "insert") or eql(name, "insert-primitive") or eql(name, "insert_primitive"))
        return parseInsertPrimitive(rest);

    // plugin <tag> [payload]
    if (eql(name, "plugin") or eql(name, "plugin-cmd") or eql(name, "plugin_command"))
        return parsePluginCmd(rest);

    // plugin-mutation <tag> [payload]
    if (eql(name, "plugin-mutation") or eql(name, "plugin_mutation"))
        return parsePluginMutation(rest);

    // import [<path>] — with path: run_import; without path: open_import_project dialog
    if (eql(name, "import") or eql(name, "run-import") or eql(name, "run_import")) {
        if (rest.len == 0) return .{ .command = .{ .immediate = .open_import_project } };
        return .{ .command = .{ .immediate = .{ .run_import = .{ .path = rest } } } };
    }

    // optimize — opens optimizer dialog
    if (eql(name, "optimize") or eql(name, "run-optimize") or eql(name, "run_optimize"))
        return .{ .command = .{ .immediate = .run_optimize } };

    // ── Meta with args ──

    if (eql(name, "saveas") or eql(name, "w!") or eql(name, "save-as"))
        return if (rest.len > 0) .{ .meta_arg = .{ .saveas = rest } } else .{ .err = "saveas requires <path>" };

    if (eql(name, "open") or eql(name, "e"))
        return if (rest.len > 0) .{ .meta_arg = .{ .open_file = rest } } else .{ .err = "open requires <path>" };

    if (eql(name, "snap"))
        return if (std.fmt.parseFloat(f32, rest) catch null) |v| .{ .meta_arg = .{ .set_snap = v } } else .{ .err = "snap requires a numeric value" };

    if (eql(name, "select-instance") or eql(name, "select_instance") or eql(name, "si"))
        return if (parseU32(rest)) |idx| .{ .meta_arg = .{ .select_instance = idx } } else .{ .err = "select-instance requires <idx>" };

    if (eql(name, "select-wire") or eql(name, "select_wire") or eql(name, "sw"))
        return if (parseU32(rest)) |idx| .{ .meta_arg = .{ .select_wire = idx } } else .{ .err = "select-wire requires <idx>" };

    if (eql(name, "deselect-instance") or eql(name, "deselect_instance"))
        return if (parseU32(rest)) |idx| .{ .meta_arg = .{ .deselect_instance = idx } } else .{ .err = "deselect-instance requires <idx>" };

    if (eql(name, "deselect-wire") or eql(name, "deselect_wire"))
        return if (parseU32(rest)) |idx| .{ .meta_arg = .{ .deselect_wire = idx } } else .{ .err = "deselect-wire requires <idx>" };

    return .{ .err = "unknown command" };
}

// ── Individual arg parsers ───────────────────────────────────────────────────

fn parsePlaceDevice(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const sym = it.next() orelse return errMsg("place requires: <symbol> <name> <x> <y>");
    const n = it.next() orelse return errMsg("place requires: <symbol> <name> <x> <y>");
    const xs = it.next() orelse return errMsg("place requires: <symbol> <name> <x> <y>");
    const ys = it.next() orelse return errMsg("place requires: <symbol> <name> <x> <y>");
    const x = std.fmt.parseInt(i32, xs, 10) catch return errMsg("place: invalid x coordinate");
    const y = std.fmt.parseInt(i32, ys, 10) catch return errMsg("place: invalid y coordinate");
    return .{ .command = .{ .undoable = .{ .place_device = .{ .sym_path = sym, .name = n, .x = x, .y = y } } } };
}

fn parseAddWire(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const x0s = it.next() orelse return errMsg("add-wire requires: <x0> <y0> <x1> <y1>");
    const y0s = it.next() orelse return errMsg("add-wire requires: <x0> <y0> <x1> <y1>");
    const x1s = it.next() orelse return errMsg("add-wire requires: <x0> <y0> <x1> <y1>");
    const y1s = it.next() orelse return errMsg("add-wire requires: <x0> <y0> <x1> <y1>");
    const x0 = std.fmt.parseInt(i32, x0s, 10) catch return errMsg("add-wire: invalid coordinate");
    const y0 = std.fmt.parseInt(i32, y0s, 10) catch return errMsg("add-wire: invalid coordinate");
    const x1 = std.fmt.parseInt(i32, x1s, 10) catch return errMsg("add-wire: invalid coordinate");
    const y1 = std.fmt.parseInt(i32, y1s, 10) catch return errMsg("add-wire: invalid coordinate");
    const net = it.next();
    return .{ .command = .{ .undoable = .{ .add_wire = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .net_name = net } } } };
}

fn parseDeleteInstance(rest: []const u8) Result {
    const idx = parseU32(rest) orelse return errMsg("delete-instance requires <idx>");
    return .{ .command = .{ .undoable = .{ .delete_instance = .{ .idx = idx } } } };
}

fn parseDeleteWire(rest: []const u8) Result {
    const idx = parseU32(rest) orelse return errMsg("delete-wire requires <idx>");
    return .{ .command = .{ .undoable = .{ .delete_wire = .{ .idx = idx } } } };
}

fn parseMoveInstance(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const is = it.next() orelse return errMsg("move-instance requires: <idx> <dx> <dy>");
    const ds = it.next() orelse return errMsg("move-instance requires: <idx> <dx> <dy>");
    const es = it.next() orelse return errMsg("move-instance requires: <idx> <dx> <dy>");
    const idx = std.fmt.parseInt(u32, is, 10) catch return errMsg("move-instance: invalid idx");
    const dx = std.fmt.parseInt(i32, ds, 10) catch return errMsg("move-instance: invalid dx");
    const dy = std.fmt.parseInt(i32, es, 10) catch return errMsg("move-instance: invalid dy");
    return .{ .command = .{ .undoable = .{ .move_instance = .{ .idx = idx, .dx = dx, .dy = dy } } } };
}

fn parseMoveWire(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const is = it.next() orelse return errMsg("move-wire requires: <idx> <dx> <dy>");
    const ds = it.next() orelse return errMsg("move-wire requires: <idx> <dx> <dy>");
    const es = it.next() orelse return errMsg("move-wire requires: <idx> <dx> <dy>");
    const idx = std.fmt.parseInt(u32, is, 10) catch return errMsg("move-wire: invalid idx");
    const dx = std.fmt.parseInt(i32, ds, 10) catch return errMsg("move-wire: invalid dx");
    const dy = std.fmt.parseInt(i32, es, 10) catch return errMsg("move-wire: invalid dy");
    return .{ .command = .{ .undoable = .{ .move_wire = .{ .idx = idx, .dx = dx, .dy = dy } } } };
}

fn parseSetProp(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const is = it.next() orelse return errMsg("set-prop requires: <idx> <key> <value>");
    const key = it.next() orelse return errMsg("set-prop requires: <idx> <key> <value>");
    const val = std.mem.trim(u8, it.rest(), " \t");
    if (val.len == 0) return errMsg("set-prop requires: <idx> <key> <value>");
    const idx = std.fmt.parseInt(u32, is, 10) catch return errMsg("set-prop: invalid idx");
    return .{ .command = .{ .undoable = .{ .set_instance_prop = .{ .idx = idx, .key = key, .val = val } } } };
}

fn parseRename(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const is = it.next() orelse return errMsg("rename requires: <idx> <new_name>");
    const n = it.next() orelse return errMsg("rename requires: <idx> <new_name>");
    const idx = std.fmt.parseInt(u32, is, 10) catch return errMsg("rename: invalid idx");
    return .{ .command = .{ .undoable = .{ .rename_instance = .{ .idx = idx, .new_name = n } } } };
}

fn parseRenameNet(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const is = it.next() orelse return errMsg("rename-net requires: <wire_idx> <new_name>");
    const n = it.next() orelse return errMsg("rename-net requires: <wire_idx> <new_name>");
    const idx = std.fmt.parseInt(u32, is, 10) catch return errMsg("rename-net: invalid wire_idx");
    return .{ .command = .{ .undoable = .{ .rename_net = .{ .wire_idx = idx, .new_name = n } } } };
}

fn parseSim(rest: []const u8) Result {
    _ = rest;
    return .{ .command = .{ .undoable = .{ .run_sim = .{} } } };
}

fn parseInsertPrimitive(rest: []const u8) Result {
    if (rest.len == 0) return errMsg("insert requires <primitive_kind>");
    inline for (@typeInfo(PrimitiveKind).@"enum".fields) |f| {
        if (eql(rest, f.name)) {
            return .{ .command = .{ .immediate = .{ .insert_primitive = @enumFromInt(f.value) } } };
        }
    }
    return errMsg("unknown primitive kind");
}

fn parsePluginCmd(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const tag = it.next() orelse return errMsg("plugin requires <tag>");
    const payload = std.mem.trim(u8, it.rest(), " \t");
    return .{ .command = .{ .immediate = .{ .plugin_command = .{
        .tag = tag,
        .payload = if (payload.len > 0) payload else null,
    } } } };
}

fn parsePluginMutation(rest: []const u8) Result {
    var it = std.mem.splitScalar(u8, rest, ' ');
    const tag = it.next() orelse return errMsg("plugin-mutation requires <tag>");
    const payload = std.mem.trim(u8, it.rest(), " \t");
    return .{ .command = .{ .undoable = .{ .plugin_mutation = .{
        .tag = tag,
        .payload = if (payload.len > 0) payload else null,
    } } } };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseU32(s: []const u8) ?u32 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

fn errMsg(msg: []const u8) Result {
    return .{ .err = msg };
}

// ── Help output ──────────────────────────────────────────────────────────────

pub fn printCommandList(file: anytype) void {
    // Use writeAll throughout since utility.platform.fs.File has no .print().
    file.writeAll(
        \\
        \\Headless CLI:
        \\  schemify --cmd   <file.chn> <command> [args...]   Run one command, auto-save
        \\  schemify --batch <file.chn>                       Read commands from stdin
        \\  schemify --commands                                List this help
        \\
        \\No-argument commands (use underscore or kebab-case):
        \\
    ) catch {};

    file.writeAll("  Immediate (view / UI / mode):\n") catch {};
    inline for (@typeInfo(Immediate).@"union".fields) |f| {
        if (comptime f.type == void) {
            file.writeAll("    " ++ f.name ++ "\n") catch {};
        }
    }

    file.writeAll("\n  Undoable (schematic mutations):\n") catch {};
    inline for (@typeInfo(Undoable).@"union".fields) |f| {
        if (comptime f.type == void) {
            file.writeAll("    " ++ f.name ++ "\n") catch {};
        }
    }

    file.writeAll(
        \\
        \\Commands with arguments:
        \\  place <symbol> <name> <x> <y>        Place a device instance
        \\  add-wire <x0> <y0> <x1> <y1> [net]   Add a wire segment
        \\  delete-instance <idx>                 Delete instance by index
        \\  delete-wire <idx>                     Delete wire by index
        \\  move-instance <idx> <dx> <dy>         Move instance by delta
        \\  move-wire <idx> <dx> <dy>             Move wire by delta
        \\  set-prop <idx> <key> <value>          Set instance property
        \\  rename <idx> <new_name>               Rename an instance
        \\  rename-net <wire_idx> <new_name>      Rename a net
        \\  set-spice-code <code>                 Set SPICE code
        \\  sim [ngspice|xyce|vacask]             Run simulation
        \\  insert <primitive_kind>               Insert a primitive
        \\  plugin <tag> [payload]                Plugin command
        \\
        \\Query (print to stdout, no save):
        \\  list-instances (li)   list-wires (lw)   info   print-netlist (nl)
        \\
        \\Meta:
        \\  save (w)              Save active document
        \\  saveas <path> (w!)    Save to new path
        \\  open <path> (e)       Open a file
        \\  quit (q)              Exit (batch mode)
        \\  select-instance <idx> (si)   Select instance by index
        \\  select-wire <idx> (sw)       Select wire by index
        \\  snap <value>                 Set snap grid size
        \\
        \\Short aliases:
        \\  rotcw  rotccw  fliph  flipv  zoomin  zoomout  zoomfit  zoomreset
        \\  delete  dup  wire  netlist  descend  back  props  find  library
        \\  tabnew  tabclose  tabnext  tabprev  clipcopy  clipcut  clippaste
        \\
        \\Tip: use '#' for comments in batch scripts.
        \\
    ) catch {};
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parse no-arg underscore" {
    const r = parse("zoom_in");
    switch (r) {
        .command => |c| switch (c) {
            .immediate => |i| try std.testing.expect(i == .zoom_in),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse no-arg kebab" {
    const r = parse("zoom-in");
    switch (r) {
        .command => |c| switch (c) {
            .immediate => |i| try std.testing.expect(i == .zoom_in),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse alias" {
    const r = parse("rotcw");
    switch (r) {
        .command => |c| switch (c) {
            .undoable => |u| try std.testing.expect(u == .rotate_cw),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse vim colon prefix" {
    const r = parse(":zoomfit");
    switch (r) {
        .command => |c| switch (c) {
            .immediate => |i| try std.testing.expect(i == .zoom_fit),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse place device" {
    const r = parse("place nmos M1 100 200");
    switch (r) {
        .command => |c| switch (c) {
            .undoable => |u| switch (u) {
                .place_device => |p| {
                    try std.testing.expectEqualStrings("nmos", p.sym_path);
                    try std.testing.expectEqualStrings("M1", p.name);
                    try std.testing.expectEqual(@as(i32, 100), p.x);
                    try std.testing.expectEqual(@as(i32, 200), p.y);
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse add-wire" {
    const r = parse("add-wire 0 0 100 50 VDD");
    switch (r) {
        .command => |c| switch (c) {
            .undoable => |u| switch (u) {
                .add_wire => |w| {
                    try std.testing.expectEqual(@as(i32, 0), w.x0);
                    try std.testing.expectEqual(@as(i32, 50), w.y1);
                    try std.testing.expectEqualStrings("VDD", w.net_name.?);
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse meta" {
    try std.testing.expect(parse("save").meta == .save);
    try std.testing.expect(parse("w").meta == .save);
    try std.testing.expect(parse("q").meta == .quit);
    try std.testing.expect(parse("li").meta == .list_instances);
}

test "parse meta arg" {
    switch (parse("saveas /tmp/out.chn")) {
        .meta_arg => |ma| switch (ma) {
            .saveas => |p| try std.testing.expectEqualStrings("/tmp/out.chn", p),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse comment and blank" {
    try std.testing.expectEqualStrings("", parse("# comment").err);
    try std.testing.expectEqualStrings("", parse("").err);
    try std.testing.expectEqualStrings("", parse("   ").err);
}

test "parse unknown" {
    try std.testing.expectEqualStrings("unknown command", parse("xyzzy").err);
}
