//! XSchem `.sch` / `.sym` output backend.
//!
//! Generates schematic files in the XSchem native text format.
//! Each subcircuit produces both a `.sch` (schematic) and `.sym` (symbol) file.
//! The top-level circuit produces only a `.sch`.

use std::collections::HashMap;
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use super::{
    classify_ports, compute_instance_bbox, distribute_x, distribute_y, Backend, PinGeometry,
    GROUND_NAMES, POWER_NAMES,
};
use crate::s2s::ir::{Circuit, PinDir, Primitive, Subcircuit};
use crate::s2s::validation::{self, Severity};

/// XSchem nmos4 pin offsets (from xschem_library/devices/nmos4.sym).
const NMOS_PIN_OFFSETS: [(i32, i32); 4] = [
    (20, -30), // D: top
    (-20, 0),  // G: left
    (20, 30),  // S: bottom
    (20, 0),   // B: middle right
];

/// XSchem pmos4 pin offsets (from xschem_library/devices/pmos4.sym).
const PMOS_PIN_OFFSETS: [(i32, i32); 4] = [
    (20, 30),  // D: bottom
    (-20, 0),  // G: left
    (20, -30), // S: top
    (20, 0),   // B: middle right
];

/// Two-terminal device pin offsets (res, cap, vsource, isource, diode).
const TWO_TERM_OFFSETS: [(i32, i32); 2] = [
    (0, -30), // p/+/A: top
    (0, 30),  // n/-/K: bottom
];

/// JFET: D=(20,-30) G=(-20,0) S=(20,30) — same layout as BJT
const JFET_PIN_OFFSETS: [(i32, i32); 3] = [(20, -30), (-20, 0), (20, 30)];

/// Voltage-controlled sources (VCVS/VCCS): p=(0,-30) n=(0,30) cp=(-30,-10) cn=(-30,10)
const VCXS_OFFSETS: [(i32, i32); 4] = [(0, -30), (0, 30), (-30, -10), (-30, 10)];

/// XSchem schematic/symbol output backend.
pub struct XschemBackend {
    pub output_dir: String,
    pub xschem_version: String,
    pub file_version: String,
    /// SPICE primitive name -> XSchem symbol path.
    pub symbol_map: HashMap<String, String>,
}

impl XschemBackend {
    /// Create a new XSchem backend writing to the given output directory.
    pub fn new(output_dir: &str) -> Self {
        let mut backend = Self {
            output_dir: output_dir.to_string(),
            xschem_version: "3.4.7".to_string(),
            file_version: "1.3".to_string(),
            symbol_map: HashMap::new(),
        };
        backend.init_default_symbols();
        backend
    }

    fn init_default_symbols(&mut self) {
        let defaults = [
            ("nmos", "devices/nmos4.sym"),
            ("pmos", "devices/pmos4.sym"),
            ("npn", "devices/npn.sym"),
            ("pnp", "devices/pnp.sym"),
            ("resistor", "devices/res.sym"),
            ("capacitor", "devices/capa.sym"),
            ("inductor", "devices/ind.sym"),
            ("diode", "devices/diode.sym"),
            ("vsource", "devices/vsource.sym"),
            ("isource", "devices/isource.sym"),
        ];
        for (key, val) in defaults {
            self.symbol_map.insert(key.to_string(), val.to_string());
        }
    }

    /// Resolve the XSchem symbol path for an instance.
    ///
    /// If the instance already carries a non-empty `symbol`, use it directly.
    /// When a `SymbolConfig` is present, use it to resolve the symbol from
    /// the primitive type and optional model name.
    /// Otherwise fall back to the hardcoded `symbol_map`.
    fn resolve_symbol_str(
        &self,
        symbol: &str,
        primitive: Primitive,
        _model: Option<&str>,
    ) -> String {
        if !symbol.is_empty() {
            return symbol.to_string();
        }
        let key = primitive_name(primitive);
        self.symbol_map
            .get(key)
            .cloned()
            .unwrap_or_else(|| format!("devices/{}.sym", key))
    }

