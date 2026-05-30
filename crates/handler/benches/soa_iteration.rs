//! Benchmark: SoA instance position iteration (the hot render loop pattern).
//!
//! Measures the cost of iterating instance positions, which is the core
//! operation the renderer does every frame. SoA layout means we only touch
//! (x, y, flags, kind) without dragging in props/names.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use lasso::Rodeo;
use schemify_core::schematic::{Instance, Schematic};
use schemify_core::types::{DeviceKind, InstanceFlags};

/// Build a schematic with `n` instances spread across a grid.
fn build_schematic_with_instances(n: usize) -> (Schematic, Rodeo) {
    let mut interner = Rodeo::default();
    let mut sch = Schematic::default();

    let empty_sym = interner.get_or_intern("");
    let nmos_sym = interner.get_or_intern("nmos");
    let res_sym = interner.get_or_intern("resistor");

    let kinds = [
        (DeviceKind::Nmos4, nmos_sym),
        (DeviceKind::Resistor, res_sym),
        (DeviceKind::Pmos4, nmos_sym),
        (DeviceKind::Capacitor, res_sym),
    ];

    for i in 0..n {
        let name = format!("inst_{i}");
        let name_sym = interner.get_or_intern(&name);
        let (kind, symbol) = kinds[i % kinds.len()];

        sch.instances.push(Instance {
            name: name_sym,
            symbol,
            spice_line: empty_sym,
            x: (i % 100) as i32 * 100,
            y: (i / 100) as i32 * 100,
            kind,
            flags: InstanceFlags::new((i % 4) as u8, i % 3 == 0, false),
            prop_start: 0,
            prop_count: 0,
            name_offset: [0, 0],
            param_offset: [0, 0],
        });
    }

    (sch, interner)
}

/// Simulate the render loop: iterate positions, compute bounding box.
/// This is the pattern the display crate uses every frame.
fn iterate_positions(sch: &Schematic) -> (i32, i32, i32, i32) {
    let instances = &sch.instances;
    let len = instances.len();
    if len == 0 {
        return (0, 0, 0, 0);
    }

    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;

    for i in 0..len {
        let x = instances.x[i];
        let y = instances.y[i];
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x);
        max_y = max_y.max(y);
    }

    (min_x, min_y, max_x, max_y)
}

/// Simulate the hit-test loop: iterate positions + flags for visibility culling.
fn iterate_with_flags(sch: &Schematic) -> usize {
    let instances = &sch.instances;
    let mut visible_count = 0usize;

    // Simulate a viewport culling pass
    let view_x0 = 1000;
    let view_y0 = 1000;
    let view_x1 = 5000;
    let view_y1 = 5000;

    for i in 0..instances.len() {
        let x = instances.x[i];
        let y = instances.y[i];
        if x >= view_x0 && x <= view_x1 && y >= view_y0 && y <= view_y1 {
            // Access kind to simulate render dispatch
            let _kind = instances.kind[i];
            let _flags = instances.flags[i];
            visible_count += 1;
        }
    }

    visible_count
}

fn bench_soa_bounding_box_500(c: &mut Criterion) {
    let (sch, _interner) = build_schematic_with_instances(500);

    c.bench_function("soa_bounding_box_500_instances", |b| {
        b.iter(|| {
            let result = iterate_positions(black_box(&sch));
            black_box(result);
        });
    });
}

fn bench_soa_bounding_box_2000(c: &mut Criterion) {
    let (sch, _interner) = build_schematic_with_instances(2000);

    c.bench_function("soa_bounding_box_2000_instances", |b| {
        b.iter(|| {
            let result = iterate_positions(black_box(&sch));
            black_box(result);
        });
    });
}

fn bench_soa_viewport_cull_2000(c: &mut Criterion) {
    let (sch, _interner) = build_schematic_with_instances(2000);

    c.bench_function("soa_viewport_cull_2000_instances", |b| {
        b.iter(|| {
            let result = iterate_with_flags(black_box(&sch));
            black_box(result);
        });
    });
}

criterion_group!(
    benches,
    bench_soa_bounding_box_500,
    bench_soa_bounding_box_2000,
    bench_soa_viewport_cull_2000
);
criterion_main!(benches);
