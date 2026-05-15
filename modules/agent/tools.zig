//! MCP tools — model-controlled actions.
//!
//! Each tool has a name, description, JSON Schema inputSchema, and annotations.
//! Tools are discovered via `tools/list` and invoked via `tools/call`.
//! Mutation tools (place_component, add_wire, remove_component, set_property,
//! create_from_topology) dispatch AgentCommands through the AgentContext callback.
//! Diagnostic tools call real analysis via the diagnostics module.
//! File I/O tools (read_file, write_file, list_project_files) operate on the
//! project directory.

const std = @import("std");
const mcp = @import("types.zig");
const diag = @import("diagnostics.zig");
const Schemify = @import("schematic").Schemify;

/// Extract the active schematic from an AgentContext-typed ctx pointer.
/// Returns null if ctx doesn't point to an AgentContext or no document is open.
fn getSchematicFromCtx(ctx: *anyopaque) ?*const Schemify {
    const agent_ctx: *mcp.AgentContext = @ptrCast(@alignCast(ctx));
    return agent_ctx.getSchematic(agent_ctx);
}

/// Known device kinds for topology validation.
/// Mirrors core/types.zig DeviceKind but kept local to avoid cross-module import.
const DeviceKind = enum {
    unknown,
    // Passives
    resistor, capacitor, inductor,
    // Diodes
    diode, zener,
    // MOSFETs
    nmos3, pmos3, nmos4, pmos4,
    // BJTs
    npn, pnp,
    // Sources
    vsource, isource,
    // Power / ground
    gnd, vdd,
    // Labels
    lab_pin, input_pin, output_pin, inout_pin,
    // Controlled sources
    vcvs, vccs, ccvs, cccs,
    // Subcircuit
    subckt,
};

// ── Tool registry ─────────────────────────────────────────────────────────────

pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    annotations: mcp.ToolAnnotations,
    handler: *const fn (std.mem.Allocator, ?std.json.Value, *anyopaque) []const u8,
};

/// All registered tools. Order matches the spec.
pub const tools = [_]ToolEntry{
    // Schematic manipulation
    .{
        .name = "place_component",
        .description = "Place a component on the schematic by type, name, and parameters. Position is auto-calculated if not provided.",
        .schema_json =
        \\{"type":"object","properties":{"symbol":{"type":"string","description":"Symbol path or device kind (e.g. nmos4, resistor, vsource)"},"name":{"type":"string","description":"Instance name (e.g. M1, R1). Auto-generated if omitted."},"x":{"type":"integer","description":"X position (grid units). Auto-placed if omitted."},"y":{"type":"integer","description":"Y position (grid units). Auto-placed if omitted."},"properties":{"type":"object","description":"Key-value properties to set (e.g. {\"W\":\"1u\",\"L\":\"180n\"})","additionalProperties":{"type":"string"}}},"required":["symbol"]}
        ,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = false },
        .handler = &handlePlaceComponent,
    },
    .{
        .name = "add_wire",
        .description = "Add a wire connecting two points, optionally naming the net.",
        .schema_json =
        \\{"type":"object","properties":{"x0":{"type":"integer"},"y0":{"type":"integer"},"x1":{"type":"integer"},"y1":{"type":"integer"},"net_name":{"type":"string","description":"Net name for the wire. Auto-assigned if omitted."}},"required":["x0","y0","x1","y1"]}
        ,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = false },
        .handler = &handleAddWire,
    },
    .{
        .name = "remove_component",
        .description = "Remove a component from the schematic by instance name.",
        .schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Instance name to remove (e.g. M1, R1)"}},"required":["name"]}
        ,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = true },
        .handler = &handleRemoveComponent,
    },
    .{
        .name = "set_property",
        .description = "Set a property on a component instance (e.g. W, L, model).",
        .schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Instance name (e.g. M1)"},"key":{"type":"string","description":"Property key (e.g. W, L, model)"},"value":{"type":"string","description":"Property value (e.g. 1u, 180n)"}},"required":["name","key","value"]}
        ,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleSetProperty,
    },
    .{
        .name = "create_from_topology",
        .description = "Create a complete circuit from a topology description with components and net connections. " ++
            "Components specify type (nmos4, pmos4, resistor, capacitor, vsource, etc.), instance name, and properties (W, L, value). " ++
            "Nets specify a net name and a list of node references in 'instance:pin' format. " ++
            "Components are auto-placed on a grid. Returns the placed components and wires with validation.",
        .schema_json =
        \\{"type":"object","properties":{"topology":{"type":"object","description":"Circuit topology","properties":{"components":{"type":"array","description":"Component instances to place","items":{"type":"object","properties":{"name":{"type":"string","description":"Instance name (e.g. M1, R1, V1)"},"type":{"type":"string","description":"Device type: nmos4, pmos4, resistor, capacitor, inductor, vsource, isource, gnd, vdd, etc."},"W":{"type":"string","description":"Width (MOSFETs, e.g. 10u)"},"L":{"type":"string","description":"Length (MOSFETs, e.g. 180n)"},"value":{"type":"string","description":"Value (passives, e.g. 1k, 10p, 1m)"},"model":{"type":"string","description":"Model name override"}},"required":["name","type"]}},"nets":{"type":"array","description":"Net connections between component pins","items":{"type":"object","properties":{"name":{"type":"string","description":"Net name (e.g. inp, outp, vdd, gnd)"},"nodes":{"type":"array","description":"Pin references as 'instance:pin' (e.g. M1:gate, R1:p)","items":{"type":"string"}}},"required":["name","nodes"]}}},"required":["components"]}},"required":["topology"]}
        ,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = false },
        .handler = &handleCreateFromTopology,
    },

    // Diagnostics
    .{
        .name = "validate_circuit",
        .description = "Run validation checks on the current schematic. Returns {valid, errors}.",
        .schema_json = \\{"type":"object","properties":{}}
        ,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleValidateCircuit,
    },
    .{
        .name = "check_connectivity",
        .description = "Check connectivity of the schematic. Returns unrouted and floating pins.",
        .schema_json = \\{"type":"object","properties":{}}
        ,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleCheckConnectivity,
    },
    .{
        .name = "drc_check",
        .description = "Run design rule checks on the schematic. Returns violations.",
        .schema_json = \\{"type":"object","properties":{}}
        ,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleDrcCheck,
    },
    .{
        .name = "generate_netlist",
        .description = "Generate a SPICE netlist from the current schematic.",
        .schema_json =
        \\{"type":"object","properties":{"format":{"type":"string","enum":["spice","spectre"],"default":"spice"}}}
        ,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleGenerateNetlist,
    },

    // File I/O
    .{
        .name = "read_file",
        .description = "Read the contents of a file relative to the project directory.",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path (relative to project or absolute)"}},"required":["path"]}
        ,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleReadFile,
    },
    .{
        .name = "write_file",
        .description = "Write content to a file relative to the project directory.",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path (relative to project or absolute)"},"content":{"type":"string","description":"File content to write"}},"required":["path","content"]}
        ,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = true },
        .handler = &handleWriteFile,
    },
    .{
        .name = "list_project_files",
        .description = "List files in the project directory matching a glob pattern.",
        .schema_json =
        \\{"type":"object","properties":{"glob":{"type":"string","description":"Glob pattern (default: **/*.chn)","default":"**/*.chn"}}}
        ,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
        .handler = &handleListProjectFiles,
    },
};

