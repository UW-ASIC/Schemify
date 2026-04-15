//! lib.zig — Canonical module root for src/core/.
//!
//! build.zig points at Schemify.zig as the module entry point, so
//! Schemify.zig does the actual re-exports that external consumers see
//! via `@import("core")`.  This file exists as the conventional module
//! root and lists all submodules.
//!
//! Submodules:
//!   simulation/    — SPICE interface and netlist emission
//!   fileio/        — Reader, Writer, TOML config
//!   devices/       — Device cell library and primitives

const std = @import("std");

// ── Submodule libs ───────────────────────────────────────────────────────────

const simulation = @import("simulation/lib.zig");
const fileio = @import("fileio/lib.zig");
const devices = @import("devices/lib.zig");

// ── Re-exports ─────────────────────────────────────────────────────────────

// Types from types.zig
const types = @import("types.zig");
pub const PinDir = types.PinDir;
pub const Line = types.Line;
pub const Rect = types.Rect;
pub const Circle = types.Circle;
pub const Arc = types.Arc;
pub const Wire = types.Wire;
pub const Text = types.Text;
pub const Pin = types.Pin;
pub const Instance = types.Instance;
pub const Prop = types.Prop;
pub const Conn = types.Conn;
pub const Net = types.Net;
pub const ConnKind = types.ConnKind;
pub const NetConn = types.NetConn;
pub const NetMap = types.NetMap;
pub const SifyType = types.SifyType;
pub const SymDataPin = types.SymDataPin;
pub const PinRef = types.PinRef;
pub const SymData = types.SymData;
pub const ComponentDesc = types.ComponentDesc;
pub const DiagLevel = types.DiagLevel;
pub const Diagnostic = types.Diagnostic;
pub const LogLevel = types.LogLevel;
pub const DeviceKind = types.DeviceKind;

// From Schemify.zig
const schemify = @import("Schemify.zig");
pub const Schemify = schemify.Schemify;
pub const primitives = schemify.primitives;
pub const SpiceBackend = schemify.SpiceBackend;
pub const NetlistMode = schemify.NetlistMode;
pub const pdk = schemify.pdk;

// From submodules
pub const SpiceIF = simulation.SpiceIF;
pub const Netlist = simulation.Netlist;
pub const Reader = fileio.Reader;
pub const Writer = fileio.Writer;
pub const Toml = fileio.Toml;
pub const Devices = devices.Devices;

// ── Comptime imports ensure all sub-file tests are pulled into `zig build test` ──

comptime {
    _ = types;
    _ = @import("helpers.zig");
    _ = @import("Schemify.zig");
    _ = simulation;
    _ = fileio;
    _ = devices;
}

// ── Module-level tests ──────────────────────────────────────────────────────

test "types re-export consistency" {
    try std.testing.expect(@sizeOf(types.Line) > 0);
    try std.testing.expect(@sizeOf(types.Instance) > 0);
    try std.testing.expect(@sizeOf(types.Pin) > 0);
    try std.testing.expect(@sizeOf(types.Wire) > 0);
    try std.testing.expect(@sizeOf(types.Prop) > 0);
    try std.testing.expect(@sizeOf(types.NetConn) > 0);
}

test "DeviceKind identity" {
    const DK = types.DeviceKind;
    try std.testing.expect(DK.resistor != DK.capacitor);
    try std.testing.expectEqual(DK.nmos3, DK.nmos3);
}

test "PinDir fromStr/toStr round-trip" {
    const PD = types.PinDir;
    const dirs = [_]PD{ .input, .output, .inout, .power, .ground };
    for (dirs) |d| {
        const s = d.toStr();
        const back = PD.fromStr(s);
        try std.testing.expectEqual(d, back);
    }
}

test "ConnKind tag round-trip" {
    const CK = types.ConnKind;
    const kinds = [_]CK{ .instance_pin, .wire_endpoint, .label };
    for (kinds) |k| {
        const tag = k.toTag();
        const back = CK.fromTag(tag);
        try std.testing.expectEqual(k, back);
    }
}

test "NetMap pointKey deterministic" {
    const NM = types.NetMap;
    const k1 = NM.pointKey(100, 200);
    const k2 = NM.pointKey(100, 200);
    const k3 = NM.pointKey(200, 100);
    try std.testing.expectEqual(k1, k2);
    try std.testing.expect(k1 != k3);
}

