//! Zig bindings for the wasm3 WebAssembly interpreter.
//!
//! This module provides a thin Zig wrapper around the wasm3 C API via @cImport.
//! All wasm3 types and functions are re-exported from the `c` namespace.

pub const c = @cImport({
    @cInclude("wasm3.h");
});

// Re-export commonly used types at top level for convenience.
pub const Environment = c.IM3Environment;
pub const Runtime = c.IM3Runtime;
pub const Module = c.IM3Module;
pub const Function = c.IM3Function;
pub const Result = c.M3Result;
pub const RawCall = c.M3RawCall;
pub const ImportContext = c.IM3ImportContext;

/// Check if a wasm3 result indicates success (null pointer = no error).
pub fn isOk(result: Result) bool {
    return result == null;
}

/// Convert a wasm3 result string to a Zig slice, or "ok" if null.
pub fn resultStr(result: Result) []const u8 {
    if (result) |r| {
        const ptr: [*:0]const u8 = r;
        return std.mem.span(ptr);
    }
    return "ok";
}

const std = @import("std");
