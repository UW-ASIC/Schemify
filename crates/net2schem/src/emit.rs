//! Schematic emission, validation, and IR <-> core adapter.
//!
//! Compacted port of the old `output/` (schemify backend only — the xschem
//! backend is dropped), `validation/`, and `adapter` modules:
//!
//! - [`PinGeometry`] + [`pin_position`]: pin offset tables and coordinate
//!   transforms, consumed by `crate::cktimg`.
//! - [`SchemifyBackend`]: `.chn` text emission (instances, wires, labels,
//!   SYMBOL section for subcircuit ports) and file writing.
//! - Validation: pure structural checks over [`Subcircuit`]/[`Circuit`]
//!   (unique names, grid alignment, rotation range, wire orthogonality,
//!   duplicate wires, net-label consistency).
//! - Adapter: `schematic_from_subcircuit` / `subcircuit_from_schematic` /
//!   `relayout` between s2s-IR and `schemify_schematic::Schematic`.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use lasso::Rodeo;

use crate::ir::{self, Circuit, NetClass, PinDir, Primitive, Subcircuit};
use crate::shared::{map_device_kind, map_primitive, primitive_sym, GROUND_NAMES, POWER_NAMES};

use schemify_schematic::{
    Color, DeviceKind, Instance as CoreInstance, InstanceFlags, Property, Schematic,
    SchematicType, Wire as CoreWire,
};

// ---------------------------------------------------------------------------
// Pin geometry
// ---------------------------------------------------------------------------

/// Pin geometry provider — knows pin offsets and coordinate transforms.
///
/// Used by placement and routing to compute absolute pin positions.
pub trait PinGeometry {
    /// Pin offsets (dx, dy) for the given primitive type, relative to instance origin.
    fn pin_offsets(&self, primitive: Primitive) -> &[(i32, i32)];

    /// Apply flip and rotation to a pin offset, returning the transformed (dx, dy).
    fn transform_pin(&self, dx: i32, dy: i32, rotation: u8, flip: bool) -> (i32, i32);
}

/// Get pin position in schematic coordinates for a placed instance.
///
/// Generic over the geometry provider so hot pin loops monomorphize on the
/// concrete backend; `?Sized` keeps `&dyn PinGeometry` callers working.
pub fn pin_position<G: PinGeometry + ?Sized>(
    geo: &G,
    inst: &ir::Instance,
    pin_idx: usize,
) -> (i32, i32) {
    // Subcircuit instances have per-instance pin lists (their definition's
    // ports), not a fixed primitive table — use the box-symbol layout that
    // the app gives project symbols so every pin gets a distinct position.
    if inst.primitive == Primitive::Subcircuit {
        let Some((dx, dy)) = subckt_box_pin_offset(&inst.pins, pin_idx) else {
            return (inst.x, inst.y);
        };
        let (rx, ry) = geo.transform_pin(dx, dy, inst.rotation, inst.flip);
        return (inst.x + rx, inst.y + ry);
    }
    let offsets = geo.pin_offsets(inst.primitive);
    if pin_idx >= offsets.len() {
        return (inst.x, inst.y);
    }
    let (dx, dy) = offsets[pin_idx];
    let (rx, ry) = geo.transform_pin(dx, dy, inst.rotation, inst.flip);
    (inst.x + rx, inst.y + ry)
}

