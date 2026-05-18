const std = @import("std");
const dvui = @import("dvui");
const tc = @import("theme_config");

const Font = dvui.Font;
const Color = dvui.Color;
const Rect = dvui.Rect;

// ── AST ───────────────────────────────────────────────────────────────────────

const FontVariant = enum { italic, roman, bold, monospace, blackboard, calligraphic };

const AccentKind = enum {
    hat, // \hat  → ̂
    bar, // \bar  → ̄
    vec, // \vec  → ⃗
    dot, // \dot  → ̇
    ddot, // \ddot → ̈
    tilde, // \tilde → ̃
    breve, // \breve → ̆
    check, // \check → ̌
    acute, // \acute → ́
    grave, // \grave → ̀
    overline, // \overline → top border
    underline, // \underline → bottom border
};

const DelimKind = enum { paren, bracket, brace, vert, double_vert, angle, ceil, floor, none };

const Node = union(enum) {
    text: []const u8,
    frac: struct { num: []const Node, den: []const Node },
    dfrac: struct { num: []const Node, den: []const Node },
    sqrt: struct { index: ?[]const Node, body: []const Node },
    sup: []const Node,
    sub: []const Node,
    subsup: struct { sub: []const Node, sup: []const Node },
    group: []const Node,
    font_variant: struct { variant: FontVariant, children: []const Node },
    accent: struct { kind: AccentKind, children: []const Node },
    operator: []const u8, // sin, cos, lim — upright
    binom: struct { top: []const Node, bot: []const Node },
    matrix: struct { rows: []const []const []const Node, delim: DelimKind },
    cases: []const []const []const Node, // rows of columns
    space: f32, // multiplier of base_size
    delimited: struct { left: DelimKind, right: DelimKind, body: []const Node },
    phantom: []const Node, // invisible but takes space
    color_node: struct { r: u8, g: u8, b: u8, children: []const Node },
    stackrel: struct { top: []const Node, bot: []const Node },
    overset: struct { over: []const Node, base: []const Node },
    underset: struct { under: []const Node, base: []const Node },
};

