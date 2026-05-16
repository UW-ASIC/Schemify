//! MCP resources — application-controlled data.
//!
//! Resources expose schematic state as readable URIs. They are discovered
//! via `resources/list` and read via `resources/read`.
//! Static resources have fixed URIs; templates use `{name}` placeholders.
//! Handlers read live schematic data from the AgentContext's Schemify pointer.
//! Selection data requires GUI state and returns a note instead.

const std = @import("std");
const mcp = @import("types.zig");
const Schemify = @import("schematic").Schemify;

// ── Resource definitions ──────────────────────────────────────────────────────

const StaticResource = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,
    handler: *const fn (std.mem.Allocator, *anyopaque) []const u8,
};

const TemplateResource = struct {
    uri_template: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,
    prefix: []const u8,
    handler: *const fn (std.mem.Allocator, []const u8, *anyopaque) []const u8,
};

const static_resources = [_]StaticResource{
    .{
        .uri = "schemify://instances",
        .name = "Component Instances",
        .description = "All component instances in the active schematic",
        .mime_type = "application/json",
        .handler = &handleInstances,
    },
    .{
        .uri = "schemify://wires",
        .name = "Wires",
        .description = "All wire segments in the active schematic",
        .mime_type = "application/json",
        .handler = &handleWires,
    },
    .{
        .uri = "schemify://selection",
        .name = "Current Selection",
        .description = "Currently selected instances and wires",
        .mime_type = "application/json",
        .handler = &handleSelection,
    },
    .{
        .uri = "schemify://info",
        .name = "Schematic Info",
        .description = "Current file, counts, and project state summary",
        .mime_type = "application/json",
        .handler = &handleInfo,
    },
    .{
        .uri = "schemify://skills/core",
        .name = "Core Skills",
        .description = "Schemify core SKILL documentation for LLM context",
        .mime_type = "text/markdown",
        .handler = &handleSkillsCore,
    },
    .{
        .uri = "schemify://pyspice",
        .name = "PySpice Source",
        .description = "PySpice circuit definition source code for the active schematic",
        .mime_type = "text/x-python",
        .handler = &handlePyspice,
    },
    .{
        .uri = "schemify://documentation",
        .name = "Documentation",
        .description = "Markdown documentation for the active schematic",
        .mime_type = "text/markdown",
        .handler = &handleDocumentation,
    },
};

const template_resources = [_]TemplateResource{
    .{
        .uri_template = "schemify://instance/{name}",
        .name = "Instance Detail",
        .description = "Detailed info for a specific component instance",
        .mime_type = "application/json",
        .prefix = "schemify://instance/",
        .handler = &handleInstanceByName,
    },
};

// ── Resource list response ────────────────────────────────────────────────────

pub fn listResources(a: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"resources\":[");
    var first = true;
    for (static_resources) |res| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"uri\":");
        try mcp.writeJsonStr(w, res.uri);
        try w.writeAll(",\"name\":");
        try mcp.writeJsonStr(w, res.name);
        try w.writeAll(",\"description\":");
        try mcp.writeJsonStr(w, res.description);
        try w.writeAll(",\"mimeType\":");
        try mcp.writeJsonStr(w, res.mime_type);
        try w.writeByte('}');
    }
    try w.writeAll("],\"resourceTemplates\":[");
    first = true;
    for (template_resources) |tmpl| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"uriTemplate\":");
        try mcp.writeJsonStr(w, tmpl.uri_template);
        try w.writeAll(",\"name\":");
        try mcp.writeJsonStr(w, tmpl.name);
        try w.writeAll(",\"description\":");
        try mcp.writeJsonStr(w, tmpl.description);
        try w.writeAll(",\"mimeType\":");
        try mcp.writeJsonStr(w, tmpl.mime_type);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return buf.items;
}

// ── Resource read dispatch ────────────────────────────────────────────────────

