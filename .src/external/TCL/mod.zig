const std = @import("std");
pub const Evaluator = @import("evaluator.zig").Evaluator;
pub const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const Token = @import("tokenizer.zig").Token;
pub const ExprResult = @import("expr.zig").ExprResult;
pub const evalExpr = @import("expr.zig").evalExpr;

pub const Tcl = struct {
    evaluator: Evaluator,

    pub fn init(backing: std.mem.Allocator) Tcl {
        return .{ .evaluator = Evaluator.init(backing) };
    }

    pub fn deinit(self: *Tcl) void {
        self.evaluator.deinit();
    }

    pub fn eval(self: *Tcl, script: []const u8) ![]const u8 {
        return self.evaluator.evalScript(script);
    }

    pub fn getVar(self: *const Tcl, name: []const u8) ?[]const u8 {
        return self.evaluator.getVar(name);
    }

    pub fn setVar(self: *Tcl, name: []const u8, value: []const u8) !void {
        return self.evaluator.setVar(name, value);
    }

    pub fn setScriptPath(self: *Tcl, path: []const u8) void {
        self.evaluator.setScriptPath(path);
    }

    /// Register a proc definition by evaluating `proc name {args} {body}`.
    pub fn defineProc(self: *Tcl, proc_script: []const u8) !void {
        _ = try self.evaluator.evalScript(proc_script);
    }

    /// Run an optional script, then extract Tcl variables matching the
    /// fields of `Schema` into a `SchemaResult`.
    pub fn runWithSchema(
        self: *Tcl,
        comptime Schema: type,
        alloc: std.mem.Allocator,
        script: []const u8,
    ) !SchemaResult(Schema) {
        if (script.len > 0) {
            _ = try self.evaluator.evalScript(script);
        }
        return SchemaResult(Schema).extract(&self.evaluator, alloc);
    }
};

/// Result of `runWithSchema`: holds duped string values for each Schema field
/// found in the Tcl variable table.
pub fn SchemaResult(comptime Schema: type) type {
    const fields = @typeInfo(Schema).@"struct".fields;

    return struct {
        const Self = @This();

        values: [fields.len]?[]const u8,
        alloc: std.mem.Allocator,

        fn extract(evaluator: *const Evaluator, alloc: std.mem.Allocator) !Self {
            var result: Self = .{ .values = undefined, .alloc = alloc };
            inline for (fields, 0..) |f, i| {
                if (evaluator.getVar(f.name)) |v| {
                    result.values[i] = try alloc.dupe(u8, v);
                } else {
                    result.values[i] = null;
                }
            }
            return result;
        }

        pub fn deinit(self: *Self) void {
            inline for (0..fields.len) |i| {
                if (self.values[i]) |v| self.alloc.free(v);
            }
        }

        /// Look up a field by name. Returns null if the variable was not set.
        pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
            inline for (fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) return self.values[i];
            }
            return null;
        }

        /// Fill a Schema struct with extracted values, applying type coercion.
        pub fn fillInto(self: *const Self, comptime S: type, target: *S) void {
            inline for (@typeInfo(S).@"struct".fields, 0..) |f, i| {
                if (self.values[i]) |v| {
                    if (f.type == bool) {
                        @field(target, f.name) = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
                    } else if (f.type == []const u8) {
                        @field(target, f.name) = v;
                    } else if (f.type == ?[]const u8) {
                        @field(target, f.name) = v;
                    }
                }
            }
        }
    };
}
