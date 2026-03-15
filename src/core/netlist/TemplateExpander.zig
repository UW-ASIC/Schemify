//! TemplateExpander — format/template token expansion and string utilities.
//!
//! Covers:
//!   - `extractTemplateDefaults` — parse template= into .subckt default params
//!   - `lookupTemplateDefault`   — look up a single key in a template= string
//!   - TCL helpers (stripTclEval, evalTclEval, simplifyParamLine, xschemTclUnescape)
//!   - SPICE value helpers (processSpiceExpr, parseValue, isPlainNumber, etc.)
//!   - @PARAM substitution helpers (substituteAtParams, resolveExprValue)
//!   - `processExprDefault` — handle expr(...) template defaults
//!   - String normalization helpers (collapseSpaces, dedupeSpaces, normalizeSpiceValue)

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const fm = @import("FeatureModel.zig");
const univ_mod = @import("../spice/universal.zig");
const Value = univ_mod.Value;

// ── Template default extraction ───────────────────────────────────────────── //

/// Parse a template= property value into default parameter string for .subckt headers.
/// Excludes `name=`, `m=`, and optionally keys in `exclude` (pass null to skip).
pub fn extractTemplateDefaults(
    a: Allocator,
    template_val: []const u8,
    exclude: ?*const std.StringHashMapUnmanaged(void),
) ![]const u8 {
    var buf: List(u8) = .{};
    var pos: usize = 0;
    var first = true;
    while (pos < template_val.len and (template_val[pos] == ' ' or template_val[pos] == '\t' or
        template_val[pos] == '\n' or template_val[pos] == '\r')) pos += 1;
    while (pos < template_val.len) {
        const eq_pos = std.mem.indexOfScalarPos(u8, template_val, pos, '=') orelse break;
        const key_raw = std.mem.trim(u8, template_val[pos..eq_pos], " \t\n\r");
        const key = std.mem.trimLeft(u8, key_raw, "+ \t\n\r");
        pos = eq_pos + 1;
        var val_start: usize = pos;
        var val_end: usize = pos;
        const dq_esc = pos + 2 < template_val.len and
            template_val[pos] == '\\' and template_val[pos + 1] == '\\' and template_val[pos + 2] == '"';
        const dq_plain = pos < template_val.len and template_val[pos] == '"';
        if (dq_esc or dq_plain) {
            const quote_len: usize = if (dq_esc) 3 else 1;
            val_start = pos + quote_len;
            pos += quote_len;
            while (pos < template_val.len) {
                if (pos + 2 < template_val.len and
                    template_val[pos] == '\\' and template_val[pos + 1] == '\\' and template_val[pos + 2] == '"')
                {
                    if (dq_esc) { val_end = pos; pos += 3; break; }
                    pos += 3;
                } else if (template_val[pos] == '\\' and pos + 1 < template_val.len and template_val[pos + 1] == '"') {
                    pos += 2;
                } else if (template_val[pos] == '"') {
                    val_end = pos; pos += 1; break;
                } else { pos += 1; }
            }
            if (val_end == val_start and pos >= template_val.len) val_end = pos;
        } else if (pos < template_val.len and template_val[pos] == '\'') {
            val_start = pos; pos += 1;
            while (pos < template_val.len and template_val[pos] != '\'') pos += 1;
            if (pos < template_val.len) pos += 1;
            val_end = pos;
        } else {
            while (pos < template_val.len and template_val[pos] != ' ' and template_val[pos] != '\t' and
                template_val[pos] != '\n' and template_val[pos] != '\r') pos += 1;
            val_end = pos;
        }
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "m") or
            (exclude != null and exclude.?.contains(key)))
        {
            while (pos < template_val.len and (template_val[pos] == ' ' or template_val[pos] == '\t' or
                template_val[pos] == '\n' or template_val[pos] == '\r')) pos += 1;
            continue;
        }
        if (!first) try buf.append(a, ' ');
        try buf.appendSlice(a, key);
        try buf.append(a, '=');
        try buf.appendSlice(a, template_val[val_start..val_end]);
        first = false;
        while (pos < template_val.len and (template_val[pos] == ' ' or template_val[pos] == '\t' or
            template_val[pos] == '\n' or template_val[pos] == '\r')) pos += 1;
    }
    return buf.toOwnedSlice(a);
}