pub fn readResource(a: std.mem.Allocator, uri: []const u8, ctx: *anyopaque) ![]const u8 {
    // Check static resources
    for (static_resources) |res| {
        if (std.mem.eql(u8, res.uri, uri)) {
            const content = res.handler(a, ctx);
            return wrapContent(a, uri, res.mime_type, content);
        }
    }

    // Check template resources by prefix
    for (template_resources) |tmpl| {
        if (std.mem.startsWith(u8, uri, tmpl.prefix)) {
            const param = uri[tmpl.prefix.len..];
            const content = tmpl.handler(a, param, ctx);
            return wrapContent(a, uri, tmpl.mime_type, content);
        }
    }

    // Not found
    return mcp.errorResponse(a, null, .resource_not_found, "Resource not found");
}

fn wrapContent(a: std.mem.Allocator, uri: []const u8, mime_type: []const u8, text: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"contents\":[{\"uri\":");
    try mcp.writeJsonStr(w, uri);
    try w.writeAll(",\"mimeType\":");
    try mcp.writeJsonStr(w, mime_type);
    try w.writeAll(",\"text\":");
    try mcp.writeJsonStr(w, text);
    try w.writeAll("}]}");
    return buf.items;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn getSchematicFromCtx(ctx: *anyopaque) ?*const Schemify {
    const agent_ctx: *mcp.AgentContext = @ptrCast(@alignCast(ctx));
    return agent_ctx.getSchematic(agent_ctx);
}

fn getAgentCtx(ctx: *anyopaque) *mcp.AgentContext {
    return @ptrCast(@alignCast(ctx));
}

// ── Resource handlers ─────────────────────────────────────────────────────────

fn handleInstances(a: std.mem.Allocator, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse
        return "{\"instances\":[],\"count\":0,\"error\":\"No schematic open\"}";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"instances\":[") catch return "{}";

    const names = sch.instances.items(.name);
    const syms = sch.instances.items(.symbol);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const kinds = sch.instances.items(.kind);
    const prop_starts = sch.instances.items(.prop_start);
    const prop_counts = sch.instances.items(.prop_count);

    for (0..sch.instances.len) |i| {
        if (i > 0) w.writeByte(',') catch {};
        w.writeAll("{\"name\":") catch {};
        mcp.writeJsonStr(w, sch.str(names[i])) catch {};
        w.writeAll(",\"symbol\":") catch {};
        mcp.writeJsonStr(w, sch.str(syms[i])) catch {};
        std.fmt.format(w, ",\"x\":{d},\"y\":{d}", .{ xs[i], ys[i] }) catch {};
        w.writeAll(",\"kind\":") catch {};
        mcp.writeJsonStr(w, @tagName(kinds[i])) catch {};

        // Include properties if present
        if (prop_counts[i] > 0) {
            const start = prop_starts[i];
            const count = prop_counts[i];
            if (start + count <= sch.props.items.len) {
                w.writeAll(",\"properties\":{") catch {};
                const props = sch.props.items[start..][0..count];
                for (props, 0..) |p, pi| {
                    if (pi > 0) w.writeByte(',') catch {};
                    mcp.writeJsonStr(w, sch.str(p.key)) catch {};
                    w.writeByte(':') catch {};
                    mcp.writeJsonStr(w, sch.str(p.val)) catch {};
                }
                w.writeByte('}') catch {};
            }
        }
        w.writeByte('}') catch {};
    }

    std.fmt.format(w, "],\"count\":{d}}}", .{sch.instances.len}) catch {};
    return buf.items;
}