/// Pin offset for a subcircuit instance, mirroring core's `box_symbol`
/// project-symbol layout: `Input` pins on the left edge (x = -40), all other
/// pins on the right edge (x = +40), 20-unit pitch, centered vertically.
///
/// Keeping this in lockstep with `schemify_schematic::box_symbol` means
/// the wires/labels routed here land on the pins the app resolves when the
/// emitted project is opened.
fn subckt_box_pin_offset(pins: &[ir::Pin], idx: usize) -> Option<(i32, i32)> {
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

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

/// Bounding box of placed instances.
#[derive(Debug, Clone, Copy)]
pub struct BBox {
    pub x_min: i32,
    pub x_max: i32,
    pub y_min: i32,
    pub y_max: i32,
}

/// Compute the bounding box of all placed instances in a subcircuit.
///
/// Returns `None` if there are no instances (caller should fall back to defaults).
pub fn compute_instance_bbox(subckt: &Subcircuit) -> Option<BBox> {
    if subckt.instances.is_empty() {
        return None;
    }
    let mut bb = BBox {
        x_min: i32::MAX,
        x_max: i32::MIN,
        y_min: i32::MAX,
        y_max: i32::MIN,
    };
    for inst in &subckt.instances {
        bb.x_min = bb.x_min.min(inst.x);
        bb.x_max = bb.x_max.max(inst.x);
        bb.y_min = bb.y_min.min(inst.y);
        bb.y_max = bb.y_max.max(inst.y);
    }
    Some(bb)
}

/// Snap a value to the nearest multiple of 10.
pub fn snap_to_grid(v: i32) -> i32 {
    ((v as f64 / 10.0).round() as i32) * 10
}

/// Distribute `n` pin Y-positions evenly within [y_min, y_max], centered.
///
/// Returns a Vec of grid-snapped Y coordinates.
pub fn distribute_y(n: usize, y_min: i32, y_max: i32) -> Vec<i32> {
    if n == 0 {
        return Vec::new();
    }
    let spacing = (y_max - y_min) / (n as i32 + 1).max(1);
    (0..n)
        .map(|i| snap_to_grid(y_min + spacing * (i as i32 + 1)))
        .collect()
}

/// Distribute `n` pin X-positions evenly within [x_min, x_max], centered.
pub fn distribute_x(n: usize, x_min: i32, x_max: i32) -> Vec<i32> {
    if n == 0 {
        return Vec::new();
    }
    let spacing = (x_max - x_min) / (n as i32 + 1).max(1);
    (0..n)
        .map(|i| snap_to_grid(x_min + spacing * (i as i32 + 1)))
        .collect()
}

/// Classify subcircuit ports into input, output, and io/power/ground groups.
///
/// Uses `subckt.port_directions` when available. Falls back to `PinDir::Inout`
/// for ports without a direction entry.
type PortList<'a> = Vec<(&'a str, PinDir)>;

pub fn classify_ports(subckt: &Subcircuit) -> (PortList<'_>, PortList<'_>, PortList<'_>) {
    let mut inputs = Vec::new();
    let mut outputs = Vec::new();
    let mut ios = Vec::new();

    for (i, port) in subckt.ports.iter().enumerate() {
        let dir = subckt
            .port_directions
            .get(i)
            .copied()
            .unwrap_or(PinDir::Inout);
        match dir {
            PinDir::Input => inputs.push((port.as_str(), dir)),
            PinDir::Output => outputs.push((port.as_str(), dir)),
            _ => ios.push((port.as_str(), dir)),
        }
    }

    (inputs, outputs, ios)
}

// ---------------------------------------------------------------------------
// Schemify `.chn` backend
// ---------------------------------------------------------------------------

/// Schemify `.chn` output backend.
///
/// Generates schematic files in the Schemify native `.chn` text format.
/// Top-level circuits become `chn_testbench`, subcircuits become `chn` with
/// a `SYMBOL` section declaring ports.
pub struct SchemifyBackend {
    pub output_dir: String,
}

impl SchemifyBackend {
    pub fn new(output_dir: &str) -> Self {
        Self {
            output_dir: output_dir.to_string(),
        }
    }

