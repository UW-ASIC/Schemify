use lasso::Rodeo;
use crate::s2s::ir::{self, NetClass};
use crate::s2s::output::schemify::SchemifyBackend;
use crate::s2s::parser::SpiceParser;
use crate::s2s::{annotation, placement, recognition, routing::Router};

use schemify_core::schematic::{Instance, ModelDef, Property, Schematic, Wire};
use schemify_core::types::{Color, DeviceKind, InstanceFlags, SchematicType};

const POWER_NAMES: &[&str] = &["vdd", "vcc", "avdd", "dvdd"];
const GROUND_NAMES: &[&str] = &["vss", "gnd", "0", "avss", "dvss"];

/// Run the full S2S pipeline and convert the result to a SchemifyRS Schematic.
pub fn import_spice(source: &str, interner: &mut Rodeo) -> Result<Schematic, String> {
    // Parse
    let mut parser = SpiceParser::new();
    let mut circuit = parser.parse(source).map_err(|e| format!("{e:#}"))?;

    // Annotate (power/ground classification, port directions)
    annotation::annotate(&mut circuit);

    // Backend needed by placer/router for pin geometry
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

    Ok(convert_subcircuit(&circuit.top, &circuit, interner))
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

        schematic.instances.push(Instance {
            name: interner.get_or_intern(&inst.name),
            symbol: interner.get_or_intern(primitive_sym(inst.primitive)),
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
            && GROUND_NAMES.iter().any(|&g| name_lower == g);
        let is_vdd = net.classification == NetClass::Power
            && POWER_NAMES.iter().any(|&p| name_lower == p);

        let (inst_name, sym, x, y) = if is_gnd {
            let n = format!("gnd{gnd_counter}");
            gnd_counter += 1;
            (n, "gnd", label.x, label.y + 10)
        } else if is_vdd {
            let n = format!("vdd{vdd_counter}");
            vdd_counter += 1;
            (n, "vdd", label.x, label.y - 10)
        } else {
            (net.name.clone(), "lab_pin", label.x, label.y)
        };

        schematic.instances.push(Instance {
            name: interner.get_or_intern(&inst_name),
            symbol: interner.get_or_intern(sym),
            spice_line: empty,
            x,
            y,
            kind: DeviceKind::Generic,
            flags: InstanceFlags::new(label.rotation, false, false),
            prop_start: schematic.properties.len() as u32,
            prop_count: 0,
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

fn map_device_kind(p: ir::Primitive) -> DeviceKind {
    match p {
        ir::Primitive::Nmos => DeviceKind::Nmos4,
        ir::Primitive::Pmos => DeviceKind::Pmos4,
        ir::Primitive::Npn => DeviceKind::Npn,
        ir::Primitive::Pnp => DeviceKind::Pnp,
        ir::Primitive::Resistor => DeviceKind::Resistor,
        ir::Primitive::Capacitor => DeviceKind::Capacitor,
        ir::Primitive::Inductor => DeviceKind::Inductor,
        ir::Primitive::Diode => DeviceKind::Diode,
        ir::Primitive::Vsource => DeviceKind::Vsource,
        ir::Primitive::Isource => DeviceKind::Isource,
        ir::Primitive::Subcircuit => DeviceKind::Subckt,
    }
}

fn primitive_sym(p: ir::Primitive) -> &'static str {
    match p {
        ir::Primitive::Nmos => "nmos4",
        ir::Primitive::Pmos => "pmos4",
        ir::Primitive::Npn => "npn",
        ir::Primitive::Pnp => "pnp",
        ir::Primitive::Resistor => "res",
        ir::Primitive::Capacitor => "capa",
        ir::Primitive::Inductor => "ind",
        ir::Primitive::Diode => "diode",
        ir::Primitive::Vsource => "vsource",
        ir::Primitive::Isource => "isource",
        ir::Primitive::Subcircuit => "subckt",
    }
}
