//! Pin geometry, validation, and IR <-> core adapter.
//!
//! - [`pin_offsets`] + [`pin_position`]: pin offset tables and coordinate
//!   transforms, consumed by `crate::cktimg` and `crate::route`.
//! - Validation: pure structural checks over [`Subcircuit`]
//!   (unique names, grid alignment, wire orthogonality,
//!   duplicate wires, net-label consistency).
//! - Adapter: `schematic_from_subcircuit` / `subcircuit_from_schematic`
//!   between s2s-IR and `schemify_schematic::Schematic`.

use std::collections::{HashMap, HashSet};

use lasso::Rodeo;

use crate::ir::{
    self, map_device_kind, map_primitive, primitive_sym, NetClass, PinDir, Primitive, Subcircuit,
    GROUND_NAMES, POWER_NAMES,
};

use schemify_schematic::{
    Color, DeviceKind, Instance as CoreInstance, InstanceFlags, Property, Schematic,
    SchematicType, Wire as CoreWire,
};

// ---------------------------------------------------------------------------
// Pin geometry
// ---------------------------------------------------------------------------

/// Pin offsets (dx, dy) for the given primitive type, relative to instance
/// origin. Matches Schemify primitive `pin_positions` exactly.
pub fn pin_offsets(primitive: Primitive) -> &'static [(i32, i32)] {
    match primitive {
        Primitive::Pmos => &PMOS_PIN_OFFSETS,
        Primitive::Npn => &NPN_PIN_OFFSETS,
        Primitive::Pnp => &PNP_PIN_OFFSETS,
        Primitive::Vcvs | Primitive::Vccs => &VCXS_OFFSETS,
        Primitive::Ccvs | Primitive::Cccs => &TWO_TERM_OFFSETS,
        Primitive::Jfet => &JFET_PIN_OFFSETS,
        _ if primitive.is_mosfet() => &NMOS_PIN_OFFSETS,
        _ => &TWO_TERM_OFFSETS,
    }
}

/// Get pin position in schematic coordinates for a placed instance.
pub fn pin_position(inst: &ir::Instance, pin_idx: usize) -> (i32, i32) {
    // Subcircuit instances have per-instance pin lists (their definition's
    // ports), not a fixed primitive table — use the box-symbol layout that
    // the app gives project symbols so every pin gets a distinct position.
    if inst.primitive == Primitive::Subcircuit {
        let Some((dx, dy)) = subckt_box_pin_offset(&inst.pins, pin_idx) else {
            return (inst.x, inst.y);
        };
        let (rx, ry) = inst.flags.transform_point(dx, dy);
        return (inst.x + rx, inst.y + ry);
    }
    let offsets = pin_offsets(inst.primitive);
    if pin_idx >= offsets.len() {
        return (inst.x, inst.y);
    }
    let (dx, dy) = offsets[pin_idx];
    let (rx, ry) = inst.flags.transform_point(dx, dy);
    (inst.x + rx, inst.y + ry)
}

/// Pin offset for a subcircuit instance, mirroring core's `box_symbol`
/// project-symbol layout: `Input` pins on the left edge (x = -40), all other
/// pins on the right edge (x = +40), 20-unit pitch, centered vertically.
///
/// Keeping this in lockstep with `schemify_schematic::box_symbol` means
/// the wires/labels routed here land on the pins the app resolves when the
/// emitted project is opened.
pub fn subckt_box_pin_offset(pins: &[ir::Pin], idx: usize) -> Option<(i32, i32)> {
    const PITCH: i32 = 20;
    const HALF_W: i32 = 40;
    if idx >= pins.len() {
        return None;
    }
    let is_left = |p: &ir::Pin| p.dir == PinDir::Input;
    let n_left = pins.iter().filter(|p| is_left(p)).count() as i32;
    let n_right = pins.len() as i32 - n_left;
    let y_for = |slot: i32, count: i32| slot * PITCH - ((count - 1) * PITCH) / 2;
    let left = is_left(&pins[idx]);
    let slot = pins[..idx].iter().filter(|p| is_left(p) == left).count() as i32;
    Some(if left {
        (-HALF_W, y_for(slot, n_left.max(1)))
    } else {
        (HALF_W, y_for(slot, n_right.max(1)))
    })
}

// Pin offsets — match Schemify primitive `pin_positions` exactly.

