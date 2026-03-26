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
};
