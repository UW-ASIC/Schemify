//! Benchmark: CHN serialization roundtrip (write + read).
//!
//! Exercises `writer::write_chn` and `reader::read_chn` on a programmatically
//! built schematic with instances, wires, pins, and drawing primitives.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use lasso::Rodeo;
use schemify_core::schematic::{Instance, Line, Pin, Schematic, Wire};
use schemify_core::types::{Color, DeviceKind, InstanceFlags, PinDirection};
use schemify_io::{reader, writer};

/// Build a representative schematic for CHN roundtrip benchmarking.
fn build_test_schematic() -> (Schematic, Rodeo) {
    let mut interner = Rodeo::default();
    let mut sch = Schematic::default();

    sch.name = "bench_circuit".to_string();

    let empty_sym = interner.get_or_intern("");

    // Add pins (symbol definition)
    for (i, (name, dir)) in [
        ("inp", PinDirection::Input),
        ("inn", PinDirection::Input),
        ("out", PinDirection::Output),
        ("vdd", PinDirection::Power),
        ("vss", PinDirection::Ground),
    ]
    .iter()
    .enumerate()
    {
        sch.pins.push(Pin {
            name: interner.get_or_intern(name),
            x: 0,
            y: i as i32 * 20,
            number: i as u32,
            width: 1,
            direction: *dir,
        });
    }

    // Add ~30 instances with properties
    let device_configs: Vec<(&str, &str, DeviceKind)> = vec![
        ("nmos", "nmos4", DeviceKind::Nmos4),
        ("pmos", "pmos4", DeviceKind::Pmos4),
        ("resistor", "resistor", DeviceKind::Resistor),
        ("capacitor", "capacitor", DeviceKind::Capacitor),
        ("vsource", "vsource", DeviceKind::Vsource),
    ];

    for i in 0..30 {
        let (sym_name, _kind_name, kind) = &device_configs[i % device_configs.len()];
        let name = format!("inst_{i}");
        let name_sym = interner.get_or_intern(&name);
        let symbol_sym = interner.get_or_intern(sym_name);

        let prop_start = sch.properties.len() as u32;

        // Add 2 properties per instance
        sch.properties.push(schemify_core::schematic::Property {
            key: interner.get_or_intern("w"),
            value: interner.get_or_intern("1u"),
        });
        sch.properties.push(schemify_core::schematic::Property {
            key: interner.get_or_intern("l"),
            value: interner.get_or_intern("100n"),
        });

        sch.instances.push(Instance {
            name: name_sym,
            symbol: symbol_sym,
            spice_line: empty_sym,
            x: (i % 10) as i32 * 100,
            y: (i / 10) as i32 * 100,
            kind: *kind,
            flags: InstanceFlags::new((i % 4) as u8, i % 3 == 0, false),
            prop_start,
            prop_count: 2,
            name_offset: [0, 0],
            param_offset: [0, 0],
        });
    }

    // Add ~40 wires
    for i in 0..40 {
        let net_name = if i < 5 {
            interner.get_or_intern(&format!("net_{i}"))
        } else {
            empty_sym
        };

        sch.wires.push(Wire {
            net_name,
            x0: (i % 10) * 100,
            y0: (i / 10) * 100,
            x1: (i % 10) * 100 + 80,
            y1: (i / 10) * 100,
            color: Color::NONE,
            thickness: 0,
            bus: i % 8 == 0,
        });
    }

    // Add drawing primitives
    for i in 0..10 {
        sch.lines.push(Line {
            x0: i * 50,
            y0: 0,
            x1: i * 50,
            y1: 100,
            color: Color::NONE,
            thickness: 0,
        });
    }

    (sch, interner)
}

fn bench_chn_write(c: &mut Criterion) {
    let (sch, interner) = build_test_schematic();

    c.bench_function("chn_write_30_instances_40_wires", |b| {
        b.iter(|| {
            let result = writer::write_chn(black_box(&sch), black_box(&interner));
            black_box(&result);
        });
    });
}

fn bench_chn_read(c: &mut Criterion) {
    let (sch, interner) = build_test_schematic();
    let chn_text = writer::write_chn(&sch, &interner).expect("write_chn should succeed");

    c.bench_function("chn_read_30_instances_40_wires", |b| {
        b.iter(|| {
            let mut fresh_interner = Rodeo::default();
            let result = reader::read_chn(black_box(&chn_text), &mut fresh_interner);
            black_box(&result);
        });
    });
}

fn bench_chn_roundtrip(c: &mut Criterion) {
    let (sch, interner) = build_test_schematic();
    let chn_text = writer::write_chn(&sch, &interner).expect("write_chn should succeed");

    c.bench_function("chn_roundtrip_30_instances_40_wires", |b| {
        b.iter(|| {
            // Read
            let mut fresh_interner = Rodeo::default();
            let parsed = reader::read_chn(black_box(&chn_text), &mut fresh_interner);
            // Write back
            let output = writer::write_chn(&parsed, &fresh_interner);
            black_box(&output);
        });
    });
}

criterion_group!(
    benches,
    bench_chn_write,
    bench_chn_read,
    bench_chn_roundtrip
);
criterion_main!(benches);