/// Look up a default value from an XSchem template= string.
/// Handles multiline templates and quoted values (\\"...\\", "...", '...').
pub fn lookupTemplateDefault(template: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < template.len) {
        while (pos < template.len and (template[pos] == ' ' or template[pos] == '\t' or
            template[pos] == '\n' or template[pos] == '\r' or template[pos] == '+')) pos += 1;
        if (pos >= template.len) break;
        const eq_pos = std.mem.indexOfScalarPos(u8, template, pos, '=') orelse break;
        const tok_key = std.mem.trim(u8, template[pos..eq_pos], " \t\n\r");
        pos = eq_pos + 1;
        const dq_esc = pos + 2 < template.len and template[pos] == '\\' and
            template[pos + 1] == '\\' and template[pos + 2] == '"';
        const dq_plain = !dq_esc and pos < template.len and template[pos] == '"';
        const sq = !dq_esc and !dq_plain and pos < template.len and template[pos] == '\'';
        var val_start: usize = undefined;
        var val_end: usize = undefined;
        if (dq_esc) {
            val_start = pos + 3;
            pos += 3;
            while (pos < template.len) {
                if (pos + 2 < template.len and template[pos] == '\\' and
                    template[pos + 1] == '\\' and template[pos + 2] == '"')
                { val_end = pos; pos += 3; break; }
                pos += 1;
            } else val_end = pos;
        } else if (dq_plain) {
            val_start = pos + 1; pos += 1;
            while (pos < template.len and template[pos] != '"') pos += 1;
            val_end = pos;
            if (pos < template.len) pos += 1;
        } else if (sq) {
            val_start = pos; pos += 1;
            while (pos < template.len and template[pos] != '\'') pos += 1;
            if (pos < template.len) pos += 1;
            val_end = pos;
        } else {
            val_start = pos;
            while (pos < template.len and template[pos] != ' ' and template[pos] != '\t' and
                template[pos] != '\n' and template[pos] != '\r') pos += 1;
            val_end = pos;
        }
        if (std.ascii.eqlIgnoreCase(tok_key, key)) return template[val_start..val_end];
    }
    return null;
}

// ── Prop lookup ───────────────────────────────────────────────────────────── //

pub fn lookupPropValue(props: []const fm.DeviceProp, key: []const u8) ?[]const u8 {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

pub fn lookupPropValueI(props: []const fm.DeviceProp, key: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
    }
    return null;
}

// ── TCL helpers ───────────────────────────────────────────────────────────── //

pub fn stripTclEval(s: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(s, "tcleval(") and std.mem.endsWith(u8, s, ")"))
        return s["tcleval(".len .. s.len - 1];
    return s;
}

pub fn extractTclSetValue(rhs: []const u8) ?[]const u8 {
    if (rhs.len < 1 or rhs[0] != '[') return null;
    const rb = std.mem.lastIndexOfScalar(u8, rhs, ']') orelse return null;
    const inner = std.mem.trim(u8, rhs[1..rb], " \t");
    if (!std.ascii.startsWithIgnoreCase(inner, "set ")) return null;
    const after = std.mem.trim(u8, inner[4..], " \t");
    const sp = std.mem.indexOfScalar(u8, after, ' ') orelse return null;
    return std.mem.trim(u8, after[sp + 1 ..], " \t");
}

pub fn evalTclEval(s: []const u8, tcl_vars: *const std.StringHashMapUnmanaged([]const u8), a: Allocator) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "tcleval(")) return s;
    if (!std.mem.endsWith(u8, trimmed, ")")) return s;
    const inner = trimmed["tcleval(".len .. trimmed.len - 1];
    var out: List(u8) = .{};
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '$') {
            i += 1;
            const var_start = i;
            while (i < inner.len and (std.ascii.isAlphanumeric(inner[i]) or inner[i] == '_')) i += 1;
            const var_name = inner[var_start..i];
            if (tcl_vars.get(var_name)) |val| {
                out.appendSlice(a, val) catch {};
            } else {
                out.append(a, '$') catch {};
                out.appendSlice(a, var_name) catch {};
            }
        } else {
            out.append(a, inner[i]) catch {};
            i += 1;
        }
    }
    return out.toOwnedSlice(a) catch inner;
}

