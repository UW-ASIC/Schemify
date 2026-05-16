// oa.zig - CDL and Spectre netlist parsers for Cadence Virtuoso import.
//
// Parses .SUBCKT blocks from CDL (Circuit Design Language) netlists and
// subckt blocks from Spectre-format netlists. Handles:
//   - `!` global net convention (VDD!, GND!, etc.)
//   - `$SUB=<net>` substrate connection syntax
//   - `$PINS` directive for named pin associations
//   - `+` continuation lines
//   - `.GLOBAL` directives
//   - Spectre-format instance lines: name (terminals) cell params

const std = @import("std");

// ── Shared Types ─────────────────────────────────────────────────────────────

pub const Param = struct {
    key: []const u8,
    val: []const u8,
};

pub const InstanceDef = struct {
    name: []const u8,
    cell: []const u8,
    nets: []const []const u8,
    pins: []const []const u8,
    params: []const Param,
};

pub const Subckt = struct {
    name: []const u8,
    ports: []const []const u8,
    instances: []const InstanceDef,
    globals: []const []const u8,
};

// ── CDL Parser ───────────────────────────────────────────────────────────────

pub const CdlParser = struct {
    content: []const u8,
    pos: usize,
    // Scratch buffers for parsing (avoid repeated allocations)
    ports_buf: [128][]const u8,
    globals_buf: [32][]const u8,
    instances_buf: [256]InstanceDef,
    nets_buf: [512][]const u8,
    pins_buf: [512][]const u8,
    params_buf: [256]Param,
    globals_count: usize,
    // Working state for the current subckt
    inst_count: usize,
    nets_offset: usize,
    pins_offset: usize,
    params_offset: usize,

    pub fn init(content: []const u8) CdlParser {
        return .{
            .content = content,
            .pos = 0,
            .ports_buf = undefined,
            .globals_buf = undefined,
            .instances_buf = undefined,
            .nets_buf = undefined,
            .pins_buf = undefined,
            .params_buf = undefined,
            .globals_count = 0,
            .inst_count = 0,
            .nets_offset = 0,
            .pins_offset = 0,
            .params_offset = 0,
        };
    }

    /// Parse global declarations at the top level.
    fn parseGlobals(self: *CdlParser) void {
        var search_pos: usize = 0;
        while (search_pos < self.content.len) {
            const line = self.getLineAt(search_pos);
            const trimmed = std.mem.trim(u8, line.text, " \t\r");

            if (std.mem.startsWith(u8, trimmed, ".GLOBAL") or
                std.mem.startsWith(u8, trimmed, ".global"))
            {
                const after = trimmed[".GLOBAL".len..];
                var toks = std.mem.tokenizeAny(u8, after, " \t");
                while (toks.next()) |tok| {
                    if (self.globals_count < self.globals_buf.len) {
                        self.globals_buf[self.globals_count] = tok;
                        self.globals_count += 1;
                    }
                }
            }
            search_pos = line.end;
        }
    }

    /// Advance to the next .SUBCKT block and parse it.
    pub fn nextSubckt(self: *CdlParser) ?Subckt {
        // Parse globals on first call
        if (self.pos == 0) {
            self.parseGlobals();
        }

        while (self.pos < self.content.len) {
            const line = self.getLogicalLine();
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (isSubcktStart(trimmed)) {
                return self.parseSubcktBlock(trimmed);
            }
        }
        return null;
    }

    /// Parse a .SUBCKT block starting from the .SUBCKT line.
    fn parseSubcktBlock(self: *CdlParser, header_line: []const u8) ?Subckt {
        // Reset per-subckt state
        self.inst_count = 0;
        self.nets_offset = 0;
        self.pins_offset = 0;
        self.params_offset = 0;

        // Parse header: .SUBCKT <name> <port1> <port2> ...
        const after_subckt = std.mem.trimLeft(u8, header_line[".SUBCKT".len..], " \t");
        var header_toks = std.mem.tokenizeAny(u8, after_subckt, " \t");
        const name = header_toks.next() orelse return null;

        var port_count: usize = 0;
        while (header_toks.next()) |tok| {
            // Stop at parameters (key=value)
            if (std.mem.indexOfScalar(u8, tok, '=') != null) break;
            // Stop at inline comments
            if (tok[0] == '$' or tok[0] == '*') break;
            if (port_count < self.ports_buf.len) {
                self.ports_buf[port_count] = tok;
                port_count += 1;
            }
        }

        // Parse instance lines until .ENDS
        while (self.pos < self.content.len) {
            const inst_line = self.getLogicalLine();
            const inst_trimmed = std.mem.trim(u8, inst_line, " \t\r");

            if (inst_trimmed.len == 0) continue;
            if (inst_trimmed[0] == '*') continue; // Comment
            if (inst_trimmed[0] == '$') continue; // CDL inline comment/directive

            // Check for end of subckt
            if (isSubcktEnd(inst_trimmed)) break;

            // Skip directives that aren't instances
            if (inst_trimmed[0] == '.') continue;

            // Parse instance line
            if (self.parseInstanceLine(inst_trimmed)) |_| {} else continue;
        }

        return Subckt{
            .name = name,
            .ports = self.ports_buf[0..port_count],
            .instances = self.instances_buf[0..self.inst_count],
            .globals = self.globals_buf[0..self.globals_count],
        };
    }

    /// Parse a single CDL instance line.
    /// Format depends on prefix:
    ///   M<name> <drain> <gate> <source> <bulk> <model> [params...]
    ///   R<name> <net1> <net2> [<value>] [params...]
    ///   C<name> <net1> <net2> [<value>] [params...]
    ///   X<name> <net1> ... <netN> <subckt_name> [params...]
    ///   D<name> <anode> <cathode> <model> [params...]
    ///   Q<name> <collector> <base> <emitter> [<sub>] <model> [params...]
    fn parseInstanceLine(self: *CdlParser, line: []const u8) ?void {
        if (line.len == 0) return null;

        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const inst_name = toks.next() orelse return null;
        const prefix = inst_name[0];

        // Collect all remaining tokens
        var all_toks: [64][]const u8 = undefined;
        var tok_count: usize = 0;
        while (toks.next()) |tok| {
            // Handle $SUB=<net> syntax
            if (std.mem.startsWith(u8, tok, "$SUB=")) continue;
            // Handle $PINS directive
            if (std.mem.eql(u8, tok, "$PINS")) {
                // Remaining tokens are pin names; skip past them
                while (toks.next()) |pin_tok| {
                    if (std.mem.indexOfScalar(u8, pin_tok, '=') != null) break;
                }
                break;
            }
            if (tok[0] == '$') continue; // Skip other $ directives
            if (tok_count < all_toks.len) {
                all_toks[tok_count] = tok;
                tok_count += 1;
            }
        }

        if (tok_count == 0) return null;
        const tokens = all_toks[0..tok_count];

        switch (prefix) {
            'M', 'm' => {
                // MOSFET: M<name> D G S B <model> [params]
                if (tok_count < 5) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                // 4 nets: D, G, S, B
                self.appendNet(tokens[0]); // drain
                self.appendNet(tokens[1]); // gate
                self.appendNet(tokens[2]); // source
                self.appendNet(tokens[3]); // bulk
                self.appendPin("D");
                self.appendPin("G");
                self.appendPin("S");
                self.appendPin("B");
                const model_name = tokens[4];
                const params_start = self.params_offset;
                self.appendParam("model", model_name);
                // Parse remaining key=value params
                for (tokens[5..]) |p| self.parseParam(p);

                self.emitInstance(
                    inst_name,
                    model_name,
                    nets_start,
                    pins_start,
                    4,
                    params_start,
                );
            },
            'R', 'r' => {
                // Resistor: R<name> net1 net2 [value | model] [params]
                if (tok_count < 2) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendPin("PLUS");
                self.appendPin("MINUS");
                const params_start = self.params_offset;
                if (tok_count > 2) {
                    if (std.mem.indexOfScalar(u8, tokens[2], '=') != null) {
                        for (tokens[2..]) |p| self.parseParam(p);
                    } else {
                        self.appendParam("value", tokens[2]);
                        for (tokens[3..]) |p| self.parseParam(p);
                    }
                }
                self.emitInstance(inst_name, "res", nets_start, pins_start, 2, params_start);
            },
            'C', 'c' => {
                // Capacitor: C<name> net1 net2 [value | model] [params]
                if (tok_count < 2) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendPin("PLUS");
                self.appendPin("MINUS");
                const params_start = self.params_offset;
                if (tok_count > 2) {
                    if (std.mem.indexOfScalar(u8, tokens[2], '=') != null) {
                        for (tokens[2..]) |p| self.parseParam(p);
                    } else {
                        self.appendParam("value", tokens[2]);
                        for (tokens[3..]) |p| self.parseParam(p);
                    }
                }
                self.emitInstance(inst_name, "cap", nets_start, pins_start, 2, params_start);
            },
            'L', 'l' => {
                // Inductor: L<name> net1 net2 [value] [params]
                if (tok_count < 2) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendPin("PLUS");
                self.appendPin("MINUS");
                const params_start = self.params_offset;
                if (tok_count > 2) {
                    if (std.mem.indexOfScalar(u8, tokens[2], '=') != null) {
                        for (tokens[2..]) |p| self.parseParam(p);
                    } else {
                        self.appendParam("value", tokens[2]);
                        for (tokens[3..]) |p| self.parseParam(p);
                    }
                }
                self.emitInstance(inst_name, "ind", nets_start, pins_start, 2, params_start);
            },
            'D', 'd' => {
                // Diode: D<name> anode cathode model [params]
                if (tok_count < 3) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]); // anode
                self.appendNet(tokens[1]); // cathode
                self.appendPin("PLUS");
                self.appendPin("MINUS");
                const model_name = tokens[2];
                const params_start = self.params_offset;
                self.appendParam("model", model_name);
                for (tokens[3..]) |p| self.parseParam(p);
                self.emitInstance(inst_name, "diode", nets_start, pins_start, 2, params_start);
            },
            'Q', 'q' => {
                // BJT: Q<name> C B E [S] model [params]
                if (tok_count < 4) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]); // collector
                self.appendNet(tokens[1]); // base
                self.appendNet(tokens[2]); // emitter
                self.appendPin("C");
                self.appendPin("B");
                self.appendPin("E");

                // Determine if 4th token is substrate or model
                var model_idx: usize = 3;
                if (tok_count > 4 and std.mem.indexOfScalar(u8, tokens[3], '=') == null and
                    !isModelName(tokens[3]))
                {
                    // 4th token is substrate net
                    self.appendNet(tokens[3]);
                    self.appendPin("S");
                    model_idx = 4;
                }

                const params_start = self.params_offset;
                if (model_idx < tok_count) {
                    const model_name = tokens[model_idx];
                    self.appendParam("model", model_name);
                    for (tokens[model_idx + 1 ..]) |p| self.parseParam(p);
                }

                const net_count = self.nets_offset - nets_start;
                // Determine cell name based on net count
                const cell_name: []const u8 = if (net_count >= 4) "npn4" else "npn";
                self.emitInstance(inst_name, cell_name, nets_start, pins_start, net_count, params_start);
            },
            'X', 'x' => {
                // Subcircuit: X<name> net1 net2 ... netN subckt_name [params]
                if (tok_count < 2) return null;

                // Find where nets end and subckt name / params begin.
                // Strategy: scan backwards from end. Tokens with '=' are params.
                // The last non-param token is the subckt name.
                var param_start_idx: usize = tok_count;
                while (param_start_idx > 0) {
                    param_start_idx -= 1;
                    if (std.mem.indexOfScalar(u8, tokens[param_start_idx], '=') == null) break;
                }
                // tokens[param_start_idx] is the subckt name
                const subckt_name = tokens[param_start_idx];
                const net_end = param_start_idx;

                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                for (tokens[0..net_end]) |net| {
                    self.appendNet(net);
                    self.appendPin(net); // For subcircuits, pin names = net names as placeholder
                }

                const params_start = self.params_offset;
                for (tokens[param_start_idx + 1 ..]) |p| self.parseParam(p);

                const net_count = self.nets_offset - nets_start;
                self.emitInstance(inst_name, subckt_name, nets_start, pins_start, net_count, params_start);
            },
            'V', 'v' => {
                // Voltage source: V<name> net+ net- [dc_value] [params]
                if (tok_count < 2) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendPin("PLUS");
                self.appendPin("MINUS");
                const params_start = self.params_offset;
                if (tok_count > 2) {
                    for (tokens[2..]) |p| self.parseParam(p);
                }
                self.emitInstance(inst_name, "vdc", nets_start, pins_start, 2, params_start);
            },
            'I', 'i' => {
                // Current source: I<name> net+ net- [dc_value] [params]
                if (tok_count < 2) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendPin("PLUS");
                self.appendPin("MINUS");
                const params_start = self.params_offset;
                if (tok_count > 2) {
                    for (tokens[2..]) |p| self.parseParam(p);
                }
                self.emitInstance(inst_name, "idc", nets_start, pins_start, 2, params_start);
            },
            'E', 'e' => {
                // VCVS: E<name> outp outn inp inn gain
                if (tok_count < 4) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]); // outp
                self.appendNet(tokens[1]); // outn
                self.appendNet(tokens[2]); // inp
                self.appendNet(tokens[3]); // inn
                self.appendPin("outp");
                self.appendPin("outn");
                self.appendPin("inp");
                self.appendPin("inn");
                const params_start = self.params_offset;
                if (tok_count > 4) self.appendParam("gain", tokens[4]);
                for (tokens[@min(tok_count, 5)..]) |p| self.parseParam(p);
                self.emitInstance(inst_name, "vcvs", nets_start, pins_start, 4, params_start);
            },
            'G', 'g' => {
                // VCCS: G<name> outp outn inp inn gain
                if (tok_count < 4) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendNet(tokens[2]);
                self.appendNet(tokens[3]);
                self.appendPin("outp");
                self.appendPin("outn");
                self.appendPin("inp");
                self.appendPin("inn");
                const params_start = self.params_offset;
                if (tok_count > 4) self.appendParam("gain", tokens[4]);
                for (tokens[@min(tok_count, 5)..]) |p| self.parseParam(p);
                self.emitInstance(inst_name, "vccs", nets_start, pins_start, 4, params_start);
            },
            'H', 'h' => {
                // CCVS: H<name> outp outn vname gain
                if (tok_count < 4) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendNet(tokens[2]);
                self.appendNet(tokens[3]);
                self.appendPin("outp");
                self.appendPin("outn");
                self.appendPin("inp");
                self.appendPin("inn");
                const params_start = self.params_offset;
                if (tok_count > 4) self.appendParam("gain", tokens[4]);
                for (tokens[@min(tok_count, 5)..]) |p| self.parseParam(p);
                self.emitInstance(inst_name, "ccvs", nets_start, pins_start, 4, params_start);
            },
            'F', 'f' => {
                // CCCS: F<name> outp outn vname gain
                if (tok_count < 4) return null;
                const nets_start = self.nets_offset;
                const pins_start = self.pins_offset;
                self.appendNet(tokens[0]);
                self.appendNet(tokens[1]);
                self.appendNet(tokens[2]);
                self.appendNet(tokens[3]);
                self.appendPin("outp");
                self.appendPin("outn");
                self.appendPin("inp");
                self.appendPin("inn");
                const params_start = self.params_offset;
                if (tok_count > 4) self.appendParam("gain", tokens[4]);
                for (tokens[@min(tok_count, 5)..]) |p| self.parseParam(p);
                self.emitInstance(inst_name, "cccs", nets_start, pins_start, 4, params_start);
            },
            else => return null,
        }
    }

    // ── Buffer helpers ───────────────────────────────────────────────────────

    fn appendNet(self: *CdlParser, net: []const u8) void {
        if (self.nets_offset < self.nets_buf.len) {
            self.nets_buf[self.nets_offset] = net;
            self.nets_offset += 1;
        }
    }

    fn appendPin(self: *CdlParser, pin: []const u8) void {
        if (self.pins_offset < self.pins_buf.len) {
            self.pins_buf[self.pins_offset] = pin;
            self.pins_offset += 1;
        }
    }

    fn appendParam(self: *CdlParser, key: []const u8, val: []const u8) void {
        if (self.params_offset < self.params_buf.len) {
            self.params_buf[self.params_offset] = .{ .key = key, .val = val };
            self.params_offset += 1;
        }
    }

    fn parseParam(self: *CdlParser, tok: []const u8) void {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            const key = tok[0..eq];
            const val = tok[eq + 1 ..];
            if (key.len > 0 and val.len > 0) {
                self.appendParam(key, val);
            }
        }
    }

    fn emitInstance(
        self: *CdlParser,
        name: []const u8,
        cell: []const u8,
        nets_start: usize,
        pins_start: usize,
        net_count: usize,
        params_start: usize,
    ) void {
        if (self.inst_count >= self.instances_buf.len) return;
        self.instances_buf[self.inst_count] = .{
            .name = name,
            .cell = cell,
            .nets = self.nets_buf[nets_start..][0..net_count],
            .pins = self.pins_buf[pins_start..][0..net_count],
            .params = self.params_buf[params_start..self.params_offset],
        };
        self.inst_count += 1;
    }

    // ── Line reading helpers ─────────────────────────────────────────────────

    /// Get a single physical line (without continuation handling).
    fn getLineAt(self: *const CdlParser, start: usize) struct { text: []const u8, end: usize } {
        var end = start;
        while (end < self.content.len and self.content[end] != '\n') : (end += 1) {}
        const text = self.content[start..end];
        return .{ .text = text, .end = if (end < self.content.len) end + 1 else end };
    }

    /// Get the next logical line (handling `+` continuation).
    fn getLogicalLine(self: *CdlParser) []const u8 {
        if (self.pos >= self.content.len) return "";

        // Find end of first physical line
        var end = self.pos;
        while (end < self.content.len and self.content[end] != '\n') : (end += 1) {}
        var line_end = end;
        if (end < self.content.len) end += 1; // skip newline

        // Check for continuation lines (start with +)
        while (end < self.content.len) {
            // Skip leading whitespace on next line
            var next_start = end;
            while (next_start < self.content.len and
                (self.content[next_start] == ' ' or self.content[next_start] == '\t'))
            {
                next_start += 1;
            }
            if (next_start < self.content.len and self.content[next_start] == '+') {
                // This is a continuation line - extend our logical line
                var cont_end = next_start;
                while (cont_end < self.content.len and self.content[cont_end] != '\n') : (cont_end += 1) {}
                line_end = cont_end;
                end = if (cont_end < self.content.len) cont_end + 1 else cont_end;
            } else {
                break;
            }
        }

        const result = self.content[self.pos..line_end];
        self.pos = end;
        return result;
    }
};