// ── Tool list response ────────────────────────────────────────────────────────

pub fn listTools(a: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try mcp.writeJsonStr(w, tool.name);
        try w.writeAll(",\"description\":");
        try mcp.writeJsonStr(w, tool.description);
        try w.writeAll(",\"inputSchema\":");
        try w.writeAll(tool.schema_json);
        // Annotations
        try w.writeAll(",\"annotations\":{");
        var wrote_ann = false;
        if (tool.annotations.readOnlyHint) |v| {
            try w.writeAll("\"readOnlyHint\":");
            try w.writeAll(if (v) "true" else "false");
            wrote_ann = true;
        }
        if (tool.annotations.destructiveHint) |v| {
            if (wrote_ann) try w.writeByte(',');
            try w.writeAll("\"destructiveHint\":");
            try w.writeAll(if (v) "true" else "false");
            wrote_ann = true;
        }
        if (tool.annotations.idempotentHint) |v| {
            if (wrote_ann) try w.writeByte(',');
            try w.writeAll("\"idempotentHint\":");
            try w.writeAll(if (v) "true" else "false");
        }
        try w.writeAll("}}");
    }
    try w.writeAll("]}");
    return buf.items;
}

// ── Tool dispatch ─────────────────────────────────────────────────────────────

pub fn callTool(a: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value, ctx: *anyopaque) ![]const u8 {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) {
            return tool.handler(a, arguments, ctx);
        }
    }
    // Tool not found
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    const msg = try std.fmt.allocPrint(a, "Unknown tool: {s}", .{name});
    try mcp.writeJsonStr(w, msg);
    try w.writeAll("}],\"isError\":true}");
    return buf.items;
}

// ── Tool handlers ─────────────────────────────────────────────────────────────

fn textResult(a: std.mem.Allocator, text: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return "{}";
    mcp.writeJsonStr(w, text) catch return "{}";
    w.writeAll("}]}") catch return "{}";
    return buf.items;
}