    /// Build the `.chn` file content for a subcircuit.
    pub fn format_schematic(&self, subckt: &Subcircuit) -> String {
        let mut buf = String::new();
        let has_ports = !subckt.ports.is_empty();

        if has_ports {
            writeln!(buf, "chn 1").unwrap();
            writeln!(buf).unwrap();
            writeln!(buf, "SYMBOL {}", subckt.name).unwrap();
            write_symbol_pins(&mut buf, subckt);
            writeln!(buf).unwrap();
            writeln!(buf, "SCHEMATIC").unwrap();
        } else {
            writeln!(buf, "chn_testbench 1").unwrap();
            writeln!(buf).unwrap();
            writeln!(buf, "TESTBENCH {}", subckt.name).unwrap();
        }

        write_instances(&mut buf, subckt);
        write_wires(&mut buf, subckt);

        buf
    }

    /// Validate the circuit, then write one `.chn` file per schematic
    /// (top-level testbench + each subcircuit) into `output_dir`.
    pub fn write_all(&self, circuit: &Circuit) -> Result<()> {
        let errors = validate_circuit(circuit);
        for e in &errors {
            if e.severity == Severity::Warning {
                eprintln!("warning: {}", e.message);
            }
        }
        if errors.iter().any(|e| e.severity == Severity::Error) {
            let msgs: Vec<&str> = errors
                .iter()
                .filter(|e| e.severity == Severity::Error)
                .map(|e| e.message.as_str())
                .collect();
            anyhow::bail!("Validation failed:\n{}", msgs.join("\n"));
        }

        // Top-level → testbench .chn
        let content = self.format_schematic(&circuit.top);
        self.write_file(&circuit.top.name, ".chn", &content)?;

        // Subcircuits → component .chn
        for subckt in circuit.subcircuits.values() {
            let content = self.format_schematic(subckt);
            self.write_file(&subckt.name, ".chn", &content)?;
        }

        Ok(())
    }

    fn write_file(&self, name: &str, ext: &str, content: &str) -> Result<()> {
        let filename = format!("{}{}", name, ext);
        let path = Path::new(&self.output_dir).join(&filename);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating output directory {:?}", parent))?;
        }
        fs::write(&path, content).with_context(|| format!("writing {}", path.display()))?;
        Ok(())
    }
}

