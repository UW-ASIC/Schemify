use crate::s2s::adapter::schematic_from_subcircuit;
use crate::s2s::ir::{self, NetClass};
use crate::s2s::output::schemify::SchemifyBackend;
use crate::s2s::parser::SpiceParser;
use crate::s2s::shared::{map_device_kind, primitive_sym, GROUND_NAMES, POWER_NAMES};
use crate::s2s::{annotation, placement, recognition, routing::Router};
use lasso::Rodeo;

use schemify_core::schematic::{Instance, ModelDef, Property, Schematic, Wire};
use schemify_core::simulation::StimulusLang;
use schemify_core::types::{Color, DeviceKind, InstanceFlags, SchematicType};

/// Result of a hierarchical SPICE import.
#[derive(Debug, Clone)]
pub struct ImportResult {
    pub top: Schematic,
    pub children: Vec<Schematic>,
}

/// Import SPICE producing a hierarchy of schematics (parent + child per subckt).
pub fn import_spice_hierarchical(
    source: &str,
    interner: &mut Rodeo,
) -> Result<ImportResult, String> {
    let mut parser = SpiceParser::new();
    let mut circuit = parser.parse(source).map_err(|e| format!("{e:#}"))?;

    annotation::annotate(&mut circuit);

    let backend = SchemifyBackend::new("");

    let subckt_names: Vec<String> = circuit.subcircuits.keys().cloned().collect();
    for name in &subckt_names {
        if let Some(subckt) = circuit.subcircuits.get(name) {
            let blocks = recognition::recognize_subcircuit(subckt);
            let subckt_mut = circuit.subcircuits.get_mut(name).unwrap();
            placement::place(subckt_mut, &blocks, &backend);
            Router::new().route(subckt_mut, &backend);
        }
    }

    let blocks = recognition::recognize(&circuit);
    placement::place(&mut circuit.top, &blocks, &backend);
    Router::new().route(&mut circuit.top, &backend);

    let mut top = convert_subcircuit(&circuit.top, &circuit, interner);

    if !circuit.analysis.is_empty() {
        top.spice_body = circuit.analysis.to_stimulus_string();
    }

    let children: Vec<Schematic> = subckt_names
        .iter()
        .filter_map(|name| circuit.subcircuits.get(name))
        .map(|sub| schematic_from_subcircuit(sub, interner))
        .collect();

    Ok(ImportResult { top, children })
}

/// Run the full S2S pipeline and convert the result to a SchemifyRS Schematic.
pub fn import_spice(source: &str, interner: &mut Rodeo) -> Result<Schematic, String> {
    // Parse
    let mut parser = SpiceParser::new();
    let mut circuit = parser.parse(source).map_err(|e| format!("{e:#}"))?;

    // Annotate (power/ground classification, port directions)
    annotation::annotate(&mut circuit);

    // Pin geometry needed by placer/router
    let backend = SchemifyBackend::new("");

    // Recognize + place + route subcircuits bottom-up
    let subckt_names: Vec<String> = circuit.subcircuits.keys().cloned().collect();
    for name in &subckt_names {
        if let Some(subckt) = circuit.subcircuits.get(name) {
            let blocks = recognition::recognize_subcircuit(subckt);
            let subckt_mut = circuit.subcircuits.get_mut(name).unwrap();
            placement::place(subckt_mut, &blocks, &backend);
            Router::new().route(subckt_mut, &backend);
        }
    }

    // Top-level recognize + place + route
    let blocks = recognition::recognize(&circuit);
    placement::place(&mut circuit.top, &blocks, &backend);
    Router::new().route(&mut circuit.top, &backend);

    let mut schematic = convert_subcircuit(&circuit.top, &circuit, interner);

    // Preserve structured analysis/stimulus from the source SPICE.
    if !circuit.analysis.is_empty() {
        schematic.spice_body = circuit.analysis.to_stimulus_string();
    }

    Ok(schematic)
}