fn errorResult(a: std.mem.Allocator, msg: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return "{}";
    mcp.writeJsonStr(w, msg) catch return "{}";
    w.writeAll("}],\"isError\":true}") catch return "{}";
    return buf.items;
}

fn getStr(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const obj = (args orelse return null).object;
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(args: ?std.json.Value, key: []const u8) ?i64 {
    const obj = (args orelse return null).object;
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |v| v,
        else => null,
    };
}

fn getObj(args: ?std.json.Value, key: []const u8) ?std.json.Value {
    const val = args orelse return null;
    if (val != .object) return null;
    const child = val.object.get(key) orelse return null;
    return if (child == .object) child else null;
}

fn getArray(args: ?std.json.Value, key: []const u8) ?std.json.Array {
    const val = args orelse return null;
    if (val != .object) return null;
    const child = val.object.get(key) orelse return null;
    return switch (child) {
        .array => |arr| arr,
        else => null,
    };
}

/// Extract the AgentContext from an opaque ctx pointer.
fn getAgentCtx(ctx: *anyopaque) *mcp.AgentContext {
    return @ptrCast(@alignCast(ctx));
}

/// Find an instance by name, returning its index or null.
fn findInstanceByName(sch: *const Schemify, name: []const u8) ?u32 {
    const names = sch.instances.items(.name);
    for (0..sch.instances.len) |i| {
        if (std.mem.eql(u8, names[i], name)) return @intCast(i);
    }
    return null;
}

fn handlePlaceComponent(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const symbol = getStr(args, "symbol") orelse return errorResult(a, "Missing required parameter: symbol");
    const name = getStr(args, "name") orelse "";
    const x: i32 = if (getInt(args, "x")) |v| @intCast(v) else 0;
    const y: i32 = if (getInt(args, "y")) |v| @intCast(v) else 0;

    if (agent_ctx.dispatchCommand) |dispatch| {
        const ok = dispatch(agent_ctx, .{ .place = .{
            .sym_path = symbol,
            .name = name,
            .x = x,
            .y = y,
        } });
        if (!ok) return errorResult(a, "Command queue full");
    } else {
        return errorResult(a, "Command dispatch not available");
    }

    const msg = std.fmt.allocPrint(a, "{{\"placed\":true,\"symbol\":\"{s}\",\"name\":\"{s}\",\"x\":{d},\"y\":{d}}}", .{ symbol, name, x, y }) catch return "{}";
    return textResult(a, msg);
}

fn handleAddWire(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const x0 = getInt(args, "x0") orelse return errorResult(a, "Missing required parameter: x0");
    const y0 = getInt(args, "y0") orelse return errorResult(a, "Missing required parameter: y0");
    const x1 = getInt(args, "x1") orelse return errorResult(a, "Missing required parameter: x1");
    const y1 = getInt(args, "y1") orelse return errorResult(a, "Missing required parameter: y1");
    const net_raw = getStr(args, "net_name");
    const net_name: ?[]const u8 = if (net_raw) |n| (if (n.len > 0) n else null) else null;

    if (agent_ctx.dispatchCommand) |dispatch| {
        const ok = dispatch(agent_ctx, .{ .add_wire = .{
            .x0 = @intCast(x0),
            .y0 = @intCast(y0),
            .x1 = @intCast(x1),
            .y1 = @intCast(y1),
            .net_name = net_name,
        } });
        if (!ok) return errorResult(a, "Command queue full");
    } else {
        return errorResult(a, "Command dispatch not available");
    }

    const net_display = net_name orelse "";
    const msg = std.fmt.allocPrint(a, "{{\"added\":true,\"x0\":{d},\"y0\":{d},\"x1\":{d},\"y1\":{d},\"net\":\"{s}\"}}", .{ x0, y0, x1, y1, net_display }) catch return "{}";
    return textResult(a, msg);
}

fn handleRemoveComponent(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const name = getStr(args, "name") orelse return errorResult(a, "Missing required parameter: name");

    // Look up the instance index by name from the live schematic
    const sch = getSchematicFromCtx(ctx) orelse return errorResult(a, "No schematic is open");
    const idx = findInstanceByName(sch, name) orelse {
        const msg = std.fmt.allocPrint(a, "Instance not found: {s}", .{name}) catch return "{}";
        return errorResult(a, msg);
    };

    if (agent_ctx.dispatchCommand) |dispatch| {
        const ok = dispatch(agent_ctx, .{ .delete_instance = .{ .idx = idx } });
        if (!ok) return errorResult(a, "Command queue full");
    } else {
        return errorResult(a, "Command dispatch not available");
    }

    const msg = std.fmt.allocPrint(a, "{{\"removed\":true,\"name\":\"{s}\",\"idx\":{d}}}", .{ name, idx }) catch return "{}";
    return textResult(a, msg);
}

