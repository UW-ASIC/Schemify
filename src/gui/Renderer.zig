//! Renderer.zig — thin re-export shim.
//!
//! Logic lives in renderer/root.zig (split across Grid, Wires, Symbols, Input).
//! Callers that already import "Renderer.zig" continue to work unchanged.

const root = @import("renderer/root.zig");
pub const Renderer = root.Renderer;
pub const DrawCmd  = root.DrawCmd;