// ── Parser ────────────────────────────────────────────────────────────────────

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn parse(self: *Parser) []const Node {
        return self.parseUntil(0);
    }

    fn parseUntil(self: *Parser, stop: u8) []const Node {
        var nodes = std.ArrayListUnmanaged(Node){};
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '}') break;
            if (stop == '&' and self.src[self.pos] == '&') break;
            if (stop == '\\' and self.pos + 1 < self.src.len and
                self.src[self.pos] == '\\' and self.src[self.pos + 1] == '\\') break;
            if (self.parseNode()) |node| {
                // Attach trailing ^ and _ to previous node as subsup
                if (nodes.items.len > 0) {
                    const last = &nodes.items[nodes.items.len - 1];
                    _ = last;
                }
                nodes.append(self.arena, node) catch {};
            }
        }
        return nodes.toOwnedSlice(self.arena) catch &.{};
    }

    fn parseNode(self: *Parser) ?Node {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];

        if (c == '\\') return self.parseCommand();
        if (c == '{') return self.parseGroup();
        if (c == '^') {
            self.pos += 1;
            return .{ .sup = self.parseSingleOrGroup() };
        }
        if (c == '_') {
            self.pos += 1;
            return .{ .sub = self.parseSingleOrGroup() };
        }
        if (c == '~') {
            self.pos += 1;
            return .{ .space = 0.33 };
        }
        if (c == ' ') {
            self.pos += 1;
            return .{ .text = "\u{2009}" }; // thin space
        }

        const start = self.pos;
        self.pos += 1;
        return .{ .text = self.src[start..self.pos] };
    }

    fn parseGroup(self: *Parser) Node {
        self.pos += 1; // skip '{'
        const nodes = self.parseUntil(0);
        if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
        return .{ .group = nodes };
    }

    fn parseSingleOrGroup(self: *Parser) []const Node {
        if (self.pos >= self.src.len) return &.{};
        if (self.src[self.pos] == '{') {
            self.pos += 1;
            const nodes = self.parseUntil(0);
            if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
            return nodes;
        }
        var nodes = std.ArrayListUnmanaged(Node){};
        if (self.parseNode()) |node| nodes.append(self.arena, node) catch {};
        return nodes.toOwnedSlice(self.arena) catch &.{};
    }

    fn parseCommand(self: *Parser) Node {
        self.pos += 1; // skip '\'
        if (self.pos >= self.src.len) return .{ .text = "\\" };

        // Single-character commands
        const ch = self.src[self.pos];
        switch (ch) {
            ',', ' ' => {
                self.pos += 1;
                return .{ .space = if (ch == ',') 0.17 else 0.33 };
            },
            ';' => {
                self.pos += 1;
                return .{ .space = 0.22 };
            },
            '!' => {
                self.pos += 1;
                return .{ .space = -0.17 };
            },
            '\\' => {
                self.pos += 1;
                return .{ .text = "\n" }; // line break
            },
            '{' => {
                self.pos += 1;
                return .{ .text = "{" };
            },
            '}' => {
                self.pos += 1;
                return .{ .text = "}" };
            },
            '|' => {
                self.pos += 1;
                return .{ .text = "\u{2016}" }; // ‖
            },
            else => {},
        }

        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isAlphabetic(self.src[self.pos])) {
            self.pos += 1;
        }
        const cmd = self.src[start..self.pos];
        if (cmd.len == 0) return .{ .text = "\\" };

        // ── Structures ────────────────────────────────────────────────
        if (std.mem.eql(u8, cmd, "frac")) {
            const num = self.parseSingleOrGroup();
            const den = self.parseSingleOrGroup();
            return .{ .frac = .{ .num = num, .den = den } };
        }
        if (std.mem.eql(u8, cmd, "dfrac")) {
            const num = self.parseSingleOrGroup();
            const den = self.parseSingleOrGroup();
            return .{ .dfrac = .{ .num = num, .den = den } };
        }
        if (std.mem.eql(u8, cmd, "tfrac")) {
            const num = self.parseSingleOrGroup();
            const den = self.parseSingleOrGroup();
            return .{ .frac = .{ .num = num, .den = den } };
        }
        if (std.mem.eql(u8, cmd, "binom") or std.mem.eql(u8, cmd, "dbinom") or
            std.mem.eql(u8, cmd, "tbinom") or std.mem.eql(u8, cmd, "choose"))
        {
            const top = self.parseSingleOrGroup();
            const bot = self.parseSingleOrGroup();
            return .{ .binom = .{ .top = top, .bot = bot } };
        }
        if (std.mem.eql(u8, cmd, "sqrt")) {
            // Check for optional index: \sqrt[n]{x}
            var index: ?[]const Node = null;
            if (self.pos < self.src.len and self.src[self.pos] == '[') {
                self.pos += 1;
                const idx_start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != ']') self.pos += 1;
                const idx_text = self.src[idx_start..self.pos];
                if (self.pos < self.src.len) self.pos += 1; // skip ]
                var idx_nodes = std.ArrayListUnmanaged(Node){};
                idx_nodes.append(self.arena, .{ .text = idx_text }) catch {};
                index = idx_nodes.toOwnedSlice(self.arena) catch null;
            }
            return .{ .sqrt = .{ .index = index, .body = self.parseSingleOrGroup() } };
        }
        if (std.mem.eql(u8, cmd, "stackrel")) {
            const top = self.parseSingleOrGroup();
            const bot = self.parseSingleOrGroup();
            return .{ .stackrel = .{ .top = top, .bot = bot } };
        }
        if (std.mem.eql(u8, cmd, "overset")) {
            const over = self.parseSingleOrGroup();
            const base = self.parseSingleOrGroup();
            return .{ .overset = .{ .over = over, .base = base } };
        }
        if (std.mem.eql(u8, cmd, "underset")) {
            const under = self.parseSingleOrGroup();
            const base = self.parseSingleOrGroup();
            return .{ .underset = .{ .under = under, .base = base } };
        }

        // ── Font variants ─────────────────────────────────────────────
        if (fontVariantFor(cmd)) |variant| {
            return .{ .font_variant = .{ .variant = variant, .children = self.parseSingleOrGroup() } };
        }

        // ── Accents ───────────────────────────────────────────────────
        if (accentFor(cmd)) |kind| {
            return .{ .accent = .{ .kind = kind, .children = self.parseSingleOrGroup() } };
        }

        // ── Operators (upright) ───────────────────────────────────────
        if (isOperator(cmd)) {
            return .{ .operator = cmd };
        }

        // ── Environments ──────────────────────────────────────────────
        if (std.mem.eql(u8, cmd, "begin")) {
            return self.parseEnvironment();
        }

        // ── left/right delimiters ─────────────────────────────────────
        if (std.mem.eql(u8, cmd, "left")) {
            return self.parseLeftRight();
        }
        if (std.mem.eql(u8, cmd, "right")) {
            // Stray \right — shouldn't happen in well-formed LaTeX
            self.skipDelimChar();
            return .{ .text = "" };
        }

        // ── Spacing commands ──────────────────────────────────────────
        if (std.mem.eql(u8, cmd, "quad")) return .{ .space = 1.0 };
        if (std.mem.eql(u8, cmd, "qquad")) return .{ .space = 2.0 };
        if (std.mem.eql(u8, cmd, "enspace")) return .{ .space = 0.5 };
        if (std.mem.eql(u8, cmd, "thinspace")) return .{ .space = 0.17 };
        if (std.mem.eql(u8, cmd, "medspace")) return .{ .space = 0.22 };
        if (std.mem.eql(u8, cmd, "thickspace")) return .{ .space = 0.28 };
        if (std.mem.eql(u8, cmd, "negthinspace")) return .{ .space = -0.17 };
        if (std.mem.eql(u8, cmd, "negmedspace")) return .{ .space = -0.22 };
        if (std.mem.eql(u8, cmd, "negthickspace")) return .{ .space = -0.28 };
        if (std.mem.eql(u8, cmd, "hspace") or std.mem.eql(u8, cmd, "mspace")) {
            _ = self.parseSingleOrGroup(); // consume arg, ignore
            return .{ .space = 0.5 };
        }
        if (std.mem.eql(u8, cmd, "phantom") or std.mem.eql(u8, cmd, "hphantom") or
            std.mem.eql(u8, cmd, "vphantom"))
        {
            return .{ .phantom = self.parseSingleOrGroup() };
        }

        // ── Symbol lookup ─────────────────────────────────────────────
        if (symbolFor(cmd)) |sym| return .{ .text = sym };

        // Unknown — show as-is
        return .{ .text = self.src[start - 1 .. self.pos] };
    }

    fn parseEnvironment(self: *Parser) Node {
        // Expect {envname}
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return .{ .text = "\\begin" };
        self.pos += 1;
        const name_start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '}') self.pos += 1;
        const env_name = self.src[name_start..self.pos];
        if (self.pos < self.src.len) self.pos += 1; // skip }

        if (std.mem.eql(u8, env_name, "cases")) {
            const rows = self.parseMatrixBody();
            self.skipEnd(env_name);
            return .{ .cases = rows };
        }

        // Matrix variants
        const delim: DelimKind = if (std.mem.eql(u8, env_name, "pmatrix"))
            .paren
        else if (std.mem.eql(u8, env_name, "bmatrix"))
            .bracket
        else if (std.mem.eql(u8, env_name, "Bmatrix"))
            .brace
        else if (std.mem.eql(u8, env_name, "vmatrix"))
            .vert
        else if (std.mem.eql(u8, env_name, "Vmatrix"))
            .double_vert
        else
            .none;

        if (std.mem.eql(u8, env_name, "matrix") or
            std.mem.eql(u8, env_name, "pmatrix") or
            std.mem.eql(u8, env_name, "bmatrix") or
            std.mem.eql(u8, env_name, "Bmatrix") or
            std.mem.eql(u8, env_name, "vmatrix") or
            std.mem.eql(u8, env_name, "Vmatrix") or
            std.mem.eql(u8, env_name, "smallmatrix"))
        {
            const rows = self.parseMatrixBody();
            self.skipEnd(env_name);
            return .{ .matrix = .{ .rows = rows, .delim = delim } };
        }

        // align, aligned, gathered — parse as matrix without delims
        if (std.mem.eql(u8, env_name, "align") or
            std.mem.eql(u8, env_name, "aligned") or
            std.mem.eql(u8, env_name, "gathered") or
            std.mem.eql(u8, env_name, "split") or
            std.mem.eql(u8, env_name, "array"))
        {
            // Consume optional column spec for array: {ccc}
            if (self.pos < self.src.len and self.src[self.pos] == '{') {
                while (self.pos < self.src.len and self.src[self.pos] != '}') self.pos += 1;
                if (self.pos < self.src.len) self.pos += 1;
            }
            const rows = self.parseMatrixBody();
            self.skipEnd(env_name);
            return .{ .matrix = .{ .rows = rows, .delim = .none } };
        }

        self.skipEnd(env_name);
        return .{ .text = env_name };
    }

    fn parseMatrixBody(self: *Parser) []const []const []const Node {
        var rows = std.ArrayListUnmanaged([]const []const Node){};
        while (self.pos < self.src.len) {
            // Check for \end
            if (self.peekEnd()) break;

            var cols = std.ArrayListUnmanaged([]const Node){};
            while (self.pos < self.src.len) {
                if (self.peekEnd()) break;
                const cell = self.parseUntil('&');
                cols.append(self.arena, cell) catch {};
                if (self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                } else break;
            }
            rows.append(self.arena, cols.toOwnedSlice(self.arena) catch &.{}) catch {};

            // Skip \\ row separator
            self.skipWhitespace();
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '\\' and self.src[self.pos + 1] == '\\') {
                self.pos += 2;
                self.skipWhitespace();
            }
        }
        return rows.toOwnedSlice(self.arena) catch &.{};
    }

    fn peekEnd(self: *Parser) bool {
        const saved = self.pos;
        self.skipWhitespace();
        if (self.pos + 4 < self.src.len and std.mem.eql(u8, self.src[self.pos..][0..4], "\\end")) {
            self.pos = saved;
            return true;
        }
        self.pos = saved;
        return false;
    }

    fn skipEnd(self: *Parser, env_name: []const u8) void {
        self.skipWhitespace();
        // Skip \end{envname}
        if (self.pos + 4 <= self.src.len and std.mem.eql(u8, self.src[self.pos..][0..4], "\\end")) {
            self.pos += 4;
            if (self.pos < self.src.len and self.src[self.pos] == '{') {
                self.pos += 1;
                self.pos += @min(env_name.len, self.src.len - self.pos);
                if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
            }
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or
            self.src[self.pos] == '\t' or self.src[self.pos] == '\n' or
            self.src[self.pos] == '\r')) self.pos += 1;
    }

    fn parseLeftRight(self: *Parser) Node {
        const left = self.readDelimChar();
        const body = self.parseUntilRight();
        const right = self.readRightDelim();
        return .{ .delimited = .{ .left = left, .right = right, .body = body } };
    }

    fn parseUntilRight(self: *Parser) []const Node {
        var nodes = std.ArrayListUnmanaged(Node){};
        while (self.pos < self.src.len) {
            // Check for \right
            if (self.pos + 5 < self.src.len and std.mem.eql(u8, self.src[self.pos..][0..6], "\\right")) break;
            if (self.src[self.pos] == '}') break;
            if (self.parseNode()) |node| nodes.append(self.arena, node) catch {};
        }
        return nodes.toOwnedSlice(self.arena) catch &.{};
    }

    fn readRightDelim(self: *Parser) DelimKind {
        if (self.pos + 5 < self.src.len and std.mem.eql(u8, self.src[self.pos..][0..6], "\\right")) {
            self.pos += 6;
            return self.readDelimChar();
        }
        return .none;
    }

    fn readDelimChar(self: *Parser) DelimKind {
        if (self.pos >= self.src.len) return .none;
        const c = self.src[self.pos];
        self.pos += 1;
        return switch (c) {
            '(' => .paren,
            ')' => .paren,
            '[' => .bracket,
            ']' => .bracket,
            '|' => .vert,
            '.' => .none,
            '\\' => blk: {
                if (self.pos < self.src.len) {
                    const next = self.src[self.pos];
                    if (next == '{' or next == '}') {
                        self.pos += 1;
                        break :blk .brace;
                    }
                    if (next == '|') {
                        self.pos += 1;
                        break :blk .double_vert;
                    }
                    // \langle, \rangle, \lceil, etc.
                    const ws = self.pos;
                    while (self.pos < self.src.len and std.ascii.isAlphabetic(self.src[self.pos])) self.pos += 1;
                    const dcmd = self.src[ws..self.pos];
                    if (std.mem.eql(u8, dcmd, "langle") or std.mem.eql(u8, dcmd, "rangle")) break :blk .angle;
                    if (std.mem.eql(u8, dcmd, "lceil") or std.mem.eql(u8, dcmd, "rceil")) break :blk .ceil;
                    if (std.mem.eql(u8, dcmd, "lfloor") or std.mem.eql(u8, dcmd, "rfloor")) break :blk .floor;
                    if (std.mem.eql(u8, dcmd, "vert")) break :blk .vert;
                    if (std.mem.eql(u8, dcmd, "Vert")) break :blk .double_vert;
                }
                break :blk .none;
            },
            '<' => .angle,
            '>' => .angle,
            else => .none,
        };
    }

    fn skipDelimChar(self: *Parser) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\\') {
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isAlphabetic(self.src[self.pos])) self.pos += 1;
            } else {
                self.pos += 1;
            }
        }
    }
};

