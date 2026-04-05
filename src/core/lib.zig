//! lib.zig — Canonical module root for src/core/.
//!
//! build.zig points at Schemify.zig as the module entry point, so
//! Schemify.zig does the actual re-exports that external consumers see
//! via `@import("core")`.  This file exists as the conventional module
//! root, listing all sub-files and providing module-level tests.
//!
//! Sub-files:
//!   types.zig     — All shared/simple data types (public within module).
//!   Schemify.zig  — Core schematic data model (module entry point + re-exports).
//!   Devices.zig   — Device cell library and PDK.
//!   SpiceIF.zig   — SPICE backend interface.
//!   Netlist.zig   — Netlist emission.
//!   Reader.zig    — .chn file reader.
//!   Writer.zig    — .chn file writer.
//!   HdlParser.zig — Verilog/VHDL parser.
//!   YosysJson.zig — Yosys JSON parser.
//!   Synthesis.zig — Yosys synthesis invocation.
//!   Toml.zig      — Config.toml parser.
//!
//! Tests in this file are only runnable through `zig build test` (not
//! standalone `zig test`) because sub-files depend on external modules
//! defined in build.zig ("utility", etc.).

const std = @import("std");
const types = @import("types.zig");

// ── Re-exports ──────────────────────────────────────────────────────────────
const schemify = @import("Schemify.zig");

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
pub const SourceMode = types.SourceMode;
pub const HdlLanguage = types.HdlLanguage;
pub const BehavioralModel = types.BehavioralModel;
pub const SynthesizedModel = types.SynthesizedModel;
pub const DigitalConfig = types.DigitalConfig;
pub const ComponentDesc = types.ComponentDesc;
pub const DiagLevel = types.DiagLevel;
pub const Diagnostic = types.Diagnostic;
pub const LogLevel = types.LogLevel;
pub const LibInclude = types.LibInclude;
pub const DeviceKind = types.DeviceKind;
pub const Schemify = schemify.Schemify;
pub const primitives = schemify.primitives;
pub const SpiceBackend = schemify.SpiceBackend;
pub const NetlistMode = schemify.NetlistMode;
pub const pdk = schemify.pdk;
pub const Toml = @import("Toml.zig");

// ── Comptime imports ensure all sub-file tests are pulled into `zig build test` ──

comptime {
    _ = types;
    _ = @import("Devices.zig");
    _ = @import("SpiceIF.zig");
    _ = @import("Netlist.zig");
    _ = @import("Reader.zig");
    _ = @import("Writer.zig");
    _ = @import("HdlParser.zig");
    _ = @import("YosysJson.zig");
    _ = @import("Synthesis.zig");
    _ = @import("Toml.zig");
}

// ── Module-level tests ───────────────────────────────────────────────────────

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

test "HdlLanguage fromStr/toStr round-trip" {
    const HL = types.HdlLanguage;
    const langs = [_]HL{ .verilog, .vhdl, .xspice, .xyce_digital };
    for (langs) |l| {
        const s = l.toStr();
        const back = HL.fromStr(s);
        try std.testing.expect(back != null);
        try std.testing.expectEqual(l, back.?);
    }
}
