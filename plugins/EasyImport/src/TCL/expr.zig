const std = @import("std");

pub const ExprResult = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
    boolean: bool,

    pub fn asBool(self: ExprResult) bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0 and !std.mem.eql(u8, s, "0") and
                !std.ascii.eqlIgnoreCase(s, "false"),
        };
    }

    pub fn asFloat(self: ExprResult) f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .boolean => |b| if (b) 1.0 else 0.0,
            .string => |s| std.fmt.parseFloat(f64, s) catch 0.0,
        };
    }

    pub fn asString(self: ExprResult) []const u8 {
        return switch (self) {
            .string => |s| s,
            else => "",
        };
    }
};

pub const EvalError = error{ InvalidExpression, DivisionByZero, UnterminatedString, UnmatchedParen, UndefinedVariable };

pub const LookupFn = *const fn (name: []const u8) ?[]const u8;
pub const BracketFn = *const fn (cmd: []const u8) ?[]const u8;

pub fn evalExpr(
    source: []const u8,
    lookup_var: LookupFn,
    lookup_env: LookupFn,
    eval_bracket: ?BracketFn,
) EvalError!ExprResult {
    var p = ExprParser{
        .src = source,
        .pos = 0,
        .lookup_var = lookup_var,
        .lookup_env = lookup_env,
        .eval_bracket = eval_bracket,
    };
    return p.parseOr();
}

