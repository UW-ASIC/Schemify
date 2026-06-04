//! Schemify `.chn` output backend.
//!
//! Generates schematic files in the Schemify native `.chn` text format.
//! Top-level circuits become `chn_testbench`, subcircuits become `chn` with
//! a `SYMBOL` section declaring ports.

use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use schemify_core::types::InstanceFlags;

use crate::s2s::ir::{Circuit, NetClass, PinDir, Primitive, Subcircuit};
use crate::s2s::shared::primitive_sym;
use crate::s2s::validation::{self, Severity};

use super::{
    classify_ports, compute_instance_bbox, distribute_x, distribute_y, Backend, PinGeometry,
    GROUND_NAMES, POWER_NAMES,
};

// ---------------------------------------------------------------------------
// Pin offsets — match Schemify primitive `pin_positions` exactly.
// ---------------------------------------------------------------------------

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
// Backend
// ---------------------------------------------------------------------------

/// Schemify `.chn` output backend.
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
        InstanceFlags::new(rotation, flip, false).transform_point(dx, dy)
    }
}

impl Backend for SchemifyBackend {
    fn resolve_symbol(&self, primitive: Primitive, _symbol_hint: &str) -> String {
        primitive_sym(primitive).to_string()
    }

    fn write_all(&self, circuit: &Circuit) -> Result<()> {
        let errors = validation::validate_circuit(circuit);
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
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

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

    // Component instances
    for inst in &subckt.instances {
        write_component_instance(buf, inst);
    }

    // Port pins (for subcircuits with ports)
    if !subckt.ports.is_empty() {
        write_port_pins(buf, subckt);
    }

    // Labels → lab_pin / gnd / vdd instances
    write_label_instances(buf, subckt);
}

/// Format a single component instance line.
fn write_component_instance(buf: &mut String, inst: &crate::s2s::ir::Instance) {
    let kind = primitive_kind(inst.primitive);
    let sym = primitive_sym(inst.primitive);

    write!(
        buf,
        "    {}  {}  x={}  y={}",
        inst.name, kind, inst.x, inst.y
    )
    .unwrap();

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

    let device_val: String;
    let needs_device = matches!(
        inst.primitive,
        Primitive::Resistor | Primitive::Capacitor | Primitive::Inductor
    );
    if needs_device && !inst.params.contains_key("device") {
        device_val = kind.to_string();
        params.push(("device", &device_val));
    }

    params.sort_by_key(|(k, _)| *k);

    if !params.is_empty() {
        if params.len() > 3 {
            // Block form
            write!(buf, "\n      .parameters{{").unwrap();
            for (i, (k, v)) in params.iter().enumerate() {
                if i == 0 {
                    write!(buf, "   {}={}", k, v).unwrap();
                } else {
                    write!(buf, "  {}={}", k, v).unwrap();
                }
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
        let net = match subckt.nets.get(label.net_idx as usize) {
            Some(n) => n,
            None => continue,
        };

        // Use gnd/vdd symbols only when BOTH classification and name match,
        // because annotation can misclassify numeric net names as ground.
        let name_lower = net.name.to_ascii_lowercase();
        let use_gnd =
            net.classification == NetClass::Ground && GROUND_NAMES.iter().any(|&g| name_lower == g);
        let use_vdd =
            net.classification == NetClass::Power && POWER_NAMES.iter().any(|&p| name_lower == p);

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
            .get(wire.net_idx as usize)
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

// ---------------------------------------------------------------------------
// Mapping helpers
// ---------------------------------------------------------------------------

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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::{Instance, Label, Net, Pin, PinDir, Primitive, Subcircuit, Wire};
    use std::collections::HashMap;

    fn sample_subckt() -> Subcircuit {
        let mut subckt = Subcircuit::new("amp");
        subckt.ports = vec!["inp".to_string(), "out".to_string(), "vdd".to_string()];
        subckt.port_directions = vec![PinDir::Input, PinDir::Output, PinDir::Inout];

        let mut params = HashMap::new();
        params.insert("model".to_string(), "nch".to_string());
        params.insert("w".to_string(), "1u".to_string());
        params.insert("l".to_string(), "180n".to_string());
        params.insert("m".to_string(), "1".to_string());

        subckt.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![
                Pin {
                    name: "D".to_string(),
                    dir: PinDir::Inout,
                    net_idx: Some(0),
                },
                Pin {
                    name: "G".to_string(),
                    dir: PinDir::Input,
                    net_idx: Some(1),
                },
                Pin {
                    name: "S".to_string(),
                    dir: PinDir::Inout,
                    net_idx: Some(2),
                },
                Pin {
                    name: "B".to_string(),
                    dir: PinDir::Bulk,
                    net_idx: Some(2),
                },
            ],
            params,
            x: 100,
            y: 200,
            rotation: 0,
            flip: false,
        });

        subckt.nets = vec![Net::new("out"), Net::new("inp"), {
            let mut n = Net::new("GND");
            n.classification = NetClass::Ground;
            n
        }];

        subckt.wires.push(Wire {
            net_idx: 0,
            x1: 120,
            y1: 170,
            x2: 200,
            y2: 170,
        });

        subckt.labels.push(Label {
            net_idx: 2,
            x: 120,
            y: 230,
            rotation: 0,
        });

        subckt
    }

    #[test]
    fn test_format_subcircuit_header() {
        let subckt = sample_subckt();
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        assert!(output.starts_with("chn 1\n"));
        assert!(output.contains("SYMBOL amp\n"));
        assert!(output.contains("SCHEMATIC\n"));
        assert!(output.contains("  pins:\n"));
        assert!(output.contains("    inp  in\n"));
        assert!(output.contains("    out  out\n"));
        assert!(output.contains("    vdd  inout\n"));
    }

    #[test]
    fn test_format_testbench_header() {
        let mut subckt = Subcircuit::new("top");
        subckt.instances.push(Instance {
            name: "R1".to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins: vec![],
            params: {
                let mut p = HashMap::new();
                p.insert("value".to_string(), "1k".to_string());
                p
            },
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        assert!(output.starts_with("chn_testbench 1\n"));
        assert!(output.contains("TESTBENCH top\n"));
        assert!(!output.contains("SYMBOL"));
        assert!(!output.contains("SCHEMATIC"));
    }

    #[test]
    fn test_format_mosfet_block_params() {
        let subckt = sample_subckt();
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        // MOSFET has 4 params → block form
        assert!(output.contains("M1  nmos  x=100  y=200  sym=nmos4\n"));
        assert!(output.contains(".parameters{"));
        assert!(output.contains("l=180n"));
        assert!(output.contains("m=1"));
        assert!(output.contains("model=nch"));
        assert!(output.contains("w=1u"));
    }

    #[test]
    fn test_format_resistor_inline_params() {
        let mut subckt = Subcircuit::new("top");
        subckt.instances.push(Instance {
            name: "R1".to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins: vec![],
            params: {
                let mut p = HashMap::new();
                p.insert("value".to_string(), "1k".to_string());
                p
            },
            x: 10,
            y: 0,
            rotation: 0,
            flip: false,
        });
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        // Resistor has 2 params (value + auto device) → inline, sorted by key
        assert!(output.contains("sym=res  device=resistor  value=1k\n"));
        assert!(!output.contains(".parameters{"));
    }

    #[test]
    fn test_format_wire_with_net_name() {
        let subckt = sample_subckt();
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        assert!(output.contains("  wires:\n"));
        assert!(output.contains("    120 170 200 170 out\n"));
    }

    #[test]
    fn test_format_gnd_label() {
        let subckt = sample_subckt();
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        // gnd label at (120, 230) → gnd instance at (120, 240) with pin at (120, 230)
        assert!(output.contains("gnd0  gnd  x=120  y=240  sym=gnd\n"));
    }

    #[test]
    fn test_format_rotation_flip() {
        let mut subckt = Subcircuit::new("top");
        subckt.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: {
                let mut p = HashMap::new();
                p.insert("model".to_string(), "nch".to_string());
                p
            },
            x: 50,
            y: 100,
            rotation: 2,
            flip: true,
        });
        let backend = SchemifyBackend::new("/tmp/test");
        let output = backend.format_schematic(&subckt);

        assert!(output.contains("x=50  y=100  rot=2  flip=1  sym=nmos4"));
    }

    #[test]
    fn test_pin_offsets_mosfet() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.pin_offsets(Primitive::Nmos), &NMOS_PIN_OFFSETS);
        assert_eq!(backend.pin_offsets(Primitive::Pmos), &PMOS_PIN_OFFSETS);
    }

    #[test]
    fn test_pin_offsets_bjt() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.pin_offsets(Primitive::Npn), &NPN_PIN_OFFSETS);
        assert_eq!(backend.pin_offsets(Primitive::Pnp), &PNP_PIN_OFFSETS);
    }

    #[test]
    fn test_pin_offsets_two_terminal() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.pin_offsets(Primitive::Resistor), &TWO_TERM_OFFSETS);
        assert_eq!(backend.pin_offsets(Primitive::Capacitor), &TWO_TERM_OFFSETS);
    }

    #[test]
    fn test_transform_pin_identity() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.transform_pin(20, -30, 0, false), (20, -30));
    }

    #[test]
    fn test_transform_pin_rot90() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.transform_pin(20, -30, 1, false), (30, 20));
    }

    #[test]
    fn test_transform_pin_flip() {
        let backend = SchemifyBackend::new("/tmp");
        assert_eq!(backend.transform_pin(20, -30, 0, true), (-20, -30));
    }
}
