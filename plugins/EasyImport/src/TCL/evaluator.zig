const std = @import("std");
const commands = @import("commands.zig");
const expr_mod = @import("expr.zig");

pub const EvalError = error{
    UndefinedVariable, UnsupportedConstruct, Unbalanced, InvalidCommand, SourceError,
    InvalidArgCount, UnknownSubcommand, FileNotFound, PathError, OutOfMemory,
    InvalidExpression, DivisionByZero, UnterminatedString, UnmatchedParen,
};

/// A user-defined Tcl proc: formal argument names + body source.
const ProcDef = struct {
    arg_names: []const []const u8,
    body: []const u8,
};

pub const Evaluator = struct {
    arena: std.heap.ArenaAllocator,
    variables: std.StringHashMapUnmanaged([]const u8),
    procs: std.StringHashMapUnmanaged(ProcDef),
    script_path: ?[]const u8,
    source_visited: std.StringHashMapUnmanaged(void),
    backing: std.mem.Allocator,

    const unsupported_constructs = std.StaticStringMap(void).initComptime(.{
        .{ "switch", {} },   .{ "array", {} },
        .{ "regexp", {} },   .{ "for", {} },      .{ "foreach", {} },
        .{ "while", {} },    .{ "global", {} },
        .{ "namespace", {} }, .{ "package", {} },  .{ "eval", {} },
        .{ "uplevel", {} },  .{ "upvar", {} },
    });

    const command_map = std.StaticStringMap(CommandKind).initComptime(.{
        .{ "set", .set },         .{ "append", .append_ },
        .{ "lappend", .lappend }, .{ "if", .if_ },
        .{ "expr", .expr },       .{ "source", .source },
        .{ "file", .file },       .{ "info", .info },
        .{ "string", .string_ },  .{ "puts", .puts },
        .{ "return", .return_ },  .{ "unset", .unset },
        .{ "proc", .proc_ },      .{ "catch", .catch_ },
    });

    const CommandKind = enum {
        set, append_, lappend, if_, expr, source,
        file, info, string_, puts, return_, unset,
        proc_, catch_,
    };

    pub fn init(backing: std.mem.Allocator) Evaluator {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .variables = .{},
            .procs = .{},
            .script_path = null,
            .source_visited = .{},
            .backing = backing,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.variables.deinit(self.backing);
        self.procs.deinit(self.backing);
        self.source_visited.deinit(self.backing);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn setScriptPath(self: *Evaluator, path: []const u8) void {
        self.script_path = self.dupeStr(path);
    }

    pub fn evalScript(self: *Evaluator, script: []const u8) EvalError![]const u8 {
        var last: []const u8 = "";
        var scanner = commands.SegmentScanner.init(script);
        while (scanner.next()) |segment| {
            const trimmed = std.mem.trim(u8, segment, " \t\r\n");
            if (trimmed.len == 0) continue;
            // Skip comments
            if (trimmed[0] == '#') continue;
            last = try self.evalCommand(trimmed);
        }
        return last;
    }

    pub fn getVar(self: *const Evaluator, name: []const u8) ?[]const u8 {
        return self.variables.get(name);
    }

    pub fn setVar(self: *Evaluator, name: []const u8, value: []const u8) EvalError!void {
        const k = self.dupeStr(name);
        const v = self.dupeStr(value);
        self.variables.put(self.backing, k, v) catch return error.OutOfMemory;
    }

    fn evalCommand(self: *Evaluator, cmd_text: []const u8) EvalError![]const u8 {
        var words_buf: [64][]const u8 = undefined;
        var word_count: usize = 0;
        try self.parseAndExpand(cmd_text, &words_buf, &word_count);
        if (word_count == 0) return "";
        const cmd_name = words_buf[0];
        const args = words_buf[1..word_count];

        // Check unsupported constructs
        if (unsupported_constructs.get(cmd_name) != null) {
            std.debug.print("Unsupported Tcl construct '{s}'\n", .{cmd_name});
            return error.UnsupportedConstruct;
        }

        return switch (command_map.get(cmd_name) orelse return self.handleUnknown(cmd_name, args)) {
            .set => self.execSet(args),
            .append_ => self.execAppend(args),
            .lappend => self.execLappend(args),
            .if_ => self.execIf(cmd_text),
            .expr => self.execExpr(args),
            .source => self.execSource(args),
            .file => self.execFileCmd(args),
            .info => self.execInfoCmd(args),
            .string_ => self.execStringCmd(args),
            .puts => "",  // no-op
            .return_ => if (args.len > 0) args[0] else "",
            .unset => blk: { if (args.len > 0) _ = self.variables.fetchRemove(args[0]); break :blk ""; },
            .proc_ => self.execProc(cmd_text),
            .catch_ => self.execCatch(cmd_text),
        };
    }

    fn handleUnknown(self: *Evaluator, cmd_name: []const u8, args: []const []const u8) EvalError![]const u8 {
        // Check for user-defined proc
        if (self.procs.get(cmd_name)) |proc_def| {
            return self.callProc(proc_def, args);
        }
        return if (args.len > 0) args[args.len - 1] else "";
    }

    /// Register a user-defined Tcl proc: `proc name {args} {body}`
    fn execProc(self: *Evaluator, full_cmd: []const u8) EvalError![]const u8 {
        // Parse: proc name {arg_list} {body}
        var blocks_buf: [32][]const u8 = undefined;
        var block_count: usize = 0;
        commands.parseBlocks(full_cmd, &blocks_buf, &block_count);
        // blocks_buf: ["proc", name, arg_list, body]
        if (block_count < 4) return "";
        const name = blocks_buf[1];
        const arg_list = blocks_buf[2];
        const body = blocks_buf[3];

        // Parse arg_list (space-separated names)
        const aa = self.arena.allocator();
        var arg_names: std.ArrayListUnmanaged([]const u8) = .{};
        var toks = std.mem.tokenizeAny(u8, arg_list, " \t\n\r");
        while (toks.next()) |tok| {
            arg_names.append(aa, self.dupeStr(tok)) catch return error.OutOfMemory;
        }

        self.procs.put(self.backing, self.dupeStr(name), .{
            .arg_names = (arg_names.toOwnedSlice(aa) catch return error.OutOfMemory),
            .body = self.dupeStr(body),
        }) catch return error.OutOfMemory;
        return "";
    }

    /// Execute `catch script ?varName?` — evaluate script, return "0" on
    /// success (and optionally set varName to the result) or "1" on error.
    fn execCatch(self: *Evaluator, full_cmd: []const u8) EvalError![]const u8 {
        // Parse: catch {script} ?varName?
        var blocks_buf: [32][]const u8 = undefined;
        var block_count: usize = 0;
        commands.parseBlocks(full_cmd, &blocks_buf, &block_count);
        // blocks_buf: ["catch", script, ?varName?]
        if (block_count < 2) return "1";
        const script = blocks_buf[1];
        const var_name: ?[]const u8 = if (block_count >= 3) blocks_buf[2] else null;

        const result = self.evalScript(script) catch {
            // Script raised an error — return "1"
            return "1";
        };
        // Script succeeded — optionally store result in varName
        if (var_name) |vn| {
            self.setVar(vn, result) catch {};
        }
        return "0";
    }

    /// Call a user-defined proc: bind formal args to actual args, evaluate body,
    /// then restore previous variable state.
    fn callProc(self: *Evaluator, proc_def: ProcDef, actual_args: []const []const u8) EvalError![]const u8 {
        // Save current values of formal arg names (so we can restore)
        const aa = self.arena.allocator();
        const saved = aa.alloc(?[]const u8, proc_def.arg_names.len) catch return error.OutOfMemory;
        for (proc_def.arg_names, 0..) |arg_name, idx| {
            saved[idx] = self.getVar(arg_name);
        }
        // Bind actual args to formal names
        for (proc_def.arg_names, 0..) |arg_name, idx| {
            const val = if (idx < actual_args.len) actual_args[idx] else "";
            self.setVar(arg_name, val) catch {};
        }
        // Evaluate the body
        const result = self.evalScript(proc_def.body) catch |err| {
            // Restore saved vars on error
            for (proc_def.arg_names, 0..) |arg_name, idx| {
                if (saved[idx]) |sv| {
                    self.setVar(arg_name, sv) catch {};
                } else {
                    _ = self.variables.fetchRemove(arg_name);
                }
            }
            return err;
        };
        // Restore saved vars
        for (proc_def.arg_names, 0..) |arg_name, idx| {
            if (saved[idx]) |sv| {
                self.setVar(arg_name, sv) catch {};
            } else {
                _ = self.variables.fetchRemove(arg_name);
            }
        }
        return result;
    }

    fn execSet(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        if (args.len == 0) return error.InvalidArgCount;
        if (args.len == 1) return self.getVar(args[0]) orelse error.UndefinedVariable;
        try self.setVar(args[0], args[1]);
        return args[1];
    }

    fn execAppend(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        if (args.len < 2) return error.InvalidArgCount;
        const existing = self.getVar(args[0]) orelse "";
        const aa = self.arena.allocator();
        const new_val = std.mem.concat(aa, u8, &.{ existing, args[1] }) catch return error.OutOfMemory;
        try self.setVar(args[0], new_val);
        return new_val;
    }

    fn execLappend(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        if (args.len < 2) return error.InvalidArgCount;
        const existing = self.getVar(args[0]) orelse "";
        const aa = self.arena.allocator();
        var parts: std.ArrayListUnmanaged([]const u8) = .{};
        if (existing.len > 0) parts.append(aa, existing) catch return error.OutOfMemory;
        for (args[1..]) |a| parts.append(aa, a) catch return error.OutOfMemory;
        const joined = std.mem.join(aa, " ", parts.items) catch return error.OutOfMemory;
        try self.setVar(args[0], joined);
        return joined;
    }

    fn execIf(self: *Evaluator, full_cmd: []const u8) EvalError![]const u8 {
        // Parse if {cond} {body} ?elseif {cond} {body}? ?else {body}?
        var blocks_buf: [32][]const u8 = undefined;
        var block_count: usize = 0;
        commands.parseBlocks(full_cmd, &blocks_buf, &block_count);
        // blocks_buf: [if_word, cond, body, elseif?, cond?, body?, else?, body?]
        var i: usize = 1; // skip "if" keyword
        while (i < block_count) {
            const token = blocks_buf[i];
            if (std.mem.eql(u8, token, "elseif")) { i += 1; continue; }
            if (std.mem.eql(u8, token, "then")) { i += 1; continue; }
            if (std.mem.eql(u8, token, "else")) {
                i += 1;
                if (i < block_count) return self.evalScript(blocks_buf[i]);
                return "";
            }
            // condition + body pair
            if (i + 1 >= block_count) return "";
            const cond = blocks_buf[i];
            i += 1;
            // Skip optional "then"
            if (i < block_count and std.mem.eql(u8, blocks_buf[i], "then")) i += 1;
            if (i >= block_count) return "";
            const body = blocks_buf[i];
            i += 1;
            if (try self.evalCondition(cond)) return self.evalScript(body);
        }
        return "";
    }

    fn execExpr(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        if (args.len == 0) return "0";
        const input = if (args.len == 1) args[0] else blk: {
            break :blk std.mem.join(self.arena.allocator(), " ", args) catch return error.OutOfMemory;
        };
        const lookup_var_ctx = LookupCtx{ .ev = self };
        const result = expr_mod.evalExpr(input, lookup_var_ctx.varFn(), lookup_var_ctx.envFn(), null) catch {
            return "0";
        };
        return self.resultToStr(result);
    }

    fn execSource(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        if (args.len == 0) return error.InvalidArgCount;
        const path = args[0];
        // Loop guard
        if (self.source_visited.get(path) != null) return "";
        self.source_visited.put(self.backing, self.dupeStr(path), {}) catch return error.OutOfMemory;
        const contents = commands.readSourceFile(path, self.arena.allocator()) orelse {
            std.debug.print("Warning: source file not found: {s}\n", .{path});
            return "";
        };
        const prev_path = self.script_path;
        self.script_path = self.dupeStr(path);
        defer self.script_path = prev_path;
        return self.evalScript(contents);
    }

    fn execFileCmd(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        return commands.execFile(args, self.arena.allocator()) catch |e| switch (e) {
            error.InvalidArgCount => return error.InvalidArgCount,
            error.UnknownSubcommand => return error.UnknownSubcommand,
            error.OutOfMemory => return error.OutOfMemory,
            else => return "",
        };
    }

    fn execInfoCmd(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        const var_fn = struct {
            fn f(ev: *const Evaluator) *const fn ([]const u8) bool {
                const S = struct {
                    var captured: *const Evaluator = undefined;
                    fn check(name: []const u8) bool { return captured.getVar(name) != null; }
                };
                S.captured = ev;
                return &S.check;
            }
        }.f(self);
        return commands.execInfo(args, var_fn, self.script_path) catch |e| switch (e) {
            error.InvalidArgCount => return error.InvalidArgCount,
            error.UnknownSubcommand => return error.UnknownSubcommand,
            else => return "",
        };
    }

    fn execStringCmd(self: *Evaluator, args: []const []const u8) EvalError![]const u8 {
        return commands.execString(args, self.arena.allocator()) catch |e| switch (e) {
            error.InvalidArgCount => return error.InvalidArgCount,
            error.UnknownSubcommand => return error.UnknownSubcommand,
            error.OutOfMemory => return error.OutOfMemory,
            else => return "",
        };
    }

    fn evalCondition(self: *Evaluator, cond: []const u8) EvalError!bool {
        const t = std.mem.trim(u8, cond, " \t\r\n");
        if (t.len == 0) return false;
        if (std.mem.eql(u8, t, "1") or std.ascii.eqlIgnoreCase(t, "true")) return true;
        if (std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "false")) return false;
        // Try as expression
        const lookup = LookupCtx{ .ev = self };
        const bracket_fn = struct {
            var captured: *Evaluator = undefined;
            fn eval(cmd: []const u8) ?[]const u8 {
                return captured.evalScript(cmd) catch null;
            }
        };
        bracket_fn.captured = self;
        const result = expr_mod.evalExpr(t, lookup.varFn(), lookup.envFn(), &bracket_fn.eval) catch return false;
        return result.asBool();
    }

    fn resultToStr(self: *Evaluator, result: expr_mod.ExprResult) []const u8 {
        const aa = self.arena.allocator();
        return switch (result) {
            .integer => |i| std.fmt.allocPrint(aa, "{d}", .{i}) catch "0",
            .float => |f| formatTclFloat(aa, f),
            .boolean => |b| if (b) "1" else "0",
            .string => |s| s,
        };
    }

    /// Format a float value similarly to Tcl's Tcl_PrintDouble (%.17g).
    /// Uses scientific notation for very small or very large values,
    /// and plain decimal otherwise.
    fn formatTclFloat(aa: std.mem.Allocator, f: f64) []const u8 {
        // Use Zig's '{e}' (scientific) vs '{d}' (decimal) based on magnitude,
        // matching C's %g behavior (scientific when exp < -4 or exp >= 17).
        const abs = @abs(f);
        if (f == 0.0) return "0.0";
        if (abs < 1e-4 or abs >= 1e17) {
            // Scientific notation — format similarly to Tcl's %.17g
            // Zig's {e} produces e.g. "5.0e-14"; we want "5.000000000000001e-14"
            // Use a buffer approach with Zig's standard fmt
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{e}", .{f}) catch return "0";
            return aa.dupe(u8, s) catch "0";
        }
        return std.fmt.allocPrint(aa, "{d}", .{f}) catch "0";
    }

    fn parseAndExpand(self: *Evaluator, src: []const u8, buf: *[64][]const u8, count: *usize) EvalError!void {
        count.* = 0;
        var i: usize = 0;
        while (i < src.len and count.* < 64) {
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
            if (i >= src.len) break;
            if (src[i] == '{') {
                const end = commands.findMatchingBrace(src, i) catch return error.Unbalanced;
                buf[count.*] = src[i + 1 .. end];
                count.* += 1;
                i = end + 1;
            } else if (src[i] == '"') {
                i += 1;
                const start = i;
                while (i < src.len and src[i] != '"') {
                    if (src[i] == '\\' and i + 1 < src.len) i += 1;
                    i += 1;
                }
                const raw = src[start..i];
                buf[count.*] = try self.substitute(raw);
                count.* += 1;
                if (i < src.len) i += 1;
            } else {
                const start = i;
                var brace_depth: usize = 0;
                var bracket_depth: usize = 0;
                while (i < src.len) {
                    if (src[i] == '{') { brace_depth += 1; i += 1; continue; }
                    if (src[i] == '}' and brace_depth > 0) { brace_depth -= 1; i += 1; continue; }
                    if (src[i] == '[') { bracket_depth += 1; i += 1; continue; }
                    if (src[i] == ']' and bracket_depth > 0) { bracket_depth -= 1; i += 1; continue; }
                    if (src[i] == '\\' and i + 1 < src.len) { i += 2; continue; }
                    if ((src[i] == ' ' or src[i] == '\t') and brace_depth == 0 and bracket_depth == 0) break;
                    i += 1;
                }
                buf[count.*] = try self.substitute(src[start..i]);
                count.* += 1;
            }
        }
    }

    fn substitute(self: *Evaluator, src: []const u8) EvalError![]const u8 {
        // Fast path: no substitution chars
        if (std.mem.indexOfAny(u8, src, "$[\\") == null) return src;
        const aa = self.arena.allocator();
        var out: std.ArrayListUnmanaged(u8) = .{};
        var i: usize = 0;
        while (i < src.len) {
            if (src[i] == '\\' and i + 1 < src.len) {
                const n = src[i + 1];
                const ch: u8 = switch (n) { 'n' => '\n', 't' => '\t', else => n };
                out.append(aa, ch) catch return error.OutOfMemory;
                i += 2; continue;
            }
            if (src[i] == '$') {
                i += 1;
                if (i < src.len and src[i] == '{') {
                    i += 1;
                    const ns = i;
                    while (i < src.len and src[i] != '}') i += 1;
                    const val = self.getVar(src[ns..i]) orelse return error.UndefinedVariable;
                    out.appendSlice(aa, val) catch return error.OutOfMemory;
                    if (i < src.len) i += 1;
                } else if (i < src.len and src[i] == ':' and i + 1 < src.len and src[i + 1] == ':') {
                    i += 2;
                    const ns = i - 2;
                    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_' or src[i] == ':')) i += 1;
                    const val = self.getVar(src[ns..i]) orelse return error.UndefinedVariable;
                    out.appendSlice(aa, val) catch return error.OutOfMemory;
                } else {
                    const ns = i;
                    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
                    const name = src[ns..i];
                    if (i < src.len and src[i] == '(' and std.mem.eql(u8, name, "env")) {
                        i += 1;
                        const es = i;
                        while (i < src.len and src[i] != ')') i += 1;
                        const env_val = std.posix.getenv(src[es..i]) orelse return error.UndefinedVariable;
                        out.appendSlice(aa, env_val) catch return error.OutOfMemory;
                        if (i < src.len) i += 1;
                    } else {
                        const val = self.getVar(name) orelse return error.UndefinedVariable;
                        out.appendSlice(aa, val) catch return error.OutOfMemory;
                    }
                }
                continue;
            }
            if (src[i] == '[') {
                const end = commands.findMatchingBracket(src, i) catch return error.Unbalanced;
                const inner = src[i + 1 .. end];
                const result = try self.evalScript(inner);
                out.appendSlice(aa, result) catch return error.OutOfMemory;
                i = end + 1; continue;
            }
            out.append(aa, src[i]) catch return error.OutOfMemory;
            i += 1;
        }
        return out.items;
    }

    fn dupeStr(self: *Evaluator, s: []const u8) []const u8 {
        return self.arena.allocator().dupe(u8, s) catch s;
    }
};

const LookupCtx = struct {
    ev: *const Evaluator,
    fn varFn(self: LookupCtx) expr_mod.LookupFn {
        const S = struct {
            var captured: *const Evaluator = undefined;
            fn lookup(name: []const u8) ?[]const u8 { return captured.getVar(name); }
        };
        S.captured = self.ev;
        return &S.lookup;
    }
    fn envFn(_: LookupCtx) expr_mod.LookupFn {
        const S = struct {
            fn lookup(name: []const u8) ?[]const u8 { return std.posix.getenv(name); }
        };
        return &S.lookup;
    }
};