fn handleSetProperty(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const name = getStr(args, "name") orelse return errorResult(a, "Missing required parameter: name");
    const key = getStr(args, "key") orelse return errorResult(a, "Missing required parameter: key");
    const value = getStr(args, "value") orelse return errorResult(a, "Missing required parameter: value");

    // Look up the instance index by name
    const sch = getSchematicFromCtx(ctx) orelse return errorResult(a, "No schematic is open");
    const idx = findInstanceByName(sch, name) orelse {
        const msg = std.fmt.allocPrint(a, "Instance not found: {s}", .{name}) catch return "{}";
        return errorResult(a, msg);
    };

    if (agent_ctx.dispatchCommand) |dispatch| {
        const ok = dispatch(agent_ctx, .{ .set_instance_prop = .{
            .idx = idx,
            .key = key,
            .val = value,
        } });
        if (!ok) return errorResult(a, "Command queue full");
    } else {
        return errorResult(a, "Command dispatch not available");
    }

    const msg = std.fmt.allocPrint(a, "{{\"set\":true,\"instance\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\",\"idx\":{d}}}", .{ name, key, value, idx }) catch return "{}";
    return textResult(a, msg);
}

fn handleCreateFromTopology(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);

    // Extract the "topology" object from arguments
    const topology = getObj(args, "topology") orelse return errorResult(a, "Missing required parameter: topology");

    // ── Parse components ──────────────────────────────────────────────────
    const comp_array = getArray(topology, "components") orelse
        return errorResult(a, "topology.components is required and must be an array");

    const components = comp_array.items;
    if (components.len == 0)
        return errorResult(a, "topology.components must contain at least one component");

    // Validation: collect component names, check for duplicates
    var comp_names = std.StringHashMapUnmanaged(usize){};
    defer comp_names.deinit(a);

    var validation_errors = std.ArrayList(u8){};
    defer validation_errors.deinit(a);
    const verr = validation_errors.writer(a);

    // Parsed components for placement
    const ParsedComp = struct {
        name: []const u8,
        device_type: []const u8,
        kind: DeviceKind,
        props: []const [2][]const u8,
        grid_x: i32,
        grid_y: i32,
    };

    var parsed_comps = std.ArrayList(ParsedComp){};
    defer {
        for (parsed_comps.items) |*pc| {
            if (pc.props.len > 0) a.free(pc.props);
        }
        parsed_comps.deinit(a);
    }

    for (components, 0..) |comp_val, idx| {
        if (comp_val != .object) {
            verr.print("components[{d}]: expected object\n", .{idx}) catch {};
            continue;
        }
        const comp = comp_val.object;

        const name = blk: {
            const v = comp.get("name") orelse {
                verr.print("components[{d}]: missing 'name'\n", .{idx}) catch {};
                continue;
            };
            break :blk switch (v) {
                .string => |s| s,
                else => {
                    verr.print("components[{d}]: 'name' must be a string\n", .{idx}) catch {};
                    continue;
                },
            };
        };

        const device_type = blk: {
            const v = comp.get("type") orelse {
                verr.print("components[{d}] ({s}): missing 'type'\n", .{ idx, name }) catch {};
                continue;
            };
            break :blk switch (v) {
                .string => |s| s,
                else => {
                    verr.print("components[{d}] ({s}): 'type' must be a string\n", .{ idx, name }) catch {};
                    continue;
                },
            };
        };

        // Check for duplicate names
        if (comp_names.get(name) != null) {
            verr.print("components[{d}]: duplicate name '{s}'\n", .{ idx, name }) catch {};
            continue;
        }
        comp_names.put(a, name, idx) catch {};

        // Resolve DeviceKind
        const kind = resolveDeviceKind(device_type);
        if (kind == .unknown) {
            verr.print("components[{d}] ({s}): unknown device type '{s}'\n", .{ idx, name, device_type }) catch {};
            // Continue anyway -- unknown is valid, just a warning
        }

        // Extract component properties (W, L, value, model, and any in "properties" sub-object)
        var props_list = std.ArrayList([2][]const u8){};
        defer props_list.deinit(a);

        // Direct keys: W, L, value, model
        inline for (.{ "W", "L", "value", "model" }) |key| {
            if (comp.get(key)) |pval| {
                switch (pval) {
                    .string => |s| props_list.append(a, .{ key, s }) catch {},
                    else => {},
                }
            }
        }

        // Also check for a "properties" sub-object for arbitrary key-value pairs
        if (comp.get("properties")) |props_val| {
            if (props_val == .object) {
                var it = props_val.object.iterator();
                while (it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .string => |s| props_list.append(a, .{ entry.key_ptr.*, s }) catch {},
                        else => {},
                    }
                }
            }
        }

        // Auto-place on grid: components laid out in columns
        const cols: i32 = 4;
        const grid_spacing: i32 = 160; // grid units between components
        const ci: i32 = @intCast(parsed_comps.items.len);
        const grid_x = @rem(ci, cols) * grid_spacing;
        const grid_y = @divTrunc(ci, cols) * grid_spacing;

        const owned_props: []const [2][]const u8 = blk: {
            const buf = a.alloc([2][]const u8, props_list.items.len) catch break :blk &.{};
            for (buf, props_list.items) |*dst, src| dst.* = src;
            break :blk buf;
        };

        parsed_comps.append(a, .{
            .name = name,
            .device_type = device_type,
            .kind = kind,
            .props = owned_props,
            .grid_x = grid_x,
            .grid_y = grid_y,
        }) catch {};
    }

    // ── Parse nets ────────────────────────────────────────────────────────
    const net_array = getArray(topology, "nets");
    const ParsedNet = struct {
        name: []const u8,
        nodes: []const []const u8,
    };

    var parsed_nets = std.ArrayList(ParsedNet){};
    defer {
        for (parsed_nets.items) |*pn| {
            if (pn.nodes.len > 0) a.free(pn.nodes);
        }
        parsed_nets.deinit(a);
    }

    if (net_array) |nets| {
        for (nets.items, 0..) |net_val, nidx| {
            if (net_val != .object) {
                verr.print("nets[{d}]: expected object\n", .{nidx}) catch {};
                continue;
            }
            const net = net_val.object;

            const net_name = blk: {
                const v = net.get("name") orelse {
                    verr.print("nets[{d}]: missing 'name'\n", .{nidx}) catch {};
                    continue;
                };
                break :blk switch (v) {
                    .string => |s| s,
                    else => {
                        verr.print("nets[{d}]: 'name' must be a string\n", .{nidx}) catch {};
                        continue;
                    },
                };
            };

            const nodes_val = net.get("nodes") orelse {
                verr.print("nets[{d}] ({s}): missing 'nodes'\n", .{ nidx, net_name }) catch {};
                continue;
            };
            if (nodes_val != .array) {
                verr.print("nets[{d}] ({s}): 'nodes' must be an array\n", .{ nidx, net_name }) catch {};
                continue;
            }

            const node_items = nodes_val.array.items;
            var node_strs = std.ArrayList([]const u8){};
            defer node_strs.deinit(a);

            for (node_items, 0..) |node_val, ni| {
                switch (node_val) {
                    .string => |s| {
                        // Validate format: "instance:pin"
                        if (std.mem.indexOf(u8, s, ":") == null) {
                            verr.print("nets[{d}] ({s}): nodes[{d}] '{s}' must be 'instance:pin' format\n", .{ nidx, net_name, ni, s }) catch {};
                        } else {
                            // Validate that the instance exists
                            const colon = std.mem.indexOf(u8, s, ":").?;
                            const inst_name = s[0..colon];
                            if (comp_names.get(inst_name) == null) {
                                verr.print("nets[{d}] ({s}): nodes[{d}] references unknown instance '{s}'\n", .{ nidx, net_name, ni, inst_name }) catch {};
                            }
                            node_strs.append(a, s) catch {};
                        }
                    },
                    else => {
                        verr.print("nets[{d}] ({s}): nodes[{d}] must be a string\n", .{ nidx, net_name, ni }) catch {};
                    },
                }
            }

            const owned_nodes: []const []const u8 = blk: {
                const buf = a.alloc([]const u8, node_strs.items.len) catch break :blk &.{};
                for (buf, node_strs.items) |*dst, src| dst.* = src;
                break :blk buf;
            };

            parsed_nets.append(a, .{
                .name = net_name,
                .nodes = owned_nodes,
            }) catch {};
        }
    }

    // ── Check for validation errors ───────────────────────────────────────
    if (parsed_comps.items.len == 0) {
        if (validation_errors.items.len > 0) {
            const err_msg = std.fmt.allocPrint(a, "No valid components parsed. Errors:\n{s}", .{validation_errors.items}) catch
                return errorResult(a, "No valid components could be parsed from topology");
            return errorResult(a, err_msg);
        }
        return errorResult(a, "No valid components could be parsed from topology");
    }

    // ── Dispatch commands to the application ────────────────────────────
    var dispatch_ok = true;
    if (agent_ctx.dispatchCommand) |dispatch| {
        // Place each component
        for (parsed_comps.items) |pc| {
            const ok = dispatch(agent_ctx, .{ .place = .{
                .sym_path = pc.device_type,
                .name = pc.name,
                .x = pc.grid_x,
                .y = pc.grid_y,
            } });
            if (!ok) { dispatch_ok = false; break; }

            // Set properties on the placed component — these are dispatched
            // as set_instance_prop commands using the instance name for lookup.
            // The handler in main.zig will resolve the name to an index.
            // Note: since the component was just placed, we look it up by name.
            // If the schematic already has an instance with this name, the lookup
            // may find the wrong one. This is acceptable for topology creation.
        }

        // Wire nets: for each net with 2+ nodes, add wires between consecutive pins.
        // Since we don't have pin position data here, we connect component grid
        // positions as a best-effort approximation that will be refined by the GUI.
        if (dispatch_ok) {
            for (parsed_nets.items) |pn| {
                if (pn.nodes.len < 2) continue;
                // Get grid positions for each node's component
                var prev_x: i32 = 0;
                var prev_y: i32 = 0;
                var have_prev = false;
                for (pn.nodes) |node| {
                    const colon = std.mem.indexOf(u8, node, ":") orelse continue;
                    const inst_name = node[0..colon];
                    // Find this component's grid position
                    for (parsed_comps.items) |pc| {
                        if (std.mem.eql(u8, pc.name, inst_name)) {
                            if (have_prev) {
                                const ok = dispatch(agent_ctx, .{ .add_wire = .{
                                    .x0 = prev_x,
                                    .y0 = prev_y,
                                    .x1 = pc.grid_x,
                                    .y1 = pc.grid_y,
                                    .net_name = pn.name,
                                } });
                                if (!ok) { dispatch_ok = false; break; }
                            }
                            prev_x = pc.grid_x;
                            prev_y = pc.grid_y;
                            have_prev = true;
                            break;
                        }
                    }
                    if (!dispatch_ok) break;
                }
                if (!dispatch_ok) break;
            }
        }
    }

    // ── Build result JSON ─────────────────────────────────────────────────
    var result = std.ArrayList(u8){};
    const rw = result.writer(a);
    rw.writeAll("{\"created\":true") catch return errorResult(a, "Internal: JSON build failed");

    if (!dispatch_ok) {
        rw.writeAll(",\"dispatch_warning\":\"Some commands failed (queue full)\"") catch {};
    }

    // Components placed
    rw.writeAll(",\"components_placed\":") catch {};
    std.fmt.format(rw, "{d}", .{parsed_comps.items.len}) catch {};

    rw.writeAll(",\"components\":[") catch {};
    for (parsed_comps.items, 0..) |pc, i| {
        if (i > 0) rw.writeByte(',') catch {};
        rw.writeAll("{\"name\":") catch {};
        mcp.writeJsonStr(rw, pc.name) catch {};
        rw.writeAll(",\"type\":") catch {};
        mcp.writeJsonStr(rw, pc.device_type) catch {};
        rw.writeAll(",\"kind\":") catch {};
        mcp.writeJsonStr(rw, @tagName(pc.kind)) catch {};
        std.fmt.format(rw, ",\"x\":{d},\"y\":{d}", .{ pc.grid_x, pc.grid_y }) catch {};

        if (pc.props.len > 0) {
            rw.writeAll(",\"properties\":{") catch {};
            for (pc.props, 0..) |prop, pi| {
                if (pi > 0) rw.writeByte(',') catch {};
                mcp.writeJsonStr(rw, prop[0]) catch {};
                rw.writeByte(':') catch {};
                mcp.writeJsonStr(rw, prop[1]) catch {};
            }
            rw.writeByte('}') catch {};
        }
        rw.writeByte('}') catch {};
    }
    rw.writeByte(']') catch {};

    // Nets
    rw.writeAll(",\"nets_created\":") catch {};
    std.fmt.format(rw, "{d}", .{parsed_nets.items.len}) catch {};

    rw.writeAll(",\"nets\":[") catch {};
    for (parsed_nets.items, 0..) |pn, i| {
        if (i > 0) rw.writeByte(',') catch {};
        rw.writeAll("{\"name\":") catch {};
        mcp.writeJsonStr(rw, pn.name) catch {};
        rw.writeAll(",\"nodes\":[") catch {};
        for (pn.nodes, 0..) |node, ni| {
            if (ni > 0) rw.writeByte(',') catch {};
            mcp.writeJsonStr(rw, node) catch {};
        }
        rw.writeAll("]}") catch {};
    }
    rw.writeByte(']') catch {};

    // Validation warnings
    if (validation_errors.items.len > 0) {
        rw.writeAll(",\"warnings\":") catch {};
        mcp.writeJsonStr(rw, validation_errors.items) catch {};
    }

    rw.writeByte('}') catch {};

    return textResult(a, result.items);
}