pub fn simplifyParamLine(line: []const u8, a: Allocator) []const u8 {
    const tl = std.mem.trimLeft(u8, line, " \t");
    if (!std.ascii.startsWithIgnoreCase(tl, ".param ")) return line;
    const eq_pos = std.mem.indexOfScalar(u8, tl, '=') orelse return line;
    const rhs = std.mem.trim(u8, tl[eq_pos + 1 ..], " \t");
    const val = extractTclSetValue(rhs) orelse return line;
    const prefix = tl[0 .. eq_pos + 1];
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, val }) catch line;
}

pub fn xschemTclUnescape(s: []const u8, a: std.mem.Allocator) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var buf = a.alloc(u8, s.len) catch return s;
    var wi: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const next = s[i + 1];
            if (next == '{' or next == '}' or next == '\\') {
                buf[wi] = next;
                wi += 1;
                i += 2;
                continue;
            }
        }
        buf[wi] = s[i];
        wi += 1;
        i += 1;
    }
    return buf[0..wi];
}

// ── SPICE value helpers ───────────────────────────────────────────────────── //

pub fn isWaveformSpec(s: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, s, " \t");
    if (trimmed.len == 0) return false;
    const keywords = [_][]const u8{ "pulse", "sin", "cos", "exp", "pwl", "sffm", "am", "dc ", "ac ", "tcleval(" };
    for (keywords) |kw| if (std.ascii.startsWithIgnoreCase(trimmed, kw)) return true;
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        const after = std.mem.trimLeft(u8, trimmed[sp..], " \t");
        for (keywords) |kw| if (std.ascii.startsWithIgnoreCase(after, kw)) return true;
        if (std.ascii.startsWithIgnoreCase(after, "dc") or std.ascii.startsWithIgnoreCase(after, "ac")) return true;
    }
    return false;
}

pub fn isPlainNumber(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return false;
    _ = std.fmt.parseFloat(f64, t) catch {
        var i: usize = t.len;
        while (i > 0 and std.ascii.isAlphabetic(t[i - 1])) : (i -= 1) {}
        if (i == 0 or i == t.len) return false;
        const suffix = t[i..];
        const known = [_][]const u8{ "k", "m", "u", "n", "p", "f", "g", "t", "meg" };
        var ok = false;
        for (known) |kw| if (std.ascii.eqlIgnoreCase(suffix, kw)) { ok = true; break; };
        if (!ok) return false;
        _ = std.fmt.parseFloat(f64, t[0..i]) catch return false;
        return true;
    };
    return true;
}

pub fn needsSpiceQuoting(s: []const u8) bool {
    if (s.len == 0) return false;
    if ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '{' and s[s.len - 1] == '}')) return false;
    if (std.mem.indexOfScalar(u8, s, ' ') != null) return false;
    if (std.ascii.startsWithIgnoreCase(s, "tcleval(")) return false;
    if (std.ascii.startsWithIgnoreCase(s, "expr(")) return false;
    if (isPlainNumber(s)) return false;
    for (s) |c| if (c == '/' or c == '*' or c == '(' or c == ')') return true;
    return false;
}

pub fn processSpiceExpr(s: []const u8, a: std.mem.Allocator) []const u8 {
    const unescaped = xschemTclUnescape(std.mem.trim(u8, s, " \t"), a);
    if (needsSpiceQuoting(unescaped)) {
        return std.fmt.allocPrint(a, "'{s}'", .{unescaped}) catch unescaped;
    }
    return unescaped;
}