const ExprParser = struct {
    src: []const u8,
    pos: usize,
    lookup_var: LookupFn,
    lookup_env: LookupFn,
    eval_bracket: ?BracketFn,

    fn parseOr(self: *ExprParser) EvalError!ExprResult {
        var lhs = try self.parseAnd();
        while (true) {
            self.skipWs();
            if (self.match("||")) {
                const rhs = try self.parseAnd();
                lhs = .{ .boolean = lhs.asBool() or rhs.asBool() };
            } else break;
        }
        return lhs;
    }

    fn parseAnd(self: *ExprParser) EvalError!ExprResult {
        var lhs = try self.parseEquality();
        while (true) {
            self.skipWs();
            if (self.match("&&")) {
                const rhs = try self.parseEquality();
                lhs = .{ .boolean = lhs.asBool() and rhs.asBool() };
            } else break;
        }
        return lhs;
    }

    fn parseEquality(self: *ExprParser) EvalError!ExprResult {
        var lhs = try self.parseComparison();
        while (true) {
            self.skipWs();
            if (self.match("==")) {
                const rhs = try self.parseComparison();
                lhs = .{ .boolean = lhs.asFloat() == rhs.asFloat() };
            } else if (self.match("!=")) {
                const rhs = try self.parseComparison();
                lhs = .{ .boolean = lhs.asFloat() != rhs.asFloat() };
            } else if (self.matchWord("eq")) {
                const rhs = try self.parseComparison();
                lhs = .{ .boolean = strEq(lhs, rhs) };
            } else if (self.matchWord("ne")) {
                const rhs = try self.parseComparison();
                lhs = .{ .boolean = !strEq(lhs, rhs) };
            } else break;
        }
        return lhs;
    }

    fn parseComparison(self: *ExprParser) EvalError!ExprResult {
        var lhs = try self.parseAdditive();
        while (true) {
            self.skipWs();
            if (self.match("<=")) {
                const rhs = try self.parseAdditive();
                lhs = .{ .boolean = lhs.asFloat() <= rhs.asFloat() };
            } else if (self.match(">=")) {
                const rhs = try self.parseAdditive();
                lhs = .{ .boolean = lhs.asFloat() >= rhs.asFloat() };
            } else if (self.matchChar('<')) {
                const rhs = try self.parseAdditive();
                lhs = .{ .boolean = lhs.asFloat() < rhs.asFloat() };
            } else if (self.matchChar('>')) {
                const rhs = try self.parseAdditive();
                lhs = .{ .boolean = lhs.asFloat() > rhs.asFloat() };
            } else break;
        }
        return lhs;
    }

    fn parseAdditive(self: *ExprParser) EvalError!ExprResult {
        var lhs = try self.parseMultiplicative();
        while (true) {
            self.skipWs();
            if (self.matchChar('+')) {
                const rhs = try self.parseMultiplicative();
                const lf: f64 = lhs.asFloat();
                const rf: f64 = rhs.asFloat();
                lhs = .{ .float = lf + rf };
            } else if (self.pos < self.src.len and self.src[self.pos] == '-') {
                self.pos += 1;
                const rhs = try self.parseMultiplicative();
                const lf: f64 = lhs.asFloat();
                const rf: f64 = rhs.asFloat();
                lhs = .{ .float = lf - rf };
            } else break;
        }
        return lhs;
    }

    fn parseMultiplicative(self: *ExprParser) EvalError!ExprResult {
        var lhs = try self.parseUnary();
        while (true) {
            self.skipWs();
            if (self.matchChar('*')) {
                const rhs = try self.parseUnary();
                const lf: f64 = lhs.asFloat();
                const rf: f64 = rhs.asFloat();
                lhs = .{ .float = lf * rf };
            } else if (self.matchChar('/')) {
                const rhs = try self.parseUnary();
                const rf: f64 = rhs.asFloat();
                if (rf == 0.0) return error.DivisionByZero;
                const lf: f64 = lhs.asFloat();
                lhs = .{ .float = lf / rf };
            } else if (self.matchChar('%')) {
                const rhs = try self.parseUnary();
                const rf: f64 = rhs.asFloat();
                if (rf == 0.0) return error.DivisionByZero;
                const lf: f64 = lhs.asFloat();
                lhs = .{ .float = @mod(lf, rf) };
            } else break;
        }
        return lhs;
    }

    fn parseUnary(self: *ExprParser) EvalError!ExprResult {
        self.skipWs();
        if (self.matchChar('!')) {
            const v = try self.parseUnary();
            return .{ .boolean = !v.asBool() };
        }
        if (self.matchChar('-')) {
            const v = try self.parseUnary();
            return .{ .float = -v.asFloat() };
        }
        if (self.matchChar('+')) {
            return self.parseUnary();
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ExprParser) EvalError!ExprResult {
        self.skipWs();
        if (self.pos >= self.src.len) return .{ .integer = 0 };
        const c = self.src[self.pos];
        if (c == '(') return self.parseParen();
        if (c == '[') return self.parseBracketCmd();
        if (c == '$') return self.parseVarRef();
        if (c == '"') return self.parseQuotedStr();
        if (c == '{') return self.parseBracedStr();
        const ident = self.parseIdent();
        if (ident.len == 0) return .{ .integer = 0 };
        if (std.ascii.eqlIgnoreCase(ident, "true")) return self.maybeTernary(.{ .boolean = true });
        if (std.ascii.eqlIgnoreCase(ident, "false")) return self.maybeTernary(.{ .boolean = false });
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            self.pos += 1;
            const arg = try self.parseOr();
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
            return self.maybeTernary(applyFunc(ident, arg));
        }
        return self.maybeTernary(parseValue(ident));
    }

    fn parseParen(self: *ExprParser) EvalError!ExprResult {
        self.pos += 1;
        const v = try self.parseOr();
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
        return self.maybeTernary(v);
    }

    fn parseBracketCmd(self: *ExprParser) EvalError!ExprResult {
        self.pos += 1;
        const start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.src.len and depth > 0) {
            if (self.src[self.pos] == '[') depth += 1;
            if (self.src[self.pos] == ']') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const inner = self.src[start..self.pos];
        if (self.pos < self.src.len) self.pos += 1;
        if (self.eval_bracket) |eval_fn| {
            if (eval_fn(inner)) |result| {
                if (std.fmt.parseInt(i64, result, 10)) |i| return self.maybeTernary(.{ .integer = i }) else |_| {}
                if (std.fmt.parseFloat(f64, result)) |f| return self.maybeTernary(.{ .float = f }) else |_| {}
                return self.maybeTernary(.{ .string = result });
            }
        }
        return self.maybeTernary(.{ .string = inner });
    }

    fn parseVarRef(self: *ExprParser) EvalError!ExprResult {
        self.pos += 1;
        if (self.pos < self.src.len and self.src[self.pos] == '{') {
            self.pos += 1;
            const ns = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '}') self.pos += 1;
            const name = self.src[ns..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            const val = self.lookup_var(name) orelse return error.UndefinedVariable;
            return self.maybeTernary(parseValue(val));
        }
        const ns = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
            self.pos += 1;
        const name = self.src[ns..self.pos];
        if (self.pos < self.src.len and self.src[self.pos] == '(' and std.mem.eql(u8, name, "env")) {
            self.pos += 1;
            const es = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != ')') self.pos += 1;
            const env_name = self.src[es..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            const val = self.lookup_env(env_name) orelse return error.UndefinedVariable;
            return self.maybeTernary(parseValue(val));
        }
        const val = self.lookup_var(name) orelse return error.UndefinedVariable;
        return self.maybeTernary(parseValue(val));
    }

    fn parseQuotedStr(self: *ExprParser) EvalError!ExprResult {
        self.pos += 1;
        const ss = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '"') {
            if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) self.pos += 1;
            self.pos += 1;
        }
        const s = self.src[ss..self.pos];
        if (self.pos < self.src.len) self.pos += 1;
        return self.maybeTernary(.{ .string = s });
    }

    fn parseBracedStr(self: *ExprParser) EvalError!ExprResult {
        self.pos += 1;
        const ss = self.pos;
        var depth: usize = 1;
        while (self.pos < self.src.len and depth > 0) {
            if (self.src[self.pos] == '{') depth += 1;
            if (self.src[self.pos] == '}') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const s = self.src[ss..self.pos];
        if (self.pos < self.src.len) self.pos += 1;
        return self.maybeTernary(.{ .string = s });
    }

    fn maybeTernary(self: *ExprParser, cond: ExprResult) EvalError!ExprResult {
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '?') {
            self.pos += 1;
            const then_val = try self.parseOr();
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ':') {
                self.pos += 1;
            }
            const else_val = try self.parseOr();
            return if (cond.asBool()) then_val else else_val;
        }
        return cond;
    }

    fn parseIdent(self: *ExprParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':') {
                self.pos += 1;
            } else if ((ch == '-' or ch == '+') and self.pos > start) {
                // Allow '-' or '+' as part of scientific notation exponent (e.g., 1e-4, 0.5E+3).
                const prev = self.src[self.pos - 1];
                if ((prev == 'e' or prev == 'E') and self.pos + 1 < self.src.len and
                    std.ascii.isDigit(self.src[self.pos + 1]))
                {
                    self.pos += 1;
                } else break;
            } else break;
        }
        return self.src[start..self.pos];
    }

    fn skipWs(self: *ExprParser) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or
            self.src[self.pos] == '\n' or self.src[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    fn match(self: *ExprParser, tok: []const u8) bool {
        if (self.pos + tok.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos..][0..tok.len], tok)) return false;
        self.pos += tok.len;
        return true;
    }

    fn matchChar(self: *ExprParser, ch: u8) bool {
        if (self.pos < self.src.len and self.src[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn matchWord(self: *ExprParser, word: []const u8) bool {
        if (self.pos + word.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos..][0..word.len], word)) return false;
        // Must be followed by non-alphanumeric to be a word boundary
        const after = self.pos + word.len;
        if (after < self.src.len and (std.ascii.isAlphanumeric(self.src[after]) or self.src[after] == '_')) {
            return false;
        }
        self.pos += word.len;
        return true;
    }

};

