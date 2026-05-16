//! MCP tools — model-controlled actions.
//!
//! Each tool has a name, description, JSON Schema inputSchema, and annotations.
//! Tools are discovered via `tools/list` and invoked via `tools/call`.
//! PySpice tools (write_pyspice, read_pyspice) operate on the schematic's
//! circuit definition. Documentation tools manage design notes.
//! Diagnostic tools call real analysis via the diagnostics module.
//! File I/O tools (read_file, write_file, list_project_files) operate on the
//! project directory.

const std = @import("std");
const mcp = @import("types.zig");
const diag = @import("diagnostics.zig");
const schematic = @import("schematic");
const Schemify = schematic.Schemify;

/// Extract the active schematic from an AgentContext-typed ctx pointer.
/// Returns null if ctx doesn't point to an AgentContext or no document is open.
fn getSchematicFromCtx(ctx: *anyopaque) ?*const Schemify {
    const agent_ctx: *mcp.AgentContext = @ptrCast(@alignCast(ctx));
    return agent_ctx.getSchematic(agent_ctx);
}

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
    // PySpice tools
    .{
        .name = "write_pyspice",
        .description = "Write PySpice circuit definition source code. This replaces the current pyspice_source in the active schematic. The code should be a complete PySpice circuit definition.",
        .schema_json =
        \\{"type":"object","properties":{"source":{"type":"string","description":"Complete PySpice Python source code"}},"required":["source"]}
        ,
        .annotations = .{ .destructiveHint = true },
        .handler = &handleWritePyspice,
    },
    .{
        .name = "read_pyspice",
        .description = "Read the current PySpice source code from the active schematic. Returns null if no PySpice source is set.",
        .schema_json =
        \\{"type":"object","properties":{}}
        ,
        .annotations = .{ .readOnlyHint = true },
        .handler = &handleReadPyspice,
    },

    // Documentation tools
    .{
        .name = "read_documentation",
        .description = "Read the documentation (Markdown) from the active schematic.",
        .schema_json =
        \\{"type":"object","properties":{}}
        ,
        .annotations = .{ .readOnlyHint = true },
        .handler = &handleReadDocumentation,
    },
    .{
        .name = "write_documentation",
        .description = "Write or update the schematic documentation in Markdown format.",
        .schema_json =
        \\{"type":"object","properties":{"content":{"type":"string","description":"Markdown documentation content"}},"required":["content"]}
        ,
        .annotations = .{ .destructiveHint = true },
        .handler = &handleWriteDocumentation,
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

/// Extract the AgentContext from an opaque ctx pointer.
fn getAgentCtx(ctx: *anyopaque) *mcp.AgentContext {
    return @ptrCast(@alignCast(ctx));
}

// ── PySpice tool handlers ─────────────────────────────────────────────────────

fn handleWritePyspice(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const source = getStr(args, "source") orelse return errorResult(a, "Missing 'source' parameter");

    if (agent_ctx.setPySpiceSource) |setter| {
        if (setter(agent_ctx, source)) {
            return textResult(a, "{\"updated\":true,\"field\":\"pyspice_source\"}");
        }
        return errorResult(a, "Failed to update PySpice source");
    }
    return errorResult(a, "PySpice source update not available");
}

fn handleReadPyspice(a: std.mem.Allocator, _: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    if (agent_ctx.getPySpiceSource) |getter| {
        if (getter(agent_ctx)) |source| {
            return textResult(a, source);
        }
        return textResult(a, "null");
    }
    return errorResult(a, "PySpice source read not available");
}

// ── Documentation tool handlers ───────────────────────────────────────────────

fn handleReadDocumentation(a: std.mem.Allocator, _: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    if (agent_ctx.getDocumentation) |getter| {
        if (getter(agent_ctx)) |doc| {
            return textResult(a, doc);
        }
        return textResult(a, "null");
    }
    return errorResult(a, "Documentation read not available");
}

fn handleWriteDocumentation(a: std.mem.Allocator, args: ?std.json.Value, ctx: *anyopaque) []const u8 {
    const agent_ctx = getAgentCtx(ctx);
    const content = getStr(args, "content") orelse return errorResult(a, "Missing 'content' parameter");

    if (agent_ctx.setDocumentation) |setter| {
        if (setter(agent_ctx, content)) {
            return textResult(a, "{\"updated\":true,\"field\":\"documentation\"}");
        }
        return errorResult(a, "Failed to update documentation");
    }
    return errorResult(a, "Documentation update not available");
}

// ── Diagnostic tool handlers ──────────────────────────────────────────────────

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

// ── File I/O tool handlers ────────────────────────────────────────────────────

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

/// Test helper: creates an AgentContext with no schematic and no callbacks.
fn testAgentCtx() mcp.AgentContext {
    const S = struct {
        fn noSchematic(_: *mcp.AgentContext) ?*const Schemify { return null; }
    };
    var dummy_app: u8 = 0;
    return .{
        .getSchematic = &S.noSchematic,
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

test "write_pyspice missing source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testAgentCtx();
    const result = handleWritePyspice(a, null, @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source") != null);
}

test "read_pyspice no callback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testAgentCtx();
    const result = handleReadPyspice(a, null, @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "not available") != null);
}

test "read_documentation no callback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testAgentCtx();
    const result = handleReadDocumentation(a, null, @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
}

test "write_documentation missing content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testAgentCtx();
    const result = handleWriteDocumentation(a, null, @ptrCast(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "content") != null);
}