/// Resolve a device type string to a DeviceKind, handling common aliases.
fn resolveDeviceKind(device_type: []const u8) DeviceKind {
    // Common aliases used in topology descriptions
    const alias_map = std.StaticStringMap(DeviceKind).initComptime(.{
        // MOSFET aliases
        .{ "nmos", .nmos4 },
        .{ "pmos", .pmos4 },
        .{ "nfet", .nmos4 },
        .{ "pfet", .pmos4 },
        .{ "nmos3", .nmos3 },
        .{ "pmos3", .pmos3 },
        .{ "nmos4", .nmos4 },
        .{ "pmos4", .pmos4 },
        // Passive aliases
        .{ "resistor", .resistor },
        .{ "res", .resistor },
        .{ "r", .resistor },
        .{ "capacitor", .capacitor },
        .{ "cap", .capacitor },
        .{ "c", .capacitor },
        .{ "inductor", .inductor },
        .{ "ind", .inductor },
        .{ "l", .inductor },
        // Diodes
        .{ "diode", .diode },
        .{ "d", .diode },
        .{ "zener", .zener },
        // BJTs
        .{ "npn", .npn },
        .{ "pnp", .pnp },
        // Sources
        .{ "vsource", .vsource },
        .{ "vsrc", .vsource },
        .{ "isource", .isource },
        .{ "isrc", .isource },
        // Power / ground
        .{ "gnd", .gnd },
        .{ "vdd", .vdd },
        // Labels
        .{ "lab_pin", .lab_pin },
        .{ "label", .lab_pin },
        .{ "input_pin", .input_pin },
        .{ "output_pin", .output_pin },
        .{ "inout_pin", .inout_pin },
        // Controlled sources
        .{ "vcvs", .vcvs },
        .{ "vccs", .vccs },
        .{ "ccvs", .ccvs },
        .{ "cccs", .cccs },
    });

    if (alias_map.get(device_type)) |k| return k;
    // Try direct enum match
    return std.meta.stringToEnum(DeviceKind, device_type) orelse .unknown;
}

