//! Benchmark: connectivity resolution on a schematic with ~100 wires + instances.
//!
//! Exercises the union-find based `connectivity::resolve` on a programmatically
//! built schematic with grid-placed components and connecting wires.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use lasso::Rodeo;
use schemify_core::schematic::{Instance, Schematic, Wire};
use schemify_core::types::{Color, DeviceKind, InstanceFlags};
use schemify_handler::connectivity;

/// Build a schematic with ~100 wires and ~50 instances placed on a grid.
/// Instances are NMOS4 devices placed every 100 grid units horizontally.
/// Wires connect adjacent drain/source pins forming chains.
fn build_connectivity_schematic() -> (Schematic, Rodeo) {
    let mut interner = Rodeo::default();
    let mut sch = Schematic::default();

    let empty_sym = interner.get_or_intern("");
    let nmos_sym = interner.get_or_intern("nmos");

    let rows = 5;
    let cols = 10;

    // Place 50 NMOS4 instances on a grid
    for row in 0..rows {
        for col in 0..cols {
            let x = col * 100;
            let y = row * 100;
            let name = format!("M{}_{}", row, col);
            let name_sym = interner.get_or_intern(&name);

            sch.instances.push(Instance {
                name: name_sym,
                symbol: nmos_sym,
                spice_line: empty_sym,
                x,
                y,
                kind: DeviceKind::Nmos4,
                flags: InstanceFlags::new(0, false, false),
                prop_start: 0,
                prop_count: 0,
                name_offset: [0, 0],
                param_offset: [0, 0],
            });
        }
    }

    // Horizontal wires connecting adjacent instances in each row (~45 per direction)
    for row in 0..rows {
        for col in 0..(cols - 1) {
            let x0 = col * 100 + 30; // approximate drain pin offset
            let y0 = row * 100;
            let x1 = (col + 1) * 100 - 30; // next instance source pin
            let y1 = row * 100;

            sch.wires.push(Wire {
                net_name: empty_sym,
                x0,
                y0,
                x1,
                y1,
                color: Color::NONE,
                thickness: 1,
                bus: false,
            });
        }
    }

    // Vertical wires connecting instances across rows (~40 wires)
    for row in 0..(rows - 1) {
        for col in 0..cols {
            let x0 = col * 100;
            let y0 = row * 100 + 30;
            let x1 = col * 100;
            let y1 = (row + 1) * 100 - 30;

            sch.wires.push(Wire {
                net_name: empty_sym,
                x0,
                y0,
                x1,
                y1,
                color: Color::NONE,
                thickness: 1,
                bus: false,
            });
        }
    }

    // Add some named wires for VDD/VSS rails
    let vdd_sym = interner.get_or_intern("VDD");
    let vss_sym = interner.get_or_intern("VSS");

    for col in 0..cols {
        // VDD rail at top
        sch.wires.push(Wire {
            net_name: vdd_sym,
            x0: col * 100 - 20,
            y0: -50,
            x1: col * 100 + 20,
            y1: -50,
            color: Color::NONE,
            thickness: 1,
            bus: false,
        });
        // VSS rail at bottom
        sch.wires.push(Wire {
            net_name: vss_sym,
            x0: col * 100 - 20,
            y0: (rows) * 100 + 50,
            x1: col * 100 + 20,
            y1: (rows) * 100 + 50,
            color: Color::NONE,
            thickness: 1,
            bus: false,
        });
    }

    (sch, interner)
}

fn bench_connectivity_resolve(c: &mut Criterion) {
    let (sch, interner) = build_connectivity_schematic();

    c.bench_function("connectivity_resolve_100_wires_50_instances", |b| {
        b.iter(|| {
            let result = connectivity::resolve(black_box(&sch), black_box(&interner));
            black_box(&result);
        });
    });
}

fn bench_connectivity_resolve_wires_only(c: &mut Criterion) {
    let mut interner = Rodeo::default();
    let mut sch = Schematic::default();
    let empty_sym = interner.get_or_intern("");

    // 100 wires forming chains
    for i in 0..100 {
        sch.wires.push(Wire {
            net_name: empty_sym,
            x0: i * 50,
            y0: 0,
            x1: (i + 1) * 50,
            y1: 0,
            color: Color::NONE,
            thickness: 1,
            bus: false,
        });
    }

    c.bench_function("connectivity_resolve_100_wires_chain", |b| {
        b.iter(|| {
            let result = connectivity::resolve(black_box(&sch), black_box(&interner));
            black_box(&result);
        });
    });
}

criterion_group!(
    benches,
    bench_connectivity_resolve,
    bench_connectivity_resolve_wires_only
);
criterion_main!(benches);