impl PinGeometry for SchemifyBackend {
    fn pin_offsets(&self, primitive: Primitive) -> &[(i32, i32)] {
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

    fn transform_pin(&self, dx: i32, dy: i32, rotation: u8, flip: bool) -> (i32, i32) {
        InstanceFlags::new(rotation, flip).transform_point(dx, dy)
    }
}

// --- .chn formatting helpers ---

/// Write the `pins:` section inside SYMBOL for subcircuits with ports.
fn write_symbol_pins(buf: &mut String, subckt: &Subcircuit) {
    if subckt.ports.is_empty() {
        return;
    }
    writeln!(buf, "  pins:").unwrap();
    for (i, port) in subckt.ports.iter().enumerate() {
        let dir = subckt
            .port_directions
            .get(i)
            .copied()
            .unwrap_or(PinDir::Inout);
        let dir_str = match dir {
            PinDir::Input => "in",
            PinDir::Output => "out",
            _ => "inout",
        };
        writeln!(buf, "    {}  {}", port, dir_str).unwrap();
    }
}

/// Write the `instances:` section (components + port pins + labels).
fn write_instances(buf: &mut String, subckt: &Subcircuit) {
    writeln!(buf, "  instances:").unwrap();

    for inst in &subckt.instances {
        write_component_instance(buf, inst);
    }

    if !subckt.ports.is_empty() {
        write_port_pins(buf, subckt);
    }

    write_label_instances(buf, subckt);
}

/// Format a single component instance line.
fn write_component_instance(buf: &mut String, inst: &ir::Instance) {
    let kind = primitive_kind(inst.primitive);
    let sym = primitive_sym(inst.primitive);

    write!(buf, "    {}  {}  x={}  y={}", inst.name, kind, inst.x, inst.y).unwrap();

    if inst.rotation != 0 {
        write!(buf, "  rot={}", inst.rotation).unwrap();
    }
    if inst.flip {
        write!(buf, "  flip=1").unwrap();
    }
    write!(buf, "  sym={}", sym).unwrap();

    // Collect params; add `device=<kind>` for passives if missing; then sort.
    let mut params: Vec<(&str, &str)> = inst
        .params
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();

    let needs_device = matches!(
        inst.primitive,
        Primitive::Resistor | Primitive::Capacitor | Primitive::Inductor
    );
    if needs_device && !inst.params.contains_key("device") {
        params.push(("device", kind));
    }

    params.sort_by_key(|(k, _)| *k);

    if !params.is_empty() {
        if params.len() > 3 {
            // Block form
            write!(buf, "\n      .parameters{{").unwrap();
            for (i, (k, v)) in params.iter().enumerate() {
                let sep = if i == 0 { "   " } else { "  " };
                write!(buf, "{}{}={}", sep, k, v).unwrap();
            }
            write!(buf, " }}").unwrap();
        } else {
            // Inline form
            for (k, v) in &params {
                write!(buf, "  {}={}", k, v).unwrap();
            }
        }
    }

    writeln!(buf).unwrap();
}

/// Write port pin instances (ipin/opin/iopin) for subcircuits.
fn write_port_pins(buf: &mut String, subckt: &Subcircuit) {
    let (input_ports, output_ports, io_ports) = classify_ports(subckt);

    let margin = 200;
    let bbox = compute_instance_bbox(subckt);
    let (left_x, right_x, bb_x_min, bb_x_max, bb_y_min, bb_y_max) = match bbox {
        Some(bb) => (
            bb.x_min - margin,
            bb.x_max + margin,
            bb.x_min,
            bb.x_max,
            bb.y_min,
            bb.y_max,
        ),
        None => (-200, 200, -200, 200, -200, 200),
    };
    let top_y = bb_y_min - margin;
    let bottom_y = bb_y_max + margin;

    // Separate power/ground from regular io.
    let mut power_ports: Vec<(&str, PinDir)> = Vec::new();
    let mut ground_ports: Vec<(&str, PinDir)> = Vec::new();
    let mut regular_io: Vec<(&str, PinDir)> = Vec::new();

    for &(name, dir) in &io_ports {
        let name_lower = name.to_ascii_lowercase();
        let is_power = subckt
            .nets
            .iter()
            .any(|n| n.name == name && n.classification == NetClass::Power)
            || POWER_NAMES.iter().any(|&p| name_lower == p);
        let is_ground = subckt
            .nets
            .iter()
            .any(|n| n.name == name && n.classification == NetClass::Ground)
            || GROUND_NAMES.iter().any(|&g| name_lower == g);

        if is_power {
            power_ports.push((name, dir));
        } else if is_ground {
            ground_ports.push((name, dir));
        } else {
            regular_io.push((name, dir));
        }
    }

    let io_on_left = input_ports.len() <= output_ports.len();
    let left_count = input_ports.len() + if io_on_left { regular_io.len() } else { 0 };
    let right_count = output_ports.len() + if !io_on_left { regular_io.len() } else { 0 };
    let left_ys = distribute_y(left_count, bb_y_min, bb_y_max);
    let right_ys = distribute_y(right_count, bb_y_min, bb_y_max);
    let power_xs = distribute_x(power_ports.len(), bb_x_min, bb_x_max);
    let ground_xs = distribute_x(ground_ports.len(), bb_x_min, bb_x_max);

    for (i, (name, _)) in input_ports.iter().enumerate() {
        writeln!(
            buf,
            "    {}  ipin  x={}  y={}  sym=input_pin",
            name, left_x, left_ys[i]
        )
        .unwrap();
    }
    for (i, (name, _)) in output_ports.iter().enumerate() {
        writeln!(
            buf,
            "    {}  opin  x={}  y={}  sym=output_pin",
            name, right_x, right_ys[i]
        )
        .unwrap();
    }
    for (i, (name, _)) in power_ports.iter().enumerate() {
        writeln!(
            buf,
            "    {}  iopin  x={}  y={}  sym=inout_pin",
            name, power_xs[i], top_y
        )
        .unwrap();
    }
    for (i, (name, _)) in ground_ports.iter().enumerate() {
        writeln!(
            buf,
            "    {}  iopin  x={}  y={}  sym=inout_pin",
            name, ground_xs[i], bottom_y
        )
        .unwrap();
    }
    for (i, (name, _)) in regular_io.iter().enumerate() {
        let (x, y) = if io_on_left {
            (left_x, left_ys[input_ports.len() + i])
        } else {
            (right_x, right_ys[output_ports.len() + i])
        };
        writeln!(buf, "    {}  iopin  x={}  y={}  sym=inout_pin", name, x, y).unwrap();
    }
}

/// Write label instances (lab_pin / gnd / vdd).
fn write_label_instances(buf: &mut String, subckt: &Subcircuit) {
    let mut gnd_counter = 0usize;
    let mut vdd_counter = 0usize;

    for label in &subckt.labels {
        let net = match subckt.nets.get(label.net_idx.index()) {
            Some(n) => n,
            None => continue,
        };

        // Use gnd/vdd symbols only when BOTH classification and name match,
        // because annotation can misclassify numeric net names as ground.
        let name_lower = net.name.to_ascii_lowercase();
        let use_gnd = net.classification == NetClass::Ground
            && GROUND_NAMES.iter().any(|&g| name_lower == g);
        let use_vdd = net.classification == NetClass::Power
            && POWER_NAMES.iter().any(|&p| name_lower == p);

        if use_gnd {
            // gnd primitive pin at (0,-10) → place instance at (x, y+10)
            writeln!(
                buf,
                "    gnd{}  gnd  x={}  y={}  sym=gnd",
                gnd_counter,
                label.x,
                label.y + 10
            )
            .unwrap();
            gnd_counter += 1;
        } else if use_vdd {
            // vdd primitive pin at (0,+10) → place instance at (x, y-10)
            writeln!(
                buf,
                "    vdd{}  vdd  x={}  y={}  sym=vdd",
                vdd_counter,
                label.x,
                label.y - 10
            )
            .unwrap();
            vdd_counter += 1;
        } else {
            writeln!(
                buf,
                "    {}  lab_pin  x={}  y={}  sym=lab_pin",
                net.name, label.x, label.y
            )
            .unwrap();
        }
    }
}

/// Write the `wires:` section with net-name annotations.
fn write_wires(buf: &mut String, subckt: &Subcircuit) {
    if subckt.wires.is_empty() {
        return;
    }
    writeln!(buf).unwrap();
    writeln!(buf, "  wires:").unwrap();
    for wire in &subckt.wires {
        let net_name = subckt
            .nets
            .get(wire.net_idx.index())
            .map(|n| n.name.as_str())
            .unwrap_or("");
        if !net_name.is_empty() {
            writeln!(
                buf,
                "    {} {} {} {} {}",
                wire.x1, wire.y1, wire.x2, wire.y2, net_name
            )
            .unwrap();
        } else {
            writeln!(buf, "    {} {} {} {}", wire.x1, wire.y1, wire.x2, wire.y2).unwrap();
        }
    }
}

fn primitive_kind(p: Primitive) -> &'static str {
    match p {
        Primitive::Nmos => "nmos",
        Primitive::Pmos => "pmos",
        Primitive::Npn => "npn",
        Primitive::Pnp => "pnp",
        Primitive::Resistor => "resistor",
        Primitive::Capacitor => "capacitor",
        Primitive::Inductor => "inductor",
        Primitive::Diode => "diode",
        Primitive::Vsource => "vsource",
        Primitive::Isource => "isource",
        Primitive::Vcvs => "vcvs",
        Primitive::Vccs => "vccs",
        Primitive::Ccvs => "ccvs",
        Primitive::Cccs => "cccs",
        Primitive::Jfet => "jfet",
        Primitive::BehavioralSource => "bsource",
        Primitive::Subcircuit => "subckt",
    }
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
    check_rotation_values(subckt, &mut errors);
    check_wire_orthogonality(subckt, &mut errors);
    check_no_duplicate_wires(subckt, &mut errors);
    check_net_label_consistency(subckt, &mut errors);