fn fontVariantFor(cmd: []const u8) ?FontVariant {
    const map = .{
        .{ "mathrm", FontVariant.roman },
        .{ "textrm", FontVariant.roman },
        .{ "text", FontVariant.roman },
        .{ "textit", FontVariant.italic },
        .{ "mathit", FontVariant.italic },
        .{ "mathbf", FontVariant.bold },
        .{ "textbf", FontVariant.bold },
        .{ "boldsymbol", FontVariant.bold },
        .{ "bm", FontVariant.bold },
        .{ "mathtt", FontVariant.monospace },
        .{ "texttt", FontVariant.monospace },
        .{ "mathbb", FontVariant.blackboard },
        .{ "mathcal", FontVariant.calligraphic },
        .{ "mathscr", FontVariant.calligraphic },
        .{ "mathfrak", FontVariant.roman }, // approximate
        .{ "operatorname", FontVariant.roman },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) return entry[1];
    }
    return null;
}

fn accentFor(cmd: []const u8) ?AccentKind {
    const map = .{
        .{ "hat", AccentKind.hat },
        .{ "widehat", AccentKind.hat },
        .{ "bar", AccentKind.bar },
        .{ "overline", AccentKind.overline },
        .{ "underline", AccentKind.underline },
        .{ "vec", AccentKind.vec },
        .{ "overrightarrow", AccentKind.vec },
        .{ "dot", AccentKind.dot },
        .{ "ddot", AccentKind.ddot },
        .{ "tilde", AccentKind.tilde },
        .{ "widetilde", AccentKind.tilde },
        .{ "breve", AccentKind.breve },
        .{ "check", AccentKind.check },
        .{ "acute", AccentKind.acute },
        .{ "grave", AccentKind.grave },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) return entry[1];
    }
    return null;
}

