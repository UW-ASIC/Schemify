const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

// ── Public Types ──────────────────────────────────────────────────────────────

pub const PortDir = enum { input, output, inout };

pub const Port = struct {
    name: []const u8,
    direction: PortDir,
    bits: []const u32,
};

pub const CellConn = struct {
    pin: []const u8,
    bits: []const u32,
};

pub const Cell = struct {
    name: []const u8,
    cell_type: []const u8,
    connections: []const CellConn,
};

pub const NetName = struct {
    name: []const u8,
    bits: []const u32,
    hide_name: bool,
};

pub const YosysModule = struct {
    name: []const u8,
    ports: []const Port,
    cells: []const Cell,
    net_names: []const NetName,
};

/// Sentinel value used for constant bits ("0", "1", "x", "z").
/// The lower 8 bits encode the character, the upper bits are all set.
pub const CONST_BIT_FLAG: u32 = 0xFFFF_FF00;

/// Returns true if a bit value is a constant sentinel (not a net ID).
pub fn isConstBit(bit: u32) bool {
    return (bit & CONST_BIT_FLAG) == CONST_BIT_FLAG;
}

/// Extracts the constant character from a sentinel bit value.
pub fn constBitChar(bit: u32) u8 {
    return @truncate(bit & 0xFF);
}

/// Encodes a constant character ('0', '1', 'x', 'z') as a sentinel u32.
fn encodeConstBit(ch: u8) u32 {
    return CONST_BIT_FLAG | @as(u32, ch);
}

// ── Parsing ───────────────────────────────────────────────────────────────────

pub const ParseError = error{
    MissingModules,
    ModuleNotFound,
    InvalidStructure,
    InvalidBitValue,
    OutOfMemory,
};

/// Parse a yosys JSON netlist (produced by `write_json`) into a `YosysModule`.
///
/// If `top_module` is non-null, that module name is looked up. Otherwise the
/// first module in the "modules" object is used.
///
/// All returned slices are owned by `alloc` — the caller is responsible for
/// freeing them (see `deinit`).
pub fn parse(json_source: []const u8, top_module: ?[]const u8, alloc: Allocator) ParseError!YosysModule {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_source,
        .{},
    ) catch return error.InvalidStructure;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    const modules_val = root_obj.get("modules") orelse return error.MissingModules;
    const modules_obj = switch (modules_val) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    // Find the target module.
    const mod_name, const mod_val = if (top_module) |name| blk: {
        const v = modules_obj.get(name) orelse return error.ModuleNotFound;
        break :blk .{ name, v };
    } else blk: {
        var it = modules_obj.iterator();
        const entry = it.next() orelse return error.MissingModules;
        break :blk .{ entry.key_ptr.*, entry.value_ptr.* };
    };

    const mod_obj = switch (mod_val) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    // Parse ports.
    const ports = try parsePorts(mod_obj, alloc);

    // Parse cells.
    const cells = try parseCells(mod_obj, alloc);

    // Parse netnames.
    const net_names = try parseNetNames(mod_obj, alloc);

    // Duplicate the module name into caller-owned memory.
    const owned_name = alloc.dupe(u8, mod_name) catch return error.OutOfMemory;

    return .{
        .name = owned_name,
        .ports = ports,
        .cells = cells,
        .net_names = net_names,
    };
}

/// Free all memory associated with a `YosysModule` returned by `parse`.
pub fn deinit(module: *const YosysModule, alloc: Allocator) void {
    alloc.free(module.name);

    for (module.ports) |p| {
        alloc.free(p.name);
        alloc.free(p.bits);
    }
    alloc.free(module.ports);

    for (module.cells) |c| {
        alloc.free(c.name);
        alloc.free(c.cell_type);
        for (c.connections) |conn| {
            alloc.free(conn.pin);
            alloc.free(conn.bits);
        }
        alloc.free(c.connections);
    }
    alloc.free(module.cells);

    for (module.net_names) |nn| {
        alloc.free(nn.name);
        alloc.free(nn.bits);
    }
    alloc.free(module.net_names);
}

// ── Internal Helpers ──────────────────────────────────────────────────────────

