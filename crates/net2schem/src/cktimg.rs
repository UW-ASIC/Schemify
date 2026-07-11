//! cktImg front-end: parse + place via the `cktimg` library.
//!
//! The seam is cktimg's backend interface — any `Fn(&Ir, &Strings) -> String`
//! — implemented here by a closure that side-loads the placed IR into this
//! crate's `Subcircuit` instead of rendering text.
//!
//! cktimg owns parse and placement; routing stays in `crate::route` because
//! wires must land on Schemify's own symbol pin geometry. (Installing
//! Schemify's anchors into cktimg via `devices::install_anchor_overrides` was
//! tried and reverted: cktimg's channel router runs trunks flush along device
//! bounding boxes — legal against its edge-pin convention, but with
//! Schemify's boundary pins those trunks pass through foreign pins and short
//! nets geometrically. Full 1:1 wire reuse needs foreign-pin clearance in
//! cktimg's router first.)
//!
//! cktimg flattens `.subckt`s, so the result is always a single top-level
//! schematic.

use std::cell::RefCell;
use std::collections::HashMap;

use ::cktimg::devices::{class_at, SymbolRole};
use ::cktimg::{Ir, Strings};

use crate::emit::snap_to_grid;
use crate::ir::{
    Circuit, InstId, Instance, Net, NetClass, NetId, Pin, PinDir, PinIdx, PinRef, Primitive,
    Subcircuit, primitive_sym,
};

/// cktimg grid → schemify grid. cktimg cells are 40 wide with ±20 pin
/// offsets; Schemify symbols use ±30 pin offsets on a 10-unit grid.
// ponytail: uniform ×2 keeps relative layout and grid alignment; tune if
// imported schematics look cramped or sparse.
const SCALE: i32 = 2;

/// Parse + place `src` with cktimg, then run this crate's router over the
/// placed result.
pub fn netlist_to_circuit(src: &str) -> anyhow::Result<Circuit> {
    let top = RefCell::new(None);
    // The cktimg backend: capture the placed IR; the rendered "document" is
    // unused.
    let (_, report) = ::cktimg::run(src, |ir: &Ir, s: &Strings| {
        *top.borrow_mut() = Some(subcircuit_from_ir(ir, s));
        String::new()
    });

    let mut circuit = Circuit::new("top");
    circuit.top = top
        .into_inner()
        .ok_or_else(|| anyhow::anyhow!("cktimg backend was not invoked"))?;

    // Surface everything cktimg could not represent (ignored/skipped lines).
    circuit.diagnostics = report
        .ignored
        .iter()
        .chain(report.skipped.iter())
        .map(|n| crate::ir::ParseDiagnostic {
            line_no: n.line as usize,
            message: format!("{}: {}", n.reason, n.text),
        })
        .collect();

    // Placement came from cktimg; route with Schemify's own pin geometry so
    // wires touch the symbols the app actually draws.
    let backend = crate::emit::SchemifyBackend::new("");
    crate::route::Router::new().route(&mut circuit.top, &backend);
    Ok(circuit)
}

/// Placed cktimg IR → this crate's `Subcircuit` (instances + classified nets,
/// no wires — routing happens after).
fn subcircuit_from_ir(ir: &Ir, s: &Strings) -> Subcircuit {
    let mut sub = Subcircuit::new("top");

    // Net indices are shared verbatim between the two IRs.
    for &name in &ir.nets.name {
        sub.nets.push(Net::new(s.get(name)));
    }

    let phys = ir.physical.as_ref();
    for d in 0..ir.devices.len() {
        let class = class_at(ir.devices.symbol[d].index());
        let pin_base = ir.devices.pin0[d].index();

        // Rails and ports exist to anchor cktimg's placer; keep only their
        // net classification — the router labels power/ground nets itself.
        if class.role != SymbolRole::None {
            if let Some(net) = ir.pins.net[pin_base] {
                let class_for = match class.role {
                    SymbolRole::PowerRail => Some(NetClass::Power),
                    SymbolRole::GroundRail => Some(NetClass::Ground),
                    _ => None,
                };
                if let Some(c) = class_for {
                    sub.nets[net.index()].classification = c;
                }
            }
            continue;
        }

        let primitive = map_class(class.name);
        let inst_id = InstId(sub.instances.len() as u32);

        let mut pins = Vec::with_capacity(class.terminals.len());
        for (slot, term) in class.terminals.iter().enumerate() {
            let net_idx = ir.pins.net[pin_base + slot].map(|n| NetId(n.index() as u32));
            if let Some(net) = net_idx {
                sub.nets[net.index()].pins.push(PinRef {
                    instance_idx: inst_id,
                    pin_idx: PinIdx(slot as u16),
                });
            }
            pins.push(Pin {
                name: term.name.to_string(),
                dir: if term.role.is_control() {
                    PinDir::Input
                } else {
                    PinDir::Inout
                },
                net_idx,
            });
        }

        let mut params = HashMap::new();
        let value = s.get(ir.devices.value[d]);
        if !value.is_empty() {
            params.insert("value".to_string(), value.to_string());
        }

        let pos = phys.map(|p| p.pos[d]).unwrap_or_default();
        let orient = ir.devices.orient[d];
        let symbol = match primitive {
            Primitive::Subcircuit => class.name.to_string(),
            p => primitive_sym(p).to_string(),
        };
        let mut inst = Instance {
            name: s.get(ir.devices.name[d]).to_string(),
            primitive,
            symbol,
            pins,
            params,
            x: snap_to_grid(pos.x * SCALE),
            y: snap_to_grid(pos.y * SCALE),
            rotation: orient.rot() as u8,
            flip: orient.mirror(),
        };
        fit_orientation(&mut inst, ir, pin_base, pos);
        sub.instances.push(inst);
    }
    sub
}

