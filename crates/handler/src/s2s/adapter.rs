//! Bidirectional adapter between s2s-IR `Subcircuit` and core `Schematic`.
//!
//! Pure functions: input in, output out, no I/O, no global state.
//!
//! - `schematic_from_subcircuit`: IR → core (replaces the inline conversion
//!   previously buried inside `spice_import::convert_subcircuit`)
//! - `subcircuit_from_schematic`: core → IR (new, enables round-trip editing)
//! - `relayout`: re-runs placement + routing on an existing schematic

use std::collections::HashMap;

use lasso::Rodeo;

use crate::s2s::ir::{self, NetClass, Primitive};
use crate::s2s::output::schemify::SchemifyBackend;
use crate::s2s::shared::{
    map_device_kind, map_primitive, primitive_sym, GROUND_NAMES, POWER_NAMES,
};
use crate::s2s::{placement, recognition, routing::Router};

use schemify_core::schematic::{Instance, Property, Schematic, Wire};
use schemify_core::types::{Color, DeviceKind, InstanceFlags, SchematicType};

// ---------------------------------------------------------------------------
// schematic_from_subcircuit
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

        schematic.instances.push(Instance {
            name: int.get_or_intern(&inst.name),
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

    // Labels -> lab_pin / gnd / vdd instances
    let mut gnd_counter = 0u32;
    let mut vdd_counter = 0u32;
    for label in &sub.labels {
        let net = match sub.nets.get(label.net_idx as usize) {
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
            let flags = InstanceFlags::new(label.rotation, false, false);
            let (tx, ty) = flags.transform_point(0, -10);
            (n, "gnd", DeviceKind::Gnd, label.x - tx, label.y - ty)
        } else if is_vdd {
            let n = format!("vdd{vdd_counter}");
            vdd_counter += 1;
            let flags = InstanceFlags::new(label.rotation, false, false);
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

        schematic.instances.push(Instance {
            name: int.get_or_intern(&inst_name),
            symbol: int.get_or_intern(sym),
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
    for wire in &sub.wires {
        let net_name = sub
            .nets
            .get(wire.net_idx as usize)
            .map(|n| int.get_or_intern(&n.name))
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
    for net in &sub.nets {
        if net.is_global {
            schematic.globals.push(net.name.clone());
        }
    }

    schematic
}

// ---------------------------------------------------------------------------
// subcircuit_from_schematic
// ---------------------------------------------------------------------------

/// Convert a core `Schematic` back into an s2s-IR `Subcircuit`.
///
/// Pure function: reads interned strings via `int`, builds a fresh
/// `Subcircuit` with instances, nets, wires, and labels.
pub fn subcircuit_from_schematic(sch: &Schematic, int: &Rodeo) -> ir::Subcircuit {
    let mut sub = ir::Subcircuit::new(&sch.name);

    // Net name -> net index map
    let mut net_map: HashMap<String, u32> = HashMap::new();

    // Helper: get or create a net by name
    let mut get_or_create_net = |name: &str, nets: &mut Vec<ir::Net>| -> u32 {
        if let Some(&idx) = net_map.get(name) {
            return idx;
        }
        let idx = nets.len() as u32;
        nets.push(ir::Net::new(name));
        net_map.insert(name.to_string(), idx);
        idx
    };

    // Collect wire net names first so net indices are available
    for i in 0..sch.wires.len() {
        let net_name = int.resolve(&sch.wires.net_name[i]);
        if !net_name.is_empty() {
            get_or_create_net(net_name, &mut sub.nets);
        }
    }

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

                // Classify the net
                if kind == DeviceKind::Gnd {
                    sub.nets[net_idx as usize].classification = NetClass::Ground;
                    // Reverse the pin offset transform to recover the label position
                    let label_flags = InstanceFlags::new(rotation, false, false);
                    let (tx, ty) = label_flags.transform_point(0, -10);
                    sub.labels.push(ir::Label {
                        net_idx,
                        x: x + tx,
                        y: y + ty,
                        rotation,
                    });
                } else {
                    sub.nets[net_idx as usize].classification = NetClass::Power;
                    let label_flags = InstanceFlags::new(rotation, false, false);
                    let (tx, ty) = label_flags.transform_point(0, 10);
                    sub.labels.push(ir::Label {
                        net_idx,
                        x: x + tx,
                        y: y + ty,
                        rotation,
                    });
                }
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
                            let k = int.resolve(&prop.key).to_owned();
                            let v = int.resolve(&prop.value).to_owned();
                            params.insert(k, v);
                        }
                    }

                    let pin_names = kind.default_pins();
                    let pins: Vec<ir::Pin> = pin_names
                        .iter()
                        .map(|&pname| ir::Pin {
                            name: pname.to_string(),
                            dir: ir::PinDir::Inout,
                            net_idx: None,
                        })
                        .collect();

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

    // Wires
    for i in 0..sch.wires.len() {
        let net_name = int.resolve(&sch.wires.net_name[i]);
        let net_idx = if net_name.is_empty() {
            // Create an anonymous net
            let idx = sub.nets.len() as u32;
            sub.nets.push(ir::Net::new(""));
            idx
        } else {
            get_or_create_net(net_name, &mut sub.nets)
        };

        sub.wires.push(ir::Wire {
            net_idx,
            x1: sch.wires.x0[i],
            y1: sch.wires.y0[i],
            x2: sch.wires.x1[i],
            y2: sch.wires.y1[i],
        });
    }

    // Globals
    for global in &sch.globals {
        let net_idx = get_or_create_net(global, &mut sub.nets);
        sub.nets[net_idx as usize].is_global = true;
    }

    // Ports: schematic-type schematics have ports derived from label instances
    if sch.stype == SchematicType::Schematic {
        for i in 0..sch.instances.len() {
            let kind = sch.instances.kind[i];
            if kind.is_label() {
                let port_name = int.resolve(&sch.instances.name[i]).to_owned();
                if !sub.ports.contains(&port_name) {
                    sub.ports.push(port_name);
                }
            }
        }
    }

    sub
}

// ---------------------------------------------------------------------------
// relayout
// ---------------------------------------------------------------------------

/// Re-run placement and routing on an existing schematic.
///
/// Converts to IR, runs recognize + place + route, converts back.
/// Pure function: no I/O, no global state.
pub fn relayout(sch: &Schematic, int: &mut Rodeo) -> Schematic {
    let mut sub = subcircuit_from_schematic(sch, int);
    let backend = SchemifyBackend::new("");
    let blocks = recognition::recognize_subcircuit(&sub);
    placement::place(&mut sub, &blocks, &backend);
    Router::new().route(&mut sub, &backend);
    schematic_from_subcircuit(&sub, int)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal IR subcircuit with one resistor for testing.
    fn one_resistor_subcircuit() -> ir::Subcircuit {
        let mut sub = ir::Subcircuit::new("test");
        sub.nets.push(ir::Net::new("in"));
        sub.nets.push(ir::Net::new("out"));
        sub.instances.push(ir::Instance {
            name: "R1".to_string(),
            primitive: Primitive::Resistor,
            symbol: "res".to_string(),
            pins: vec![
                ir::Pin {
                    name: "p".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(0),
                },
                ir::Pin {
                    name: "n".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(1),
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
    fn schematic_from_subcircuit_preserves_instance() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.instances.len(), 1);
        assert_eq!(int.resolve(&sch.instances.name[0]), "R1");
        assert_eq!(sch.instances.kind[0], DeviceKind::Resistor);
        assert_eq!(sch.instances.x[0], 100);
        assert_eq!(sch.instances.y[0], 200);
    }

    #[test]
    fn schematic_from_subcircuit_preserves_properties() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.instances.prop_count[0], 1);
        let prop = &sch.properties[sch.instances.prop_start[0] as usize];
        assert_eq!(int.resolve(&prop.key), "value");
        assert_eq!(int.resolve(&prop.value), "1k");
    }

    #[test]
    fn schematic_from_subcircuit_preserves_wires() {
        let mut sub = one_resistor_subcircuit();
        sub.wires.push(ir::Wire {
            net_idx: 0,
            x1: 10,
            y1: 20,
            x2: 30,
            y2: 40,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.wires.len(), 1);
        assert_eq!(sch.wires.x0[0], 10);
        assert_eq!(sch.wires.y0[0], 20);
        assert_eq!(sch.wires.x1[0], 30);
        assert_eq!(sch.wires.y1[0], 40);
        assert_eq!(int.resolve(&sch.wires.net_name[0]), "in");
    }

    #[test]
    fn schematic_from_subcircuit_testbench_type() {
        let sub = ir::Subcircuit::new("tb");
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.stype, SchematicType::Testbench);
    }

    #[test]
    fn schematic_from_subcircuit_with_ports_is_schematic_type() {
        let mut sub = ir::Subcircuit::new("amp");
        sub.ports.push("in".into());
        sub.ports.push("out".into());
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.stype, SchematicType::Schematic);
    }

    #[test]
    fn schematic_from_subcircuit_labels_become_instances() {
        let mut sub = ir::Subcircuit::new("test");
        sub.nets.push(ir::Net::new("sig"));
        sub.labels.push(ir::Label {
            net_idx: 0,
            x: 50,
            y: 60,
            rotation: 0,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.instances.len(), 1);
        assert_eq!(sch.instances.kind[0], DeviceKind::LabPin);
        assert_eq!(int.resolve(&sch.instances.name[0]), "sig");
    }

    #[test]
    fn schematic_from_subcircuit_gnd_label() {
        let mut sub = ir::Subcircuit::new("test");
        let mut net = ir::Net::new("gnd");
        net.classification = NetClass::Ground;
        sub.nets.push(net);
        sub.labels.push(ir::Label {
            net_idx: 0,
            x: 50,
            y: 60,
            rotation: 0,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.instances.len(), 1);
        assert_eq!(sch.instances.kind[0], DeviceKind::Gnd);
    }

    #[test]
    fn schematic_from_subcircuit_globals() {
        let mut sub = ir::Subcircuit::new("test");
        let mut net = ir::Net::new("vdd!");
        net.is_global = true;
        sub.nets.push(net);
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);

        assert_eq!(sch.globals, vec!["vdd!"]);
    }

    // -- subcircuit_from_schematic tests --

    #[test]
    fn subcircuit_from_schematic_preserves_instance_count() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.instances.len(), sub.instances.len());
    }

    #[test]
    fn subcircuit_from_schematic_preserves_instance_fields() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.instances[0].name, "R1");
        assert_eq!(sub2.instances[0].primitive, Primitive::Resistor);
        assert_eq!(sub2.instances[0].x, 100);
        assert_eq!(sub2.instances[0].y, 200);
        assert_eq!(sub2.instances[0].rotation, 0);
        assert!(!sub2.instances[0].flip);
    }

    #[test]
    fn subcircuit_from_schematic_preserves_params() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(
            sub2.instances[0].params.get("value").map(String::as_str),
            Some("1k")
        );
    }

    #[test]
    fn subcircuit_from_schematic_preserves_wires() {
        let mut sub = one_resistor_subcircuit();
        sub.wires.push(ir::Wire {
            net_idx: 0,
            x1: 10,
            y1: 20,
            x2: 30,
            y2: 40,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.wires.len(), 1);
        assert_eq!(sub2.wires[0].x1, 10);
        assert_eq!(sub2.wires[0].y1, 20);
        assert_eq!(sub2.wires[0].x2, 30);
        assert_eq!(sub2.wires[0].y2, 40);
        // Net should be resolved to same name
        assert_eq!(sub2.nets[sub2.wires[0].net_idx as usize].name, "in");
    }

    #[test]
    fn subcircuit_from_schematic_preserves_globals() {
        let mut sub = ir::Subcircuit::new("test");
        let mut net = ir::Net::new("vdd!");
        net.is_global = true;
        sub.nets.push(net);
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        let has_global = sub2.nets.iter().any(|n| n.name == "vdd!" && n.is_global);
        assert!(has_global, "global net vdd! should be preserved");
    }

    #[test]
    fn subcircuit_from_schematic_gnd_becomes_label() {
        let mut sub = ir::Subcircuit::new("test");
        let mut net = ir::Net::new("gnd");
        net.classification = NetClass::Ground;
        sub.nets.push(net);
        sub.labels.push(ir::Label {
            net_idx: 0,
            x: 50,
            y: 60,
            rotation: 0,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        // GND instance should become a label again
        assert_eq!(sub2.labels.len(), 1);
        assert_eq!(sub2.nets[sub2.labels[0].net_idx as usize].name, "gnd");
        assert_eq!(
            sub2.nets[sub2.labels[0].net_idx as usize].classification,
            NetClass::Ground
        );
    }

    #[test]
    fn subcircuit_from_schematic_lab_pin_becomes_label() {
        let mut sub = ir::Subcircuit::new("test");
        sub.nets.push(ir::Net::new("sig"));
        sub.labels.push(ir::Label {
            net_idx: 0,
            x: 50,
            y: 60,
            rotation: 0,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.labels.len(), 1);
        assert_eq!(sub2.nets[sub2.labels[0].net_idx as usize].name, "sig");
    }

    #[test]
    fn subcircuit_from_schematic_ports_from_labels() {
        let mut sub = ir::Subcircuit::new("amp");
        sub.ports.push("in".into());
        sub.ports.push("out".into());
        sub.nets.push(ir::Net::new("in"));
        sub.nets.push(ir::Net::new("out"));
        sub.labels.push(ir::Label {
            net_idx: 0,
            x: 0,
            y: 0,
            rotation: 0,
        });
        sub.labels.push(ir::Label {
            net_idx: 1,
            x: 100,
            y: 0,
            rotation: 0,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.ports.len(), 2);
        assert!(sub2.ports.contains(&"in".to_string()));
        assert!(sub2.ports.contains(&"out".to_string()));
    }

    // -- Round-trip tests --

    #[test]
    fn roundtrip_preserves_instance_count() {
        let sub = one_resistor_subcircuit();
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.instances.len(), sub.instances.len());
    }

    #[test]
    fn roundtrip_preserves_net_count() {
        // Nets only survive round-trip if referenced by wires or labels.
        let mut sub = one_resistor_subcircuit();
        sub.wires.push(ir::Wire {
            net_idx: 0,
            x1: 0,
            y1: 0,
            x2: 10,
            y2: 0,
        });
        sub.wires.push(ir::Wire {
            net_idx: 1,
            x1: 20,
            y1: 0,
            x2: 30,
            y2: 0,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        for name in &["in", "out"] {
            assert!(
                sub2.nets.iter().any(|n| n.name == *name),
                "net '{name}' should survive round-trip"
            );
        }
    }

    #[test]
    fn roundtrip_preserves_wire_connectivity() {
        let mut sub = one_resistor_subcircuit();
        sub.wires.push(ir::Wire {
            net_idx: 0,
            x1: 10,
            y1: 20,
            x2: 30,
            y2: 40,
        });
        sub.wires.push(ir::Wire {
            net_idx: 1,
            x1: 50,
            y1: 60,
            x2: 70,
            y2: 80,
        });
        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        assert_eq!(sub2.wires.len(), sub.wires.len());
        // Wire endpoints preserved
        assert_eq!(sub2.wires[0].x1, 10);
        assert_eq!(sub2.wires[0].y1, 20);
        // Net assignment preserved
        let net0 = &sub2.nets[sub2.wires[0].net_idx as usize];
        assert_eq!(net0.name, "in");
        let net1 = &sub2.nets[sub2.wires[1].net_idx as usize];
        assert_eq!(net1.name, "out");
    }

    #[test]
    fn roundtrip_complex_circuit() {
        let mut sub = ir::Subcircuit::new("diff_pair");
        sub.ports = vec!["inp".into(), "inn".into(), "out".into()];
        // Nets
        sub.nets.push(ir::Net::new("inp"));
        sub.nets.push(ir::Net::new("inn"));
        sub.nets.push(ir::Net::new("out"));
        sub.nets.push(ir::Net::new("tail"));
        let mut vdd_net = ir::Net::new("vdd");
        vdd_net.classification = NetClass::Power;
        sub.nets.push(vdd_net);
        let mut gnd_net = ir::Net::new("gnd");
        gnd_net.classification = NetClass::Ground;
        sub.nets.push(gnd_net);
        // Instances
        sub.instances.push(ir::Instance {
            name: "M1".into(),
            primitive: Primitive::Nmos,
            symbol: "nmos4".into(),
            pins: vec![
                ir::Pin {
                    name: "d".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(2),
                },
                ir::Pin {
                    name: "g".into(),
                    dir: ir::PinDir::Input,
                    net_idx: Some(0),
                },
                ir::Pin {
                    name: "s".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(3),
                },
                ir::Pin {
                    name: "b".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(5),
                },
            ],
            params: [("w".into(), "10u".into()), ("l".into(), "1u".into())]
                .into_iter()
                .collect(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        sub.instances.push(ir::Instance {
            name: "M2".into(),
            primitive: Primitive::Nmos,
            symbol: "nmos4".into(),
            pins: vec![
                ir::Pin {
                    name: "d".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(2),
                },
                ir::Pin {
                    name: "g".into(),
                    dir: ir::PinDir::Input,
                    net_idx: Some(1),
                },
                ir::Pin {
                    name: "s".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(3),
                },
                ir::Pin {
                    name: "b".into(),
                    dir: ir::PinDir::Inout,
                    net_idx: Some(5),
                },
            ],
            params: [("w".into(), "10u".into()), ("l".into(), "1u".into())]
                .into_iter()
                .collect(),
            x: 200,
            y: 0,
            rotation: 0,
            flip: false,
        });
        // Labels for ports
        sub.labels.push(ir::Label {
            net_idx: 0,
            x: -100,
            y: 0,
            rotation: 0,
        });
        sub.labels.push(ir::Label {
            net_idx: 1,
            x: 300,
            y: 0,
            rotation: 0,
        });
        sub.labels.push(ir::Label {
            net_idx: 2,
            x: 100,
            y: -100,
            rotation: 0,
        });
        // Power/ground labels
        sub.labels.push(ir::Label {
            net_idx: 4,
            x: 100,
            y: -200,
            rotation: 0,
        });
        sub.labels.push(ir::Label {
            net_idx: 5,
            x: 100,
            y: 200,
            rotation: 0,
        });
        // Wires
        sub.wires.push(ir::Wire {
            net_idx: 3,
            x1: 0,
            y1: 50,
            x2: 200,
            y2: 50,
        });

        let mut int = Rodeo::default();
        let sch = schematic_from_subcircuit(&sub, &mut int);
        let sub2 = subcircuit_from_schematic(&sch, &int);

        // Preserve instance count (2 devices)
        assert_eq!(sub2.instances.len(), 2);
        // Preserve label count (3 port labels + 1 vdd + 1 gnd = 5)
        assert_eq!(sub2.labels.len(), 5);
        // Preserve wire count
        assert_eq!(sub2.wires.len(), 1);
        // Port names preserved
        assert_eq!(sub2.ports.len(), 3);
    }
}