pub fn parseValue(s: []const u8) Value {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return .{ .literal = 0 };
    if (trimmed.len > 6 and std.ascii.startsWithIgnoreCase(trimmed, "expr(") and trimmed[trimmed.len - 1] == ')')
        return .{ .expr = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t") };
    if (trimmed.len > 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')
        return .{ .param = trimmed[1 .. trimmed.len - 1] };
    if (trimmed.len > 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
        return .{ .expr = trimmed };
    return .{ .expr = trimmed };
}

pub fn normalizeSpiceValue(val: []const u8, a: Allocator) ![]const u8 {
    var buf: List(u8) = .{};
    var it = std.mem.splitScalar(u8, val, '\n');
    var first = true;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0) continue;
        const content = if (trimmed[0] == '+') std.mem.trim(u8, trimmed[1..], " \t") else trimmed;
        if (content.len == 0) continue;
        if (!first) try buf.append(a, ' ');
        try buf.appendSlice(a, content);
        first = false;
    }
    return buf.toOwnedSlice(a);
}

pub fn collapseSpaces(s: []const u8, a: std.mem.Allocator) []const u8 {
    var joined: List(u8) = .{};
    defer joined.deinit(a);
    var line_it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (line_it.next()) |raw_ln| {
        const ln = std.mem.trimLeft(u8, raw_ln, " \t\r");
        if (ln.len > 0 and ln[0] == '+') {
            joined.append(a, ' ') catch return s;
            joined.appendSlice(a, std.mem.trimLeft(u8, ln[1..], " \t")) catch return s;
        } else {
            if (!first) joined.append(a, ' ') catch return s;
            joined.appendSlice(a, raw_ln) catch return s;
        }
        first = false;
    }
    return dedupeSpaces(joined.items, a);
}

pub fn dedupeSpaces(s: []const u8, a: std.mem.Allocator) []const u8 {
    var buf: List(u8) = .{};
    var prev_space = false;
    var started = false;
    for (s) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\r';
        if (is_ws) {
            if (started and !prev_space) buf.append(a, ' ') catch return s;
            prev_space = true;
        } else {
            buf.append(a, c) catch return s;
            prev_space = false;
            started = true;
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') buf.items.len -= 1;
    return buf.toOwnedSlice(a) catch s;
}

// ── @PARAM substitution ───────────────────────────────────────────────────── //

pub fn isPlainIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn substituteAtParams(s: []const u8, parent_params: []const fm.DeviceProp, a: std.mem.Allocator) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '@') == null) return s;
    var out: List(u8) = .{};
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '@') {
            i += 1;
            const name_start = i;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
            const param_name = s[name_start..i];
            if (param_name.len > 0) {
                var found = false;
                for (parent_params) |p| {
                    if (std.ascii.eqlIgnoreCase(p.key, param_name)) {
                        out.appendSlice(a, p.value) catch {};
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    out.append(a, '@') catch {};
                    out.appendSlice(a, param_name) catch {};
                }
            } else {
                out.append(a, '@') catch {};
            }
        } else {
            out.append(a, s[i]) catch {};
            i += 1;
        }
    }
    return out.toOwnedSlice(a) catch s;
}

pub fn processExprDefault(val: []const u8, a: std.mem.Allocator) []const u8 {
    const trimmed = std.mem.trim(u8, val, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "expr(")) return val;
    if (trimmed[trimmed.len - 1] != ')') return val;
    const inner = trimmed[5 .. trimmed.len - 1];

    var s1: List(u8) = .{};
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '@') {
            i += 1;
            while (i < inner.len and (std.ascii.isAlphanumeric(inner[i]) or inner[i] == '_')) {
                s1.append(a, inner[i]) catch {};
                i += 1;
            }
        } else {
            s1.append(a, inner[i]) catch {};
            i += 1;
        }
    }
    const s = s1.items;

    var out: List(u8) = .{};
    var j: usize = 0;
    while (j < s.len) {
        if (s[j] == ' ' and j + 2 < s.len and
            (s[j + 1] == '+' or s[j + 1] == '-' or s[j + 1] == '/') and
            s[j + 2] == ' ')
        {
            const left_has_dot = blk: {
                var k: usize = out.items.len;
                while (k > 0) {
                    k -= 1;
                    const c = out.items[k];
                    if (c == '.') break :blk true;
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk false;
                }
                break :blk false;
            };
            const right_has_dot = blk: {
                var k: usize = j + 3;
                while (k < s.len) {
                    const c = s[k];
                    if (c == '.') break :blk true;
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk false;
                    k += 1;
                }
                break :blk false;
            };
            if (!left_has_dot and !right_has_dot) {
                out.append(a, s[j + 1]) catch {};
                j += 3;
                continue;
            }
        }
        out.append(a, s[j]) catch {};
        j += 1;
    }

    var result = out.items;
    while (result.len > 0 and result[result.len - 1] == ' ') result.len -= 1;
    if (result.len >= 2 and result[result.len - 1] == '\'') {
        var k2: usize = result.len - 1;
        while (k2 > 0 and result[k2 - 1] == ' ') k2 -= 1;
        if (k2 < result.len - 1) {
            result[k2] = '\'';
            result = result[0 .. k2 + 1];
        }
    }
    return a.dupe(u8, result) catch val;
}

// ── Arithmetic eval helpers ───────────────────────────────────────────────── //

