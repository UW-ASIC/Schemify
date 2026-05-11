//! Stub wasm3 module — used when wasm3 C source is not available.
//! loader_wasm.zig detects this stub by checking `@hasDecl(wasm3, "is_stub")`.

/// Sentinel declaration — presence of this field means wasm3 runtime is NOT available.
pub const is_stub = true;