// ── Spectre Parser ───────────────────────────────────────────────────────────

pub const SpectreParser = struct {
    content: []const u8,
    pos: usize,
    ports_buf: [128][]const u8,
    globals_buf: [32][]const u8,
    instances_buf: [256]InstanceDef,
    nets_buf: [512][]const u8,
    pins_buf: [512][]const u8,
    params_buf: [256]Param,
    globals_count: usize,
    inst_count: usize,
    nets_offset: usize,
    pins_offset: usize,
    params_offset: usize,

    pub fn init(content: []const u8) SpectreParser {
        return .{
            .content = content,
            .pos = 0,
            .ports_buf = undefined,
            .globals_buf = undefined,
            .instances_buf = undefined,
            .nets_buf = undefined,
            .pins_buf = undefined,
            .params_buf = undefined,
            .globals_count = 0,
            .inst_count = 0,
            .nets_offset = 0,
            .pins_offset = 0,
            .params_offset = 0,
        };
    }

    /// Parse the next subckt block in Spectre format.
    pub fn nextSubckt(self: *SpectreParser) ?Subckt {
        while (self.pos < self.content.len) {
            const line = self.getLine();
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip comments
            if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') continue;
            if (trimmed.len == 0) continue;

            // Look for "subckt <name> (<ports>)" or "subckt <name> ports..."
            if (std.mem.startsWith(u8, trimmed, "subckt ")) {
                return self.parseSpectreSubckt(trimmed);
            }
        }
        return null;
    }

    fn parseSpectreSubckt(self: *SpectreParser, header: []const u8) ?Subckt {
        self.inst_count = 0;
        self.nets_offset = 0;
        self.pins_offset = 0;
        self.params_offset = 0;

        // Parse: subckt <name> (<port1> <port2> ...) or subckt <name> port1 port2
        const after = header["subckt ".len..];
        var toks = std.mem.tokenizeAny(u8, after, " \t");
        const name = toks.next() orelse return null;

        var port_count: usize = 0;
        var in_parens = false;

        while (toks.next()) |tok| {
            if (tok[0] == '(') {
                in_parens = true;
                // Token might be "(port1" or just "("
                const inner = tok[1..];
                if (inner.len > 0) {
                    const stripped = if (inner[inner.len - 1] == ')')
                        inner[0 .. inner.len - 1]
                    else
                        inner;
                    if (stripped.len > 0 and port_count < self.ports_buf.len) {
                        self.ports_buf[port_count] = stripped;
                        port_count += 1;
                    }
                    if (inner[inner.len - 1] == ')') {
                        in_parens = false;
                    }
                }
                continue;
            }
            if (in_parens) {
                const stripped = if (tok[tok.len - 1] == ')')
                    tok[0 .. tok.len - 1]
                else
                    tok;
                if (stripped.len > 0 and port_count < self.ports_buf.len) {
                    self.ports_buf[port_count] = stripped;
                    port_count += 1;
                }
                if (tok[tok.len - 1] == ')') {
                    in_parens = false;
                }
                continue;
            }
            // Not in parens - ports listed directly
            if (std.mem.indexOfScalar(u8, tok, '=') != null) break;
            if (port_count < self.ports_buf.len) {
                self.ports_buf[port_count] = tok;
                port_count += 1;
            }
        }

        // Parse instance lines until "ends"
        while (self.pos < self.content.len) {
            const line = self.getLine();
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0) continue;
            if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') continue;

            // Check for end of subckt
            if (std.mem.startsWith(u8, trimmed, "ends")) break;

            // Parse Spectre instance: <name> (<terminals>) <type> [params]
            self.parseSpectreInstance(trimmed);
        }

        return Subckt{
            .name = name,
            .ports = self.ports_buf[0..port_count],
            .instances = self.instances_buf[0..self.inst_count],
            .globals = self.globals_buf[0..self.globals_count],
        };
    }

    /// Parse a Spectre instance line: name (term1 term2 ...) cell_type param=val ...
    fn parseSpectreInstance(self: *SpectreParser, line: []const u8) void {
        // Find instance name (first token before '(')
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const inst_name = toks.next() orelse return;

        // Skip if it looks like a directive
        if (inst_name[0] == '.' or inst_name[0] == '/' or inst_name[0] == '*') return;

        // Find terminals in parentheses
        const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return;
        const close_paren = std.mem.indexOfScalar(u8, line[open_paren..], ')') orelse return;
        const terminals_str = line[open_paren + 1 ..][0 .. close_paren - 1];
        const after_parens = line[open_paren + close_paren + 1 ..];

        const nets_start = self.nets_offset;
        const pins_start = self.pins_offset;

        // Parse terminals
        var term_toks = std.mem.tokenizeAny(u8, terminals_str, " \t");
        var net_count: usize = 0;
        while (term_toks.next()) |term| {
            if (self.nets_offset < self.nets_buf.len) {
                self.nets_buf[self.nets_offset] = term;
                self.nets_offset += 1;
            }
            if (self.pins_offset < self.pins_buf.len) {
                self.pins_buf[self.pins_offset] = term; // Spectre uses net names as pins initially
                self.pins_offset += 1;
            }
            net_count += 1;
        }

        // After closing paren: cell_type followed by key=value params
        var after_toks = std.mem.tokenizeAny(u8, std.mem.trimLeft(u8, after_parens, " \t"), " \t");
        const cell_type = after_toks.next() orelse return;

        const params_start = self.params_offset;
        while (after_toks.next()) |param_tok| {
            if (std.mem.indexOfScalar(u8, param_tok, '=')) |eq| {
                const key = param_tok[0..eq];
                const val = param_tok[eq + 1 ..];
                if (key.len > 0 and val.len > 0 and self.params_offset < self.params_buf.len) {
                    self.params_buf[self.params_offset] = .{ .key = key, .val = val };
                    self.params_offset += 1;
                }
            }
        }

        // Assign pin names based on cell type heuristics (avoids circular import)
        const ctx = inferPinContext(cell_type);
        assignPinNames(self, pins_start, net_count, ctx);

        if (self.inst_count < self.instances_buf.len) {
            self.instances_buf[self.inst_count] = .{
                .name = inst_name,
                .cell = cell_type,
                .nets = self.nets_buf[nets_start..][0..net_count],
                .pins = self.pins_buf[pins_start..][0..net_count],
                .params = self.params_buf[params_start..self.params_offset],
            };
            self.inst_count += 1;
        }
    }

    fn getLine(self: *SpectreParser) []const u8 {
        if (self.pos >= self.content.len) return "";
        var end = self.pos;
        while (end < self.content.len and self.content[end] != '\n') : (end += 1) {}
        const line = self.content[self.pos..end];
        self.pos = if (end < self.content.len) end + 1 else end;
        return line;
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Pin assignment context (local copy to avoid circular import with mod.zig).
const PinCtx = enum { mosfet, bjt, passive, controlled_source, probe, other };

/// Infer pin context from a cell type name using prefix heuristics.
/// This is a self-contained version that avoids importing mod.zig.
fn inferPinContext(cell_type: []const u8) PinCtx {
    // MOSFET patterns
    if (std.mem.startsWith(u8, cell_type, "nmos") or
        std.mem.startsWith(u8, cell_type, "pmos") or
        std.mem.startsWith(u8, cell_type, "nch") or
        std.mem.startsWith(u8, cell_type, "pch") or
        std.mem.startsWith(u8, cell_type, "nfet") or
        std.mem.startsWith(u8, cell_type, "pfet"))
        return .mosfet;
    // BJT patterns
    if (std.mem.startsWith(u8, cell_type, "npn") or
        std.mem.startsWith(u8, cell_type, "pnp") or
        std.mem.startsWith(u8, cell_type, "vpnp"))
        return .bjt;
    // Controlled sources
    if (std.mem.startsWith(u8, cell_type, "vcvs") or
        std.mem.startsWith(u8, cell_type, "vccs") or
        std.mem.startsWith(u8, cell_type, "ccvs") or
        std.mem.startsWith(u8, cell_type, "cccs") or
        std.mem.startsWith(u8, cell_type, "pvcvs") or
        std.mem.startsWith(u8, cell_type, "pvccs") or
        std.mem.startsWith(u8, cell_type, "pccvs") or
        std.mem.startsWith(u8, cell_type, "pcccs"))
        return .controlled_source;
    // Probe
    if (std.mem.eql(u8, cell_type, "iprobe") or
        std.mem.eql(u8, cell_type, "port"))
        return .probe;
    // Passive (resistor, capacitor, inductor, diode, sources)
    if (std.mem.startsWith(u8, cell_type, "res") or
        std.mem.eql(u8, cell_type, "resistor") or
        std.mem.startsWith(u8, cell_type, "cap") or
        std.mem.eql(u8, cell_type, "capacitor") or
        std.mem.startsWith(u8, cell_type, "ind") or
        std.mem.eql(u8, cell_type, "inductor") or
        std.mem.startsWith(u8, cell_type, "diode") or
        std.mem.startsWith(u8, cell_type, "vdc") or
        std.mem.startsWith(u8, cell_type, "vsin") or
        std.mem.startsWith(u8, cell_type, "vpulse") or
        std.mem.startsWith(u8, cell_type, "idc") or
        std.mem.startsWith(u8, cell_type, "isin") or
        std.mem.startsWith(u8, cell_type, "vsource") or
        std.mem.startsWith(u8, cell_type, "isource"))
        return .passive;
    return .other;
}

/// Assign canonical pin names based on device context and pin position.
fn assignPinNames(parser: *SpectreParser, pins_start: usize, count: usize, ctx: PinCtx) void {
    const mosfet_pins = [_][]const u8{ "D", "G", "S", "B" };
    const bjt3_pins = [_][]const u8{ "C", "B", "E" };
    const bjt4_pins = [_][]const u8{ "C", "B", "E", "S" };
    const passive2_pins = [_][]const u8{ "PLUS", "MINUS" };
    const ctrl4_pins = [_][]const u8{ "inp", "inn", "outp", "outn" };

    const pin_names: []const []const u8 = switch (ctx) {
        .mosfet => if (count >= 4) mosfet_pins[0..4] else mosfet_pins[0..@min(count, 4)],
        .bjt => if (count >= 4) bjt4_pins[0..4] else bjt3_pins[0..@min(count, 3)],
        .passive => passive2_pins[0..@min(count, 2)],
        .controlled_source => ctrl4_pins[0..@min(count, 4)],
        .probe => passive2_pins[0..@min(count, 2)],
        .other => return, // Keep net names as pin names for subcircuits
    };

    for (pin_names, 0..) |pin, i| {
        if (pins_start + i < parser.pins_buf.len) {
            parser.pins_buf[pins_start + i] = pin;
        }
    }
}

fn isSubcktStart(line: []const u8) bool {
    // Case-insensitive check for .SUBCKT
    if (line.len < 7) return false;
    if (line[0] != '.') return false;
    const keyword = line[1..7];
    return std.ascii.eqlIgnoreCase(keyword, "SUBCKT");
}

fn isSubcktEnd(line: []const u8) bool {
    if (line.len < 5) return false;
    if (line[0] != '.') return false;
    const keyword = line[1..];
    if (keyword.len >= 4 and std.ascii.eqlIgnoreCase(keyword[0..4], "ENDS")) return true;
    return false;
}

/// Heuristic: Check if a token looks like a SPICE model name (alphanumeric + underscore).
fn isModelName(tok: []const u8) bool {
    if (tok.len == 0) return false;
    // Model names typically start with a letter and don't contain special net chars
    if (!std.ascii.isAlphabetic(tok[0]) and tok[0] != '_') return false;
    for (tok) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    }
    return true;
}