fn isOperator(cmd: []const u8) bool {
    const ops = [_][]const u8{
        "sin",    "cos",    "tan",    "cot",    "sec",    "csc",
        "arcsin", "arccos", "arctan", "sinh",   "cosh",   "tanh",
        "coth",   "log",    "ln",     "exp",    "lim",    "limsup",
        "liminf", "sup",    "inf",    "max",    "min",    "arg",
        "deg",    "det",    "dim",    "gcd",    "hom",    "ker",
        "Pr",     "mod",    "bmod",   "pmod",   "sgn",    "tr",
        "diag",   "rank",   "span",   "Re",     "Im",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, cmd, op)) return true;
    }
    return false;
}

fn symbolFor(cmd: []const u8) ?[]const u8 {
    const map = .{
        // ── Greek lowercase ───────────────────────────────────────────
        .{ "alpha", "\u{03B1}" },
        .{ "beta", "\u{03B2}" },
        .{ "gamma", "\u{03B3}" },
        .{ "delta", "\u{03B4}" },
        .{ "epsilon", "\u{03B5}" },
        .{ "varepsilon", "\u{025B}" },
        .{ "zeta", "\u{03B6}" },
        .{ "eta", "\u{03B7}" },
        .{ "theta", "\u{03B8}" },
        .{ "vartheta", "\u{03D1}" },
        .{ "iota", "\u{03B9}" },
        .{ "kappa", "\u{03BA}" },
        .{ "varkappa", "\u{03F0}" },
        .{ "lambda", "\u{03BB}" },
        .{ "mu", "\u{03BC}" },
        .{ "nu", "\u{03BD}" },
        .{ "xi", "\u{03BE}" },
        .{ "omicron", "o" },
        .{ "pi", "\u{03C0}" },
        .{ "varpi", "\u{03D6}" },
        .{ "rho", "\u{03C1}" },
        .{ "varrho", "\u{03F1}" },
        .{ "sigma", "\u{03C3}" },
        .{ "varsigma", "\u{03C2}" },
        .{ "tau", "\u{03C4}" },
        .{ "upsilon", "\u{03C5}" },
        .{ "phi", "\u{03C6}" },
        .{ "varphi", "\u{03D5}" },
        .{ "chi", "\u{03C7}" },
        .{ "psi", "\u{03C8}" },
        .{ "omega", "\u{03C9}" },

        // ── Greek uppercase ───────────────────────────────────────────
        .{ "Gamma", "\u{0393}" },
        .{ "Delta", "\u{0394}" },
        .{ "Theta", "\u{0398}" },
        .{ "Lambda", "\u{039B}" },
        .{ "Xi", "\u{039E}" },
        .{ "Pi", "\u{03A0}" },
        .{ "Sigma", "\u{03A3}" },
        .{ "Upsilon", "\u{03A5}" },
        .{ "Phi", "\u{03A6}" },
        .{ "Psi", "\u{03A8}" },
        .{ "Omega", "\u{03A9}" },

        // ── Binary operators ──────────────────────────────────────────
        .{ "pm", "\u{00B1}" },
        .{ "mp", "\u{2213}" },
        .{ "times", "\u{00D7}" },
        .{ "div", "\u{00F7}" },
        .{ "cdot", "\u{22C5}" },
        .{ "ast", "\u{2217}" },
        .{ "star", "\u{22C6}" },
        .{ "circ", "\u{2218}" },
        .{ "bullet", "\u{2219}" },
        .{ "oplus", "\u{2295}" },
        .{ "ominus", "\u{2296}" },
        .{ "otimes", "\u{2297}" },
        .{ "odot", "\u{2299}" },
        .{ "dagger", "\u{2020}" },
        .{ "ddagger", "\u{2021}" },
        .{ "wedge", "\u{2227}" },
        .{ "vee", "\u{2228}" },
        .{ "cap", "\u{2229}" },
        .{ "cup", "\u{222A}" },
        .{ "sqcap", "\u{2293}" },
        .{ "sqcup", "\u{2294}" },
        .{ "setminus", "\u{2216}" },
        .{ "wr", "\u{2240}" },
        .{ "diamond", "\u{22C4}" },
        .{ "bigtriangleup", "\u{25B3}" },
        .{ "bigtriangledown", "\u{25BD}" },
        .{ "triangleleft", "\u{25C1}" },
        .{ "triangleright", "\u{25B7}" },
        .{ "lhd", "\u{22B2}" },
        .{ "rhd", "\u{22B3}" },
        .{ "amalg", "\u{2A3F}" },

        // ── Relations ─────────────────────────────────────────────────
        .{ "leq", "\u{2264}" },
        .{ "le", "\u{2264}" },
        .{ "geq", "\u{2265}" },
        .{ "ge", "\u{2265}" },
        .{ "neq", "\u{2260}" },
        .{ "ne", "\u{2260}" },
        .{ "approx", "\u{2248}" },
        .{ "equiv", "\u{2261}" },
        .{ "sim", "\u{223C}" },
        .{ "simeq", "\u{2243}" },
        .{ "cong", "\u{2245}" },
        .{ "propto", "\u{221D}" },
        .{ "prec", "\u{227A}" },
        .{ "succ", "\u{227B}" },
        .{ "preceq", "\u{2AAF}" },
        .{ "succeq", "\u{2AB0}" },
        .{ "ll", "\u{226A}" },
        .{ "gg", "\u{226B}" },
        .{ "subset", "\u{2282}" },
        .{ "supset", "\u{2283}" },
        .{ "subseteq", "\u{2286}" },
        .{ "supseteq", "\u{2287}" },
        .{ "sqsubseteq", "\u{2291}" },
        .{ "sqsupseteq", "\u{2292}" },
        .{ "in", "\u{2208}" },
        .{ "notin", "\u{2209}" },
        .{ "ni", "\u{220B}" },
        .{ "vdash", "\u{22A2}" },
        .{ "dashv", "\u{22A3}" },
        .{ "models", "\u{22A8}" },
        .{ "perp", "\u{22A5}" },
        .{ "mid", "\u{2223}" },
        .{ "nmid", "\u{2224}" },
        .{ "parallel", "\u{2225}" },
        .{ "bowtie", "\u{22C8}" },
        .{ "smile", "\u{2323}" },
        .{ "frown", "\u{2322}" },
        .{ "asymp", "\u{224D}" },
        .{ "doteq", "\u{2250}" },

        // ── Negated relations ─────────────────────────────────────────
        .{ "nleq", "\u{2270}" },
        .{ "ngeq", "\u{2271}" },
        .{ "nless", "\u{226E}" },
        .{ "ngtr", "\u{226F}" },
        .{ "nsubseteq", "\u{2288}" },
        .{ "nsupseteq", "\u{2289}" },

        // ── Arrows ────────────────────────────────────────────────────
        .{ "to", "\u{2192}" },
        .{ "rightarrow", "\u{2192}" },
        .{ "leftarrow", "\u{2190}" },
        .{ "leftrightarrow", "\u{2194}" },
        .{ "Rightarrow", "\u{21D2}" },
        .{ "Leftarrow", "\u{21D0}" },
        .{ "Leftrightarrow", "\u{21D4}" },
        .{ "iff", "\u{21D4}" },
        .{ "implies", "\u{21D2}" },
        .{ "uparrow", "\u{2191}" },
        .{ "downarrow", "\u{2193}" },
        .{ "updownarrow", "\u{2195}" },
        .{ "Uparrow", "\u{21D1}" },
        .{ "Downarrow", "\u{21D3}" },
        .{ "Updownarrow", "\u{21D5}" },
        .{ "mapsto", "\u{21A6}" },
        .{ "longmapsto", "\u{27FC}" },
        .{ "longrightarrow", "\u{27F6}" },
        .{ "longleftarrow", "\u{27F5}" },
        .{ "longleftrightarrow", "\u{27F7}" },
        .{ "Longrightarrow", "\u{27F9}" },
        .{ "Longleftarrow", "\u{27F8}" },
        .{ "Longleftrightarrow", "\u{27FA}" },
        .{ "hookrightarrow", "\u{21AA}" },
        .{ "hookleftarrow", "\u{21A9}" },
        .{ "nearrow", "\u{2197}" },
        .{ "searrow", "\u{2198}" },
        .{ "swarrow", "\u{2199}" },
        .{ "nwarrow", "\u{2196}" },
        .{ "rightharpoonup", "\u{21C0}" },
        .{ "rightharpoondown", "\u{21C1}" },
        .{ "leftharpoonup", "\u{21BC}" },
        .{ "leftharpoondown", "\u{21BD}" },
        .{ "rightleftharpoons", "\u{21CC}" },

        // ── Big operators ─────────────────────────────────────────────
        .{ "sum", "\u{2211}" },
        .{ "prod", "\u{220F}" },
        .{ "coprod", "\u{2210}" },
        .{ "int", "\u{222B}" },
        .{ "iint", "\u{222C}" },
        .{ "iiint", "\u{222D}" },
        .{ "oint", "\u{222E}" },
        .{ "oiint", "\u{222F}" },
        .{ "bigcup", "\u{22C3}" },
        .{ "bigcap", "\u{22C2}" },
        .{ "bigsqcup", "\u{2A06}" },
        .{ "bigvee", "\u{22C1}" },
        .{ "bigwedge", "\u{22C0}" },
        .{ "bigoplus", "\u{2A01}" },
        .{ "bigotimes", "\u{2A02}" },
        .{ "bigodot", "\u{2A00}" },

        // ── Delimiters ────────────────────────────────────────────────
        .{ "langle", "\u{27E8}" },
        .{ "rangle", "\u{27E9}" },
        .{ "lceil", "\u{2308}" },
        .{ "rceil", "\u{2309}" },
        .{ "lfloor", "\u{230A}" },
        .{ "rfloor", "\u{230B}" },
        .{ "lbrace", "{" },
        .{ "rbrace", "}" },
        .{ "lbrack", "[" },
        .{ "rbrack", "]" },
        .{ "vert", "|" },
        .{ "Vert", "\u{2016}" },
        .{ "lvert", "|" },
        .{ "rvert", "|" },
        .{ "lVert", "\u{2016}" },
        .{ "rVert", "\u{2016}" },

        // ── Dots ──────────────────────────────────────────────────────
        .{ "ldots", "\u{2026}" },
        .{ "cdots", "\u{22EF}" },
        .{ "vdots", "\u{22EE}" },
        .{ "ddots", "\u{22F1}" },
        .{ "dots", "\u{2026}" },
        .{ "dotsc", "\u{2026}" },
        .{ "dotsb", "\u{22EF}" },
        .{ "dotsm", "\u{22EF}" },
        .{ "dotsi", "\u{22EF}" },

        // ── Misc symbols ──────────────────────────────────────────────
        .{ "infty", "\u{221E}" },
        .{ "partial", "\u{2202}" },
        .{ "nabla", "\u{2207}" },
        .{ "forall", "\u{2200}" },
        .{ "exists", "\u{2203}" },
        .{ "nexists", "\u{2204}" },
        .{ "emptyset", "\u{2205}" },
        .{ "varnothing", "\u{2205}" },
        .{ "neg", "\u{00AC}" },
        .{ "lnot", "\u{00AC}" },
        .{ "surd", "\u{221A}" },
        .{ "top", "\u{22A4}" },
        .{ "bot", "\u{22A5}" },
        .{ "angle", "\u{2220}" },
        .{ "measuredangle", "\u{2221}" },
        .{ "triangle", "\u{25B3}" },
        .{ "backslash", "\\" },
        .{ "prime", "\u{2032}" },
        .{ "dprime", "\u{2033}" },
        .{ "hbar", "\u{210F}" },
        .{ "ell", "\u{2113}" },
        .{ "wp", "\u{2118}" },
        .{ "aleph", "\u{2135}" },
        .{ "beth", "\u{2136}" },
        .{ "gimel", "\u{2137}" },
        .{ "daleth", "\u{2138}" },
        .{ "imath", "\u{0131}" },
        .{ "jmath", "\u{0237}" },
        .{ "clubsuit", "\u{2663}" },
        .{ "diamondsuit", "\u{2662}" },
        .{ "heartsuit", "\u{2661}" },
        .{ "spadesuit", "\u{2660}" },
        .{ "flat", "\u{266D}" },
        .{ "natural", "\u{266E}" },
        .{ "sharp", "\u{266F}" },
        .{ "checkmark", "\u{2713}" },
        .{ "maltese", "\u{2720}" },
        .{ "degree", "\u{00B0}" },
        .{ "Box", "\u{25A1}" },
        .{ "square", "\u{25A1}" },
        .{ "blacksquare", "\u{25A0}" },
        .{ "Diamond", "\u{25C7}" },
        .{ "lozenge", "\u{25CA}" },
        .{ "Star", "\u{2605}" },
        .{ "bigstar", "\u{2605}" },
        .{ "SS", "\u{00A7}" },
        .{ "copyright", "\u{00A9}" },
        .{ "dag", "\u{2020}" },
        .{ "ddag", "\u{2021}" },
        .{ "pounds", "\u{00A3}" },

        // ── Blackboard bold (standalone) ──────────────────────────────
        .{ "N", "\u{2115}" },
        .{ "Z", "\u{2124}" },
        .{ "Q", "\u{211A}" },
        .{ "R", "\u{211D}" },
        .{ "C", "\u{2102}" },

        // ── Logic ─────────────────────────────────────────────────────
        .{ "land", "\u{2227}" },
        .{ "lor", "\u{2228}" },
        .{ "therefore", "\u{2234}" },
        .{ "because", "\u{2235}" },

        // ── No-ops (consume without output) ───────────────────────────
        .{ "left", "" },
        .{ "right", "" },
        .{ "displaystyle", "" },
        .{ "textstyle", "" },
        .{ "scriptstyle", "" },
        .{ "scriptscriptstyle", "" },
        .{ "limits", "" },
        .{ "nolimits", "" },
        .{ "nonumber", "" },
        .{ "notag", "" },
        .{ "label", "" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) return entry[1];
    }
    return null;
}