/// NMOS: D=(20,-30) G=(-20,0) S=(20,30) B=(20,0)
const NMOS_PIN_OFFSETS: [(i32, i32); 4] = [(20, -30), (-20, 0), (20, 30), (20, 0)];
/// PMOS: D=(20,30) G=(-20,0) S=(20,-30) B=(20,0)  (D/S swapped vs NMOS)
const PMOS_PIN_OFFSETS: [(i32, i32); 4] = [(20, 30), (-20, 0), (20, -30), (20, 0)];
/// NPN: C=(20,-30) B=(-20,0) E=(20,30)
const NPN_PIN_OFFSETS: [(i32, i32); 3] = [(20, -30), (-20, 0), (20, 30)];
/// PNP: C=(20,30) B=(-20,0) E=(20,-30)  (C/E swapped vs NPN)
const PNP_PIN_OFFSETS: [(i32, i32); 3] = [(20, 30), (-20, 0), (20, -30)];
/// JFET: D=(20,-30) G=(-20,0) S=(20,30) — same layout as BJT
const JFET_PIN_OFFSETS: [(i32, i32); 3] = [(20, -30), (-20, 0), (20, 30)];
/// Two-terminal devices (R/C/L/V/I/D): p=(0,-30) n=(0,30)
const TWO_TERM_OFFSETS: [(i32, i32); 2] = [(0, -30), (0, 30)];
/// Voltage-controlled sources (VCVS/VCCS): p=(0,-30) n=(0,30) cp=(-30,-10) cn=(-30,10)
const VCXS_OFFSETS: [(i32, i32); 4] = [(0, -30), (0, 30), (-30, -10), (-30, 10)];

/// Snap a value to the nearest multiple of 10.
pub fn snap_to_grid(v: i32) -> i32 {
    ((v as f64 / 10.0).round() as i32) * 10
}

// ---------------------------------------------------------------------------
// Validation — pure structural checks (the R-rule implementations)
// ---------------------------------------------------------------------------

/// A validation error or warning found during checking.
#[derive(Debug, Clone)]
pub struct ValidationError {
    pub severity: Severity,
    pub message: String,
}

/// Severity level for validation errors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

/// Validate a subcircuit for schematic output correctness.
pub fn validate_subcircuit(subckt: &Subcircuit) -> Vec<ValidationError> {
    let mut errors = Vec::new();

    check_unique_names(subckt, &mut errors);
    check_grid_alignment(subckt, &mut errors);
    check_wire_orthogonality(subckt, &mut errors);
    check_no_duplicate_wires(subckt, &mut errors);
    check_net_label_consistency(subckt, &mut errors);

    errors
}

/// Every instance name must be unique within a subcircuit.
pub fn check_unique_names(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    let mut seen = HashSet::new();
    for inst in &subckt.instances {
        if !seen.insert(&inst.name) {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!("duplicate instance name '{}'", inst.name),
            });
        }
    }
}

/// All coordinates must be multiples of 10 (grid alignment).
pub fn check_grid_alignment(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    for inst in &subckt.instances {
        if inst.x % 10 != 0 || inst.y % 10 != 0 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "instance '{}' off-grid at ({}, {})",
                    inst.name, inst.x, inst.y
                ),
            });
        }
    }
    for (i, wire) in subckt.wires.iter().enumerate() {
        if wire.x1 % 10 != 0 || wire.y1 % 10 != 0 || wire.x2 % 10 != 0 || wire.y2 % 10 != 0 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "wire {} off-grid at ({}, {})-({}, {})",
                    i, wire.x1, wire.y1, wire.x2, wire.y2
                ),
            });
        }
    }
    for (i, label) in subckt.labels.iter().enumerate() {
        if label.x % 10 != 0 || label.y % 10 != 0 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!("label {} off-grid at ({}, {})", i, label.x, label.y),
            });
        }
    }
}

/// Every wire must be horizontal (y1==y2) or vertical (x1==x2).
pub fn check_wire_orthogonality(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    for (i, wire) in subckt.wires.iter().enumerate() {
        if wire.x1 != wire.x2 && wire.y1 != wire.y2 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "wire {} is diagonal: ({}, {})-({}, {})",
                    i, wire.x1, wire.y1, wire.x2, wire.y2
                ),
            });
        }
    }
}

/// No two wires with identical endpoints on the same net.
pub fn check_no_duplicate_wires(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    let mut seen = HashSet::new();
    for (i, wire) in subckt.wires.iter().enumerate() {
        // Normalize: always store smaller endpoint first so (A,B) == (B,A).
        let key = if (wire.x1, wire.y1) <= (wire.x2, wire.y2) {
            (wire.net_idx, wire.x1, wire.y1, wire.x2, wire.y2)
        } else {
            (wire.net_idx, wire.x2, wire.y2, wire.x1, wire.y1)
        };
        if !seen.insert(key) {
            errors.push(ValidationError {
                severity: Severity::Warning,
                message: format!(
                    "duplicate wire {} at ({}, {})-({}, {})",
                    i, wire.x1, wire.y1, wire.x2, wire.y2
                ),
            });
        }
    }
}

/// Every label's net_idx must be a valid index into the subcircuit's nets.
pub fn check_net_label_consistency(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    let net_count = subckt.nets.len();
    for (i, label) in subckt.labels.iter().enumerate() {
        if label.net_idx.index() >= net_count {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "label {} references net_idx {} but only {} nets exist",
                    i, label.net_idx.0, net_count
                ),
            });
        }
    }
}