fn parseValue(s: []const u8) ExprResult {
    if (std.fmt.parseInt(i64, s, 10)) |i| return .{ .integer = i } else |_| {}
    if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
    return .{ .string = s };
}

fn strEq(a: ExprResult, b: ExprResult) bool {
    const sa = resolveStr(a);
    const sb = resolveStr(b);
    return std.mem.eql(u8, sa, sb);
}

fn resolveStr(v: ExprResult) []const u8 {
    return switch (v) {
        .string => |s| s,
        .boolean => |b| if (b) "1" else "0",
        .integer => "?int",
        .float => "?float",
    };
}

fn applyFunc(name: []const u8, arg: ExprResult) ExprResult {
    const v = arg.asFloat();
    const map = std.StaticStringMap(enum { int, abs, round, ceil, floor, passthrough, sqrt, exp_ }).initComptime(.{
        .{ "int", .int },       .{ "entier", .int },
        .{ "abs", .abs },       .{ "round", .round },
        .{ "ceil", .ceil },     .{ "floor", .floor },
        .{ "double", .passthrough }, .{ "wide", .passthrough },
        .{ "sqrt", .sqrt },     .{ "exp", .exp_ },
    });
    return switch (map.get(name) orelse return arg) {
        .int => .{ .integer = @intFromFloat(@trunc(v)) },
        .abs => .{ .float = @abs(v) },
        .round => .{ .float = @round(v) },
        .ceil => .{ .float = @ceil(v) },
        .floor => .{ .float = @floor(v) },
        .passthrough => .{ .float = v },
        .sqrt => .{ .float = @sqrt(v) },
        .exp_ => .{ .float = @exp(v) },
    };
}

// Tests are in test/test_tcl.zig

fn dummyLookup(_: []const u8) ?[]const u8 { return null; }

test "arithmetic with scientific notation" {
    // Verify integer * float gives correct results
    const r1 = try evalExpr("1200*1e-4", &dummyLookup, &dummyLookup, null);
    try std.testing.expectApproxEqRel(@as(f64, 0.12), r1.asFloat(), 1e-10);

    // Full calc_rc expression: 1200 * L / W with L=1e-4, W=0.5e-6
    const r2 = try evalExpr("1200*1e-4/0.5e-6", &dummyLookup, &dummyLookup, null);
    try std.testing.expectApproxEqRel(@as(f64, 240000.0), r2.asFloat(), 1e-10);

    // Cap expression: 1e-3 * W * L
    const r3 = try evalExpr("1e-3*0.5e-6*1e-4", &dummyLookup, &dummyLookup, null);
    try std.testing.expectApproxEqRel(@as(f64, 5e-14), r3.asFloat(), 1e-10);
}