    /// Build the `.sch` file content for a subcircuit.
    pub fn format_schematic(&self, subckt: &Subcircuit) -> String {
        let mut buf = String::new();

        // Version header
        writeln!(
            buf,
            "v {{xschem version={} file_version={}}}",
            self.xschem_version, self.file_version
        )
        .unwrap();

        // Required empty records
        buf.push_str("G {}\n");
        buf.push_str("K {}\n");
        buf.push_str("V {}\n");
        buf.push_str("S {}\n");
        buf.push_str("E {}\n");

        // Port pins for subcircuits (ipin/opin/iopin)
        let (input_ports, output_ports, io_ports) = classify_ports(subckt);

        // Compute bounding box of instances for pin placement.
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

        // Separate power/ground iopins from regular iopins.
        let mut power_ports: Vec<(&str, PinDir)> = Vec::new();
        let mut ground_ports: Vec<(&str, PinDir)> = Vec::new();
        let mut regular_io: Vec<(&str, PinDir)> = Vec::new();

        for &(name, dir) in &io_ports {
            let name_lower = name.to_ascii_lowercase();
            // Check net classification first, fall back to name matching.
            let is_power = subckt
                .nets
                .iter()
                .any(|n| n.name == name && n.classification == crate::s2s::ir::NetClass::Power)
                || POWER_NAMES.iter().any(|&p| name_lower == p);
            let is_ground =
                subckt.nets.iter().any(|n| {
                    n.name == name && n.classification == crate::s2s::ir::NetClass::Ground
                }) || GROUND_NAMES.iter().any(|&g| name_lower == g);

            if is_power {
                power_ports.push((name, dir));
            } else if is_ground {
                ground_ports.push((name, dir));
            } else {
                regular_io.push((name, dir));
            }
        }

        // Decide which side regular iopins go on: whichever has fewer pins.
        let io_on_left = input_ports.len() <= output_ports.len();

        let left_count = input_ports.len() + if io_on_left { regular_io.len() } else { 0 };
        let right_count = output_ports.len() + if !io_on_left { regular_io.len() } else { 0 };

        let left_ys = distribute_y(left_count, bb_y_min, bb_y_max);
        let right_ys = distribute_y(right_count, bb_y_min, bb_y_max);

        // Power pins at top edge, ground pins at bottom edge, distributed across X.
        let power_xs = distribute_x(power_ports.len(), bb_x_min, bb_x_max);
        let ground_xs = distribute_x(ground_ports.len(), bb_x_min, bb_x_max);

        let mut pin_counter: usize = 0;

        for (i, (name, _dir)) in input_ports.iter().enumerate() {
            let y = left_ys[i];
            writeln!(
                buf,
                "C {{devices/ipin.sym}} {} {} 0 0 {{name=p{} lab={}}}",
                left_x, y, pin_counter, name
            )
            .unwrap();
            pin_counter += 1;
        }

        for (i, (name, _dir)) in output_ports.iter().enumerate() {
            let y = right_ys[i];
            writeln!(
                buf,
                "C {{devices/opin.sym}} {} {} 0 0 {{name=p{} lab={}}}",
                right_x, y, pin_counter, name
            )
            .unwrap();
            pin_counter += 1;
        }

        // Power iopins at top
        for (i, (name, _dir)) in power_ports.iter().enumerate() {
            let x = power_xs[i];
            writeln!(
                buf,
                "C {{devices/iopin.sym}} {} {} 0 0 {{name=p{} lab={}}}",
                x, top_y, pin_counter, name
            )
            .unwrap();
            pin_counter += 1;
        }

        // Ground iopins at bottom
        for (i, (name, _dir)) in ground_ports.iter().enumerate() {
            let x = ground_xs[i];
            writeln!(
                buf,
                "C {{devices/iopin.sym}} {} {} 0 0 {{name=p{} lab={}}}",
                x, bottom_y, pin_counter, name
            )
            .unwrap();
            pin_counter += 1;
        }

        // Regular iopins on side edges
        for (i, (name, _dir)) in regular_io.iter().enumerate() {
            let (x, y) = if io_on_left {
                (left_x, left_ys[input_ports.len() + i])
            } else {
                (right_x, right_ys[output_ports.len() + i])
            };
            writeln!(
                buf,
                "C {{devices/iopin.sym}} {} {} 0 0 {{name=p{} lab={}}}",
                x, y, pin_counter, name
            )
            .unwrap();
            pin_counter += 1;
        }

        // Component instances
        for inst in &subckt.instances {
            let model = inst.params.get("model").map(|s| s.as_str());
            let sym = self.resolve_symbol_str(&inst.symbol, inst.primitive, model);
            let flip_val: u8 = if inst.flip { 1 } else { 0 };

            write!(
                buf,
                "C {{{}}} {} {} {} {} {{name={}",
                sym, inst.x, inst.y, inst.rotation, flip_val, inst.name
            )
            .unwrap();

            // Append parameters in deterministic order for testability.
            let mut keys: Vec<&String> = inst.params.keys().collect();
            keys.sort();
            for k in keys {
                write!(buf, " {}={}", k, inst.params[k]).unwrap();
            }
            buf.push_str("}\n");
        }

        // Wire segments
        for wire in &subckt.wires {
            let net_name = subckt
                .nets
                .get(wire.net_idx as usize)
                .map(|n| n.name.as_str())
                .unwrap_or("");

            if !net_name.is_empty() {
                writeln!(
                    buf,
                    "N {} {} {} {} {{lab={}}}",
                    wire.x1, wire.y1, wire.x2, wire.y2, net_name
                )
                .unwrap();
            } else {
                writeln!(
                    buf,
                    "N {} {} {} {} {{}}",
                    wire.x1, wire.y1, wire.x2, wire.y2
                )
                .unwrap();
            }
        }

        // Net labels (lab_pin.sym for distant connections)
        for label in &subckt.labels {
            let net_name = match subckt.nets.get(label.net_idx as usize) {
                Some(n) => n.name.as_str(),
                None => continue,
            };

            writeln!(
                buf,
                "C {{devices/lab_pin.sym}} {} {} {} 0 {{name=l{} sig_type=std_logic lab={}}}",
                label.x, label.y, label.rotation, label.net_idx, net_name
            )
            .unwrap();
        }

        // Title text at bottom-left
        let title_y = 300;
        writeln!(
            buf,
            "T {{{}}} -200 {} 0 0 0.4 0.4 {{}}",
            subckt.name, title_y
        )
        .unwrap();

        buf
    }