// ---------------------------------------------------------------------------
// Adapter: s2s-IR `Subcircuit` <-> core `Schematic`
//
// Pure functions: input in, output out, no I/O, no global state.
// ---------------------------------------------------------------------------

/// Convert an s2s-IR `Subcircuit` into a core `Schematic`.
///
/// Pure function: takes the subcircuit and an interner, returns a fully
/// `*.PININFO a:I b:O c:B` comment lines (the Calibre/LVS convention) →
/// port directions. `I` = input, `O` = output, `B`/`IO` = inout;
/// case-insensitive, names lowercased to match parsed net names.
pub fn parse_pininfo(source: &str) -> HashMap<String, PinDir> {
    let mut map = HashMap::new();
    for line in source.lines() {
        let lower = line.trim().to_ascii_lowercase();
        let Some(rest) = lower.strip_prefix("*.pininfo") else {
            continue;
        };
        for tok in rest.split_whitespace() {
            let Some((name, d)) = tok.rsplit_once(':') else {
                continue;
            };
            let dir = match d {
                "i" => PinDir::Input,
                "o" => PinDir::Output,
                "b" | "io" | "x" => PinDir::Inout,
                _ => continue,
            };
            map.insert(name.to_string(), dir);
        }
    }
    map
}

/// populated `Schematic` with instances, wires, and labels. Nets named in
/// `ports` (see [`parse_pininfo`]) become directional input/output/inout
/// pin symbols instead of plain net labels.
pub fn schematic_from_subcircuit(
    sub: &ir::Subcircuit,
    int: &mut Rodeo,
    ports: &HashMap<String, PinDir>,
) -> Schematic {
    let mut schematic = Schematic {
        name: sub.name.clone(),
        // Declared ports (either .subckt ports or PININFO) make this a
        // reusable cell; port-less netlists are sim entry points.
        stype: if sub.ports.is_empty() && ports.is_empty() {
            SchematicType::Testbench
        } else {
            SchematicType::Schematic
        },
        ..Default::default()
    };

    // Component instances
    for inst in &sub.instances {
        let prop_start = schematic.properties.len() as u32;

        // Params are kept sorted by key at construction.
        for (k, v) in &inst.params {
            schematic.properties.push(Property {
                key: int.get_or_intern(k),
                value: int.get_or_intern(v),
            });
        }

        let prop_count = (schematic.properties.len() as u32 - prop_start) as u16;

        let sym = if inst.primitive == Primitive::Subcircuit {
            int.get_or_intern(&inst.symbol)
        } else {
            int.get_or_intern(primitive_sym(inst.primitive))
        };

        schematic.instances.push(CoreInstance {
            name: int.get_or_intern(&inst.name),
            symbol: sym,
            x: inst.x,
            y: inst.y,
            kind: map_device_kind(inst.primitive),
            flags: inst.flags,
            prop_start,
            prop_count,
        });
    }

    // Labels -> lab_pin / gnd / vdd instances
    let mut gnd_counter = 0u32;
    let mut vdd_counter = 0u32;
    for label in &sub.labels {
        let net = match sub.nets.get(label.net_idx.index()) {
            Some(n) => n,
            None => continue,
        };

        let name = net.name.as_str();
        let ends_with_ci = |s: &str, suffix: &str| {
            s.len() >= suffix.len() && s[s.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
        };
        let is_gnd = net.classification == NetClass::Ground
            && (GROUND_NAMES.iter().any(|&g| name.eq_ignore_ascii_case(g))
                || ends_with_ci(name, "_gnd")
                || ends_with_ci(name, "_vss"));
        let is_vdd = net.classification == NetClass::Power
            && (POWER_NAMES.iter().any(|&p| name.eq_ignore_ascii_case(p))
                || ends_with_ci(name, "_vdd")
                || ends_with_ci(name, "_vcc"));

        let (inst_name, sym, kind, x, y) = if is_gnd {
            let n = format!("gnd{gnd_counter}");
            gnd_counter += 1;
            let (tx, ty) = label.flags.transform_point(0, -10);
            (n, "gnd", DeviceKind::Gnd, label.x - tx, label.y - ty)
        } else if is_vdd {
            let n = format!("vdd{vdd_counter}");
            vdd_counter += 1;
            let (tx, ty) = label.flags.transform_point(0, 10);
            (n, "vdd", DeviceKind::Vdd, label.x - tx, label.y - ty)
        } else {
            // Declared ports become directional pin symbols; .subckt ports
            // without a PININFO entry default to inout.
            let (sym, kind) = port_symbol(port_dir(name, ports, sub));
            (net.name.clone(), sym, kind, label.x, label.y)
        };

        let prop_start = schematic.properties.len() as u32;
        // gnd/vdd name their net via the "net" prop (connectivity reads it);
        // lab_pin and the directional pins display theirs via the "@lab"
        // text anchor — without the prop the symbol shows a literal "lab".
        schematic.properties.push(Property {
            key: int.get_or_intern(if is_gnd || is_vdd { "net" } else { "lab" }),
            value: int.get_or_intern(&net.name),
        });
        let prop_count = 1u16;

        schematic.instances.push(CoreInstance {
            name: int.get_or_intern(&inst_name),
            symbol: int.get_or_intern(sym),
            x,
            y,
            kind,
            flags: label.flags,
            prop_start,
            prop_count,
        });
    }

    // cktimg renders ground/power as glyphs, not label entities — those
    // nets can arrive with wires + pins and NO label. Without a symbol the
    // app sees an unnamed floating stub; synthesize the gnd/vdd instance
    // at a dangling wire endpoint of the net.
    let labeled: HashSet<usize> = sub.labels.iter().map(|l| l.net_idx.index()).collect();
    for (ni, net) in sub.nets.iter().enumerate() {
        let (sym, kind, prefix, pin_off) = match net.classification {
            NetClass::Ground => ("gnd", DeviceKind::Gnd, "gnd", (0, -10)),
            NetClass::Power => ("vdd", DeviceKind::Vdd, "vdd", (0, 10)),
            _ => continue,
        };
        if labeled.contains(&ni) {
            continue;
        }
        let Some((ex, ey)) = dangling_endpoint(sub, ni) else {
            continue;
        };
        let n = if kind == DeviceKind::Gnd {
            let s = format!("{prefix}{gnd_counter}");
            gnd_counter += 1;
            s
        } else {
            let s = format!("{prefix}{vdd_counter}");
            vdd_counter += 1;
            s
        };
        let prop_start = schematic.properties.len() as u32;
        schematic.properties.push(Property {
            key: int.get_or_intern("net"),
            value: int.get_or_intern(&net.name),
        });
        schematic.instances.push(CoreInstance {
            name: int.get_or_intern(&n),
            symbol: int.get_or_intern(sym),
            x: ex - pin_off.0,
            y: ey - pin_off.1,
            kind,
            flags: InstanceFlags::default(),
            prop_start,
            prop_count: 1,
        });
    }

    // Ports declared via PININFO whose nets came out fully wired get no
    // label from cktimg — synthesize the directional pin symbol anyway:
    // GenerateSymbolFromSchematic derives the cell's pins from them.
    for (ni, net) in sub.nets.iter().enumerate() {
        if labeled.contains(&ni) || port_dir(&net.name, ports, sub).is_none() {
            continue;
        }
        let Some((ex, ey)) = dangling_endpoint(sub, ni) else {
            continue;
        };
        let (sym, kind) = port_symbol(port_dir(&net.name, ports, sub));
        if kind == DeviceKind::LabPin {
            continue; // unreachable given the dir check, but keep it honest
        }
        let prop_start = schematic.properties.len() as u32;
        schematic.properties.push(Property {
            key: int.get_or_intern("lab"),
            value: int.get_or_intern(&net.name),
        });
        schematic.instances.push(CoreInstance {
            name: int.get_or_intern(&net.name),
            symbol: int.get_or_intern(sym),
            x: ex,
            y: ey,
            kind,
            flags: InstanceFlags::default(),
            prop_start,
            prop_count: 1,
        });
    }

    // Wires carry their cktimg net name: geometric islands keep correct
    // SPICE node names (ground "0", label-connected segments) even when
    // no label instance sits on that island.
    for wire in &sub.wires {
        let net_name = sub
            .nets
            .get(wire.net_idx.index())
            .map(|n| int.get_or_intern(&n.name));
        schematic.wires.push(CoreWire {
            net_name,
            x0: wire.x1,
            y0: wire.y1,
            x1: wire.x2,
            y1: wire.y2,
            color: Color::NONE,
            thickness: 10,
        });
    }

    schematic
}

/// Port direction for a net: PININFO declaration first, then `.subckt`
/// port membership (defaulting to inout), else not a port.
fn port_dir(
    name: &str,
    ports: &HashMap<String, PinDir>,
    sub: &ir::Subcircuit,
) -> Option<PinDir> {
    ports.get(&name.to_ascii_lowercase()).copied().or_else(|| {
        sub.ports
            .iter()
            .any(|p| p.eq_ignore_ascii_case(name))
            .then_some(PinDir::Inout)
    })
}

fn port_symbol(dir: Option<PinDir>) -> (&'static str, DeviceKind) {
    match dir {
        Some(PinDir::Input) => ("input_pin", DeviceKind::InputPin),
        Some(PinDir::Output) => ("output_pin", DeviceKind::OutputPin),
        Some(PinDir::Inout) => ("inout_pin", DeviceKind::InoutPin),
        None => ("lab_pin", DeviceKind::LabPin),
    }
}

/// A wire endpoint of `net` that nothing else touches (not a second wire,
/// not a device pin) — where cktimg pointed the ground/power stub.
/// Falls back to any endpoint, then to a pin position.
fn dangling_endpoint(sub: &ir::Subcircuit, ni: usize) -> Option<(i32, i32)> {
    let pins: Vec<(i32, i32)> = sub.nets[ni]
        .pins
        .iter()
        .filter_map(|pr| {
            sub.instances
                .get(pr.instance_idx.index())
                .map(|inst| pin_position(inst, pr.pin_idx.index()))
        })
        .collect();
    let mut counts: Vec<((i32, i32), u32)> = Vec::new();
    for w in sub.wires.iter().filter(|w| w.net_idx.index() == ni) {
        for e in [(w.x1, w.y1), (w.x2, w.y2)] {
            match counts.iter_mut().find(|(p, _)| *p == e) {
                Some((_, c)) => *c += 1,
                None => counts.push((e, 1)),
            }
        }
    }
    counts
        .iter()
        .find(|(p, c)| *c == 1 && !pins.contains(p))
        .or_else(|| counts.first())
        .map(|(p, _)| *p)
        .or_else(|| pins.first().copied())
}

/// Convert a core `Schematic` back into an s2s-IR `Subcircuit`.
///
/// Pure function: reads interned strings via `int`, builds a fresh
/// `Subcircuit` with instances, nets, wires, and labels.
///
/// Subcircuit (X) instances get empty pin lists: the schematic form does not
/// carry per-instance pins (the app resolves them from project symbols).
/// Callers with circuit context should use
/// [`subcircuit_from_schematic_with_symbols`] instead.
pub fn subcircuit_from_schematic(sch: &Schematic, int: &Rodeo) -> ir::Subcircuit {
    subcircuit_from_schematic_with_symbols(sch, int, &HashMap::new())
}

/// [`subcircuit_from_schematic`] with subcircuit-symbol pin counts supplied.
///
/// `subckt_pin_counts` maps a subcircuit symbol name to its port count, so X
/// instances are reconstructed with their full pin lists (positions follow
/// the same `box_symbol` layout used by `pin_position`). Symbols missing from
/// the map fall back to an empty pin list.
pub fn subcircuit_from_schematic_with_symbols(
    sch: &Schematic,
    int: &Rodeo,
    subckt_pin_counts: &HashMap<String, usize>,
) -> ir::Subcircuit {
    let mut sub = ir::Subcircuit::new(&sch.name);

    // Net name -> net index map
    let mut net_map: HashMap<String, ir::NetId> = HashMap::new();

    // Helper: get or create a net by name
    let mut get_or_create_net = |name: &str, nets: &mut Vec<ir::Net>| -> ir::NetId {
        if let Some(&idx) = net_map.get(name) {
            return idx;
        }
        let idx = ir::NetId(nets.len() as u32);
        nets.push(ir::Net::new(name));
        net_map.insert(name.to_string(), idx);
        idx
    };

    // Process instances: split into device instances vs label/power/ground
    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];
        let name = int.resolve(&sch.instances.name[i]).to_owned();
        let x = sch.instances.x[i];
        let y = sch.instances.y[i];
        let flags = sch.instances.flags[i];

        match kind {
            DeviceKind::Gnd | DeviceKind::Vdd => {
                // Power/ground symbols become labels on the corresponding net
                let net_name = get_prop_value(sch, int, i, "net")
                    .unwrap_or_else(|| kind.injected_net().unwrap_or("0").to_owned());
                let net_idx = get_or_create_net(&net_name, &mut sub.nets);

                // Classify the net and reverse the pin offset transform to
                // recover the label position.
                let (class, pin_dy) = if kind == DeviceKind::Gnd {
                    (NetClass::Ground, -10)
                } else {
                    (NetClass::Power, 10)
                };
                sub.nets[net_idx.index()].classification = class;
                let label_flags = InstanceFlags::new(flags.rotation(), false);
                let (tx, ty) = label_flags.transform_point(0, pin_dy);
                sub.labels.push(ir::Label {
                    net_idx,
                    x: x + tx,
                    y: y + ty,
                    flags: label_flags,
                });
            }
            DeviceKind::LabPin
            | DeviceKind::InputPin
            | DeviceKind::OutputPin
            | DeviceKind::InoutPin => {
                // Label instances become IR labels
                let net_idx = get_or_create_net(&name, &mut sub.nets);
                sub.labels.push(ir::Label {
                    net_idx,
                    x,
                    y,
                    flags: InstanceFlags::new(flags.rotation(), false),
                });
            }
            _ => {
                // Device instance
                if let Some(prim) = map_primitive(kind) {
                    let mut params: Vec<(String, String)> = Vec::new();
                    let prop_start = sch.instances.prop_start[i] as usize;
                    let prop_count = sch.instances.prop_count[i] as usize;
                    for pi in prop_start..prop_start + prop_count {
                        if let Some(prop) = sch.properties.get(pi) {
                            params.push((
                                int.resolve(&prop.key).to_owned(),
                                int.resolve(&prop.value).to_owned(),
                            ));
                        }
                    }
                    params.sort_by(|a, b| a.0.cmp(&b.0));

                    let pins: Vec<ir::Pin> =
                        if matches!(kind, DeviceKind::Subckt | DeviceKind::DigitalInstance) {
                            // Pin count comes from the subcircuit definition
                            // (X-instance pins are its ports, all Inout —
                            // matching the parser's construction).
                            let symbol = int.resolve(&sch.instances.symbol[i]);
                            let n = subckt_pin_counts.get(symbol).copied().unwrap_or(0);
                            (0..n)
                                .map(|pi| ir::Pin {
                                    name: format!("p{pi}"),
                                    dir: ir::PinDir::Inout,
                                    net_idx: None,
                                })
                                .collect()
                        } else {
                            kind.default_pins()
                                .iter()
                                .map(|&pname| ir::Pin {
                                    name: pname.to_string(),
                                    dir: ir::PinDir::Inout,
                                    net_idx: None,
                                })
                                .collect()
                        };

                    sub.instances.push(ir::Instance {
                        name,
                        primitive: prim,
                        symbol: int.resolve(&sch.instances.symbol[i]).to_owned(),
                        pins,
                        params,
                        x,
                        y,
                        flags,
                    });
                }
            }
        }
    }

    // Wires — net assignment comes from connectivity engine, not stored on wire
    for i in 0..sch.wires.len() {
        let idx = ir::NetId(sub.nets.len() as u32);
        sub.nets.push(ir::Net::new(""));

        sub.wires.push(ir::Wire {
            net_idx: idx,
            x1: sch.wires.x0[i],
            y1: sch.wires.y0[i],
            x2: sch.wires.x1[i],
            y2: sch.wires.y1[i],
        });
    }

    // Ports: schematic-type schematics have ports derived from label instances
    if sch.stype == SchematicType::Schematic {
        for i in 0..sch.instances.len() {
            let kind = sch.instances.kind[i];
            if kind.is_label() {
                let port_name = int.resolve(&sch.instances.name[i]).to_owned();
                if !sub.ports.contains(&port_name) {
                    sub.ports.push(port_name);
                    sub.port_directions.push(match kind {
                        DeviceKind::InputPin => PinDir::Input,
                        DeviceKind::OutputPin => PinDir::Output,
                        _ => PinDir::Inout,
                    });
                }
            }
        }
    }

    sub
}