    errors
}

/// Validate full circuit (all subcircuits + top).
pub fn validate_circuit(circuit: &Circuit) -> Vec<ValidationError> {
    let mut errors = validate_subcircuit(&circuit.top);
    for (name, sub) in &circuit.subcircuits {
        for mut e in validate_subcircuit(sub) {
            e.message = format!("subcircuit '{}': {}", name, e.message);
            errors.push(e);
        }
    }
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

/// Rotation must be in {0, 1, 2, 3}.
pub fn check_rotation_values(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    for inst in &subckt.instances {
        if inst.rotation > 3 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "instance '{}' has invalid rotation {}",
                    inst.name, inst.rotation
                ),
            });
        }
    }
    for (i, label) in subckt.labels.iter().enumerate() {
        if label.rotation > 3 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!("label {} has invalid rotation {}", i, label.rotation),
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
/// populated `Schematic` with instances, wires, labels, and globals.
pub fn schematic_from_subcircuit(sub: &ir::Subcircuit, int: &mut Rodeo) -> Schematic {
    let empty = int.get_or_intern("");
    let mut schematic = Schematic {
        name: sub.name.clone(),
        stype: if sub.ports.is_empty() {
            SchematicType::Testbench
        } else {
            SchematicType::Schematic
        },
        ..Default::default()
    };

    // Component instances
    for inst in &sub.instances {
        let prop_start = schematic.properties.len() as u32;

        let mut params: Vec<(&str, &str)> = inst
            .params
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        params.sort_by_key(|(k, _)| *k);

        for (k, v) in &params {
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
            spice_line: empty,
            x: inst.x,
            y: inst.y,
            kind: map_device_kind(inst.primitive),
            flags: InstanceFlags::new(inst.rotation, inst.flip),
            prop_start,
            prop_count,
            name_offset: [0, 0],
            param_offset: [0, 0],
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
            let flags = InstanceFlags::new(label.rotation, false);
            let (tx, ty) = flags.transform_point(0, -10);
            (n, "gnd", DeviceKind::Gnd, label.x - tx, label.y - ty)
        } else if is_vdd {
            let n = format!("vdd{vdd_counter}");
            vdd_counter += 1;
            let flags = InstanceFlags::new(label.rotation, false);
            let (tx, ty) = flags.transform_point(0, 10);
            (n, "vdd", DeviceKind::Vdd, label.x - tx, label.y - ty)
        } else {
            (
                net.name.clone(),
                "lab_pin",
                DeviceKind::LabPin,
                label.x,
                label.y,
            )
        };

        let prop_start = schematic.properties.len() as u32;
        let prop_count = if is_gnd || is_vdd {
            schematic.properties.push(Property {
                key: int.get_or_intern("net"),
                value: int.get_or_intern(&net.name),
            });
            1u16
        } else {
            0u16
        };

        schematic.instances.push(CoreInstance {
            name: int.get_or_intern(&inst_name),
            symbol: int.get_or_intern(sym),
            spice_line: empty,
            x,
            y,
            kind,
            flags: InstanceFlags::new(label.rotation, false),
            prop_start,
            prop_count,
            name_offset: [0, 0],
            param_offset: [0, 0],
        });
    }

    // Wires — net_name is populated by connectivity engine, not here
    for wire in &sub.wires {
        schematic.wires.push(CoreWire {
            net_name: None,
            x0: wire.x1,
            y0: wire.y1,
            x1: wire.x2,
            y1: wire.y2,
            color: Color::NONE,
            thickness: 10,
        });
    }

    // Globals
    for net in &sub.nets {
        if net.is_global {
            schematic.globals.push(net.name.clone());
        }
    }

    schematic
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
        let rotation = flags.rotation();
        let flip = flags.flip();

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
                let label_flags = InstanceFlags::new(rotation, false);
                let (tx, ty) = label_flags.transform_point(0, pin_dy);
                sub.labels.push(ir::Label {
                    net_idx,
                    x: x + tx,
                    y: y + ty,
                    rotation,
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
                    rotation,
                });
            }
            _ => {
                // Device instance
                if let Some(prim) = map_primitive(kind) {
                    let mut params = HashMap::new();
                    let prop_start = sch.instances.prop_start[i] as usize;
                    let prop_count = sch.instances.prop_count[i] as usize;
                    for pi in prop_start..prop_start + prop_count {
                        if let Some(prop) = sch.properties.get(pi) {
                            params.insert(
                                int.resolve(&prop.key).to_owned(),
                                int.resolve(&prop.value).to_owned(),
                            );
                        }
                    }

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
                        rotation,
                        flip,
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

    // Globals
    for global in &sch.globals {
        let net_idx = get_or_create_net(global, &mut sub.nets);
        sub.nets[net_idx.index()].is_global = true;
    }

    // Ports: schematic-type schematics have ports derived from label instances
    if sch.stype == SchematicType::Schematic {
        for i in 0..sch.instances.len() {
            if sch.instances.kind[i].is_label() {
                let port_name = int.resolve(&sch.instances.name[i]).to_owned();
                if !sub.ports.contains(&port_name) {
                    sub.ports.push(port_name);
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
    use std::collections::HashMap;

    fn mosfet(name: &str, x: i32, y: i32) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: HashMap::new(),
            x,
            y,
            rotation: 0,
            flip: false,
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
            rotation: 0,
        });
        subckt
    }

    // -- emission --

    #[test]
    fn format_subcircuit_with_ports_has_symbol_section() {
        let mut subckt = valid_subckt();
        subckt.ports = vec!["inp".to_string(), "out".to_string()];
        subckt.port_directions = vec![PinDir::Input, PinDir::Output];
        let out = SchemifyBackend::new("/tmp/test").format_schematic(&subckt);

        assert!(out.starts_with("chn 1\n"));
        assert!(out.contains("SYMBOL test\n"));
        assert!(out.contains("SCHEMATIC\n"));
        assert!(out.contains("    inp  in\n"));
        assert!(out.contains("    out  out\n"));
        assert!(out.contains("    inp  ipin"));
        assert!(out.contains("    out  opin"));
    }

    #[test]
    fn format_portless_subcircuit_is_testbench() {
        let subckt = valid_subckt();
        let out = SchemifyBackend::new("/tmp/test").format_schematic(&subckt);

        assert!(out.starts_with("chn_testbench 1\n"));
        assert!(out.contains("TESTBENCH test\n"));
        assert!(!out.contains("SYMBOL"));
        // wire emitted with net name
        assert!(out.contains("    100 200 200 200 vdd\n"));
    }

    #[test]
    fn format_resistor_gets_device_param_inline() {
        let mut subckt = Subcircuit::new("top");
        subckt.instances.push(Instance {
            name: "R1".to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins: vec![],
            params: [("value".to_string(), "1k".to_string())].into_iter().collect(),
            x: 10,
            y: 0,
            rotation: 0,
            flip: false,
        });
        let out = SchemifyBackend::new("/tmp/test").format_schematic(&subckt);

        assert!(out.contains("sym=res  device=resistor  value=1k\n"));
        assert!(!out.contains(".parameters{"));
    }

    // -- pin geometry --

    #[test]
    fn pin_offsets_and_transforms() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.pin_offsets(Primitive::Nmos), &NMOS_PIN_OFFSETS);
        assert_eq!(backend.pin_offsets(Primitive::Pmos), &PMOS_PIN_OFFSETS);
        assert_eq!(backend.pin_offsets(Primitive::Resistor), &TWO_TERM_OFFSETS);
        assert_eq!(backend.transform_pin(20, -30, 0, false), (20, -30));
        assert_eq!(backend.transform_pin(20, -30, 1, false), (30, 20));
        assert_eq!(backend.transform_pin(20, -30, 0, true), (-20, -30));
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
    fn duplicate_name_diagonal_wire_bad_rotation_bad_label_detected() {
        let mut subckt = valid_subckt();
        subckt.instances.push(mosfet("M1", 200, 200));
        subckt.wires.push(Wire {
            net_idx: NetId(0),
            x1: 0,
            y1: 0,
            x2: 100,
            y2: 100,
        });
        subckt.instances[0].rotation = 5;
        subckt.labels[0].net_idx = NetId(99);
        let errors = validate_subcircuit(&subckt);
        assert!(errors.iter().any(|e| e.message.contains("duplicate instance name 'M1'")));
        assert!(errors.iter().any(|e| e.message.contains("diagonal")));
        assert!(errors.iter().any(|e| e.message.contains("invalid rotation")));
        assert!(errors.iter().any(|e| e.message.contains("references net_idx 99")));
    }

    #[test]
    fn validate_circuit_prefixes_subcircuit_name() {
        let mut circuit = Circuit::new("top");
        let mut bad_sub = Subcircuit::new("inv");
        bad_sub.instances.push(mosfet("X1", 105, 200)); // off-grid
        circuit.subcircuits.insert("inv".to_string(), bad_sub);

        let errors = validate_circuit(&circuit);
        assert!(errors.iter().any(|e| e.message.contains("subcircuit 'inv':")));
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
            params: [("value".into(), "1k".into())].into_iter().collect(),
            x: 100,
            y: 200,
            rotation: 0,
            flip: false,
        });
        sub
    }

    #[test]
    fn schematic_from_subcircuit_preserves_instance_and_props() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

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
        sub.labels.push(Label { net_idx: NetId(0), x: 0, y: 0, rotation: 0 });
        sub.labels.push(Label { net_idx: NetId(1), x: 10, y: 0, rotation: 0 });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        // Instance count + fields preserved
        assert_eq!(sub2.instances.len(), sub.instances.len());
        assert_eq!(sub2.instances[0].name, "R1");
        assert_eq!(sub2.instances[0].primitive, Primitive::Resistor);
        assert_eq!((sub2.instances[0].x, sub2.instances[0].y), (100, 200));
        assert_eq!(
            sub2.instances[0].params.get("value").map(String::as_str),
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
        sub.labels.push(Label { net_idx: NetId(0), x: 50, y: 60, rotation: 0 });
        sub.labels.push(Label { net_idx: NetId(1), x: 50, y: -60, rotation: 0 });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
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
    fn roundtrip_globals_and_ports() {
        let mut sub = ir::Subcircuit::new("amp");
        sub.ports = vec!["in".into(), "out".into()];
        sub.nets.push(Net::new("in"));
        sub.nets.push(Net::new("out"));
        let mut glob = Net::new("vdd!");
        glob.is_global = true;
        sub.nets.push(glob);
        sub.labels.push(Label { net_idx: NetId(0), x: 0, y: 0, rotation: 0 });
        sub.labels.push(Label { net_idx: NetId(1), x: 100, y: 0, rotation: 0 });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        assert_eq!(sch.stype, SchematicType::Schematic);
        assert_eq!(sch.globals, vec!["vdd!"]);

        let sub2 = subcircuit_from_schematic(&sch, &int);
        assert!(sub2.nets.iter().any(|n| n.name == "vdd!" && n.is_global));
        assert_eq!(sub2.ports.len(), 2);
        assert!(sub2.ports.contains(&"in".to_string()));
        assert!(sub2.ports.contains(&"out".to_string()));
    }
}