fn handleWires(a: std.mem.Allocator, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse
        return "{\"wires\":[],\"count\":0,\"error\":\"No schematic open\"}";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"wires\":[") catch return "{}";

    const wx0 = sch.wires.items(.x0);
    const wy0 = sch.wires.items(.y0);
    const wx1 = sch.wires.items(.x1);
    const wy1 = sch.wires.items(.y1);
    const wnn = sch.wires.items(.net_name);
    const wbus = sch.wires.items(.bus);

    for (0..sch.wires.len) |i| {
        if (i > 0) w.writeByte(',') catch {};
        std.fmt.format(w, "{{\"x0\":{d},\"y0\":{d},\"x1\":{d},\"y1\":{d}", .{ wx0[i], wy0[i], wx1[i], wy1[i] }) catch {};
        if (!wnn[i].isEmpty()) {
            w.writeAll(",\"net_name\":") catch {};
            mcp.writeJsonStr(w, sch.str(wnn[i])) catch {};
        }
        if (wbus[i]) {
            w.writeAll(",\"bus\":true") catch {};
        }
        w.writeByte('}') catch {};
    }

    std.fmt.format(w, "],\"count\":{d}}}", .{sch.wires.len}) catch {};
    return buf.items;
}

fn handleSelection(_: std.mem.Allocator, _: *anyopaque) []const u8 {
    // Selection state lives in gui/state.zig (AppState.Selection), which is not
    // accessible from the core agent module. Return a note explaining this.
    return "{\"instances\":[],\"wires\":[],\"note\":\"Selection data requires GUI state access; use schemify://instances to see all components\"}";
}

fn handleInfo(a: std.mem.Allocator, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const sch = getSchematicFromCtx(ctx);
    const proj_dir = if (agent_ctx.getProjectDir) |getPd| getPd(agent_ctx) else ".";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);

    if (sch) |s| {
        w.writeAll("{\"file\":") catch return "{}";
        const name_str = s.str(s.name);
        if (name_str.len > 0) mcp.writeJsonStr(w, name_str) catch {} else w.writeAll("null") catch {};
        std.fmt.format(w, ",\"instance_count\":{d}", .{s.instances.len}) catch {};
        std.fmt.format(w, ",\"wire_count\":{d}", .{s.wires.len}) catch {};
        std.fmt.format(w, ",\"pin_count\":{d}", .{s.pins.len}) catch {};
        w.writeAll(",\"type\":") catch {};
        mcp.writeJsonStr(w, @tagName(s.stype)) catch {};
        w.writeAll(",\"project_dir\":") catch {};
        mcp.writeJsonStr(w, proj_dir) catch {};
        w.writeByte('}') catch {};
    } else {
        w.writeAll("{\"file\":null,\"instance_count\":0,\"wire_count\":0,\"project_dir\":") catch return "{}";
        mcp.writeJsonStr(w, proj_dir) catch {};
        w.writeAll(",\"error\":\"No schematic open\"}") catch {};
    }

    return buf.items;
}

fn handleSkillsCore(_: std.mem.Allocator, _: *anyopaque) []const u8 {
    return
        \\# Schemify Core Skills
        \\
        \\## Circuit Design (PySpice-RS Workflow)
        \\- Use `write_pyspice` to set the PySpice-RS circuit definition
        \\- Use `read_pyspice` to see the current circuit definition
        \\- Use `write_documentation` / `read_documentation` for design notes
        \\- Circuits are defined as PySpice-RS Python code (Circuit objects)
        \\
        \\## PySpice-RS Example
        \\```python
        \\from pyspice_rs import Circuit
        \\from pyspice_rs.unit import *
        \\circuit = Circuit('Diff Pair')
        \\circuit.V('dd', 'vdd', circuit.gnd, 1.8)
        \\circuit.M(1, 'out_p', 'in_p', 'tail', circuit.gnd, model='nmos', w=10e-6, l=180e-9)
        \\circuit.M(2, 'out_n', 'in_n', 'tail', circuit.gnd, model='nmos', w=10e-6, l=180e-9)
        \\```
        \\
        \\## Naming Conventions
        \\- MOSFETs: M1, M2, ...
        \\- Resistors: R1, R2, ...
        \\- Capacitors: C1, C2, ...
        \\- Voltage sources: V1, V2, ...
        \\
        \\## Workflow
        \\1. Read schemify://info to understand current state
        \\2. Read schemify://pyspice for the current circuit definition
        \\3. Write PySpice code with write_pyspice
        \\4. Validate with validate_circuit and check_connectivity
        \\5. Generate netlist with generate_netlist
    ;
}

