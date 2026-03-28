//! HdlParser — targeted Verilog/VHDL port extraction for symbol generation.
//!
//! NOT a full HDL parser. Extracts module/entity names, port declarations
//! (name, direction, width), and parameter/generic declarations — just enough
//! to auto-generate schematic symbols from digital source files.
//!
//! Supported styles:
//! - Verilog ANSI and non-ANSI port declarations
//! - VHDL entity/port/generic declarations
//!
//! All returned slices point into allocator-owned memory. The caller owns
//! the returned `HdlModule` and must free it via `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── PinDir ────────────────────────────────────────────────────────────────────
// Matches src/core/Geometry.zig PinDir for compatibility.

pub const PinDir = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const HdlPin = struct {
    name: []const u8,
    direction: PinDir,
    width: u16, // 1 for scalar, N for [N-1:0]
    param_width: ?[]const u8, // "{WIDTH}" if parameterized
};

pub const HdlParam = struct {
    name: []const u8,
    default_value: ?[]const u8,
};

pub const HdlModule = struct {
    name: []const u8,
    pins: []const HdlPin,
    params: []const HdlParam,
    alloc: Allocator,

    pub fn deinit(self: *const HdlModule) void {
        for (self.pins) |pin| {
            self.alloc.free(pin.name);
            if (pin.param_width) |pw| self.alloc.free(pw);
        }
        self.alloc.free(self.pins);
        for (self.params) |param| {
            self.alloc.free(param.name);
            if (param.default_value) |dv| self.alloc.free(dv);
        }
        self.alloc.free(self.params);
        self.alloc.free(self.name);
    }
};

// ── Errors ────────────────────────────────────────────────────────────────────

pub const ParseError = error{
    ModuleNotFound,
    InvalidSyntax,
    OutOfMemory,
};

// ── Verilog parser ────────────────────────────────────────────────────────────

pub fn parseVerilog(source: []const u8, top_module: ?[]const u8, alloc: Allocator) ParseError!HdlModule {
    // Step 1: Strip comments
    const stripped = stripVerilogComments(source, alloc) catch return error.OutOfMemory;
    defer alloc.free(stripped);

    // Step 2: Find the target module
    const mod_info = findVerilogModule(stripped, top_module) orelse return error.ModuleNotFound;

    // Step 3: Duplicate the module name
    const mod_name = alloc.dupe(u8, mod_info.name) catch return error.OutOfMemory;
    errdefer alloc.free(mod_name);

    // Step 4: Extract parameters
    var params = std.ArrayList(HdlParam).init(alloc);
    defer {
        for (params.items) |p| {
            alloc.free(p.name);
            if (p.default_value) |dv| alloc.free(dv);
        }
        params.deinit();
    }
    if (mod_info.param_section) |ps| {
        extractVerilogParams(ps, alloc, &params) catch return error.OutOfMemory;
    }
    extractVerilogParams(mod_info.body, alloc, &params) catch return error.OutOfMemory;

    // Step 5: Extract pins
    var pins = std.ArrayList(HdlPin).init(alloc);
    defer {
        for (pins.items) |p| {
            alloc.free(p.name);
            if (p.param_width) |pw| alloc.free(pw);
        }
        pins.deinit();
    }

    if (mod_info.is_ansi) {
        parseAnsiPorts(mod_info.port_list, alloc, &pins) catch return error.OutOfMemory;
    } else {
        parseNonAnsiPorts(mod_info.port_list, mod_info.body, alloc, &pins) catch return error.OutOfMemory;
    }

    // Move ownership to caller
    const owned_pins = alloc.dupe(HdlPin, pins.items) catch return error.OutOfMemory;
    const owned_params = alloc.dupe(HdlParam, params.items) catch return error.OutOfMemory;

    // Clear the lists without freeing the items (ownership transferred)
    for (pins.items) |*p| {
        p.name = "";
        p.param_width = null;
    }
    for (params.items) |*p| {
        p.name = "";
        p.default_value = null;
    }

    return HdlModule{
        .name = mod_name,
        .pins = owned_pins,
        .params = owned_params,
        .alloc = alloc,
    };
}

// ── VHDL parser ───────────────────────────────────────────────────────────────

pub fn parseVhdl(source: []const u8, top_module: ?[]const u8, alloc: Allocator) ParseError!HdlModule {
    // Step 1: Strip VHDL comments (-- to EOL)
    const stripped = stripVhdlComments(source, alloc) catch return error.OutOfMemory;
    defer alloc.free(stripped);

    // Step 2: Find entity
    const entity_info = findVhdlEntity(stripped, top_module) orelse return error.ModuleNotFound;

    // Step 3: Duplicate the entity name
    const entity_name = alloc.dupe(u8, entity_info.name) catch return error.OutOfMemory;
    errdefer alloc.free(entity_name);

    // Step 4: Extract generics (parameters)
    var params = std.ArrayList(HdlParam).init(alloc);
    defer {
        for (params.items) |p| {
            alloc.free(p.name);
            if (p.default_value) |dv| alloc.free(dv);
        }
        params.deinit();
    }
    if (entity_info.generic_section) |gen_sec| {
        extractVhdlGenerics(gen_sec, alloc, &params) catch return error.OutOfMemory;
    }

    // Step 5: Extract ports
    var pins = std.ArrayList(HdlPin).init(alloc);
    defer {
        for (pins.items) |p| {
            alloc.free(p.name);
            if (p.param_width) |pw| alloc.free(pw);
        }
        pins.deinit();
    }
    if (entity_info.port_section) |port_sec| {
        extractVhdlPorts(port_sec, alloc, &pins) catch return error.OutOfMemory;
    }

    // Move ownership
    const owned_pins = alloc.dupe(HdlPin, pins.items) catch return error.OutOfMemory;
    const owned_params = alloc.dupe(HdlParam, params.items) catch return error.OutOfMemory;

    for (pins.items) |*p| {
        p.name = "";
        p.param_width = null;
    }
    for (params.items) |*p| {
        p.name = "";
        p.default_value = null;
    }

    return HdlModule{
        .name = entity_name,
        .pins = owned_pins,
        .params = owned_params,
        .alloc = alloc,
    };
}