// ── Rendering ─────────────────────────────────────────────────────────────────

const base_size: f32 = 14;
const min_size: f32 = 8;

fn mathFont(size: f32, variant: FontVariant) Font {
    const sz = @max(size, min_size);
    return switch (variant) {
        .italic => Font.find(.{ .family = "Vera Sans", .size = sz, .style = .italic }),
        .roman => Font.find(.{ .family = "Vera Sans", .size = sz }),
        .bold => Font.find(.{ .family = "Vera Sans", .size = sz, .weight = .bold }),
        .monospace => Font.find(.{ .family = "Vera Sans", .size = sz }),
        .blackboard => Font.find(.{ .family = "Vera Sans", .size = sz, .weight = .bold }),
        .calligraphic => Font.find(.{ .family = "Vera Sans", .size = sz, .style = .italic }),
    };
}

fn mathColor() Color {
    return tc.chromeAccent();
}

fn delimStr(kind: DelimKind, is_left: bool) []const u8 {
    return switch (kind) {
        .paren => if (is_left) "(" else ")",
        .bracket => if (is_left) "[" else "]",
        .brace => if (is_left) "{" else "}",
        .vert => "|",
        .double_vert => "\u{2016}",
        .angle => if (is_left) "\u{27E8}" else "\u{27E9}",
        .ceil => if (is_left) "\u{2308}" else "\u{2309}",
        .floor => if (is_left) "\u{230A}" else "\u{230B}",
        .none => "",
    };
}