    /// Build the `.sym` file content for a subcircuit.
    pub fn format_symbol(&self, subckt: &Subcircuit) -> String {
        let mut buf = String::new();

        // Version header
        writeln!(
            buf,
            "v {{xschem version={} file_version={}}}",
            self.xschem_version, self.file_version
        )
        .unwrap();

        buf.push_str("G {}\n");
        buf.push_str("K {type=subcircuit format=\"@name @pinlist @symname\"}\n");
        buf.push_str("V {}\n");
        buf.push_str("S {}\n");
        buf.push_str("E {}\n");

        // Classify ports by direction.
        let (input_ports, output_ports, io_ports) = classify_ports(subckt);

        let left_count = input_ports.len() as i32;
        let right_count = output_ports.len() as i32;
        let top_count = io_ports.iter().filter(|(_, d)| *d == PinDir::Power).count() as i32;
        let bottom_count = io_ports
            .iter()
            .filter(|(_, d)| *d == PinDir::Ground)
            .count() as i32;
        let general_io_count = io_ports.len() as i32 - top_count - bottom_count;

        // Size the box: height based on max(left, right) pins, width based on max(top, bottom).
        let side_max = left_count
            .max(right_count)
            .max(general_io_count + left_count);
        let box_h: i32 = 60i32.max(side_max * 30 + 20);
        let tb_max = top_count.max(bottom_count);
        let box_w: i32 = 120i32.max(tb_max * 30 + 20);

        // Four sides of the box (L records, layer 4)
        writeln!(buf, "L 4 0 0 {} 0 {{}}", box_w).unwrap();
        writeln!(buf, "L 4 {} 0 {} {} {{}}", box_w, box_w, box_h).unwrap();
        writeln!(buf, "L 4 {} {} 0 {} {{}}", box_w, box_h, box_h).unwrap();
        writeln!(buf, "L 4 0 {} 0 0 {{}}", box_h).unwrap();

        // Center text label
        let half_w = box_w / 2;
        let half_h = box_h / 2;
        writeln!(
            buf,
            "T {{{}}} {} {} 0 0 0.3 0.3 {{}}",
            subckt.name, half_w, half_h
        )
        .unwrap();

        // Input pins on left edge
        for (i, (port, _dir)) in input_ports.iter().enumerate() {
            let pin_y = (i as i32) * 30 + 15;
            writeln!(
                buf,
                "B 5 -5 {} 0 {} {{name={} dir=in}}",
                pin_y - 5,
                pin_y + 5,
                port
            )
            .unwrap();
        }

        // Output pins on right edge
        for (i, (port, _dir)) in output_ports.iter().enumerate() {
            let pin_y = (i as i32) * 30 + 15;
            writeln!(
                buf,
                "B 5 {} {} {} {} {{name={} dir=out}}",
                box_w,
                pin_y - 5,
                box_w + 5,
                pin_y + 5,
                port
            )
            .unwrap();
        }

        // Power/ground/inout pins
        let mut top_idx = 0;
        let mut bottom_idx = 0;
        let mut io_left_idx = left_count; // stack below input pins on left
        for (port, dir) in &io_ports {
            match dir {
                PinDir::Power => {
                    let pin_x = top_idx * 30 + 15;
                    writeln!(
                        buf,
                        "B 5 {} -5 {} 0 {{name={} dir=inout}}",
                        pin_x - 5,
                        pin_x + 5,
                        port
                    )
                    .unwrap();
                    top_idx += 1;
                }
                PinDir::Ground => {
                    let pin_x = bottom_idx * 30 + 15;
                    writeln!(
                        buf,
                        "B 5 {} {} {} {} {{name={} dir=inout}}",
                        pin_x - 5,
                        box_h,
                        pin_x + 5,
                        box_h + 5,
                        port
                    )
                    .unwrap();
                    bottom_idx += 1;
                }
                _ => {
                    let pin_y = io_left_idx * 30 + 15;
                    writeln!(
                        buf,
                        "B 5 -5 {} 0 {} {{name={} dir=inout}}",
                        pin_y - 5,
                        pin_y + 5,
                        port
                    )
                    .unwrap();
                    io_left_idx += 1;
                }
            }
        }

        buf
    }