// ── Verilog internals ─────────────────────────────────────────────────────────

const VerilogModuleInfo = struct {
    name: []const u8,
    port_list: []const u8, // content between ( and );
    body: []const u8, // content after ); up to endmodule
    param_section: ?[]const u8, // content inside #( ... ) if present
    is_ansi: bool,
};

fn stripVerilogComments(source: []const u8, alloc: Allocator) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try out.ensureTotalCapacity(source.len);

    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            // Line comment: skip to end of line
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        } else if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
            // Block comment: skip to */
            i += 2;
            while (i + 1 < source.len) {
                if (source[i] == '*' and source[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            out.appendAssumeCapacity(source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

fn findVerilogModule(source: []const u8, top_module: ?[]const u8) ?VerilogModuleInfo {
    var pos: usize = 0;
    while (pos < source.len) {
        // Find "module" keyword
        const mod_start = indexOfKeyword(source, "module", pos) orelse return null;
        pos = mod_start + 6;

        // Skip whitespace after "module"
        pos = skipWhitespace(source, pos);
        if (pos >= source.len) return null;

        // Read module name
        const name_start = pos;
        while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_' or source[pos] == '$')) : (pos += 1) {}
        const name = source[name_start..pos];
        if (name.len == 0) continue;

        // Check if this is the module we want
        if (top_module) |target| {
            if (!std.mem.eql(u8, name, target)) {
                // Skip to endmodule
                if (std.mem.indexOf(u8, source[pos..], "endmodule")) |end_off| {
                    pos = pos + end_off + 9;
                    continue;
                }
                return null;
            }
        }

        // Skip whitespace
        pos = skipWhitespace(source, pos);

        // Check for parameter section: #(...)
        var param_section: ?[]const u8 = null;
        if (pos < source.len and source[pos] == '#') {
            pos += 1;
            pos = skipWhitespace(source, pos);
            if (pos < source.len and source[pos] == '(') {
                const param_paren_close = findMatchingParen(source, pos) orelse return null;
                param_section = source[pos + 1 .. param_paren_close];
                pos = param_paren_close + 1; // skip closing ')'
            }
        }

        pos = skipWhitespace(source, pos);

        // Find the port list opening '('
        if (pos >= source.len or source[pos] != '(') continue;

        const port_start = pos + 1;
        const port_end_paren = findMatchingParen(source, pos) orelse return null;
        const port_list = source[port_start..port_end_paren];

        // Find ');' after port list
        pos = port_end_paren + 1;
        pos = skipWhitespace(source, pos);
        if (pos < source.len and source[pos] == ';') {
            pos += 1;
        }

        // Body goes until endmodule
        const body_start = pos;
        const endmod = std.mem.indexOf(u8, source[pos..], "endmodule") orelse return null;
        const body = source[body_start .. pos + endmod];

        // Determine if ANSI style: port list contains direction keywords
        const is_ansi = isAnsiPortList(port_list);

        return VerilogModuleInfo{
            .name = name,
            .port_list = port_list,
            .body = body,
            .param_section = param_section,
            .is_ansi = is_ansi,
        };
    }
    return null;
}

fn isAnsiPortList(port_list: []const u8) bool {
    // ANSI style contains direction keywords (input, output, inout) in the port list itself
    var i: usize = 0;
    while (i < port_list.len) {
        i = skipWhitespace(port_list, i);
        if (i >= port_list.len) break;

        if (matchKeywordAt(port_list, i, "input") or
            matchKeywordAt(port_list, i, "output") or
            matchKeywordAt(port_list, i, "inout"))
        {
            return true;
        }
        i += 1;
    }
    return false;
}

fn parseAnsiPorts(port_list: []const u8, alloc: Allocator, pins: *std.ArrayList(HdlPin)) Allocator.Error!void {
    // Also need to handle parameter declarations that may appear in the port list
    // (when #(parameter...) is inside the port list of the module header)
    // Split on commas, but respect parentheses nesting
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < port_list.len) : (i += 1) {
        switch (port_list[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    try parseAnsiPortDecl(std.mem.trim(u8, port_list[start..i], &std.ascii.whitespace), alloc, pins);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    // Last port
    const last = std.mem.trim(u8, port_list[start..], &std.ascii.whitespace);
    if (last.len > 0) {
        try parseAnsiPortDecl(last, alloc, pins);
    }
}

fn parseAnsiPortDecl(decl: []const u8, alloc: Allocator, pins: *std.ArrayList(HdlPin)) Allocator.Error!void {
    if (decl.len == 0) return;

    var pos: usize = 0;
    pos = skipWhitespace(decl, pos);

    // Parse direction
    var direction: PinDir = .inout;
    if (matchKeywordAt(decl, pos, "input")) {
        direction = .input;
        pos += 5;
    } else if (matchKeywordAt(decl, pos, "output")) {
        direction = .output;
        pos += 6;
    } else if (matchKeywordAt(decl, pos, "inout")) {
        direction = .inout;
        pos += 5;
    } else {
        // Not a port declaration (might be a parameter in #(...) block)
        return;
    }

    pos = skipWhitespace(decl, pos);

    // Skip optional wire/reg/logic keywords
    if (matchKeywordAt(decl, pos, "wire")) {
        pos += 4;
        pos = skipWhitespace(decl, pos);
    } else if (matchKeywordAt(decl, pos, "reg")) {
        pos += 3;
        pos = skipWhitespace(decl, pos);
    } else if (matchKeywordAt(decl, pos, "logic")) {
        pos += 5;
        pos = skipWhitespace(decl, pos);
    }

    // Parse optional width [MSB:LSB]
    var width: u16 = 1;
    var param_width: ?[]const u8 = null;
    if (pos < decl.len and decl[pos] == '[') {
        const result = parseVerilogRange(decl, pos);
        width = result.width;
        param_width = result.param_expr;
        pos = result.end_pos;
        pos = skipWhitespace(decl, pos);
    }

    // Remaining text is the signal name (possibly with trailing stuff we ignore)
    const name_start = pos;
    while (pos < decl.len and (std.ascii.isAlphanumeric(decl[pos]) or decl[pos] == '_' or decl[pos] == '$')) : (pos += 1) {}
    const name_slice = decl[name_start..pos];
    if (name_slice.len == 0) return;

    const owned_name = try alloc.dupe(u8, name_slice);
    errdefer alloc.free(owned_name);
    const owned_pw = if (param_width) |pw| try alloc.dupe(u8, pw) else null;

    try pins.append(.{
        .name = owned_name,
        .direction = direction,
        .width = width,
        .param_width = owned_pw,
    });
}

const RangeResult = struct {
    width: u16,
    param_expr: ?[]const u8,
    end_pos: usize,
};

fn parseVerilogRange(source: []const u8, start: usize) RangeResult {
    // source[start] == '['
    const pos = start + 1;
    // Find the matching ']'
    const bracket_end = std.mem.indexOfScalarPos(u8, source, pos, ']') orelse return .{ .width = 1, .param_expr = null, .end_pos = start + 1 };

    const range_text = std.mem.trim(u8, source[pos..bracket_end], &std.ascii.whitespace);

    // Find the colon separator
    const colon_pos = std.mem.indexOfScalar(u8, range_text, ':') orelse return .{ .width = 1, .param_expr = null, .end_pos = bracket_end + 1 };

    const msb_str = std.mem.trim(u8, range_text[0..colon_pos], &std.ascii.whitespace);
    const lsb_str = std.mem.trim(u8, range_text[colon_pos + 1 ..], &std.ascii.whitespace);

    // Try to parse as numeric constants
    const msb = std.fmt.parseInt(i32, msb_str, 10) catch {
        // Parameterized width — extract the parameter name
        // Common patterns: WIDTH-1, N-1, etc.
        const param_name = extractParamName(msb_str);
        if (param_name) |pn| {
            // Format as "{PARAM}"
            return .{
                .width = 0,
                .param_expr = pn,
                .end_pos = bracket_end + 1,
            };
        }
        return .{ .width = 0, .param_expr = null, .end_pos = bracket_end + 1 };
    };
    const lsb = std.fmt.parseInt(i32, lsb_str, 10) catch {
        return .{ .width = 0, .param_expr = null, .end_pos = bracket_end + 1 };
    };

    const w = @as(i32, @intCast(@abs(msb - lsb))) + 1;
    return .{
        .width = @intCast(@as(u32, @intCast(w))),
        .param_expr = null,
        .end_pos = bracket_end + 1,
    };
}

fn extractParamName(expr: []const u8) ?[]const u8 {
    // Given something like "WIDTH-1" or "N-1", extract the identifier part
    // Look for pattern: IDENTIFIER followed by optional -1 or +0 etc.
    const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    // Find the identifier portion (letters, digits, underscore starting with letter/_)
    var end: usize = 0;
    while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '_')) : (end += 1) {}

    if (end == 0) return null;

    // Build "{PARAM}" string — but we return just the raw expression for now
    // and let the caller wrap it. Actually, per spec, return "{WIDTH}" format.
    // We'll construct this in the caller with allocation.
    return trimmed[0..end];
}

fn parseNonAnsiPorts(port_list: []const u8, body: []const u8, alloc: Allocator, pins: *std.ArrayList(HdlPin)) Allocator.Error!void {
    // Step 1: Collect port names from the header port list
    var port_names = std.ArrayList([]const u8).init(alloc);
    defer port_names.deinit();

    var start: usize = 0;
    var i: usize = 0;
    while (i < port_list.len) : (i += 1) {
        if (port_list[i] == ',') {
            const name = std.mem.trim(u8, port_list[start..i], &std.ascii.whitespace);
            if (name.len > 0) try port_names.append(name);
            start = i + 1;
        }
    }
    const last_name = std.mem.trim(u8, port_list[start..], &std.ascii.whitespace);
    if (last_name.len > 0) try port_names.append(last_name);

    // Step 2: For each port name, find its declaration in the body
    for (port_names.items) |port_name| {
        const decl = findNonAnsiDecl(body, port_name);

        const owned_name = try alloc.dupe(u8, port_name);
        errdefer alloc.free(owned_name);

        if (decl) |d| {
            const owned_pw = if (d.param_width) |pw| try alloc.dupe(u8, pw) else null;
            try pins.append(.{
                .name = owned_name,
                .direction = d.direction,
                .width = d.width,
                .param_width = owned_pw,
            });
        } else {
            // Port listed but no declaration found; default to inout, width 1
            try pins.append(.{
                .name = owned_name,
                .direction = .inout,
                .width = 1,
                .param_width = null,
            });
        }
    }
}

const NonAnsiDecl = struct {
    direction: PinDir,
    width: u16,
    param_width: ?[]const u8,
};

fn findNonAnsiDecl(body: []const u8, port_name: []const u8) ?NonAnsiDecl {
    // Scan body for lines like: input [3:0] port_name;  or  output port_name;
    var pos: usize = 0;
    while (pos < body.len) {
        pos = skipWhitespace(body, pos);
        if (pos >= body.len) break;

        var direction: ?PinDir = null;
        if (matchKeywordAt(body, pos, "input")) {
            direction = .input;
            pos += 5;
        } else if (matchKeywordAt(body, pos, "output")) {
            direction = .output;
            pos += 6;
        } else if (matchKeywordAt(body, pos, "inout")) {
            direction = .inout;
            pos += 5;
        }

        if (direction) |dir| {
            pos = skipWhitespace(body, pos);

            // Skip optional wire/reg
            if (matchKeywordAt(body, pos, "wire")) {
                pos += 4;
                pos = skipWhitespace(body, pos);
            } else if (matchKeywordAt(body, pos, "reg")) {
                pos += 3;
                pos = skipWhitespace(body, pos);
            }

            // Parse optional range
            var width: u16 = 1;
            var param_width: ?[]const u8 = null;
            if (pos < body.len and body[pos] == '[') {
                const result = parseVerilogRange(body, pos);
                width = result.width;
                param_width = result.param_expr;
                pos = result.end_pos;
                pos = skipWhitespace(body, pos);
            }

            // Now check for the port name — may be a comma-separated list
            // e.g. "input [3:0] a, b, c;"
            const line_end = std.mem.indexOfScalarPos(u8, body, pos, ';') orelse body.len;
            const names_section = body[pos..line_end];

            // Check if port_name appears in this declaration's name list
            if (containsIdentifier(names_section, port_name)) {
                return NonAnsiDecl{
                    .direction = dir,
                    .width = width,
                    .param_width = param_width,
                };
            }

            pos = if (line_end < body.len) line_end + 1 else body.len;
        } else {
            // Skip to next line or semicolon
            while (pos < body.len and body[pos] != '\n' and body[pos] != ';') : (pos += 1) {}
            if (pos < body.len) pos += 1;
        }
    }
    return null;
}

fn containsIdentifier(text: []const u8, identifier: []const u8) bool {
    var pos: usize = 0;
    while (pos < text.len) {
        if (std.mem.indexOfPos(u8, text, pos, identifier)) |found| {
            // Check word boundaries
            const before_ok = found == 0 or !isIdentChar(text[found - 1]);
            const after_pos = found + identifier.len;
            const after_ok = after_pos >= text.len or !isIdentChar(text[after_pos]);
            if (before_ok and after_ok) return true;
            pos = found + 1;
        } else {
            break;
        }
    }
    return false;
}

fn extractVerilogParams(source: []const u8, alloc: Allocator, params: *std.ArrayList(HdlParam)) Allocator.Error!void {
    // Scan for "parameter" keyword followed by name = value
    var pos: usize = 0;
    while (pos < source.len) {
        const kw_pos = indexOfKeyword(source, "parameter", pos) orelse break;
        pos = kw_pos + 9;
        pos = skipWhitespace(source, pos);

        // Skip optional type (integer, real, etc.)
        if (matchKeywordAt(source, pos, "integer") or
            matchKeywordAt(source, pos, "real") or
            matchKeywordAt(source, pos, "signed") or
            matchKeywordAt(source, pos, "unsigned"))
        {
            while (pos < source.len and !std.ascii.isWhitespace(source[pos]) and source[pos] != '=' and source[pos] != '[') : (pos += 1) {}
            pos = skipWhitespace(source, pos);
        }

        // Skip optional range
        if (pos < source.len and source[pos] == '[') {
            if (std.mem.indexOfScalarPos(u8, source, pos, ']')) |close| {
                pos = close + 1;
                pos = skipWhitespace(source, pos);
            }
        }

        // Read parameter name
        const name_start = pos;
        while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_')) : (pos += 1) {}
        const param_name = source[name_start..pos];
        if (param_name.len == 0) continue;

        pos = skipWhitespace(source, pos);

        // Look for '=' and value
        var default_val: ?[]const u8 = null;
        if (pos < source.len and source[pos] == '=') {
            pos += 1;
            pos = skipWhitespace(source, pos);
            const val_start = pos;
            // Value goes until comma, semicolon, closing paren, or end
            while (pos < source.len and source[pos] != ',' and source[pos] != ';' and source[pos] != ')') : (pos += 1) {}
            const val_text = std.mem.trim(u8, source[val_start..pos], &std.ascii.whitespace);
            if (val_text.len > 0) {
                default_val = val_text;
            }
        }

        const owned_name = try alloc.dupe(u8, param_name);
        errdefer alloc.free(owned_name);
        const owned_val = if (default_val) |dv| try alloc.dupe(u8, dv) else null;

        try params.append(.{
            .name = owned_name,
            .default_value = owned_val,
        });
    }
}

// ── VHDL internals ────────────────────────────────────────────────────────────

const VhdlEntityInfo = struct {
    name: []const u8,
    generic_section: ?[]const u8,
    port_section: ?[]const u8,
};

fn stripVhdlComments(source: []const u8, alloc: Allocator) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try out.ensureTotalCapacity(source.len);

    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '-' and source[i + 1] == '-') {
            // VHDL line comment: skip to end of line
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        } else {
            out.appendAssumeCapacity(source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

fn findVhdlEntity(source: []const u8, top_module: ?[]const u8) ?VhdlEntityInfo {
    // Case-insensitive search for VHDL
    var pos: usize = 0;
    while (pos < source.len) {
        const entity_pos = indexOfKeywordCaseInsensitive(source, "entity", pos) orelse return null;
        pos = entity_pos + 6;
        pos = skipWhitespace(source, pos);

        // Read entity name
        const name_start = pos;
        while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_')) : (pos += 1) {}
        const name = source[name_start..pos];
        if (name.len == 0) continue;

        pos = skipWhitespace(source, pos);

        // Expect "is"
        if (!matchKeywordAtCaseInsensitive(source, pos, "is")) continue;
        pos += 2;

        // Check if this is the entity we want
        if (top_module) |target| {
            if (!std.ascii.eqlIgnoreCase(name, target)) {
                // Skip to "end"
                if (indexOfKeywordCaseInsensitive(source, "end", pos)) |end_pos| {
                    pos = end_pos + 3;
                    // skip past the semicolon
                    if (std.mem.indexOfScalarPos(u8, source, pos, ';')) |sc| {
                        pos = sc + 1;
                    }
                    continue;
                }
                return null;
            }
        }

        // Now find generic and port sections before "end"
        // Find the end of this entity
        const end_pos = findVhdlEntityEnd(source, pos) orelse return null;
        const entity_body = source[pos..end_pos];

        // Find generic section
        var generic_section: ?[]const u8 = null;
        if (indexOfKeywordCaseInsensitive(entity_body, "generic", 0)) |gen_pos| {
            const after_gen = gen_pos + 7;
            const paren_open = std.mem.indexOfScalarPos(u8, entity_body, after_gen, '(') orelse null;
            if (paren_open) |po| {
                if (findMatchingParen(entity_body, po)) |pc| {
                    generic_section = entity_body[po + 1 .. pc];
                }
            }
        }

        // Find port section
        var port_section: ?[]const u8 = null;
        if (indexOfKeywordCaseInsensitive(entity_body, "port", 0)) |port_pos| {
            const after_port = port_pos + 4;
            const paren_open = std.mem.indexOfScalarPos(u8, entity_body, after_port, '(') orelse null;
            if (paren_open) |po| {
                if (findMatchingParen(entity_body, po)) |pc| {
                    port_section = entity_body[po + 1 .. pc];
                }
            }
        }

        return VhdlEntityInfo{
            .name = name,
            .generic_section = generic_section,
            .port_section = port_section,
        };
    }
    return null;
}

fn findVhdlEntityEnd(source: []const u8, start: usize) ?usize {
    // Find "end" followed by optional "entity" and optional entity name, then ";"
    // Simple heuristic: accept the first "end" keyword we find after start.
    return indexOfKeywordCaseInsensitive(source, "end", start);
}

fn extractVhdlGenerics(gen_section: []const u8, alloc: Allocator, params: *std.ArrayList(HdlParam)) Allocator.Error!void {
    // Parse declarations like: WIDTH : integer := 8
    // Split on semicolons
    var iter = std.mem.splitScalar(u8, gen_section, ';');
    while (iter.next()) |decl_raw| {
        const decl = std.mem.trim(u8, decl_raw, &std.ascii.whitespace);
        if (decl.len == 0) continue;

        // Find the colon
        const colon_pos = std.mem.indexOfScalar(u8, decl, ':') orelse continue;

        // Name(s) before the colon — may be comma-separated
        const names_part = std.mem.trim(u8, decl[0..colon_pos], &std.ascii.whitespace);
        const after_colon = std.mem.trim(u8, decl[colon_pos + 1 ..], &std.ascii.whitespace);

        // Find default value after ":="
        var default_val: ?[]const u8 = null;
        if (std.mem.indexOf(u8, after_colon, ":=")) |assign_pos| {
            const val = std.mem.trim(u8, after_colon[assign_pos + 2 ..], &std.ascii.whitespace);
            if (val.len > 0) default_val = val;
        }

        // Parse names (might be comma-separated)
        var name_iter = std.mem.splitScalar(u8, names_part, ',');
        while (name_iter.next()) |name_raw| {
            const name = std.mem.trim(u8, name_raw, &std.ascii.whitespace);
            if (name.len == 0) continue;

            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            const owned_val = if (default_val) |dv| try alloc.dupe(u8, dv) else null;

            try params.append(.{
                .name = owned_name,
                .default_value = owned_val,
            });
        }
    }
}

fn extractVhdlPorts(port_section: []const u8, alloc: Allocator, pins: *std.ArrayList(HdlPin)) Allocator.Error!void {
    // Parse declarations like:
    //   clk   : in  std_logic;
    //   data  : out std_logic_vector(7 downto 0)
    // Split on semicolons
    var iter = std.mem.splitScalar(u8, port_section, ';');
    while (iter.next()) |decl_raw| {
        const decl = std.mem.trim(u8, decl_raw, &std.ascii.whitespace);
        if (decl.len == 0) continue;

        // Find the colon
        const colon_pos = std.mem.indexOfScalar(u8, decl, ':') orelse continue;

        // Name(s) before the colon
        const names_part = std.mem.trim(u8, decl[0..colon_pos], &std.ascii.whitespace);
        const after_colon = std.mem.trim(u8, decl[colon_pos + 1 ..], &std.ascii.whitespace);

        // Parse direction
        var dir_end: usize = 0;
        var direction: PinDir = .inout;
        if (matchKeywordAtCaseInsensitive(after_colon, 0, "in") and
            !matchKeywordAtCaseInsensitive(after_colon, 0, "inout"))
        {
            direction = .input;
            dir_end = 2;
        } else if (matchKeywordAtCaseInsensitive(after_colon, 0, "out")) {
            direction = .output;
            dir_end = 3;
        } else if (matchKeywordAtCaseInsensitive(after_colon, 0, "inout")) {
            direction = .inout;
            dir_end = 5;
        } else if (matchKeywordAtCaseInsensitive(after_colon, 0, "buffer")) {
            direction = .output;
            dir_end = 6;
        }

        const type_str = std.mem.trim(u8, after_colon[dir_end..], &std.ascii.whitespace);

        // Parse type for width
        var width: u16 = 1;
        var param_width: ?[]const u8 = null;
        const pw_result = parseVhdlType(type_str);
        width = pw_result.width;
        param_width = pw_result.param_expr;

        // Parse names (might be comma-separated)
        var name_iter = std.mem.splitScalar(u8, names_part, ',');
        while (name_iter.next()) |name_raw| {
            const name = std.mem.trim(u8, name_raw, &std.ascii.whitespace);
            if (name.len == 0) continue;

            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            const owned_pw = if (param_width) |pw| try alloc.dupe(u8, pw) else null;

            try pins.append(.{
                .name = owned_name,
                .direction = direction,
                .width = width,
                .param_width = owned_pw,
            });
        }
    }
}

const VhdlTypeResult = struct {
    width: u16,
    param_expr: ?[]const u8,
};

fn parseVhdlType(type_str: []const u8) VhdlTypeResult {
    // std_logic → width 1
    // std_logic_vector(7 downto 0) → width 8
    // std_logic_vector(WIDTH-1 downto 0) → param_width "{WIDTH}"

    // Check for vector types with parenthesized range
    const paren_open = std.mem.indexOfScalar(u8, type_str, '(') orelse {
        // No parens — scalar type, width 1
        return .{ .width = 1, .param_expr = null };
    };
    const paren_close = std.mem.lastIndexOfScalar(u8, type_str, ')') orelse {
        return .{ .width = 1, .param_expr = null };
    };

    const range_str = type_str[paren_open + 1 .. paren_close];

    // Find "downto" or "to"
    const downto_pos = indexOfCaseInsensitive(range_str, "downto");
    const to_pos = if (downto_pos == null) indexOfCaseInsensitive(range_str, "to") else null;

    if (downto_pos) |dt| {
        const msb_str = std.mem.trim(u8, range_str[0..dt], &std.ascii.whitespace);
        const lsb_str = std.mem.trim(u8, range_str[dt + 6 ..], &std.ascii.whitespace);
        return computeVhdlRange(msb_str, lsb_str);
    } else if (to_pos) |t| {
        const lsb_str = std.mem.trim(u8, range_str[0..t], &std.ascii.whitespace);
        const msb_str = std.mem.trim(u8, range_str[t + 2 ..], &std.ascii.whitespace);
        return computeVhdlRange(msb_str, lsb_str);
    }

    return .{ .width = 1, .param_expr = null };
}

fn computeVhdlRange(msb_str: []const u8, lsb_str: []const u8) VhdlTypeResult {
    const msb = std.fmt.parseInt(i32, msb_str, 10) catch {
        // Parameterized
        const param_name = extractParamName(msb_str);
        if (param_name) |pn| {
            return .{ .width = 0, .param_expr = pn };
        }
        return .{ .width = 0, .param_expr = null };
    };
    const lsb = std.fmt.parseInt(i32, lsb_str, 10) catch {
        return .{ .width = 0, .param_expr = null };
    };

    const w = @as(i32, @intCast(@abs(msb - lsb))) + 1;
    return .{
        .width = @intCast(@as(u32, @intCast(w))),
        .param_expr = null,
    };
}

// ── Common helpers ────────────────────────────────────────────────────────────

fn skipWhitespace(source: []const u8, start: usize) usize {
    var pos = start;
    while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
    return pos;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn indexOfKeyword(source: []const u8, keyword: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < source.len) {
        const found = std.mem.indexOfPos(u8, source, pos, keyword) orelse return null;
        // Check word boundaries
        const before_ok = found == 0 or !isIdentChar(source[found - 1]);
        const after_pos = found + keyword.len;
        const after_ok = after_pos >= source.len or !isIdentChar(source[after_pos]);
        if (before_ok and after_ok) return found;
        pos = found + 1;
    }
    return null;
}

fn matchKeywordAt(source: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > source.len) return false;
    if (!std.mem.eql(u8, source[pos .. pos + keyword.len], keyword)) return false;
    // Check that the character after is not an identifier char
    const after_pos = pos + keyword.len;
    return after_pos >= source.len or !isIdentChar(source[after_pos]);
}

fn indexOfKeywordCaseInsensitive(source: []const u8, keyword: []const u8, start: usize) ?usize {
    if (keyword.len == 0) return null;
    var pos = start;
    while (pos + keyword.len <= source.len) {
        if (std.ascii.eqlIgnoreCase(source[pos .. pos + keyword.len], keyword)) {
            const before_ok = pos == 0 or !isIdentChar(source[pos - 1]);
            const after_pos = pos + keyword.len;
            const after_ok = after_pos >= source.len or !isIdentChar(source[after_pos]);
            if (before_ok and after_ok) return pos;
        }
        pos += 1;
    }
    return null;
}

fn matchKeywordAtCaseInsensitive(source: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > source.len) return false;
    if (!std.ascii.eqlIgnoreCase(source[pos .. pos + keyword.len], keyword)) return false;
    const after_pos = pos + keyword.len;
    return after_pos >= source.len or !isIdentChar(source[after_pos]);
}

fn indexOfCaseInsensitive(source: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > source.len) return null;
    var i: usize = 0;
    while (i + needle.len <= source.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(source[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn findMatchingParen(source: []const u8, open_pos: usize) ?usize {
    if (open_pos >= source.len or source[open_pos] != '(') return null;
    var depth: usize = 1;
    var pos = open_pos + 1;
    while (pos < source.len) : (pos += 1) {
        switch (source[pos]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return pos;
            },
            else => {},
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parse ANSI verilog" {
    const src =
        \\module counter_8bit(
        \\    input wire CLK,
        \\    input wire EN,
        \\    input wire RST,
        \\    output reg [7:0] COUNT,
        \\    output reg CARRY
        \\);
        \\    always @(posedge CLK) begin end
        \\endmodule
    ;
    const m = try parseVerilog(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 5), m.pins.len);
    try std.testing.expectEqualStrings("counter_8bit", m.name);

    // Verify directions
    try std.testing.expectEqual(PinDir.input, m.pins[0].direction); // CLK
    try std.testing.expectEqual(PinDir.input, m.pins[1].direction); // EN
    try std.testing.expectEqual(PinDir.input, m.pins[2].direction); // RST
    try std.testing.expectEqual(PinDir.output, m.pins[3].direction); // COUNT
    try std.testing.expectEqual(PinDir.output, m.pins[4].direction); // CARRY

    // Verify widths
    try std.testing.expectEqual(@as(u16, 1), m.pins[0].width); // CLK
    try std.testing.expectEqual(@as(u16, 1), m.pins[1].width); // EN
    try std.testing.expectEqual(@as(u16, 1), m.pins[2].width); // RST
    try std.testing.expectEqual(@as(u16, 8), m.pins[3].width); // COUNT [7:0]
    try std.testing.expectEqual(@as(u16, 1), m.pins[4].width); // CARRY

    // Verify names
    try std.testing.expectEqualStrings("CLK", m.pins[0].name);
    try std.testing.expectEqualStrings("EN", m.pins[1].name);
    try std.testing.expectEqualStrings("RST", m.pins[2].name);
    try std.testing.expectEqualStrings("COUNT", m.pins[3].name);
    try std.testing.expectEqualStrings("CARRY", m.pins[4].name);
}

test "parse non-ANSI verilog" {
    const src =
        \\module adder(a, b, sum);
        \\    input [3:0] a;
        \\    input [3:0] b;
        \\    output [4:0] sum;
        \\    assign sum = a + b;
        \\endmodule
    ;
    const m = try parseVerilog(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 3), m.pins.len);

    // a and b should have width 4, sum should have width 5
    try std.testing.expectEqualStrings("a", m.pins[0].name);
    try std.testing.expectEqual(@as(u16, 4), m.pins[0].width);
    try std.testing.expectEqual(PinDir.input, m.pins[0].direction);

    try std.testing.expectEqualStrings("b", m.pins[1].name);
    try std.testing.expectEqual(@as(u16, 4), m.pins[1].width);
    try std.testing.expectEqual(PinDir.input, m.pins[1].direction);

    try std.testing.expectEqualStrings("sum", m.pins[2].name);
    try std.testing.expectEqual(@as(u16, 5), m.pins[2].width);
    try std.testing.expectEqual(PinDir.output, m.pins[2].direction);
}

test "parse verilog with parameters" {
    const src =
        \\module counter #(parameter WIDTH = 8) (
        \\    input wire CLK,
        \\    output reg [WIDTH-1:0] COUNT
        \\);
        \\endmodule
    ;
    const m = try parseVerilog(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.pins.len);
    try std.testing.expectEqual(@as(usize, 1), m.params.len);

    // Parameter check
    try std.testing.expectEqualStrings("WIDTH", m.params[0].name);
    try std.testing.expectEqualStrings("8", m.params[0].default_value.?);

    // COUNT should have param_width = "{WIDTH}"
    try std.testing.expectEqualStrings("COUNT", m.pins[1].name);
    try std.testing.expect(m.pins[1].param_width != null);
    try std.testing.expectEqualStrings("WIDTH", m.pins[1].param_width.?);
    try std.testing.expectEqual(@as(u16, 0), m.pins[1].width);
}

test "parse verilog with comments" {
    const src =
        \\// Top-level counter
        \\module counter(
        \\    input CLK, /* clock signal */
        \\    output [7:0] COUNT // output bus
        \\);
        \\endmodule
    ;
    const m = try parseVerilog(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.pins.len);
    try std.testing.expectEqualStrings("CLK", m.pins[0].name);
    try std.testing.expectEqualStrings("COUNT", m.pins[1].name);
    try std.testing.expectEqual(@as(u16, 8), m.pins[1].width);
}

test "parse verilog multiple modules with top_module" {
    const src =
        \\module helper(input A, output B);
        \\endmodule
        \\module main(input X, output Y, output Z);
        \\endmodule
    ;
    const m = try parseVerilog(src, "main", std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqualStrings("main", m.name);
    try std.testing.expectEqual(@as(usize, 3), m.pins.len);
    try std.testing.expectEqualStrings("X", m.pins[0].name);
    try std.testing.expectEqual(PinDir.input, m.pins[0].direction);
    try std.testing.expectEqualStrings("Y", m.pins[1].name);
    try std.testing.expectEqual(PinDir.output, m.pins[1].direction);
    try std.testing.expectEqualStrings("Z", m.pins[2].name);
    try std.testing.expectEqual(PinDir.output, m.pins[2].direction);
}

test "parse simple VHDL" {
    const src =
        \\entity counter is
        \\    port (
        \\        clk   : in  std_logic;
        \\        count : out std_logic_vector(7 downto 0)
        \\    );
        \\end entity counter;
    ;
    const m = try parseVhdl(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.pins.len);
    try std.testing.expectEqualStrings("counter", m.name);

    try std.testing.expectEqualStrings("clk", m.pins[0].name);
    try std.testing.expectEqual(PinDir.input, m.pins[0].direction);
    try std.testing.expectEqual(@as(u16, 1), m.pins[0].width);

    try std.testing.expectEqualStrings("count", m.pins[1].name);
    try std.testing.expectEqual(PinDir.output, m.pins[1].direction);
    try std.testing.expectEqual(@as(u16, 8), m.pins[1].width);
}

test "parse VHDL with generics" {
    const src =
        \\entity shifter is
        \\    generic (
        \\        WIDTH : integer := 8;
        \\        DEPTH : integer := 4
        \\    );
        \\    port (
        \\        clk  : in  std_logic;
        \\        din  : in  std_logic_vector(WIDTH-1 downto 0);
        \\        doubt : out std_logic_vector(WIDTH-1 downto 0)
        \\    );
        \\end entity shifter;
    ;
    const m = try parseVhdl(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqualStrings("shifter", m.name);
    try std.testing.expectEqual(@as(usize, 3), m.pins.len);
    try std.testing.expectEqual(@as(usize, 2), m.params.len);

    // Generics
    try std.testing.expectEqualStrings("WIDTH", m.params[0].name);
    try std.testing.expectEqualStrings("8", m.params[0].default_value.?);
    try std.testing.expectEqualStrings("DEPTH", m.params[1].name);
    try std.testing.expectEqualStrings("4", m.params[1].default_value.?);

    // Ports
    try std.testing.expectEqualStrings("clk", m.pins[0].name);
    try std.testing.expectEqual(@as(u16, 1), m.pins[0].width);

    try std.testing.expectEqualStrings("din", m.pins[1].name);
    try std.testing.expect(m.pins[1].param_width != null);
    try std.testing.expectEqualStrings("WIDTH", m.pins[1].param_width.?);

    try std.testing.expectEqualStrings("doubt", m.pins[2].name);
    try std.testing.expect(m.pins[2].param_width != null);
    try std.testing.expectEqualStrings("WIDTH", m.pins[2].param_width.?);
}

test "parse VHDL inout port" {
    const src =
        \\entity bidir is
        \\    port (
        \\        data : inout std_logic_vector(7 downto 0)
        \\    );
        \\end entity bidir;
    ;
    const m = try parseVhdl(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 1), m.pins.len);
    try std.testing.expectEqual(PinDir.inout, m.pins[0].direction);
    try std.testing.expectEqual(@as(u16, 8), m.pins[0].width);
}

test "verilog module not found returns error" {
    const src =
        \\module foo(input A);
        \\endmodule
    ;
    const result = parseVerilog(src, "nonexistent", std.testing.allocator);
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "vhdl entity not found returns error" {
    const src =
        \\entity foo is
        \\    port ( a : in std_logic );
        \\end entity foo;
    ;
    const result = parseVhdl(src, "nonexistent", std.testing.allocator);
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "parse verilog with inout port" {
    const src =
        \\module bidir(
        \\    input clk,
        \\    inout [7:0] data
        \\);
        \\endmodule
    ;
    const m = try parseVerilog(src, null, std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.pins.len);
    try std.testing.expectEqual(PinDir.input, m.pins[0].direction);
    try std.testing.expectEqual(PinDir.inout, m.pins[1].direction);
    try std.testing.expectEqual(@as(u16, 8), m.pins[1].width);
}