fn accentStr(kind: AccentKind) []const u8 {
    return switch (kind) {
        .hat => "\u{0302}",
        .bar => "\u{0304}",
        .vec => "\u{20D7}",
        .dot => "\u{0307}",
        .ddot => "\u{0308}",
        .tilde => "\u{0303}",
        .breve => "\u{0306}",
        .check => "\u{030C}",
        .acute => "\u{0301}",
        .grave => "\u{0300}",
        .overline, .underline => "", // handled structurally
    };
}

pub fn renderInline(latex: []const u8, id_extra: u16) void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var parser = Parser{ .src = latex, .arena = arena };
    const nodes = parser.parse();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
    });
    defer row.deinit();
    renderNodes(nodes, base_size, .italic, id_extra +% 100);
}

pub fn renderDisplay(latex: []const u8, id_extra: u16) void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var parser = Parser{ .src = latex, .arena = arena };
    const nodes = parser.parse();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 8, .w = 16, .h = 8 },
    });
    defer row.deinit();

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = id_extra +% 1 });
    renderNodes(nodes, base_size + 2, .italic, id_extra +% 100);
    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = id_extra +% 2 });
}

fn renderNodes(nodes: []const Node, size: f32, variant: FontVariant, id_base: u16) void {
    for (nodes, 0..) |node, i| {
        const id: u16 = id_base +% @as(u16, @intCast(i & 0xFF)) *% 17;
        renderNode(node, size, variant, id);
    }
}