/// Read a property value from an instance's property slice.
fn get_prop_value(sch: &Schematic, int: &Rodeo, inst_idx: usize, key: &str) -> Option<String> {
    let prop_start = sch.instances.prop_start[inst_idx] as usize;
    let prop_count = sch.instances.prop_count[inst_idx] as usize;
    for pi in prop_start..prop_start + prop_count {
        if let Some(prop) = sch.properties.get(pi) {
            if int.resolve(&prop.key) == key {
                return Some(int.resolve(&prop.value).to_owned());
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{Instance, Label, Net, NetId, Pin, Wire};

    fn mosfet(name: &str, x: i32, y: i32) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: Vec::new(),
            x,
            y,
            flags: InstanceFlags::new(0, false),
        }
    }

    /// Build a valid subcircuit (all checks pass).
    fn valid_subckt() -> Subcircuit {
        let mut subckt = Subcircuit::new("test");
        subckt.nets.push(Net::new("vdd"));
        subckt.nets.push(Net::new("gnd"));
        subckt.instances.push(mosfet("M1", 100, 200));
        subckt.wires.push(Wire {
            net_idx: NetId(0),
            x1: 100,
            y1: 200,
            x2: 200,
            y2: 200,
        });
        subckt.labels.push(Label {
            net_idx: NetId(0),
            x: 100,
            y: 200,
            flags: InstanceFlags::new(0, false),
        });
        subckt
    }

    // -- pin geometry --

    #[test]
    fn pin_offsets_and_transforms() {
        assert_eq!(pin_offsets(Primitive::Nmos), &NMOS_PIN_OFFSETS);
        assert_eq!(pin_offsets(Primitive::Pmos), &PMOS_PIN_OFFSETS);
        assert_eq!(pin_offsets(Primitive::Resistor), &TWO_TERM_OFFSETS);
        // Transforms via InstanceFlags: rotation and flip of the NMOS drain.
        let mut m = mosfet("M1", 0, 0);
        assert_eq!(pin_position(&m, 0), (20, -30));
        m.flags = InstanceFlags::new(1, false);
        assert_eq!(pin_position(&m, 0), (30, 20));
        m.flags = InstanceFlags::new(0, true);
        assert_eq!(pin_position(&m, 0), (-20, -30));
    }

    // -- validation (R-rules) --

    #[test]
    fn valid_subcircuit_no_errors() {
        assert!(validate_subcircuit(&valid_subckt()).is_empty());
    }

    #[test]
    fn off_grid_coordinates_detected() {
        let mut subckt = valid_subckt();
        subckt.instances[0].x = 105;
        subckt.wires[0].x1 = 103;
        subckt.labels[0].y = 15;
        let errors = validate_subcircuit(&subckt);
        assert!(errors
            .iter()
            .any(|e| e.severity == Severity::Error && e.message.contains("'M1' off-grid")));
        assert!(errors
            .iter()
            .any(|e| e.severity == Severity::Error && e.message.contains("wire 0 off-grid")));
        assert!(errors
            .iter()
            .any(|e| e.severity == Severity::Error && e.message.contains("label 0 off-grid")));
    }

    #[test]
    fn duplicate_wire_detected_both_orientations() {
        let mut subckt = valid_subckt();
        // Same wire with reversed endpoints — still a duplicate.
        subckt.wires.push(Wire {
            net_idx: NetId(0),
            x1: 200,
            y1: 200,
            x2: 100,
            y2: 200,
        });
        let errors = validate_subcircuit(&subckt);
        assert!(errors
            .iter()
            .any(|e| e.severity == Severity::Warning && e.message.contains("duplicate wire")));
    }

    #[test]
    fn duplicate_name_diagonal_wire_bad_label_detected() {
        let mut subckt = valid_subckt();
        subckt.instances.push(mosfet("M1", 200, 200));
        subckt.wires.push(Wire {
            net_idx: NetId(0),
            x1: 0,
            y1: 0,
            x2: 100,
            y2: 100,
        });
        subckt.labels[0].net_idx = NetId(99);
        let errors = validate_subcircuit(&subckt);
        assert!(errors.iter().any(|e| e.message.contains("duplicate instance name 'M1'")));
        assert!(errors.iter().any(|e| e.message.contains("diagonal")));
        assert!(errors.iter().any(|e| e.message.contains("references net_idx 99")));
    }

    // -- adapter round-trip --

    fn one_resistor_subcircuit() -> ir::Subcircuit {
        let mut sub = ir::Subcircuit::new("test");
        sub.nets.push(Net::new("in"));
        sub.nets.push(Net::new("out"));
        sub.instances.push(Instance {
            name: "R1".to_string(),
            primitive: Primitive::Resistor,
            symbol: "res".to_string(),
            pins: vec![
                Pin {
                    name: "p".into(),
                    dir: PinDir::Inout,
                    net_idx: Some(NetId(0)),
                },
                Pin {
                    name: "n".into(),
                    dir: PinDir::Inout,
                    net_idx: Some(NetId(1)),
                },
            ],
            params: vec![("value".into(), "1k".into())],
            x: 100,
            y: 200,
            flags: InstanceFlags::new(0, false),
        });
        sub
    }

    #[test]
    fn schematic_from_subcircuit_preserves_instance_and_props() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int, &HashMap::new());

        assert_eq!(sch.instances.len(), 1);
        assert_eq!(int.resolve(&sch.instances.name[0]), "R1");
        assert_eq!(sch.instances.kind[0], DeviceKind::Resistor);
        assert_eq!((sch.instances.x[0], sch.instances.y[0]), (100, 200));
        assert_eq!(sch.instances.prop_count[0], 1);
        let prop = &sch.properties[sch.instances.prop_start[0] as usize];
        assert_eq!(int.resolve(&prop.key), "value");
        assert_eq!(int.resolve(&prop.value), "1k");
        assert_eq!(sch.stype, SchematicType::Testbench);
    }

    #[test]
    fn roundtrip_preserves_instances_wires_and_label_nets() {
        let mut sub = one_resistor_subcircuit();
        sub.wires.push(Wire {
            net_idx: NetId(0),
            x1: 10,
            y1: 20,
            x2: 30,
            y2: 40,
        });
        // Labels keep net connectivity across the round-trip.
        sub.labels.push(Label {
            net_idx: NetId(0),
            x: 0,
            y: 0,
            flags: InstanceFlags::new(0, false),
        });
        sub.labels.push(Label {
            net_idx: NetId(1),
            x: 10,
            y: 0,
            flags: InstanceFlags::new(0, false),
        });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int, &HashMap::new());
        let sub2 = subcircuit_from_schematic(&sch, &int);

        // Instance count + fields preserved
        assert_eq!(sub2.instances.len(), sub.instances.len());
        assert_eq!(sub2.instances[0].name, "R1");
        assert_eq!(sub2.instances[0].primitive, Primitive::Resistor);
        assert_eq!((sub2.instances[0].x, sub2.instances[0].y), (100, 200));
        assert_eq!(
            sub2.instances[0]
                .params
                .iter()
                .find(|(k, _)| k == "value")
                .map(|(_, v)| v.as_str()),
            Some("1k")
        );

        // Wire coordinates preserved
        assert_eq!(sub2.wires.len(), 1);
        assert_eq!(
            (sub2.wires[0].x1, sub2.wires[0].y1, sub2.wires[0].x2, sub2.wires[0].y2),
            (10, 20, 30, 40)
        );

        // Connectivity: labelled nets survive
        for name in &["in", "out"] {
            assert!(
                sub2.nets.iter().any(|n| n.name == *name),
                "net '{name}' should survive round-trip via labels"
            );
        }
    }

    #[test]
    fn roundtrip_gnd_and_vdd_labels() {
        let mut sub = ir::Subcircuit::new("test");
        let mut gnd = Net::new("gnd");
        gnd.classification = NetClass::Ground;
        sub.nets.push(gnd);
        let mut vdd = Net::new("vdd");
        vdd.classification = NetClass::Power;
        sub.nets.push(vdd);
        sub.labels.push(Label {
            net_idx: NetId(0),
            x: 50,
            y: 60,
            flags: InstanceFlags::new(0, false),
        });
        sub.labels.push(Label {
            net_idx: NetId(1),
            x: 50,
            y: -60,
            flags: InstanceFlags::new(0, false),
        });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int, &HashMap::new());
        assert_eq!(sch.instances.kind[0], DeviceKind::Gnd);
        assert_eq!(sch.instances.kind[1], DeviceKind::Vdd);

        let sub2 = subcircuit_from_schematic(&sch, &int);
        assert_eq!(sub2.labels.len(), 2);
        let gnd_net = &sub2.nets[sub2.labels[0].net_idx.index()];
        assert_eq!(gnd_net.name, "gnd");
        assert_eq!(gnd_net.classification, NetClass::Ground);
        // Label positions preserved exactly (transform is reversed)
        assert_eq!((sub2.labels[0].x, sub2.labels[0].y), (50, 60));
        assert_eq!((sub2.labels[1].x, sub2.labels[1].y), (50, -60));
    }

    #[test]
    fn pininfo_ports_become_directional_pins() {
        let ports = parse_pininfo("* rc filter\n*.PININFO in:I out:O io:B\nR1 in out 1k\n");
        assert_eq!(ports.get("in"), Some(&PinDir::Input));
        assert_eq!(ports.get("out"), Some(&PinDir::Output));
        assert_eq!(ports.get("io"), Some(&PinDir::Inout));

        let mut sub = ir::Subcircuit::new("rc");
        sub.nets.push(Net::new("in"));
        sub.nets.push(Net::new("plain"));
        sub.labels.push(Label {
            net_idx: NetId(0),
            x: 0,
            y: 0,
            flags: InstanceFlags::new(0, false),
        });
        sub.labels.push(Label {
            net_idx: NetId(1),
            x: 40,
            y: 0,
            flags: InstanceFlags::new(0, false),
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int, &ports);
        assert_eq!(sch.instances.kind[0], DeviceKind::InputPin);
        assert_eq!(sch.instances.kind[1], DeviceKind::LabPin); // not declared
    }

    #[test]
    fn unlabeled_ground_net_gets_gnd_symbol_and_named_wires() {
        // cktimg style: ground net with wires + no label entity (it renders
        // the glyph itself). The adapter must synthesize a gnd symbol at the
        // dangling endpoint and name the wires "0".
        let mut sub = ir::Subcircuit::new("rc");
        let mut zero = Net::new("0");
        zero.classification = NetClass::Ground;
        sub.nets.push(zero);
        sub.instances.push(mosfet("M1", 100, 200));
        sub.wires.push(Wire { net_idx: NetId(0), x1: 80, y1: 10, x2: 80, y2: 60 });
        sub.wires.push(Wire { net_idx: NetId(0), x1: 80, y1: 10, x2: 120, y2: 10 });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int, &HashMap::new());

        assert_eq!(sch.instances.kind[1], DeviceKind::Gnd);
        // Symbol pin (0,-10 offset) lands on the dangling endpoint (80,60).
        assert_eq!((sch.instances.x[1], sch.instances.y[1]), (80, 70));
        let name = sch.wires.net_name[0].map(|s| int.resolve(&s).to_string());
        assert_eq!(name.as_deref(), Some("0"));
    }

    #[test]
    fn roundtrip_ports() {
        let mut sub = ir::Subcircuit::new("amp");
        sub.ports = vec!["in".into(), "out".into()];
        sub.nets.push(Net::new("in"));
        sub.nets.push(Net::new("out"));
        sub.labels.push(Label {
            net_idx: NetId(0),
            x: 0,
            y: 0,
            flags: InstanceFlags::new(0, false),
        });
        sub.labels.push(Label {
            net_idx: NetId(1),
            x: 100,
            y: 0,
            flags: InstanceFlags::new(0, false),
        });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int, &HashMap::new());
        assert_eq!(sch.stype, SchematicType::Schematic);

        let sub2 = subcircuit_from_schematic(&sch, &int);
        assert_eq!(sub2.ports.len(), 2);
        assert!(sub2.ports.contains(&"in".to_string()));
        assert!(sub2.ports.contains(&"out".to_string()));
        // Every port gets a direction (lab_pin labels -> Inout).
        assert_eq!(sub2.port_directions, vec![PinDir::Inout, PinDir::Inout]);
    }
}