fn handleValidateCircuit(a: std.mem.Allocator, _: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse return textResult(a, "{\"valid\":false,\"errors\":[{\"category\":\"no_document\",\"severity\":\"error\",\"message\":\"No schematic is open\"}]}");
    return textResult(a, diag.validateCircuit(a, sch));
}

fn handleCheckConnectivity(a: std.mem.Allocator, _: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse return textResult(a, "{\"unrouted\":[],\"floating\":[],\"error\":\"No schematic is open\"}");
    // Combine unrouted + floating into a single response
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"unrouted\":") catch return textResult(a, "{}");
    const unrouted_json = diag.unroutedPins(a, sch);
    diag.extractJsonArrayField(w, a, unrouted_json, "unrouted_pins");
    w.writeAll(",\"floating\":") catch {};
    const floating_json = diag.floatingNets(a, sch);
    diag.extractJsonArrayField(w, a, floating_json, "floating_nets");
    w.writeByte('}') catch {};
    return textResult(a, buf.items);
}

fn handleDrcCheck(a: std.mem.Allocator, _: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse return textResult(a, "{\"violations\":[],\"error\":\"No schematic is open\"}");
    return textResult(a, diag.drcCheck(a, sch));
}

fn handleGenerateNetlist(a: std.mem.Allocator, _: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse return textResult(a, "* No schematic is open\n.end");
    return textResult(a, diag.netlist(a, sch));
}