fn renderNode(node: Node, size: f32, variant: FontVariant, id: u16) void {
    switch (node) {
        .text => |t| {
            if (t.len == 0) return;
            dvui.labelNoFmt(@src(), t, .{}, .{
                .id_extra = id,
                .font = mathFont(size, variant),
                .color_text = mathColor(),
                .gravity_y = 0.5,
            });
        },
        .frac => |f| renderFraction(f.num, f.den, size, variant, id, false),
        .dfrac => |f| renderFraction(f.num, f.den, size, variant, id, true),
        .sqrt => |s| {
            // Optional index
            if (s.index) |idx| {
                var idx_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 50,
                    .gravity_y = 0.0,
                });
                defer idx_box.deinit();
                renderNodes(idx, size - 6, variant, id +% 51);
            }
            dvui.labelNoFmt(@src(), "\u{221A}", .{}, .{
                .id_extra = id,
                .font = mathFont(size, variant),
                .color_text = mathColor(),
                .gravity_y = 0.5,
            });
            var inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = id +% 1,
                .gravity_y = 0.5,
                .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
                .color_border = mathColor(),
                .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
            });
            defer inner.deinit();
            renderNodes(s.body, size, variant, id +% 10);
        },
        .sup => |children| {
            var sup_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = id,
                .gravity_y = 0.0,
            });
            defer sup_box.deinit();
            renderNodes(children, size * 0.7, variant, id +% 10);
        },
        .sub => |children| {
            var sub_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = id,
                .gravity_y = 1.0,
            });
            defer sub_box.deinit();
            renderNodes(children, size * 0.7, variant, id +% 10);
        },
        .subsup => |ss| {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = id,
                .gravity_y = 0.5,
            });
            defer col.deinit();
            {
                var sup_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 1,
                    .gravity_x = 0.5,
                });
                defer sup_row.deinit();
                renderNodes(ss.sup, size * 0.7, variant, id +% 10);
            }
            {
                var sub_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 2,
                    .gravity_x = 0.5,
                });
                defer sub_row.deinit();
                renderNodes(ss.sub, size * 0.7, variant, id +% 20);
            }
        },
        .group => |children| {
            renderNodes(children, size, variant, id +% 10);
        },
        .font_variant => |fv| {
            renderNodes(fv.children, size, fv.variant, id +% 10);
        },
        .accent => |a| {
            switch (a.kind) {
                .overline => {
                    var inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = id,
                        .gravity_y = 0.5,
                        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
                        .color_border = mathColor(),
                        .padding = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
                    });
                    defer inner.deinit();
                    renderNodes(a.children, size, variant, id +% 10);
                },
                .underline => {
                    var inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = id,
                        .gravity_y = 0.5,
                        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                        .color_border = mathColor(),
                        .padding = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
                    });
                    defer inner.deinit();
                    renderNodes(a.children, size, variant, id +% 10);
                },
                else => {
                    // Render children followed by combining accent character
                    renderNodes(a.children, size, variant, id +% 10);
                    const accent_char = accentStr(a.kind);
                    if (accent_char.len > 0) {
                        dvui.labelNoFmt(@src(), accent_char, .{}, .{
                            .id_extra = id +% 30,
                            .font = mathFont(size, variant),
                            .color_text = mathColor(),
                        });
                    }
                },
            }
        },
        .operator => |name| {
            dvui.labelNoFmt(@src(), name, .{}, .{
                .id_extra = id,
                .font = mathFont(size, .roman),
                .color_text = mathColor(),
                .gravity_y = 0.5,
            });
            // Thin space after operator
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = size * 0.2 }, .id_extra = id +% 1 });
        },
        .binom => |b| {
            dvui.labelNoFmt(@src(), "(", .{}, .{
                .id_extra = id,
                .font = mathFont(size + 4, variant),
                .color_text = mathColor(),
                .gravity_y = 0.5,
            });
            {
                var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = id +% 1,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
                });
                defer col.deinit();
                {
                    var top_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = id +% 2,
                        .gravity_x = 0.5,
                    });
                    defer top_row.deinit();
                    renderNodes(b.top, size - 2, variant, id +% 10);
                }
                {
                    var bot_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = id +% 3,
                        .gravity_x = 0.5,
                    });
                    defer bot_row.deinit();
                    renderNodes(b.bot, size - 2, variant, id +% 20);
                }
            }
            dvui.labelNoFmt(@src(), ")", .{}, .{
                .id_extra = id +% 4,
                .font = mathFont(size + 4, variant),
                .color_text = mathColor(),
                .gravity_y = 0.5,
            });
        },
        .matrix => |m| renderMatrix(m.rows, m.delim, size, variant, id),
        .cases => |rows| {
            dvui.labelNoFmt(@src(), "{", .{}, .{
                .id_extra = id,
                .font = mathFont(size + 4, variant),
                .color_text = mathColor(),
                .gravity_y = 0.5,
            });
            renderMatrixRows(rows, size, variant, id +% 10);
        },
        .space => |mul| {
            const w = size * mul;
            if (w > 0) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = w }, .id_extra = id });
            }
        },
        .delimited => |d| {
            const left_str = delimStr(d.left, true);
            if (left_str.len > 0) {
                dvui.labelNoFmt(@src(), left_str, .{}, .{
                    .id_extra = id,
                    .font = mathFont(size + 4, variant),
                    .color_text = mathColor(),
                    .gravity_y = 0.5,
                });
            }
            renderNodes(d.body, size, variant, id +% 10);
            const right_str = delimStr(d.right, false);
            if (right_str.len > 0) {
                dvui.labelNoFmt(@src(), right_str, .{}, .{
                    .id_extra = id +% 1,
                    .font = mathFont(size + 4, variant),
                    .color_text = mathColor(),
                    .gravity_y = 0.5,
                });
            }
        },
        .phantom => {
            // Invisible — skip rendering
        },
        .color_node => |cn| {
            // TODO: dvui labels don't support per-span color easily; render default
            _ = cn;
            renderNodes(node.color_node.children, size, variant, id +% 10);
        },
        .stackrel => |sr| {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = id,
                .gravity_y = 0.5,
            });
            defer col.deinit();
            {
                var top_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 1,
                    .gravity_x = 0.5,
                });
                defer top_row.deinit();
                renderNodes(sr.top, size * 0.7, variant, id +% 10);
            }
            {
                var bot_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 2,
                    .gravity_x = 0.5,
                });
                defer bot_row.deinit();
                renderNodes(sr.bot, size, variant, id +% 20);
            }
        },
        .overset => |os| {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = id,
                .gravity_y = 0.5,
            });
            defer col.deinit();
            {
                var over_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 1,
                    .gravity_x = 0.5,
                });
                defer over_row.deinit();
                renderNodes(os.over, size * 0.7, variant, id +% 10);
            }
            {
                var base_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 2,
                    .gravity_x = 0.5,
                });
                defer base_row.deinit();
                renderNodes(os.base, size, variant, id +% 20);
            }
        },
        .underset => |us| {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = id,
                .gravity_y = 0.5,
            });
            defer col.deinit();
            {
                var base_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 1,
                    .gravity_x = 0.5,
                });
                defer base_row.deinit();
                renderNodes(us.base, size, variant, id +% 10);
            }
            {
                var under_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id +% 2,
                    .gravity_x = 0.5,
                });
                defer under_row.deinit();
                renderNodes(us.under, size * 0.7, variant, id +% 20);
            }
        },
    }
}