    /// Write string content to a file under `output_dir`.
    fn write_file(&self, name: &str, ext: &str, content: &str) -> Result<()> {
        let filename = format!("{}{}", name, ext);
        let path = Path::new(&self.output_dir).join(&filename);

        // Ensure the output directory exists.
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating output directory {:?}", parent))?;
        }

        fs::write(&path, content).with_context(|| format!("writing {}", path.display()))?;
        Ok(())
    }

    /// Write `manifest.json` listing all output files.
    fn write_manifest(&self, circuit: &Circuit) -> Result<()> {
        let mut manifest = serde_json::Map::new();
        manifest.insert(
            "top".to_string(),
            serde_json::Value::String(format!("{}.sch", circuit.top.name)),
        );

        let mut subs = serde_json::Map::new();
        for name in circuit.subcircuits.keys() {
            let mut entry = serde_json::Map::new();
            entry.insert(
                "sch".to_string(),
                serde_json::Value::String(format!("{}.sch", name)),
            );
            entry.insert(
                "sym".to_string(),
                serde_json::Value::String(format!("{}.sym", name)),
            );
            subs.insert(name.clone(), serde_json::Value::Object(entry));
        }
        manifest.insert("subcircuits".to_string(), serde_json::Value::Object(subs));

        let json = serde_json::to_string_pretty(&serde_json::Value::Object(manifest))
            .context("serializing manifest")?;

        let path = Path::new(&self.output_dir).join("manifest.json");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating output directory {:?}", parent))?;
        }
        fs::write(&path, json).with_context(|| format!("writing {}", path.display()))?;
        Ok(())
    }

    fn write_schematic(&self, subckt: &Subcircuit) -> Result<()> {
        let content = self.format_schematic(subckt);
        self.write_file(&subckt.name, ".sch", &content)
    }

    fn write_symbol(&self, subckt: &Subcircuit) -> Result<()> {
        let content = self.format_symbol(subckt);
        self.write_file(&subckt.name, ".sym", &content)
    }
}

impl PinGeometry for XschemBackend {
    fn pin_offsets(&self, primitive: Primitive) -> &[(i32, i32)] {
        match primitive {
            Primitive::Pmos => &PMOS_PIN_OFFSETS,
            Primitive::Vcvs | Primitive::Vccs => &VCXS_OFFSETS,
            Primitive::Ccvs | Primitive::Cccs => &TWO_TERM_OFFSETS,
            Primitive::Jfet => &JFET_PIN_OFFSETS,
            _ if primitive.is_mosfet() => &NMOS_PIN_OFFSETS,
            _ => &TWO_TERM_OFFSETS,
        }
    }

    fn transform_pin(&self, dx: i32, dy: i32, rotation: u8, flip: bool) -> (i32, i32) {
        let dx = if flip { -dx } else { dx };
        match rotation {
            0 => (dx, dy),
            1 => (-dy, dx),
            2 => (-dx, -dy),
            3 => (dy, -dx),
            _ => (dx, dy),
        }
    }
}

impl Backend for XschemBackend {
    fn resolve_symbol(&self, primitive: Primitive, symbol_hint: &str) -> String {
        self.resolve_symbol_str(symbol_hint, primitive, None)
    }

    fn write_all(&self, circuit: &Circuit) -> Result<()> {
        // Run structural validation before writing files.
        let errors = validation::validate_circuit(circuit);
        let fatal = errors.iter().any(|e| e.severity == Severity::Error);

        // Print warnings to stderr.
        for e in &errors {
            if e.severity == Severity::Warning {
                eprintln!("warning: {}", e.message);
            }
        }

        if fatal {
            let msgs: Vec<&str> = errors
                .iter()
                .filter(|e| e.severity == Severity::Error)
                .map(|e| e.message.as_str())
                .collect();
            anyhow::bail!("Validation failed:\n{}", msgs.join("\n"));
        }

        // Top-level schematic (no symbol needed).
        self.write_schematic(&circuit.top)?;

        // Each subcircuit gets both .sch and .sym.
        for subckt in circuit.subcircuits.values() {
            self.write_schematic(subckt)?;
            self.write_symbol(subckt)?;
        }

        // Write manifest.json.
        self.write_manifest(circuit)?;

        Ok(())
    }
}

