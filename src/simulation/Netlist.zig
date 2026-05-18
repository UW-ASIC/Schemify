//! Netlist.zig — Schemify schematic → netlist generation via connectivity + pyspice.zig
//!
//! Resolves connectivity (union-find on wire endpoints + pin positions),
//! then delegates to schematic.pyspice for PySpice-rs Python emission.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const schematic = @import("schematic");
const types = schematic.types;
const Instance = types.Instance;
const Property = types.Property;
const Conn = types.Conn;
const DeviceKind = types.DeviceKind;
const StringPool = schematic.string_pool.StringPool;
const StringRef = schematic.string_pool.StringRef;
const Connectivity = schematic.connectivity.Connectivity;
const SpiceIF = @import("SpiceIF.zig");
const Devices = schematic.devices.Devices;

pub const Mode = schematic.pyspice.Mode;

// ═════════════════════════════════════════════════════════════════════════════
// Public API
// ═════════════════════════════════════════════════════════════════════════════

/// Emit a SPICE netlist from a Schemify model.
/// Delegates to emitPySpice (raw SPICE deprecated in favor of PySpice-rs).
pub fn emitSpice(
    model: anytype,
    gpa: Allocator,
    pdk: ?*const Devices.Pdk,
) ![]u8 {
    _ = pdk;
    return emitPySpiceMode(model, gpa, null, .ngspice, .hierarchical);
}

/// Emit a PySpice-rs Python script (hierarchical mode) from a Schemify model.
pub fn emitPySpice(
    model: anytype,
    gpa: Allocator,
    pdk: ?*const Devices.Pdk,
    backend: SpiceIF.Backend,
) ![]u8 {
    return emitPySpiceMode(model, gpa, pdk, backend, .hierarchical);
}

/// Emit a PySpice-rs Python script with explicit netlist mode.
///
/// Modes:
///   .hierarchical — emits subcircuit instances as circuit.X() (default)
///   .top_only     — skips subcircuit/unknown instances, only primitives
///   .flat         — emits subcircuit instances + appends circuit.build_flat_circuit()
pub fn emitPySpiceMode(
    model: anytype,
    gpa: Allocator,
    pdk: ?*const Devices.Pdk,
    backend: SpiceIF.Backend,
    mode: Mode,
) ![]u8 {
    _ = pdk;

    // 1. Resolve connectivity
    var conn: Connectivity = .{};
    defer conn.deinit(gpa);
    conn.resolve(gpa, &model.instances, &model.wires, model.sym_data.items, &model.strings);

    // 2. Build a merged pool and resolved Conn array.
    //    Pin names come from source pool (via SymData), net names come from
    //    either source pool (user-labeled) or connectivity's own pool (auto-generated).
    //    We copy everything into a single merged pool so pyspice.zig can use one pool.
    var merged_pool: StringPool = .{};
    defer merged_pool.deinit(gpa);

    const n_conns = conn.conns.items.len;
    var resolved_conns = try gpa.alloc(Conn, n_conns);
    defer gpa.free(resolved_conns);

    for (conn.conns.items, 0..) |c, i| {
        const pin_str = model.strings.get(c.pin);
        const pin_ref = try merged_pool.add(gpa, pin_str);

        const net_str = conn.getNetName(c.net, &model.strings);
        const net_ref = try merged_pool.add(gpa, net_str);

        resolved_conns[i] = .{ .pin = pin_ref, .net = net_ref };
    }

    // 3. Build AoS Instance slice from MAL
    const inst_count = model.instances.len;
    var instances_aos = try gpa.alloc(Instance, inst_count);
    defer gpa.free(instances_aos);

    if (inst_count > 0) {
        const slice = model.instances.slice();
        const names = slice.items(.name);
        const symbols = slice.items(.symbol);
        const kinds = slice.items(.kind);
        const prop_starts = slice.items(.prop_start);
        const prop_counts = slice.items(.prop_count);

        for (0..inst_count) |i| {
            const name_s = model.strings.get(names[i]);
            const sym_s = model.strings.get(symbols[i]);
            instances_aos[i] = .{
                .name = try merged_pool.add(gpa, name_s),
                .symbol = try merged_pool.add(gpa, sym_s),
                .kind = kinds[i],
                .prop_start = prop_starts[i],
                .prop_count = prop_counts[i],
            };
        }
    }

    // 4. Build merged props array
    var merged_props = try gpa.alloc(Property, model.props.items.len);
    defer gpa.free(merged_props);

    for (model.props.items, 0..) |p, i| {
        const key_str = model.strings.get(p.key);
        const val_str = model.strings.get(p.val);
        merged_props[i] = .{
            .key = try merged_pool.add(gpa, key_str),
            .val = try merged_pool.add(gpa, val_str),
        };
    }

    // 5. Build merged model_defs
    const ModelDef = schematic.types.ModelDef;
    var merged_models = try gpa.alloc(ModelDef, model.model_defs.items.len);
    defer gpa.free(merged_models);

    for (model.model_defs.items, 0..) |md, i| {
        merged_models[i] = .{
            .name = try merged_pool.add(gpa, model.strings.get(md.name)),
            .kind = try merged_pool.add(gpa, model.strings.get(md.kind)),
            .prop_start = md.prop_start,
            .prop_count = md.prop_count,
        };
    }

    // 6. Get circuit name
    const name_str = model.str(model.name);

    // 7. Delegate to pyspice.emitTemplateMode
    return schematic.pyspice.emitTemplateMode(
        gpa,
        &merged_pool,
        name_str,
        instances_aos,
        merged_props,
        resolved_conns,
        conn.conn_starts,
        conn.conn_counts,
        merged_models,
        backend.displayName(),
        mode,
    );
}