fn renderFraction(num: []const Node, den: []const Node, size: f32, variant: FontVariant, id: u16, display: bool) void {
    const child_size = if (display) size else size - 2;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .gravity_y = 0.5,
        .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    defer col.deinit();

    {
        var num_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id +% 1,
            .gravity_x = 0.5,
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        });
        defer num_row.deinit();
        renderNodes(num, child_size, variant, id +% 10);
    }

    _ = dvui.separator(@src(), .{
        .expand = .horizontal,
        .id_extra = id +% 2,
    });

    {
        var den_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id +% 3,
            .gravity_x = 0.5,
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        });
        defer den_row.deinit();
        renderNodes(den, child_size, variant, id +% 20);
    }
}

fn renderMatrix(rows: []const []const []const Node, delim: DelimKind, size: f32, variant: FontVariant, id: u16) void {
    const left_str = delimStr(delim, true);
    if (left_str.len > 0) {
        dvui.labelNoFmt(@src(), left_str, .{}, .{
            .id_extra = id,
            .font = mathFont(size + 4, variant),
            .color_text = mathColor(),
            .gravity_y = 0.5,
        });
    }

    renderMatrixRows(rows, size, variant, id +% 10);

    const right_str = delimStr(delim, false);
    if (right_str.len > 0) {
        dvui.labelNoFmt(@src(), right_str, .{}, .{
            .id_extra = id +% 1,
            .font = mathFont(size + 4, variant),
            .color_text = mathColor(),
            .gravity_y = 0.5,
        });
    }
}

fn renderMatrixRows(rows: []const []const []const Node, size: f32, variant: FontVariant, id: u16) void {
    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .gravity_y = 0.5,
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
    });
    defer grid.deinit();

    for (rows, 0..) |row, ri| {
        const row_id: u16 = id +% @as(u16, @intCast(ri & 0xFF)) *% 31 +% 100;
        var row_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
        defer row_box.deinit();

        for (row, 0..) |cell, ci| {
            if (ci > 0) {
                _ = dvui.spacer(@src(), .{
                    .min_size_content = .{ .w = size * 0.8 },
                    .id_extra = row_id +% @as(u16, @intCast(ci & 0xFF)) +% 200,
                });
            }
            const cell_id: u16 = row_id +% @as(u16, @intCast(ci & 0xFF)) *% 7 +% 10;
            renderNodes(cell, size - 1, variant, cell_id);
        }
    }
}