fn handlePyspice(a: std.mem.Allocator, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse
        return "{\"error\":\"No schematic open\"}";
    if (sch.pyspice_source.isEmpty())
        return "{\"pyspice_source\":null,\"note\":\"No PySpice source set\"}";

    const source = sch.str(sch.pyspice_source);
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"pyspice_source\":") catch return "{}";
    mcp.writeJsonStr(w, source) catch return "{}";
    w.writeByte('}') catch return "{}";
    return buf.items;
}

fn handleDocumentation(a: std.mem.Allocator, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse
        return "{\"error\":\"No schematic open\"}";
    if (sch.documentation.isEmpty())
        return "{\"documentation\":null,\"note\":\"No documentation set\"}";

    const doc = sch.str(sch.documentation);
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("{\"documentation\":") catch return "{}";
    mcp.writeJsonStr(w, doc) catch return "{}";
    w.writeByte('}') catch return "{}";
    return buf.items;
}

fn handleInstanceByName(a: std.mem.Allocator, name: []const u8, ctx: *anyopaque) []const u8 {
    const sch = getSchematicFromCtx(ctx) orelse
        return std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"found\":false,\"error\":\"No schematic open\"}}", .{name}) catch "{}";

    const names = sch.instances.items(.name);
    const syms = sch.instances.items(.symbol);
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    const kinds = sch.instances.items(.kind);
    const prop_starts = sch.instances.items(.prop_start);
    const prop_counts = sch.instances.items(.prop_count);

    for (0..sch.instances.len) |i| {
        if (!std.mem.eql(u8, sch.str(names[i]), name)) continue;

        var buf: std.ArrayList(u8) = .{};
        const w = buf.writer(a);
        w.writeAll("{\"found\":true,\"name\":") catch return "{}";
        mcp.writeJsonStr(w, sch.str(names[i])) catch {};
        w.writeAll(",\"symbol\":") catch {};
        mcp.writeJsonStr(w, sch.str(syms[i])) catch {};
        std.fmt.format(w, ",\"x\":{d},\"y\":{d},\"idx\":{d}", .{ xs[i], ys[i], i }) catch {};
        w.writeAll(",\"kind\":") catch {};
        mcp.writeJsonStr(w, @tagName(kinds[i])) catch {};

        // Properties
        if (prop_counts[i] > 0) {
            const start = prop_starts[i];
            const count = prop_counts[i];
            if (start + count <= sch.props.items.len) {
                w.writeAll(",\"properties\":{") catch {};
                const props = sch.props.items[start..][0..count];
                for (props, 0..) |p, pi| {
                    if (pi > 0) w.writeByte(',') catch {};
                    mcp.writeJsonStr(w, sch.str(p.key)) catch {};
                    w.writeByte(':') catch {};
                    mcp.writeJsonStr(w, sch.str(p.val)) catch {};
                }
                w.writeByte('}') catch {};
            }
        }

        w.writeByte('}') catch {};
        return buf.items;
    }

    return std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"found\":false}}", .{name}) catch "{}";
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "listResources produces valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try listResources(a);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("resources") != null);
    try std.testing.expect(obj.get("resourceTemplates") != null);
}

test "readResource unknown returns error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const S = struct {
        fn noSchematic(_: *mcp.AgentContext) ?*const Schemify { return null; }
    };
    var dummy_app: u8 = 0;
    var ctx: mcp.AgentContext = .{
        .getSchematic = &S.noSchematic,
        .app = @ptrCast(&dummy_app),
    };
    const result = try readResource(a, "schemify://nonexistent", @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "-32001") != null);
}