fn parseEngValue(s: []const u8) ?f64 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    var num_end: usize = t.len;
    var multiplier: f64 = 1.0;
    if (t.len >= 3 and std.ascii.eqlIgnoreCase(t[t.len - 3 ..], "meg")) {
        num_end = t.len - 3;
        multiplier = 1e6;
    } else if (t.len >= 1) {
        const last = t[t.len - 1];
        switch (last) {
            'f', 'F' => { num_end = t.len - 1; multiplier = 1e-15; },
            'p', 'P' => { num_end = t.len - 1; multiplier = 1e-12; },
            'n', 'N' => { num_end = t.len - 1; multiplier = 1e-9;  },
            'u', 'U' => { num_end = t.len - 1; multiplier = 1e-6;  },
            'm', 'M' => { num_end = t.len - 1; multiplier = 1e-3;  },
            'k', 'K' => { num_end = t.len - 1; multiplier = 1e3;   },
            'g', 'G' => { num_end = t.len - 1; multiplier = 1e9;   },
            't', 'T' => { num_end = t.len - 1; multiplier = 1e12;  },
            else => {},
        }
    }
    if (num_end == 0) return null;
    const num_f = std.fmt.parseFloat(f64, t[0..num_end]) catch return null;
    return num_f * multiplier;
}

fn evalSimpleArith(expr_str: []const u8, a: std.mem.Allocator) ?f64 {
    _ = a;
    const t = std.mem.trim(u8, expr_str, " \t");
    var result: f64 = 0;
    var pending_op: u8 = '+';
    var i: usize = 0;
    while (i <= t.len) {
        var j = i;
        while (j < t.len and t[j] != '+' and t[j] != '-' and t[j] != '*' and t[j] != '/') j += 1;
        const token = std.mem.trim(u8, t[i..j], " \t");
        if (token.len == 0) {
            if (j < t.len) { pending_op = t[j]; i = j + 1; }
            else break;
            continue;
        }
        const val = parseEngValue(token) orelse return null;
        switch (pending_op) {
            '+' => result += val,
            '-' => result -= val,
            '*' => result *= val,
            '/' => if (val != 0) { result /= val; } else return null,
            else => return null,
        }
        if (j < t.len) { pending_op = t[j]; i = j + 1; }
        else break;
    }
    return result;
}

fn formatEvalResult(val: f64, a: std.mem.Allocator) []const u8 {
    const rounded = @round(val);
    const is_integer = blk: {
        if (rounded == 0.0) break :blk (val == 0.0);
        if (@abs(rounded) < 1.0) break :blk false;
        const rel_err = @abs(val - rounded) / @abs(rounded);
        break :blk rel_err < 1e-9 and @abs(rounded) < 1e15;
    };
    if (is_integer) {
        const int_val: i64 = @intFromFloat(rounded);
        return std.fmt.allocPrint(a, "{d}", .{int_val}) catch return "0";
    }
    const raw = std.fmt.allocPrint(a, "{e}", .{val}) catch return "0";
    const e_pos = std.mem.indexOfScalar(u8, raw, 'e') orelse return raw;
    var mant = raw[0..e_pos];
    const exp_part = raw[e_pos..];
    if (std.mem.indexOfScalar(u8, mant, '.') != null) {
        var end = mant.len;
        while (end > 1 and mant[end - 1] == '0') end -= 1;
        if (end > 1 and mant[end - 1] == '.') end -= 1;
        mant = mant[0..end];
    }
    return std.fmt.allocPrint(a, "{s}{s}", .{ mant, exp_part }) catch raw;
}

pub fn resolveExprValue(val_raw: []const u8, parent_params: []const fm.DeviceProp, a: std.mem.Allocator) []const u8 {
    const trimmed = std.mem.trim(u8, val_raw, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "expr(")) return val_raw;
    if (trimmed[trimmed.len - 1] != ')') return val_raw;
    const inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t");
    if (parent_params.len == 0) return val_raw;
    const substituted = substituteAtParams(inner, parent_params, a);
    if (std.mem.indexOfScalar(u8, substituted, '@') != null) return val_raw;
    const eval_result = evalSimpleArith(substituted, a) orelse {
        return std.fmt.allocPrint(a, "expr({s})", .{substituted}) catch val_raw;
    };
    return formatEvalResult(eval_result, a);
}