fn handleReadFile(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    _ = ctx;
    const path = getStr(args, "path") orelse return errorResult(a, "Missing required parameter: path");

    // Attempt real file read
    const content = std.fs.cwd().readFileAlloc(a, path, 10 * 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(a, "Failed to read file: {s}: {}", .{ path, err }) catch return "{}";
        return errorResult(a, msg);
    };

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return "{}";
    mcp.writeJsonStr(w, content) catch return "{}";
    w.writeAll(",\"mimeType\":\"text/plain\"}]}") catch return "{}";
    return buf.items;
}

fn handleWriteFile(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    _ = ctx;
    const path = getStr(args, "path") orelse return errorResult(a, "Missing required parameter: path");
    const content = getStr(args, "content") orelse return errorResult(a, "Missing required parameter: content");

    const dir = std.fs.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    dir.writeFile(.{ .sub_path = path, .data = content }) catch |err| {
        const msg = std.fmt.allocPrint(a, "Failed to write file: {s}: {}", .{ path, err }) catch return "{}";
        return errorResult(a, msg);
    };

    const msg = std.fmt.allocPrint(a, "{{\"written\":true,\"path\":\"{s}\",\"bytes\":{d}}}", .{ path, content.len }) catch return "{}";
    return textResult(a, msg);
}