/// Map a `Primitive` enum variant to its lowercase string key for symbol lookup.
fn primitive_name(p: Primitive) -> &'static str {
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
        Primitive::Subcircuit => "subcircuit",
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::{Instance, Label, Net, Pin, PinDir, Primitive, Subcircuit, Wire};

    /// Helper: build a minimal subcircuit with one NMOS instance, one wire, and one label.
    fn sample_subckt() -> Subcircuit {
        let mut subckt = Subcircuit::new("amp");
        subckt.ports = vec!["inp".to_string(), "out".to_string(), "vdd".to_string()];

        let mut params = HashMap::new();
        params.insert("w".to_string(), "1u".to_string());
        params.insert("l".to_string(), "180n".to_string());

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

        subckt.nets.push(Net::new("out"));
        subckt.nets.push(Net::new("inp"));
        subckt.nets.push(Net::new("gnd"));

        subckt.wires.push(Wire {
            net_idx: 0,
            x1: 100,
            y1: 170,
            x2: 200,
            y2: 170,
        });

        subckt.labels.push(Label {
            net_idx: 1,
            x: 80,
            y: 200,
            rotation: 2,
        });

        subckt
    }

    #[test]
    fn schematic_starts_with_version_header() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sch = backend.format_schematic(&subckt);

        assert!(
            sch.starts_with("v {xschem version=3.4.7 file_version=1.3}"),
            "schematic should start with version header, got: {}",
            sch.lines().next().unwrap_or("")
        );
    }

    #[test]
    fn schematic_has_gkvse_records() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sch = backend.format_schematic(&subckt);

        for record in ["G {}", "K {}", "V {}", "S {}", "E {}"] {
            assert!(sch.contains(record), "schematic should contain '{record}'");
        }
    }

    #[test]
    fn instance_rendered_as_c_record() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sch = backend.format_schematic(&subckt);

        // Should have a C record for M1 with the nmos4 symbol
        assert!(
            sch.contains("C {devices/nmos4.sym} 100 200 0 0 {name=M1"),
            "should have C record for instance M1, got:\n{sch}"
        );
    }

    #[test]
    fn wire_rendered_as_n_record() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sch = backend.format_schematic(&subckt);

        assert!(
            sch.contains("N 100 170 200 170 {lab=out}"),
            "should have N record for wire with lab=out, got:\n{sch}"
        );
    }

    #[test]
    fn net_label_rendered_as_lab_pin_c_record() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sch = backend.format_schematic(&subckt);

        assert!(
            sch.contains("C {devices/lab_pin.sym} 80 200 2 0 {name=l1 sig_type=std_logic lab=inp}"),
            "should have lab_pin C record for net label, got:\n{sch}"
        );
    }

    #[test]
    fn symbol_has_box_outline_and_pin_boxes() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sym = backend.format_symbol(&subckt);

        // All 3 ports default to Inout (no port_directions set).
        // side_max = 3, box_h = max(60, 3*30+20) = 110, box_w = 120.
        // Top edge of box:
        assert!(
            sym.contains("L 4 0 0 120 0 {}"),
            "should have box top-edge L record, got:\n{sym}"
        );

        // Pin boxes for ports (all inout, on left edge)
        assert!(
            sym.contains("B 5 -5 10 0 20 {name=inp dir=inout}"),
            "should have B 5 pin box for first port 'inp', got:\n{sym}"
        );
        assert!(
            sym.contains("B 5 -5 40 0 50 {name=out dir=inout}"),
            "should have B 5 pin box for second port 'out', got:\n{sym}"
        );
        assert!(
            sym.contains("B 5 -5 70 0 80 {name=vdd dir=inout}"),
            "should have B 5 pin box for third port 'vdd', got:\n{sym}"
        );
    }

    #[test]
    fn default_symbol_map_resolves_all_primitives() {
        let backend = XschemBackend::new("/tmp/xschem_test");

        let cases = [
            (Primitive::Nmos, "devices/nmos4.sym"),
            (Primitive::Pmos, "devices/pmos4.sym"),
            (Primitive::Npn, "devices/npn.sym"),
            (Primitive::Pnp, "devices/pnp.sym"),
            (Primitive::Resistor, "devices/res.sym"),
            (Primitive::Capacitor, "devices/capa.sym"),
            (Primitive::Inductor, "devices/ind.sym"),
            (Primitive::Diode, "devices/diode.sym"),
            (Primitive::Vsource, "devices/vsource.sym"),
            (Primitive::Isource, "devices/isource.sym"),
        ];

        for (prim, expected_sym) in cases {
            let resolved = backend.resolve_symbol_str("", prim, None);
            assert_eq!(
                resolved, expected_sym,
                "primitive {:?} should map to {}",
                prim, expected_sym
            );
        }
    }

    #[test]
    fn symbol_file_starts_with_version_header() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sym = backend.format_symbol(&subckt);

        assert!(
            sym.starts_with("v {xschem version=3.4.7 file_version=1.3}"),
            "symbol should start with version header"
        );
    }

    #[test]
    fn symbol_has_text_label() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sym = backend.format_symbol(&subckt);

        // box_w=120, box_h=110 => center at (60, 55)
        assert!(
            sym.contains("T {amp} 60 55 0 0 0.3 0.3 {}"),
            "symbol should contain centered text label, got:\n{sym}"
        );
    }

    #[test]
    fn instance_with_explicit_symbol_uses_it() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let mut subckt = Subcircuit::new("test");
        subckt.instances.push(Instance {
            name: "X1".to_string(),
            primitive: Primitive::Subcircuit,
            symbol: "my_custom.sym".to_string(),
            pins: vec![],
            params: HashMap::new(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        subckt.nets = vec![];

        let sch = backend.format_schematic(&subckt);
        assert!(
            sch.contains("C {my_custom.sym}"),
            "should use the explicit symbol, got:\n{sch}"
        );
    }

    // -----------------------------------------------------------------------
    // New tests: port pins, title text, hierarchy, manifest
    // -----------------------------------------------------------------------

    /// Build a subcircuit with explicit port directions.
    fn subckt_with_directions() -> Subcircuit {
        let mut subckt = Subcircuit::new("inv");
        subckt.ports = vec![
            "inp".to_string(),
            "out".to_string(),
            "vdd".to_string(),
            "vss".to_string(),
        ];
        subckt.port_directions = vec![PinDir::Input, PinDir::Output, PinDir::Power, PinDir::Ground];
        subckt.nets.push(Net::new("inp"));
        subckt.nets.push(Net::new("out"));
        subckt.nets.push(Net::new("vdd"));
        subckt.nets.push(Net::new("vss"));
        subckt
    }

    #[test]
    fn port_pins_emitted_for_subcircuit_with_ports() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_directions();
        let sch = backend.format_schematic(&subckt);

        // Input port -> ipin
        assert!(
            sch.contains("C {devices/ipin.sym}"),
            "should emit ipin.sym for input port, got:\n{sch}"
        );
        // Output port -> opin
        assert!(
            sch.contains("C {devices/opin.sym}"),
            "should emit opin.sym for output port, got:\n{sch}"
        );
        // Power/Ground -> iopin
        assert!(
            sch.contains("C {devices/iopin.sym}"),
            "should emit iopin.sym for power/ground port, got:\n{sch}"
        );
    }

    #[test]
    fn ipin_for_input_port() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_directions();
        let sch = backend.format_schematic(&subckt);

        // No instances => fallback bbox, left_x=-200, y distributed in [-200, 200]
        assert!(
            sch.contains("C {devices/ipin.sym} -200 0 0 0 {name=p0 lab=inp}"),
            "input port should use ipin.sym at left edge, got:\n{sch}"
        );
    }

    #[test]
    fn opin_for_output_port() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_directions();
        let sch = backend.format_schematic(&subckt);

        // No instances => fallback bbox, right_x=200
        assert!(
            sch.contains("C {devices/opin.sym} 200 0 0 0 {name=p1 lab=out}"),
            "output port should use opin.sym at right edge, got:\n{sch}"
        );
    }

    #[test]
    fn iopin_for_inout_port() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let mut subckt = Subcircuit::new("buf");
        subckt.ports = vec!["io".to_string()];
        subckt.port_directions = vec![PinDir::Inout];
        subckt.nets.push(Net::new("io"));

        let sch = backend.format_schematic(&subckt);
        assert!(
            sch.contains("C {devices/iopin.sym}") && sch.contains("lab=io"),
            "inout port should use iopin.sym, got:\n{sch}"
        );
    }

    #[test]
    fn title_text_present_in_output() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = sample_subckt();
        let sch = backend.format_schematic(&subckt);

        assert!(
            sch.contains("T {amp} -200 300 0 0 0.4 0.4 {}"),
            "should have title text record, got:\n{sch}"
        );
    }

    #[test]
    fn manifest_json_is_valid() {
        let dir = "/tmp/xschem_test_manifest";
        let _ = fs::remove_dir_all(dir);
        let backend = XschemBackend::new(dir);

        let mut circuit = Circuit::new("top");
        circuit
            .subcircuits
            .insert("inv".to_string(), Subcircuit::new("inv"));

        backend.write_manifest(&circuit).unwrap();

        let manifest_str = fs::read_to_string(Path::new(dir).join("manifest.json")).unwrap();
        let value: serde_json::Value = serde_json::from_str(&manifest_str).unwrap();

        assert_eq!(value["top"], "top.sch");
        assert_eq!(value["subcircuits"]["inv"]["sch"], "inv.sch");
        assert_eq!(value["subcircuits"]["inv"]["sym"], "inv.sym");

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn symbol_with_directions_has_correct_pin_count() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_directions();
        let sym = backend.format_symbol(&subckt);

        // 4 ports total, should have 4 B 5 records (pins)
        let pin_count = sym.matches("B 5 ").count();
        assert_eq!(
            pin_count, 4,
            "symbol should have 4 pin boxes, got {}, sym:\n{}",
            pin_count, sym
        );
    }

    #[test]
    fn symbol_input_pins_on_left_output_on_right() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_directions();
        let sym = backend.format_symbol(&subckt);

        // Input pin (inp) should be on left: B 5 -5 ... 0 ... {name=inp dir=in}
        assert!(
            sym.contains("name=inp dir=in}"),
            "input pin should have dir=in, got:\n{sym}"
        );
        // Output pin (out) should be on right edge
        assert!(
            sym.contains("name=out dir=out}"),
            "output pin should have dir=out, got:\n{sym}"
        );
    }

    #[test]
    fn empty_subcircuit_emits_valid_sch_with_header() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = Subcircuit::new("empty");
        let sch = backend.format_schematic(&subckt);

        assert!(
            sch.starts_with("v {xschem version="),
            "empty subcircuit should still have version header"
        );
        assert!(sch.contains("G {}"), "should have G record");
        assert!(sch.contains("K {}"), "should have K record");
        assert!(
            sch.contains("T {empty}"),
            "should have title text even for empty subcircuit"
        );
    }

    #[test]
    fn write_all_writes_subcircuit_sch_and_sym() {
        let dir = "/tmp/xschem_test_writeall";
        let _ = fs::remove_dir_all(dir);
        let backend = XschemBackend::new(dir);

        let mut circuit = Circuit::new("top");
        circuit
            .subcircuits
            .insert("inv".to_string(), Subcircuit::new("inv"));

        backend.write_all(&circuit).unwrap();

        assert!(
            Path::new(dir).join("top.sch").exists(),
            "top.sch should exist"
        );
        assert!(
            Path::new(dir).join("inv.sch").exists(),
            "inv.sch should exist"
        );
        assert!(
            Path::new(dir).join("inv.sym").exists(),
            "inv.sym should exist"
        );
        assert!(
            Path::new(dir).join("manifest.json").exists(),
            "manifest.json should exist"
        );

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn write_all_rejects_invalid_circuit() {
        let dir = "/tmp/xschem_test_invalid";
        let _ = fs::remove_dir_all(dir);
        let backend = XschemBackend::new(dir);

        let mut circuit = Circuit::new("top");
        // Add an instance with off-grid coordinate.
        circuit.top.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: HashMap::new(),
            x: 105, // off-grid!
            y: 200,
            rotation: 0,
            flip: false,
        });

        let result = backend.write_all(&circuit);
        assert!(result.is_err(), "write_all should fail on invalid circuit");
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("Validation failed"),
            "error should mention validation failure, got: {err_msg}"
        );

        let _ = fs::remove_dir_all(dir);
    }

    // -----------------------------------------------------------------------
    // New tests: bbox-relative port pin placement
    // -----------------------------------------------------------------------

    /// Build a subcircuit with instances at known positions and explicit port directions.
    fn subckt_with_instances_and_directions() -> Subcircuit {
        let mut subckt = Subcircuit::new("ota");
        subckt.ports = vec![
            "inp".to_string(),
            "inn".to_string(),
            "out".to_string(),
            "vdd".to_string(),
        ];
        subckt.port_directions = vec![PinDir::Input, PinDir::Input, PinDir::Output, PinDir::Power];

        // Two instances at known positions: (100, 0) and (300, 200)
        subckt.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: HashMap::new(),
            x: 100,
            y: 0,
            rotation: 0,
            flip: false,
        });
        subckt.instances.push(Instance {
            name: "M2".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: HashMap::new(),
            x: 300,
            y: 200,
            rotation: 0,
            flip: false,
        });

        subckt.nets.push(Net::new("inp"));
        subckt.nets.push(Net::new("inn"));
        subckt.nets.push(Net::new("out"));
        subckt.nets.push(Net::new("vdd"));

        subckt
    }

    #[test]
    fn pins_placed_outside_instance_bbox_with_margin() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_instances_and_directions();
        let sch = backend.format_schematic(&subckt);

        // bbox: x_min=100, x_max=300, y_min=0, y_max=200
        // margin=200 => left_x = -100, right_x = 500
        // input_ports = [inp, inn], output_ports = [out], io_ports = [vdd]
        // input_ports.len()=2, output_ports.len()=1 => io_on_left = false (2 > 1)
        // left_count=2, right_count=1+1=2

        // Verify input pins are to the left of bbox
        for line in sch.lines() {
            if line.contains("devices/ipin.sym") {
                let x: i32 = line.split_whitespace().nth(2).unwrap().parse().unwrap();
                assert!(
                    x < 100,
                    "input pin x={} should be left of bbox x_min=100",
                    x
                );
                assert_eq!(x, -100, "input pin should be at bbox.x_min - margin");
            }
        }

        // Verify output pins are to the right of bbox
        for line in sch.lines() {
            if line.contains("devices/opin.sym") {
                let x: i32 = line.split_whitespace().nth(2).unwrap().parse().unwrap();
                assert!(
                    x > 300,
                    "output pin x={} should be right of bbox x_max=300",
                    x
                );
                assert_eq!(x, 500, "output pin should be at bbox.x_max + margin");
            }
        }
    }

    #[test]
    fn input_pins_left_output_pins_right() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_instances_and_directions();
        let sch = backend.format_schematic(&subckt);

        let mut ipin_xs = Vec::new();
        let mut opin_xs = Vec::new();

        for line in sch.lines() {
            if line.contains("devices/ipin.sym") {
                let x: i32 = line.split_whitespace().nth(2).unwrap().parse().unwrap();
                ipin_xs.push(x);
            }
            if line.contains("devices/opin.sym") {
                let x: i32 = line.split_whitespace().nth(2).unwrap().parse().unwrap();
                opin_xs.push(x);
            }
        }

        assert!(!ipin_xs.is_empty(), "should have input pins");
        assert!(!opin_xs.is_empty(), "should have output pins");

        for ix in &ipin_xs {
            for ox in &opin_xs {
                assert!(
                    ix < ox,
                    "input pin x={} should be to the left of output pin x={}",
                    ix,
                    ox
                );
            }
        }
    }

    #[test]
    fn pin_y_spacing_is_even() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_instances_and_directions();
        let sch = backend.format_schematic(&subckt);

        // Collect Y positions of input pins (there are 2: inp, inn)
        let mut ipin_ys: Vec<i32> = Vec::new();
        for line in sch.lines() {
            if line.contains("devices/ipin.sym") {
                let y: i32 = line.split_whitespace().nth(3).unwrap().parse().unwrap();
                ipin_ys.push(y);
            }
        }

        assert_eq!(ipin_ys.len(), 2, "should have 2 input pins");

        // bbox y range is [0, 200], distributing 2 pins => spacing = 200/3 = 66
        // pin 0 at snap(0 + 66) = snap(66) = 70
        // pin 1 at snap(0 + 132) = snap(132) = 130
        assert_eq!(ipin_ys[0], 70, "first input pin Y");
        assert_eq!(ipin_ys[1], 130, "second input pin Y");

        // Verify even spacing: difference between consecutive pins should be constant
        let spacing = ipin_ys[1] - ipin_ys[0];
        assert_eq!(
            spacing, 60,
            "spacing between input pins should be 60 (snapped)"
        );
    }

    #[test]
    fn power_iopin_placed_at_top() {
        let backend = XschemBackend::new("/tmp/xschem_test");

        // subckt has port vdd (Power) with instances at (100,0) and (300,200)
        // bbox: x_min=100, x_max=300, y_min=0, y_max=200
        // vdd is power => placed at top: y = y_min - margin = 0 - 200 = -200
        let subckt = subckt_with_instances_and_directions();
        let sch = backend.format_schematic(&subckt);

        let mut iopin_ys = Vec::new();
        for line in sch.lines() {
            if line.contains("devices/iopin.sym") && line.contains("lab=vdd") {
                let y: i32 = line.split_whitespace().nth(3).unwrap().parse().unwrap();
                iopin_ys.push(y);
            }
        }

        assert!(!iopin_ys.is_empty(), "should have vdd iopin");
        for y in &iopin_ys {
            assert_eq!(
                *y, -200,
                "power iopin should be at top edge (y_min - margin)"
            );
        }
    }

    #[test]
    fn fallback_positions_when_no_instances() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_directions(); // no instances

        let sch = backend.format_schematic(&subckt);

        // Should fall back to default positions: left_x=-200, right_x=200
        let mut has_ipin = false;
        let mut has_opin = false;
        for line in sch.lines() {
            if line.contains("devices/ipin.sym") {
                let x: i32 = line.split_whitespace().nth(2).unwrap().parse().unwrap();
                assert_eq!(x, -200, "ipin fallback x should be -200");
                has_ipin = true;
            }
            if line.contains("devices/opin.sym") {
                let x: i32 = line.split_whitespace().nth(2).unwrap().parse().unwrap();
                assert_eq!(x, 200, "opin fallback x should be 200");
                has_opin = true;
            }
        }
        assert!(has_ipin, "should have input pin");
        assert!(has_opin, "should have output pin");
    }

    #[test]
    fn all_pin_positions_are_grid_snapped() {
        let backend = XschemBackend::new("/tmp/xschem_test");
        let subckt = subckt_with_instances_and_directions();
        let sch = backend.format_schematic(&subckt);

        for line in sch.lines() {
            if line.contains("devices/ipin.sym")
                || line.contains("devices/opin.sym")
                || line.contains("devices/iopin.sym")
            {
                let parts: Vec<&str> = line.split_whitespace().collect();
                let x: i32 = parts[2].parse().unwrap();
                let y: i32 = parts[3].parse().unwrap();
                assert_eq!(x % 10, 0, "pin x={} should be on 10-unit grid", x);
                assert_eq!(y % 10, 0, "pin y={} should be on 10-unit grid", y);
            }
        }
    }
}