/// cktimg and Schemify draw the same primitive in different canonical
/// orientations (cktimg's MOS channel is horizontal, Schemify's vertical), so
/// cktimg's rot/mirror can't be copied over. Instead pick the (rotation,
/// flip) whose Schemify pin offsets point the same way as the pins cktimg
/// actually placed: maximize Σ dot(cktimg pin direction, Schemify offset)
/// over the 8 orientations.
fn fit_orientation(inst: &mut Instance, ir: &Ir, pin_base: usize, pos: ::cktimg::ir::Pt) {
    let Some(phys) = ir.physical.as_ref() else {
        return;
    };
    let backend = crate::emit::SchemifyBackend::new("");
    let mut best = (i64::MIN, inst.rotation, inst.flip);
    for rotation in 0..4u8 {
        for flip in [false, true] {
            inst.rotation = rotation;
            inst.flip = flip;
            let score: i64 = (0..inst.pins.len())
                .map(|slot| {
                    let q = phys.pin_xy[pin_base + slot];
                    let (vx, vy) = ((q.x - pos.x) as i64, (q.y - pos.y) as i64);
                    let (px, py) = crate::emit::pin_position(&backend, inst, slot);
                    let (ox, oy) = ((px - inst.x) as i64, (py - inst.y) as i64);
                    vx * ox + vy * oy
                })
                .sum();
            if score > best.0 {
                best = (score, rotation, flip);
            }
        }
    }
    inst.rotation = best.1;
    inst.flip = best.2;
}

/// cktimg device class name → this crate's primitive. Classes with no
/// counterpart fall back to a subcircuit box (per-instance pins).
fn map_class(name: &str) -> Primitive {
    match name {
        "nmos" | "nfet" | "nfetd" => Primitive::Nmos,
        "pmos" | "pfet" | "pfetd" => Primitive::Pmos,
        "njfet" | "pjfet" => Primitive::Jfet,
        "npn" => Primitive::Npn,
        "pnp" => Primitive::Pnp,
        "res" | "generic" | "varistor" | "potentiometer" | "thermistor" | "thermistorptc"
        | "thermistorntc" | "photoresistor" | "memristor" => Primitive::Resistor,
        "cap" | "ecap" | "vcap" => Primitive::Capacitor,
        "ind" | "cuteind" | "vind" => Primitive::Inductor,
        "diode" | "schottky" | "zener" | "tunneldiode" | "led" | "photodiode" | "varcap"
        | "tvsdiode" => Primitive::Diode,
        "vsource" | "vsourceac" | "vsourcesin" | "battery" => Primitive::Vsource,
        "isource" | "isourceac" => Primitive::Isource,
        "cvsource" => Primitive::Vcvs,
        "cisource" => Primitive::Vccs,
        _ => Primitive::Subcircuit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Report plumbing: a line cktimg can't represent lands in diagnostics.
    #[test]
    fn unsupported_lines_reported() {
        let c = netlist_to_circuit("R1 in out 1k\nT1 in 0 out 0 z0=50\n").unwrap();
        assert_eq!(c.diagnostics.len(), 1, "{:?}", c.diagnostics);
        assert!(c.diagnostics[0].to_string().contains("no builtin symbol"));
    }

    // A rail-named bulk on a 4-node MOS card must parse (upstream model fix).
    #[test]
    fn rail_named_bulk_parses() {
        let c = netlist_to_circuit("M1 out in vss vss nmos\nR1 vdd out 1k\n").unwrap();
        assert!(c.top.instances.iter().any(|i| i.primitive == Primitive::Nmos));
        // Rail devices classify their nets even though they import as labels.
        let vss = c.top.nets.iter().find(|n| n.name == "vss").unwrap();
        assert_eq!(vss.classification, NetClass::Ground);
    }

    // Smallest check that fails if the wiring breaks: parse a divider, expect
    // placed instances, connected nets, and routed wires/labels.
    #[test]
    fn rc_divider_imports_placed_and_routed() {
        let c = netlist_to_circuit("V1 in 0 1\nR1 in out 1k\nR2 out 0 1k\n").unwrap();
        assert_eq!(c.top.instances.len(), 3, "V1 R1 R2 kept, rails dropped");
        for inst in &c.top.instances {
            assert!(inst.pins.iter().any(|p| p.net_idx.is_some()), "{} floats", inst.name);
            assert_eq!(inst.x % 10, 0, "{} off-grid x={}", inst.name, inst.x);
            assert_eq!(inst.y % 10, 0, "{} off-grid y={}", inst.name, inst.y);
        }
        assert!(
            !c.top.wires.is_empty() || !c.top.labels.is_empty(),
            "router produced no connectivity"
        );
        let r1 = c.top.instances.iter().find(|i| i.name.eq_ignore_ascii_case("r1")).unwrap();
        assert_eq!(r1.primitive, Primitive::Resistor);
        assert_eq!(r1.params.get("value").map(String::as_str), Some("1k"));
    }
}