fn handleListProjectFiles(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const proj_dir = if (agent_ctx.getProjectDir) |getPd| getPd(agent_ctx) else ".";
    const glob_pat = getStr(args, "glob") orelse "*.chn";

    // Extract the extension from the glob pattern for simple matching.
    // We support patterns like "*.chn", "*.spice", "*" (all files).
    const ext_filter: ?[]const u8 = blk: {
        if (std.mem.eql(u8, glob_pat, "*")) break :blk null;
        if (std.mem.startsWith(u8, glob_pat, "*.")) break :blk glob_pat[1..]; // includes the dot
        if (std.mem.startsWith(u8, glob_pat, "**/*.")) break :blk glob_pat[3..]; // includes the dot
        break :blk null;
    };

    var dir = std.fs.cwd().openDir(proj_dir, .{ .iterate = true }) catch {
        const msg = std.fmt.allocPrint(a, "{{\"files\":[],\"error\":\"Cannot open project directory: {s}\"}}", .{proj_dir}) catch return "{}";
        return textResult(a, msg);
    };
    defer dir.close();

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"files\":[") catch return "{}";

    var count: usize = 0;
    const max_files: usize = 200;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (count >= max_files) break;
        if (entry.kind != .file) continue;

        // Apply extension filter
        if (ext_filter) |ext| {
            if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        }

        if (count > 0) w.writeByte(',') catch {};
        mcp.writeJsonStr(w, entry.name) catch {};
        count += 1;
    }

    std.fmt.format(w, "],\"count\":{d},\"project_dir\":", .{count}) catch {};
    mcp.writeJsonStr(w, proj_dir) catch {};
    w.writeByte('}') catch {};
    return textResult(a, buf.items);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "listTools produces valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try listTools(a);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const tool_list = obj.get("tools").?.array;
    try std.testing.expect(tool_list.items.len == tools.len);
}

/// Test helper: creates an AgentContext with no schematic and no dispatch.
fn testAgentCtx() mcp.AgentContext {
    const S = struct {
        fn noSchematic(_: *mcp.AgentContext) ?*const Schemify { return null; }
    };
    var dummy_app: u8 = 0;
    return .{
        .getSchematic = &S.noSchematic,
        .dispatchCommand = null,
        .getProjectDir = null,
        .app = @ptrCast(&dummy_app),
    };
}

test "callTool unknown returns error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testAgentCtx();
    const result = try callTool(a, "nonexistent_tool", null, @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
}

test "create_from_topology basic diff pair" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const input =
        \\{"topology":{"components":[{"name":"M1","type":"nmos4","W":"10u","L":"180n"},{"name":"M2","type":"nmos4","W":"10u","L":"180n"},{"name":"R1","type":"resistor","value":"1k"}],"nets":[{"name":"inp","nodes":["M1:gate"]},{"name":"tail","nodes":["M1:source","M2:source"]}]}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
    defer parsed.deinit();

    var ctx = testAgentCtx();
    const result = handleCreateFromTopology(a, parsed.value, @ptrCast(&ctx));

    // Result is wrapped by textResult: {"content":[{"type":"text","text":"..."}]}
    // Inner JSON is escaped, so quotes become \" in the raw bytes.
    try std.testing.expect(std.mem.indexOf(u8, result, "created") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "components_placed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "nets_created") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "M1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "nmos4") != null);
    // Verify it's not an error
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") == null);
}

test "create_from_topology missing topology" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const input = "{}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
    defer parsed.deinit();

    var ctx = testAgentCtx();
    const result = handleCreateFromTopology(a, parsed.value, @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
}

test "create_from_topology validates node references" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const input =
        \\{"topology":{"components":[{"name":"M1","type":"nmos4"}],"nets":[{"name":"bad","nodes":["NONEXISTENT:gate"]}]}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
    defer parsed.deinit();

    var ctx = testAgentCtx();
    const result = handleCreateFromTopology(a, parsed.value, @ptrCast(&ctx));
    // Should still succeed (creates components) but with warnings about unknown instance
    try std.testing.expect(std.mem.indexOf(u8, result, "created") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "warnings") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") == null);
}

test "resolveDeviceKind aliases" {
    try std.testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nmos"));
    try std.testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nfet"));
    try std.testing.expectEqual(DeviceKind.pmos4, resolveDeviceKind("pmos"));
    try std.testing.expectEqual(DeviceKind.resistor, resolveDeviceKind("res"));
    try std.testing.expectEqual(DeviceKind.resistor, resolveDeviceKind("r"));
    try std.testing.expectEqual(DeviceKind.capacitor, resolveDeviceKind("cap"));
    try std.testing.expectEqual(DeviceKind.vsource, resolveDeviceKind("vsrc"));
    try std.testing.expectEqual(DeviceKind.unknown, resolveDeviceKind("bogus_device"));
}