fn convert_subcircuit(
    subckt: &ir::Subcircuit,
    circuit: &ir::Circuit,
    interner: &mut Rodeo,
) -> Schematic {
    let empty = interner.get_or_intern("");
    let mut schematic = Schematic {
        name: subckt.name.clone(),
        stype: if subckt.ports.is_empty() {
            SchematicType::Testbench
        } else {
            SchematicType::Schematic
        },
        ..Default::default()
    };

    // Component instances
    for inst in &subckt.instances {
        let prop_start = schematic.properties.len() as u32;

        let mut params: Vec<(&str, &str)> = inst
            .params
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        params.sort_by_key(|(k, _)| *k);

        for (k, v) in &params {
            schematic.properties.push(Property {
                key: interner.get_or_intern(k),
                value: interner.get_or_intern(v),
            });
        }

        let prop_count = (schematic.properties.len() as u32 - prop_start) as u16;

        let sym = if inst.primitive == ir::Primitive::Subcircuit {
            interner.get_or_intern(&inst.symbol)
        } else {
            interner.get_or_intern(primitive_sym(inst.primitive))
        };

        schematic.instances.push(Instance {
            name: interner.get_or_intern(&inst.name),
            symbol: sym,
            spice_line: empty,
            x: inst.x,
            y: inst.y,
            kind: map_device_kind(inst.primitive),
            flags: InstanceFlags::new(inst.rotation, inst.flip, false),
            prop_start,
            prop_count,
            name_offset: [0, 0],
            param_offset: [0, 0],
        });
    }

    // Labels → lab_pin / gnd / vdd instances
    let mut gnd_counter = 0u32;
    let mut vdd_counter = 0u32;
    for label in &subckt.labels {
        let net = match subckt.nets.get(label.net_idx as usize) {
            Some(n) => n,
            None => continue,
        };

        let name_lower = net.name.to_ascii_lowercase();
        let is_gnd = net.classification == NetClass::Ground
            && (GROUND_NAMES.iter().any(|&g| name_lower == g)
                || name_lower.ends_with("_gnd")
                || name_lower.ends_with("_vss"));
        let is_vdd = net.classification == NetClass::Power
            && (POWER_NAMES.iter().any(|&p| name_lower == p)
                || name_lower.ends_with("_vdd")
                || name_lower.ends_with("_vcc"));

        let (inst_name, sym, kind, x, y) = if is_gnd {
            let n = format!("gnd{gnd_counter}");
            gnd_counter += 1;
            // GND pin offset is (0, -10). Compute instance position so that
            // the absolute pin position equals (label.x, label.y) regardless
            // of label rotation.
            let flags = InstanceFlags::new(label.rotation, false, false);
            let (tx, ty) = flags.transform_point(0, -10);
            (n, "gnd", DeviceKind::Gnd, label.x - tx, label.y - ty)
        } else if is_vdd {
            let n = format!("vdd{vdd_counter}");
            vdd_counter += 1;
            // VDD pin offset is (0, 10).
            let flags = InstanceFlags::new(label.rotation, false, false);
            let (tx, ty) = flags.transform_point(0, 10);
            (n, "vdd", DeviceKind::Vdd, label.x - tx, label.y - ty)
        } else {
            // LabPin pin offset is (0, 0) — rotation doesn't affect it.
            (
                net.name.clone(),
                "lab_pin",
                DeviceKind::LabPin,
                label.x,
                label.y,
            )
        };

        // For GND/VDD, store original net name as a property so connectivity
        // preserves it instead of using the hardcoded injected_net() value.
        let prop_start = schematic.properties.len() as u32;
        let prop_count = if is_gnd || is_vdd {
            schematic.properties.push(Property {
                key: interner.get_or_intern("net"),
                value: interner.get_or_intern(&net.name),
            });
            1u16
        } else {
            0u16
        };

        schematic.instances.push(Instance {
            name: interner.get_or_intern(&inst_name),
            symbol: interner.get_or_intern(sym),
            spice_line: empty,
            x,
            y,
            kind,
            flags: InstanceFlags::new(label.rotation, false, false),
            prop_start,
            prop_count,
            name_offset: [0, 0],
            param_offset: [0, 0],
        });
    }

    // Wires
    for wire in &subckt.wires {
        let net_name = subckt
            .nets
            .get(wire.net_idx as usize)
            .map(|n| interner.get_or_intern(&n.name))
            .unwrap_or(empty);

        schematic.wires.push(Wire {
            net_name,
            x0: wire.x1,
            y0: wire.y1,
            x1: wire.x2,
            y1: wire.y2,
            color: Color::NONE,
            thickness: 10,
            bus: false,
        });
    }

    // Globals
    for net in &subckt.nets {
        if net.is_global {
            schematic.globals.push(net.name.clone());
        }
    }

    // Model definitions
    for model in circuit.models.values() {
        let params_str: String = model
            .params
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join(" ");
        schematic.model_defs.push(ModelDef {
            name: model.name.clone(),
            body: format!(".model {} {} ({params_str})", model.name, model.model_type),
        });
    }

    schematic
}

/// Import a PySpice `.py` source.
///
/// Runs the script via `python3`, captures the SPICE netlist from stdout,
/// pipes it through the normal S2S pipeline, and stores the original Python
/// source in `schematic.pyspice_source`.
#[cfg(not(target_arch = "wasm32"))]
pub fn import_pyspice(
    py_source: &str,
    name: &str,
    interner: &mut Rodeo,
) -> Result<Schematic, String> {
    use std::process::{Command, Stdio};

    // Write to a temp file so cross-file imports can resolve.
    let tmp_path = std::env::temp_dir().join(format!("schemify_pyspice_{name}.py"));
    std::fs::write(&tmp_path, py_source).map_err(|e| format!("writing temp file: {e}"))?;

    let output = Command::new("python3")
        .arg(&tmp_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("running python3: {e}"))?;

    let _ = std::fs::remove_file(&tmp_path);

    let stdout = String::from_utf8_lossy(&output.stdout);

    // Accept stdout containing valid SPICE even on non-zero exit
    // (testbenches may print netlist then fail running simulation).
    if (stdout.is_empty() || !stdout.contains(".end")) && !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("python3 failed:\n{stderr}"));
    }

    let mut schematic = import_spice(&stdout, interner)?;
    schematic.pyspice_source = py_source.to_string();
    schematic.stimulus_lang = StimulusLang::PySpice;
    Ok(schematic)
}

/// Check if source text looks like a PySpice script (first 50 lines).
pub fn is_pyspice_source(source: &str) -> bool {
    source.lines().take(50).any(|line| {
        let t = line.trim();
        t.starts_with("from pyspice_rs")
            || t.starts_with("import pyspice_rs")
            || t.starts_with("from PySpice")
            || t.starts_with("import PySpice")
    })
}

