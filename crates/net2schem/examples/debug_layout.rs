//! Debug: run the pipeline on a SPICE netlist (stdin or file arg) and dump
//! recognized blocks, instance positions/orientations, power/ground pin
//! coords, and Q4-style wire crossings. Layout debugging tool:
//!   cargo run -p schemify-net2schem --example debug_layout netlist.cir

use schemify_net2schem::emit::{pin_position, SchemifyBackend};
use schemify_net2schem::ir::NetClass;

fn main() -> anyhow::Result<()> {
    let arg = std::env::args().nth(1);
    let netlist = match arg {
        Some(p) => std::fs::read_to_string(p)?,
        None => {
            use std::io::Read;
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s)?;
            s
        }
    };
    let circuit = schemify_net2schem::netlist_to_circuit(&netlist)?;
    let backend = SchemifyBackend::new("");

    let mut scopes = vec![("top".to_string(), &circuit.top)];
    for (name, sub) in &circuit.subcircuits {
        scopes.push((format!("subckt {name}"), sub));
    }

    for (scope, sub) in scopes {
        println!("== {scope} ==");
        // Q4 replica: proper crossings between different nets.
        for (i, wa) in sub.wires.iter().enumerate() {
            for wb in sub.wires.iter().skip(i + 1) {
                if wa.net_idx == wb.net_idx {
                    continue;
                }
                let (h, v) = if wa.y1 == wa.y2 && wb.x1 == wb.x2 {
                    (wa, wb)
                } else if wb.y1 == wb.y2 && wa.x1 == wa.x2 {
                    (wb, wa)
                } else {
                    continue;
                };
                let (hx_lo, hx_hi) = (h.x1.min(h.x2), h.x1.max(h.x2));
                let (vy_lo, vy_hi) = (v.y1.min(v.y2), v.y1.max(v.y2));
                if v.x1 > hx_lo && v.x1 < hx_hi && h.y1 > vy_lo && h.y1 < vy_hi {
                    println!(
                        "  X net '{}' h({},{})-({},{})  net '{}' v({},{})-({},{})",
                        sub.nets[h.net_idx.index()].name, h.x1, h.y1, h.x2, h.y2,
                        sub.nets[v.net_idx.index()].name, v.x1, v.y1, v.x2, v.y2
                    );
                }
            }
        }
        let blocks = schemify_net2schem::recognition::recognize_subcircuit(sub);
        for block in &blocks {
            println!("  block {:?} instances {:?}", block.block_type, block.instance_indices);
        }
        for inst in &sub.instances {
            println!(
                "  inst {:<20} kind={:?} pos=({}, {}) rot={} flip={}",
                inst.name, inst.primitive, inst.x, inst.y, inst.rotation, inst.flip
            );
        }
        for net in &sub.nets {
            if net.classification == NetClass::Power || net.classification == NetClass::Ground {
                let pins: Vec<String> = net
                    .pins
                    .iter()
                    .filter_map(|pr| {
                        sub.instances.get(pr.instance_idx.index()).map(|inst| {
                            let (x, y) = pin_position(&backend, inst, pr.pin_idx.index());
                            format!("{}#{}@({x},{y})", inst.name, pr.pin_idx.index())
                        })
                    })
                    .collect();
                println!(
                    "  net {:<12} {:?} pins: {}",
                    net.name,
                    net.classification,
                    pins.join(" ")
                );
            }
        }
    }
    Ok(())
}