fn parsePorts(mod_obj: std.json.ObjectMap, alloc: Allocator) ParseError![]const Port {
    const ports_val = mod_obj.get("ports") orelse return &.{};
    const ports_obj = switch (ports_val) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    var list = List(Port){};
    errdefer {
        for (list.items) |p| {
            alloc.free(p.name);
            alloc.free(p.bits);
        }
        list.deinit(alloc);
    }

    var it = ports_obj.iterator();
    while (it.next()) |entry| {
        const port_obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.InvalidStructure,
        };

        const dir_str = switch (port_obj.get("direction") orelse return error.InvalidStructure) {
            .string => |s| s,
            else => return error.InvalidStructure,
        };

        const direction: PortDir = if (std.mem.eql(u8, dir_str, "input"))
            .input
        else if (std.mem.eql(u8, dir_str, "output"))
            .output
        else if (std.mem.eql(u8, dir_str, "inout"))
            .inout
        else
            return error.InvalidStructure;

        const bits = try parseBitsArray(port_obj.get("bits") orelse return error.InvalidStructure, alloc);
        errdefer alloc.free(bits);

        const owned_name = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        errdefer alloc.free(owned_name);

        list.append(alloc, .{
            .name = owned_name,
            .direction = direction,
            .bits = bits,
        }) catch return error.OutOfMemory;
    }

    return list.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn parseCells(mod_obj: std.json.ObjectMap, alloc: Allocator) ParseError![]const Cell {
    const cells_val = mod_obj.get("cells") orelse return &.{};
    const cells_obj = switch (cells_val) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    var list = List(Cell){};
    errdefer {
        for (list.items) |c| {
            alloc.free(c.name);
            alloc.free(c.cell_type);
            for (c.connections) |conn| {
                alloc.free(conn.pin);
                alloc.free(conn.bits);
            }
            alloc.free(c.connections);
        }
        list.deinit(alloc);
    }

    var it = cells_obj.iterator();
    while (it.next()) |entry| {
        const cell_obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.InvalidStructure,
        };

        const cell_type_str = switch (cell_obj.get("type") orelse return error.InvalidStructure) {
            .string => |s| s,
            else => return error.InvalidStructure,
        };

        const conns = try parseCellConnections(cell_obj, alloc);
        errdefer {
            for (conns) |conn| {
                alloc.free(conn.pin);
                alloc.free(conn.bits);
            }
            alloc.free(conns);
        }

        const owned_name = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        errdefer alloc.free(owned_name);

        const owned_type = alloc.dupe(u8, cell_type_str) catch return error.OutOfMemory;
        errdefer alloc.free(owned_type);

        list.append(alloc, .{
            .name = owned_name,
            .cell_type = owned_type,
            .connections = conns,
        }) catch return error.OutOfMemory;
    }

    return list.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn parseCellConnections(cell_obj: std.json.ObjectMap, alloc: Allocator) ParseError![]const CellConn {
    const conns_val = cell_obj.get("connections") orelse return &.{};
    const conns_obj = switch (conns_val) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    var list = List(CellConn){};
    errdefer {
        for (list.items) |conn| {
            alloc.free(conn.pin);
            alloc.free(conn.bits);
        }
        list.deinit(alloc);
    }

    var it = conns_obj.iterator();
    while (it.next()) |entry| {
        const bits = try parseBitsArray(entry.value_ptr.*, alloc);
        errdefer alloc.free(bits);

        const owned_pin = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        errdefer alloc.free(owned_pin);

        list.append(alloc, .{
            .pin = owned_pin,
            .bits = bits,
        }) catch return error.OutOfMemory;
    }

    return list.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn parseNetNames(mod_obj: std.json.ObjectMap, alloc: Allocator) ParseError![]const NetName {
    const nn_val = mod_obj.get("netnames") orelse return &.{};
    const nn_obj = switch (nn_val) {
        .object => |o| o,
        else => return error.InvalidStructure,
    };

    var list = List(NetName){};
    errdefer {
        for (list.items) |nn| {
            alloc.free(nn.name);
            alloc.free(nn.bits);
        }
        list.deinit(alloc);
    }

    var it = nn_obj.iterator();
    while (it.next()) |entry| {
        const nn_entry = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.InvalidStructure,
        };

        const hide_val = nn_entry.get("hide_name") orelse return error.InvalidStructure;
        const hide_name = switch (hide_val) {
            .integer => |i| i != 0,
            .bool => |b| b,
            else => return error.InvalidStructure,
        };

        const bits = try parseBitsArray(nn_entry.get("bits") orelse return error.InvalidStructure, alloc);
        errdefer alloc.free(bits);

        const owned_name = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        errdefer alloc.free(owned_name);

        list.append(alloc, .{
            .name = owned_name,
            .bits = bits,
            .hide_name = hide_name,
        }) catch return error.OutOfMemory;
    }

    return list.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Parse a JSON array of bit values. Each element is either an integer (net ID)
/// or a string constant ("0", "1", "x", "z").
fn parseBitsArray(val: std.json.Value, alloc: Allocator) ParseError![]const u32 {
    const arr = switch (val) {
        .array => |a| a,
        else => return error.InvalidStructure,
    };

    const result = alloc.alloc(u32, arr.items.len) catch return error.OutOfMemory;
    errdefer alloc.free(result);

    for (arr.items, 0..) |item, i| {
        result[i] = switch (item) {
            .integer => |n| blk: {
                if (n < 0) return error.InvalidBitValue;
                break :blk @intCast(n);
            },
            .string => |s| blk: {
                if (s.len == 1) {
                    const ch = s[0];
                    if (ch == '0' or ch == '1' or ch == 'x' or ch == 'z') {
                        break :blk encodeConstBit(ch);
                    }
                }
                return error.InvalidBitValue;
            },
            else => return error.InvalidBitValue,
        };
    }

    return result;
}

// ── SPICE Emission ────────────────────────────────────────────────────────────

/// Emit a gate-level SPICE subcircuit from a parsed yosys module.
///
/// The output follows the form:
/// ```
/// .subckt <subckt_name> <port_nets...> <supply_pins...>
/// X<cell_name> <pin_nets...> <cell_type>
/// ...
/// .ends
/// ```
pub fn emitGateLevelSpice(
    w: anytype,
    module: *const YosysModule,
    subckt_name: []const u8,
    supply_pins: []const []const u8,
    alloc: Allocator,
) !void {
    // Build bit-to-net-name map from net_names.
    var bit_map = std.AutoHashMap(u32, []const u8).init(alloc);
    defer bit_map.deinit();

    for (module.net_names) |nn| {
        for (nn.bits, 0..) |bit, i| {
            if (isConstBit(bit)) continue;
            // For multi-bit nets, generate indexed names.
            if (nn.bits.len > 1) {
                const indexed = std.fmt.allocPrint(alloc, "{s}[{d}]", .{ cleanNetName(nn.name), i }) catch
                    return error.OutOfMemory;
                try bit_map.put(bit, indexed);
            } else {
                const name = alloc.dupe(u8, cleanNetName(nn.name)) catch
                    return error.OutOfMemory;
                try bit_map.put(bit, name);
            }
        }
    }
    defer {
        var map_it = bit_map.valueIterator();
        while (map_it.next()) |v| {
            alloc.free(v.*);
        }
    }

    // Write .subckt header.
    try w.print(".subckt {s}", .{subckt_name});
    for (module.ports) |port| {
        for (port.bits, 0..) |bit, i| {
            if (isConstBit(bit)) continue;
            if (bit_map.get(bit)) |name| {
                try w.print(" {s}", .{name});
            } else if (port.bits.len > 1) {
                try w.print(" {s}[{d}]", .{ cleanNetName(port.name), i });
            } else {
                try w.print(" {s}", .{cleanNetName(port.name)});
            }
        }
    }
    for (supply_pins) |sp| {
        try w.print(" {s}", .{sp});
    }
    try w.writeAll("\n");

    // Write cells as X-instances.
    for (module.cells) |cell| {
        try w.print("X{s}", .{cleanInstanceName(cell.name)});
        for (cell.connections) |conn| {
            for (conn.bits) |bit| {
                if (isConstBit(bit)) {
                    const ch = constBitChar(bit);
                    if (ch == '0') {
                        try w.writeAll(" VSS");
                    } else if (ch == '1') {
                        try w.writeAll(" VDD");
                    } else {
                        // 'x' or 'z' — map to a named net
                        try w.print(" net_{c}", .{ch});
                    }
                } else if (bit_map.get(bit)) |name| {
                    try w.print(" {s}", .{name});
                } else {
                    try w.print(" net_{d}", .{bit});
                }
            }
        }
        try w.print(" {s}\n", .{cell.cell_type});
    }

    // Write .ends.
    try w.writeAll(".ends\n");
}

/// Strip a leading backslash from yosys-escaped net names.
fn cleanNetName(name: []const u8) []const u8 {
    if (name.len > 0 and name[0] == '\\') {
        return name[1..];
    }
    return name;
}

/// Clean cell instance names: strip leading '$' or '\\' and replace special
/// characters that are invalid in SPICE identifiers.
fn cleanInstanceName(name: []const u8) []const u8 {
    var start: usize = 0;
    if (name.len > 0 and (name[0] == '$' or name[0] == '\\')) {
        start = 1;
    }
    return name[start..];
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parse simple yosys json" {
    const json =
        \\{
        \\  "modules": {
        \\    "inv": {
        \\      "ports": {
        \\        "A": { "direction": "input", "bits": [2] },
        \\        "Y": { "direction": "output", "bits": [3] }
        \\      },
        \\      "cells": {
        \\        "inv_0": {
        \\          "type": "sky130_fd_sc_hd__inv_2",
        \\          "port_directions": { "A": "input", "Y": "output" },
        \\          "connections": { "A": [2], "Y": [3] }
        \\        }
        \\      },
        \\      "netnames": {
        \\        "A": { "bits": [2], "hide_name": 0 },
        \\        "Y": { "bits": [3], "hide_name": 0 }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const module = try parse(json, null, std.testing.allocator);
    defer deinit(&module, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), module.ports.len);
    try std.testing.expectEqual(@as(usize, 1), module.cells.len);
    try std.testing.expectEqual(@as(usize, 2), module.net_names.len);

    try std.testing.expectEqualStrings("inv", module.name);

    // Check the cell.
    const cell = module.cells[0];
    try std.testing.expectEqualStrings("inv_0", cell.name);
    try std.testing.expectEqualStrings("sky130_fd_sc_hd__inv_2", cell.cell_type);
    try std.testing.expectEqual(@as(usize, 2), cell.connections.len);
}

test "parse with explicit top module" {
    const json =
        \\{
        \\  "modules": {
        \\    "mod_a": {
        \\      "ports": {},
        \\      "cells": {},
        \\      "netnames": {}
        \\    },
        \\    "mod_b": {
        \\      "ports": {
        \\        "X": { "direction": "inout", "bits": [5] }
        \\      },
        \\      "cells": {},
        \\      "netnames": {}
        \\    }
        \\  }
        \\}
    ;
    const module = try parse(json, "mod_b", std.testing.allocator);
    defer deinit(&module, std.testing.allocator);

    try std.testing.expectEqualStrings("mod_b", module.name);
    try std.testing.expectEqual(@as(usize, 1), module.ports.len);
    try std.testing.expectEqual(PortDir.inout, module.ports[0].direction);
}

test "parse constant bits" {
    const json =
        \\{
        \\  "modules": {
        \\    "top": {
        \\      "ports": {
        \\        "Y": { "direction": "output", "bits": [3] }
        \\      },
        \\      "cells": {
        \\        "tie_0": {
        \\          "type": "sky130_fd_sc_hd__conb_1",
        \\          "port_directions": { "LO": "output" },
        \\          "connections": { "LO": ["0"] }
        \\        }
        \\      },
        \\      "netnames": {
        \\        "Y": { "bits": [3], "hide_name": 0 }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const module = try parse(json, null, std.testing.allocator);
    defer deinit(&module, std.testing.allocator);

    const cell = module.cells[0];
    try std.testing.expectEqual(@as(usize, 1), cell.connections.len);

    const conn_bits = cell.connections[0].bits;
    try std.testing.expectEqual(@as(usize, 1), conn_bits.len);
    try std.testing.expect(isConstBit(conn_bits[0]));
    try std.testing.expectEqual(@as(u8, '0'), constBitChar(conn_bits[0]));
}

test "parse missing modules returns error" {
    const json =
        \\{ "creator": "yosys" }
    ;
    const result = parse(json, null, std.testing.allocator);
    try std.testing.expectError(error.MissingModules, result);
}

test "parse module not found returns error" {
    const json =
        \\{
        \\  "modules": {
        \\    "top": {
        \\      "ports": {},
        \\      "cells": {},
        \\      "netnames": {}
        \\    }
        \\  }
        \\}
    ;
    const result = parse(json, "nonexistent", std.testing.allocator);
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "emit gate-level spice" {
    const json =
        \\{
        \\  "modules": {
        \\    "inv": {
        \\      "ports": {
        \\        "A": { "direction": "input", "bits": [2] },
        \\        "Y": { "direction": "output", "bits": [3] }
        \\      },
        \\      "cells": {
        \\        "inv_0": {
        \\          "type": "sky130_fd_sc_hd__inv_2",
        \\          "port_directions": { "A": "input", "Y": "output" },
        \\          "connections": { "A": [2], "Y": [3] }
        \\        }
        \\      },
        \\      "netnames": {
        \\        "A": { "bits": [2], "hide_name": 0 },
        \\        "Y": { "bits": [3], "hide_name": 0 }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const module = try parse(json, null, std.testing.allocator);
    defer deinit(&module, std.testing.allocator);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const supply = [_][]const u8{ "VDD", "VSS" };
    try emitGateLevelSpice(buf.writer(), &module, "inv", &supply, std.testing.allocator);

    const output = buf.items;

    // Verify .subckt header.
    try std.testing.expect(std.mem.startsWith(u8, output, ".subckt inv "));
    try std.testing.expect(std.mem.indexOf(u8, output, "VDD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VSS") != null);

    // Verify cell instance line.
    try std.testing.expect(std.mem.indexOf(u8, output, "Xinv_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sky130_fd_sc_hd__inv_2") != null);

    // Verify .ends.
    try std.testing.expect(std.mem.endsWith(u8, output, ".ends\n"));
}

test "emit gate-level spice with constants" {
    const json =
        \\{
        \\  "modules": {
        \\    "tied": {
        \\      "ports": {
        \\        "Y": { "direction": "output", "bits": [3] }
        \\      },
        \\      "cells": {
        \\        "buf_0": {
        \\          "type": "sky130_fd_sc_hd__buf_1",
        \\          "port_directions": { "A": "input", "X": "output" },
        \\          "connections": { "A": ["1"], "X": [3] }
        \\        }
        \\      },
        \\      "netnames": {
        \\        "Y": { "bits": [3], "hide_name": 0 }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const module = try parse(json, null, std.testing.allocator);
    defer deinit(&module, std.testing.allocator);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const supply = [_][]const u8{ "VDD", "VSS" };
    try emitGateLevelSpice(buf.writer(), &module, "tied", &supply, std.testing.allocator);

    const output = buf.items;

    // Constant "1" should map to VDD.
    try std.testing.expect(std.mem.indexOf(u8, output, "VDD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Xbuf_0") != null);
}

test "emit gate-level spice multibit port" {
    const json =
        \\{
        \\  "modules": {
        \\    "counter": {
        \\      "ports": {
        \\        "CLK": { "direction": "input", "bits": [2] },
        \\        "COUNT": { "direction": "output", "bits": [5, 6] }
        \\      },
        \\      "cells": {
        \\        "dff_0": {
        \\          "type": "sky130_fd_sc_hd__dfxtp_1",
        \\          "port_directions": { "CLK": "input", "D": "input", "Q": "output" },
        \\          "connections": { "CLK": [2], "D": [10], "Q": [5] }
        \\        }
        \\      },
        \\      "netnames": {
        \\        "CLK": { "bits": [2], "hide_name": 0 },
        \\        "COUNT": { "bits": [5, 6], "hide_name": 0 }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const module = try parse(json, null, std.testing.allocator);
    defer deinit(&module, std.testing.allocator);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const supply = [_][]const u8{ "VDD", "VSS" };
    try emitGateLevelSpice(buf.writer(), &module, "counter", &supply, std.testing.allocator);

    const output = buf.items;

    // Multi-bit port should produce indexed names.
    try std.testing.expect(std.mem.indexOf(u8, output, "COUNT[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "COUNT[1]") != null);
}
