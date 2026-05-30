//! Benchmark: SPICE netlist parsing (~50 components).
//!
//! Exercises `SpiceParser::parse` on a programmatically generated netlist
//! containing MOSFETs, passives, subcircuit instances, .param, .model, and
//! analysis commands -- representative of a medium-size analog block.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use schemify_handler::s2s::parser::SpiceParser;

/// Build a ~50 component SPICE netlist string.
fn build_medium_netlist() -> String {
    let mut lines = Vec::with_capacity(120);

    lines.push("* Medium benchmark netlist (~50 components)".to_string());
    lines.push(".param vdd_nom=1.8".to_string());
    lines.push(".param ibias=10u".to_string());
    lines.push(".param wn=1u".to_string());
    lines.push(".param wp=2u".to_string());
    lines.push(".param lmin=100n".to_string());
    lines.push(".global VDD VSS".to_string());

    // .model definitions
    lines.push(".model nch nmos (vth0=0.5 tox=7n)".to_string());
    lines.push(".model pch pmos (vth0=-0.5 tox=7n)".to_string());
    lines.push(".model npn_mod npn (bf=100)".to_string());

    // Subcircuit definition: simple inverter
    lines.push(".subckt inv in out vdd vss".to_string());
    lines.push("M1 out in vdd vdd pch w=2u l=100n".to_string());
    lines.push("M2 out in vss vss nch w=1u l=100n".to_string());
    lines.push(".ends inv".to_string());

    // 10 NMOS transistors (diff pairs, mirrors)
    for i in 0..10 {
        lines.push(format!(
            "M{i} drain{i} gate{i} source{i} bulk{i} nch w=1u l=100n"
        ));
    }

    // 5 PMOS transistors
    for i in 10..15 {
        lines.push(format!(
            "M{i} drain{i} gate{i} source{i} bulk{i} pch w=2u l=100n"
        ));
    }

    // 8 resistors
    for i in 0..8 {
        lines.push(format!("R{i} net_ra{i} net_rb{i} 1k"));
    }

    // 5 capacitors
    for i in 0..5 {
        lines.push(format!("C{i} net_ca{i} net_cb{i} 1p"));
    }

    // 3 inductors
    for i in 0..3 {
        lines.push(format!("L{i} net_la{i} net_lb{i} 10n"));
    }

    // 2 diodes
    lines.push("D1 anode1 cathode1 dmod".to_string());
    lines.push("D2 anode2 cathode2 dmod".to_string());

    // 2 BJTs
    lines.push("Q1 coll1 base1 emit1 npn_mod".to_string());
    lines.push("Q2 coll2 base2 emit2 npn_mod".to_string());

    // 3 voltage sources
    lines.push("V1 vdd 0 1.8".to_string());
    lines.push("V2 inp 0 PULSE(0 1.8 0 1n 1n 5u 10u)".to_string());
    lines.push("V3 vbias 0 DC 0.9".to_string());

    // 2 current sources
    lines.push("I1 vdd tail 100u".to_string());
    lines.push("I2 vdd mirror_in 50u".to_string());

    // 1 VCVS
    lines.push("E1 out_e 0 inp inn 10".to_string());

    // 1 VCCS
    lines.push("G1 out_g 0 inp inn 1m".to_string());

    // 5 subcircuit instances
    for i in 0..5 {
        lines.push(format!("X{i} in{i} out{i} vdd vss inv m=1"));
    }

    // Analysis commands
    lines.push(".tran 1n 100u".to_string());
    lines.push(".ac dec 10 1 1G".to_string());
    lines.push(".save all".to_string());
    lines.push(".meas tran vout_avg AVG V(out0) FROM=10u TO=100u".to_string());
    lines.push(".options reltol=1e-4".to_string());
    lines.push(".end".to_string());

    lines.join("\n")
}

fn bench_spice_parse(c: &mut Criterion) {
    let netlist = build_medium_netlist();

    c.bench_function("spice_parse_50_components", |b| {
        b.iter(|| {
            let mut parser = SpiceParser::new();
            let circuit = parser.parse(black_box(&netlist)).unwrap();
            black_box(&circuit);
        });
    });
}

fn bench_spice_parse_reuse_parser(c: &mut Criterion) {
    let netlist = build_medium_netlist();
    let mut parser = SpiceParser::new();

    c.bench_function("spice_parse_50_components_reuse_parser", |b| {
        b.iter(|| {
            let circuit = parser.parse(black_box(&netlist)).unwrap();
            black_box(&circuit);
        });
    });
}

criterion_group!(benches, bench_spice_parse, bench_spice_parse_reuse_parser);
criterion_main!(benches);
