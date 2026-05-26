//! Integration tests exercising the full SPICE import pipeline:
//!   Parse SPICE -> Annotate -> Recognize -> Place -> Route -> Validate -> Emit
//!
//! Ported from SpiceToSchematic/tests/integration.rs.

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use schemify_handler::s2s::annotation::annotate;
use schemify_handler::s2s::ir::{Circuit, Primitive};
use schemify_handler::s2s::output::schemify::SchemifyBackend;
use schemify_handler::s2s::parser::SpiceParser;
use schemify_handler::s2s::placement::place;
use schemify_handler::s2s::recognition::{recognize_subcircuit, Block};
use schemify_handler::s2s::routing::Router;
use schemify_handler::s2s::validation::{self, Severity};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_temp_dir(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join("schemify_import_tests")
        .join(test_name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("failed to create temp dir");
    dir
}

fn test_backend() -> SchemifyBackend {
    SchemifyBackend::new("/tmp")
}

fn parse_spice(input: &str) -> Circuit {
    let mut parser = SpiceParser::new();
    parser.parse(input).expect("parse failed")
}

/// Fixture path relative to workspace root.
fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Run the full pipeline on the first subcircuit.
/// Returns (subcircuit name, .chn output string, validation errors).
fn run_full_pipeline(
    input: &str,
    test_name: &str,
) -> (String, String, Vec<validation::ValidationError>) {
    let mut circuit = parse_spice(input);
    annotate(&mut circuit);

    let sub_name = circuit
        .subcircuits
        .keys()
        .next()
        .expect("no subcircuit found")
        .clone();

    let subckt = circuit
        .subcircuits
        .get_mut(&sub_name)
        .expect("subcircuit not in map");

    let blocks: Vec<Block> = recognize_subcircuit(subckt);
    place(subckt, &blocks, &test_backend());
    Router::new().route(subckt, &test_backend());
    let errors = validation::validate_subcircuit(subckt);

    let tmp_dir = test_temp_dir(test_name);
    let backend = SchemifyBackend::new(tmp_dir.to_str().unwrap());
    let chn_string = backend.format_schematic(subckt);

    (sub_name, chn_string, errors)
}

/// Run the full pipeline on a top-level circuit (no .subckt).
fn run_top_pipeline(input: &str, test_name: &str) -> (String, Circuit) {
    let mut parser = SpiceParser::new();
    let mut circuit = match parser.parse(input) {
        Ok(c) => c,
        Err(e) => panic!("[{}] parse failed: {}", test_name, e),
    };

    annotate(&mut circuit);

    for subckt in circuit.subcircuits.values_mut() {
        let blocks = recognize_subcircuit(subckt);
        place(subckt, &blocks, &test_backend());
        Router::new().route(subckt, &test_backend());
    }

    let blocks = recognize_subcircuit(&mut circuit.top);
    place(&mut circuit.top, &blocks, &test_backend());
    Router::new().route(&mut circuit.top, &test_backend());

    let tmp_dir = test_temp_dir(test_name);
    let backend = SchemifyBackend::new(tmp_dir.to_str().unwrap());
    let chn = backend.format_schematic(&circuit.top);

    (chn, circuit)
}

fn assert_no_fatal_errors(errors: &[validation::ValidationError]) {
    let fatals: Vec<_> = errors
        .iter()
        .filter(|e| e.severity == Severity::Error)
        .collect();
    assert!(fatals.is_empty(), "fatal validation errors: {:#?}", fatals);
}

/// Assert instance names appear in the .chn output.
fn assert_instances_in_chn(chn: &str, names: &[&str]) {
    for name in names {
        assert!(
            chn.contains(name),
            "expected instance '{}' in .chn output, but not found.\nExcerpt:\n{}",
            name,
            &chn[..chn.len().min(2000)],
        );
    }
}

fn assert_no_overlapping_placements(circuit: &Circuit, sub_name: &str) {
    let subckt = circuit
        .subcircuits
        .get(sub_name)
        .expect("subcircuit not in map");
    let mut positions: HashSet<(i32, i32)> = HashSet::new();
    for inst in &subckt.instances {
        let pos = (inst.x, inst.y);
        assert!(
            positions.insert(pos),
            "overlapping placement: '{}' at ({}, {})",
            inst.name, inst.x, inst.y,
        );
    }
}

/// Structural match: every instance from IR appears in output,
/// and counts match.
fn assert_structural_match(chn: &str, circuit: &Circuit, name: &str) {
    let chn_instances: Vec<&str> = chn
        .lines()
        .filter(|l| {
            let l = l.trim();
            !l.is_empty()
                && !l.starts_with("chn")
                && !l.starts_with("SYMBOL")
                && !l.starts_with("TESTBENCH")
                && !l.starts_with("SCHEMATIC")
                && !l.starts_with("instances:")
                && !l.starts_with("wires:")
                && !l.starts_with("pins:")
                && !l.starts_with(".")
                && !l.contains("lab_pin")
                && !l.contains("gnd")
                && !l.contains("vdd")
                && !l.contains("ipin")
                && !l.contains("opin")
                && !l.contains("iopin")
                && !l.contains("inout_pin")
                && !l.contains("input_pin")
                && !l.contains("output_pin")
                // Wire lines are just coordinates
                && l.split_whitespace().count() > 2
                && l.contains("sym=")
        })
        .collect();

    let input_instance_count = circuit.top.instances.len();

    assert_eq!(
        chn_instances.len(),
        input_instance_count,
        "[{}] instance count mismatch: .chn has {}, IR has {}",
        name, chn_instances.len(), input_instance_count,
    );

    for inst in &circuit.top.instances {
        assert!(
            chn.contains(&inst.name),
            "[{}] instance '{}' not found in .chn output",
            name, inst.name,
        );
    }
}

// ---------------------------------------------------------------------------
// Test 1: Simple 2-MOSFET current mirror
// ---------------------------------------------------------------------------

#[test]
fn test_simple_current_mirror() {
    let spice = "\
.subckt mirror_simple bias out vss
M1 bias bias vss vss nmos w=1u l=180n
M2 out bias vss vss nmos w=1u l=180n
.ends
";

    let (sub_name, chn, errors) = run_full_pipeline(spice, "test_simple_current_mirror");
    assert_eq!(sub_name, "mirror_simple");
    assert_no_fatal_errors(&errors);
    assert_instances_in_chn(&chn, &["m1", "m2"]);

    let has_wires = chn.contains("wires:");
    let has_labels = chn.contains("lab_pin");
    assert!(has_wires || has_labels, "expected wires or labels in output");

    let mut circuit = parse_spice(spice);
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get_mut(&sub_name).unwrap();
    let blocks = recognize_subcircuit(subckt);
    place(subckt, &blocks, &test_backend());
    assert_no_overlapping_placements(&circuit, &sub_name);
}

// ---------------------------------------------------------------------------
// Test 2: Differential pair + tail current source (5 devices)
// ---------------------------------------------------------------------------

#[test]
fn test_diffpair_tail() {
    let spice = "\
.subckt diffpair_tail inp inn outp outm vdd vss
M1 outm inp tail vss nmos w=2u l=180n
M2 outp inn tail vss nmos w=2u l=180n
M3 tail bias vss vss nmos w=4u l=180n
M4 outm outm vdd vdd pmos w=2u l=180n
M5 outp outm vdd vdd pmos w=2u l=180n
.ends
";

    let (sub_name, chn, errors) = run_full_pipeline(spice, "test_diffpair_tail");
    assert_eq!(sub_name, "diffpair_tail");
    assert_no_fatal_errors(&errors);
    assert_instances_in_chn(&chn, &["m1", "m2", "m3", "m4", "m5"]);

    let mut circuit = parse_spice(spice);
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get_mut(&sub_name).unwrap();
    let blocks = recognize_subcircuit(subckt);
    place(subckt, &blocks, &test_backend());
    assert_no_overlapping_placements(&circuit, &sub_name);
}

// ---------------------------------------------------------------------------
// Test 3: Edge case — single resistor
// ---------------------------------------------------------------------------

#[test]
fn test_single_resistor() {
    let spice = "\
.subckt single_res a b
R1 a b 10k
.ends
";

    let (sub_name, chn, errors) = run_full_pipeline(spice, "test_single_resistor");
    assert_eq!(sub_name, "single_res");
    assert_no_fatal_errors(&errors);
    assert_instances_in_chn(&chn, &["r1"]);
    assert!(chn.contains("chn 1"), "expected chn header in output");

    let mut circuit = parse_spice(spice);
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get_mut(&sub_name).unwrap();
    let blocks = recognize_subcircuit(subckt);
    place(subckt, &blocks, &test_backend());
    assert_no_overlapping_placements(&circuit, &sub_name);
}

// ---------------------------------------------------------------------------
// Test 4: Vertical separation — PMOS above NMOS
// ---------------------------------------------------------------------------

#[test]
fn test_vertical_separation() {
    let spice = "\
.subckt ota inp inn out vdd vss
M1 outm inp tail vss nmos w=2u l=180n
M2 outp inn tail vss nmos w=2u l=180n
M3 tail bias vss vss nmos w=4u l=180n
M4 outm outm vdd vdd pmos w=2u l=180n
M5 outp outm vdd vdd pmos w=2u l=180n
.ends
";

    let mut circuit = parse_spice(spice);
    annotate(&mut circuit);
    let sub_name = "ota";
    let subckt = circuit.subcircuits.get_mut(sub_name).unwrap();
    let blocks = recognize_subcircuit(subckt);
    place(subckt, &blocks, &test_backend());

    let pmos_max_y = subckt
        .instances
        .iter()
        .filter(|i| i.primitive == Primitive::Pmos)
        .map(|i| i.y)
        .max()
        .unwrap();
    let nmos_min_y = subckt
        .instances
        .iter()
        .filter(|i| i.primitive == Primitive::Nmos)
        .map(|i| i.y)
        .min()
        .unwrap();

    assert!(
        pmos_max_y < nmos_min_y,
        "PMOS max_y ({}) should be above NMOS min_y ({})",
        pmos_max_y, nmos_min_y,
    );
}

// ---------------------------------------------------------------------------
// Test 5: No false positive diff pair on power rails
// ---------------------------------------------------------------------------

#[test]
fn test_no_false_positive_diff_pair() {
    let spice = "\
.subckt mirror_pair vdd vss out1 out2 bias
M1 out1 bias vdd vdd pmos w=2u l=180n
M2 out2 bias vdd vdd pmos w=2u l=180n
.ends
";

    let mut circuit = parse_spice(spice);
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get_mut("mirror_pair").unwrap();
    let blocks = recognize_subcircuit(subckt);

    let has_diff_pair = blocks
        .iter()
        .any(|b| format!("{:?}", b.block_type) == "DiffPair");
    assert!(
        !has_diff_pair,
        "MOSFETs sharing power rail should not be diff pair, got: {:?}",
        blocks.iter().map(|b| format!("{:?}", b.block_type)).collect::<Vec<_>>(),
    );
}

// ---------------------------------------------------------------------------
// Test 6: Fixture file — simple_amp.spice
// ---------------------------------------------------------------------------

#[test]
fn test_simple_amp_fixture() {
    let path = fixture("simple_amp.spice");
    if !path.exists() {
        eprintln!("fixture not found at {:?}, skipping", path);
        return;
    }
    let input = fs::read_to_string(&path).unwrap();
    let (chn, circuit) = run_top_pipeline(&input, "simple_amp");

    // 4 devices: M1, R1, V1, V2
    assert_eq!(circuit.top.instances.len(), 4);
    assert!(chn.contains("m1"));
    assert!(chn.contains("r1"));
}

// ---------------------------------------------------------------------------
// Test 7: Fixture file — diff_pair.spice
// ---------------------------------------------------------------------------

#[test]
fn test_diff_pair_fixture() {
    let path = fixture("diff_pair.spice");
    if !path.exists() {
        eprintln!("fixture not found at {:?}, skipping", path);
        return;
    }
    let input = fs::read_to_string(&path).unwrap();
    let (chn, circuit) = run_top_pipeline(&input, "diff_pair");

    // 10 devices: M1-M5, R1-R2, V1-V3
    assert_eq!(circuit.top.instances.len(), 10);
    assert!(chn.contains("m1"));
    assert!(chn.contains("r1"));
    assert!(chn.contains("v1"));
}

// ---------------------------------------------------------------------------
// Test 8: SKY130 strongarm — X-prefix MOSFETs reclassified
// ---------------------------------------------------------------------------

#[test]
fn test_sky130_strongarm_x_prefix() {
    let path = fixture("sky130_strongarm.spice");
    let input = fs::read_to_string(&path).unwrap();
    let mut circuit = parse_spice(&input);

    let subckt = circuit.subcircuits.get("strongarm").expect("strongarm subcircuit");

    // All 9 X-instances should be reclassified from Subcircuit to Nmos/Pmos.
    let subckts: Vec<_> = subckt
        .instances
        .iter()
        .filter(|i| i.primitive == Primitive::Subcircuit)
        .collect();
    assert!(
        subckts.is_empty(),
        "expected zero Subcircuit instances after reclassification, got: {:?}",
        subckts.iter().map(|i| &i.name).collect::<Vec<_>>(),
    );

    let nmos_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Nmos).count();
    let pmos_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Pmos).count();
    assert_eq!(nmos_count, 5, "expected 5 NMOS (tail + inp + inn + xnp + xnn)");
    assert_eq!(pmos_count, 4, "expected 4 PMOS (xpp + xpn + rstp + rstn)");

    // Pins should be relabelled to D/G/S/B.
    for inst in &subckt.instances {
        assert_eq!(inst.pins.len(), 4);
        assert_eq!(inst.pins[0].name, "D");
        assert_eq!(inst.pins[1].name, "G");
        assert_eq!(inst.pins[2].name, "S");
        assert_eq!(inst.pins[3].name, "B");
    }

    // Model param should be stored.
    let tail = subckt.instances.iter().find(|i| i.name == "xtail").unwrap();
    assert_eq!(
        tail.params.get("model").unwrap(),
        "sky130_fd_pr__nfet_01v8",
    );

    // Full pipeline should succeed.
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get_mut("strongarm").unwrap();
    let blocks = recognize_subcircuit(subckt);

    // Recognition should find analog blocks (diff pair from inp/inn).
    let diff_pairs: Vec<_> = blocks
        .iter()
        .filter(|b| format!("{:?}", b.block_type) == "DiffPair")
        .collect();
    assert!(
        !diff_pairs.is_empty(),
        "expected diff pair recognition for inp/inn, got blocks: {:?}",
        blocks.iter().map(|b| format!("{:?}", b.block_type)).collect::<Vec<_>>(),
    );

    place(subckt, &blocks, &test_backend());
    Router::new().route(subckt, &test_backend());
    let errors = validation::validate_subcircuit(subckt);
    assert_no_fatal_errors(&errors);
}

// ---------------------------------------------------------------------------
// Test 9: SKY130 extracted netlist — M-prefix with PDK model names
// ---------------------------------------------------------------------------

#[test]
fn test_sky130_extracted_cir() {
    let path = fixture("sky130_strongarm_extracted.cir");
    let input = fs::read_to_string(&path).unwrap();
    let mut circuit = parse_spice(&input);

    let subckt = circuit.subcircuits.get("strongarm").expect("strongarm subcircuit");

    // All M-prefix instances should be correctly classified.
    let nmos_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Nmos).count();
    let pmos_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Pmos).count();
    assert_eq!(nmos_count, 5, "expected 5 NMOS");
    assert_eq!(pmos_count, 4, "expected 4 PMOS");

    // sky130_gnd should be classified as ground after annotation.
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get("strongarm").unwrap();
    let sky130_gnd = subckt.nets.iter().find(|n| n.name == "sky130_gnd");
    assert!(sky130_gnd.is_some(), "sky130_gnd net should exist");
    assert_eq!(
        sky130_gnd.unwrap().classification,
        schemify_handler::s2s::ir::NetClass::Ground,
        "sky130_gnd should be classified as Ground",
    );
}

// ---------------------------------------------------------------------------
// Test 10: PEX netlist with $ comments and parasitic caps
// ---------------------------------------------------------------------------

#[test]
fn test_sky130_pex_with_dollar_comments() {
    let path = fixture("sky130_pex_caps.spice");
    let input = fs::read_to_string(&path).unwrap();
    let mut circuit = parse_spice(&input);

    let subckt = circuit.subcircuits.get("strongarm_flat").expect("strongarm_flat subcircuit");

    // X-prefix MOSFETs should be reclassified.
    let nmos_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Nmos).count();
    let pmos_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Pmos).count();
    assert!(nmos_count > 0, "expected NMOS instances");
    assert!(pmos_count > 0, "expected PMOS instances");
    assert_eq!(nmos_count, 3, "expected 3 NMOS");
    assert_eq!(pmos_count, 4, "expected 4 PMOS (incl. 2 resets, 2 latch)");

    // Parasitic caps (C0-C5) should parse correctly despite $ comments.
    let cap_count = subckt.instances.iter().filter(|i| i.primitive == Primitive::Capacitor).count();
    assert_eq!(cap_count, 6, "expected 6 parasitic capacitors");

    // Cap values should NOT contain the $ comment text.
    for inst in &subckt.instances {
        if inst.primitive == Primitive::Capacitor {
            if let Some(val) = inst.params.get("value") {
                assert!(
                    !val.contains('$') && !val.contains("FLOATING"),
                    "cap {} value '{}' contains comment text",
                    inst.name, val,
                );
            }
        }
    }

    // Full pipeline should succeed.
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get_mut("strongarm_flat").unwrap();
    let blocks = recognize_subcircuit(subckt);
    place(subckt, &blocks, &test_backend());
    Router::new().route(subckt, &test_backend());
}

// ---------------------------------------------------------------------------
// Test 11: is_nmos correctly handles SKY130 model names
// ---------------------------------------------------------------------------

#[test]
fn test_sky130_model_classification() {
    // Parse a circuit with both nfet and pfet to verify classification.
    let spice = "\
.subckt test_models a b c d vdd vss
M1 a b c d sky130_fd_pr__nfet_01v8 W=1 L=0.15
M2 a b c d sky130_fd_pr__pfet_01v8 W=1 L=0.15
M3 a b c d sky130_fd_pr__nfet_01v8_lvt W=1 L=0.15
M4 a b c d sky130_fd_pr__pfet_01v8_hvt W=1 L=0.15
.ends
";
    let circuit = parse_spice(spice);
    let subckt = circuit.subcircuits.get("test_models").unwrap();
    assert_eq!(subckt.instances[0].primitive, Primitive::Nmos, "nfet_01v8 should be NMOS");
    assert_eq!(subckt.instances[1].primitive, Primitive::Pmos, "pfet_01v8 should be PMOS");
    assert_eq!(subckt.instances[2].primitive, Primitive::Nmos, "nfet_01v8_lvt should be NMOS");
    assert_eq!(subckt.instances[3].primitive, Primitive::Pmos, "pfet_01v8_hvt should be PMOS");
}

// ---------------------------------------------------------------------------
// Test 12: GF180MCU X-prefix MOSFETs
// ---------------------------------------------------------------------------

#[test]
fn test_gf180mcu_x_prefix() {
    let spice = "\
.subckt inv out inp vdd vss
Xn out inp vss vss nfet_03v3 W=0.56 L=0.28
Xp out inp vdd vdd pfet_03v3 W=1.12 L=0.28
.ends
";
    let circuit = parse_spice(spice);
    let subckt = circuit.subcircuits.get("inv").unwrap();
    assert_eq!(subckt.instances[0].primitive, Primitive::Nmos, "nfet_03v3 → NMOS");
    assert_eq!(subckt.instances[1].primitive, Primitive::Pmos, "pfet_03v3 → PMOS");
    assert_eq!(subckt.instances[0].pins[0].name, "D");
}

// ---------------------------------------------------------------------------
// Test 13: IHP SG13G2 X-prefix MOSFETs
// ---------------------------------------------------------------------------

#[test]
fn test_ihp_sg13g2_x_prefix() {
    let spice = "\
.subckt inv out inp vdd vss
Xn out inp vss vss sg13_lv_nmos W=0.39 L=0.13
Xp out inp vdd vdd sg13_lv_pmos W=0.78 L=0.13
.ends
";
    let circuit = parse_spice(spice);
    let subckt = circuit.subcircuits.get("inv").unwrap();
    assert_eq!(subckt.instances[0].primitive, Primitive::Nmos, "sg13_lv_nmos → NMOS");
    assert_eq!(subckt.instances[1].primitive, Primitive::Pmos, "sg13_lv_pmos → PMOS");
    assert_eq!(subckt.instances[0].pins[0].name, "D");
}

// ---------------------------------------------------------------------------
// Test 14: PDK-agnostic ground/power suffix matching
// ---------------------------------------------------------------------------

#[test]
fn test_pdk_agnostic_power_ground_annotation() {
    let spice = "\
.subckt test a b foo_gnd bar_vdd baz_vss quux_vcc
M1 a b foo_gnd foo_gnd sky130_fd_pr__nfet_01v8 W=1 L=0.15
M2 a b bar_vdd bar_vdd sky130_fd_pr__pfet_01v8 W=1 L=0.15
M3 a b baz_vss baz_vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
M4 a b quux_vcc quux_vcc sky130_fd_pr__pfet_01v8 W=1 L=0.15
.ends
";
    let mut circuit = parse_spice(spice);
    annotate(&mut circuit);
    let subckt = circuit.subcircuits.get("test").unwrap();

    let find_net = |name: &str| subckt.nets.iter().find(|n| n.name == name);

    let foo_gnd = find_net("foo_gnd").expect("foo_gnd net");
    assert_eq!(
        foo_gnd.classification,
        schemify_handler::s2s::ir::NetClass::Ground,
        "foo_gnd should be Ground via suffix match"
    );

    let bar_vdd = find_net("bar_vdd").expect("bar_vdd net");
    assert_eq!(
        bar_vdd.classification,
        schemify_handler::s2s::ir::NetClass::Power,
        "bar_vdd should be Power via suffix match"
    );

    let baz_vss = find_net("baz_vss").expect("baz_vss net");
    assert_eq!(
        baz_vss.classification,
        schemify_handler::s2s::ir::NetClass::Ground,
        "baz_vss should be Ground via suffix match"
    );

    let quux_vcc = find_net("quux_vcc").expect("quux_vcc net");
    assert_eq!(
        quux_vcc.classification,
        schemify_handler::s2s::ir::NetClass::Power,
        "quux_vcc should be Power via suffix match"
    );
}

// ---------------------------------------------------------------------------
// Test 15: AMSnet corpus (ignored by default)
// ---------------------------------------------------------------------------

#[test]
#[ignore] // Run with: cargo test --test spice_import -- --ignored --nocapture
fn test_amsnet_structural_roundtrip() {
    // Look for AMSnet in sibling project or local tests/
    let amsnet_dir = {
        let local = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/amsnet");
        let sibling = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../SpiceToSchematic/tests/amsnet");
        if local.exists() {
            local
        } else if sibling.exists() {
            sibling
        } else {
            eprintln!("AMSnet corpus not found, skipping");
            return;
        }
    };

    let mut passed = 0;
    let mut failed = Vec::new();
    let mut skipped = 0;

    for i in 0..734 {
        let cir_path = amsnet_dir.join(format!("{}/{}.cir", i, i));
        let input = match fs::read_to_string(&cir_path) {
            Ok(s) => s,
            Err(_) => {
                skipped += 1;
                continue;
            }
        };

        let test_name = format!("amsnet_{}", i);

        let result = std::panic::catch_unwind(|| run_top_pipeline(&input, &test_name));

        match result {
            Ok((chn, circuit)) => {
                let structural_ok = std::panic::catch_unwind(|| {
                    assert_structural_match(&chn, &circuit, &test_name);
                });
                match structural_ok {
                    Ok(_) => passed += 1,
                    Err(e) => {
                        let msg = if let Some(s) = e.downcast_ref::<String>() {
                            s.clone()
                        } else if let Some(s) = e.downcast_ref::<&str>() {
                            s.to_string()
                        } else {
                            "unknown panic".to_string()
                        };
                        failed.push((i, msg));
                    }
                }
            }
            Err(e) => {
                let msg = if let Some(s) = e.downcast_ref::<String>() {
                    s.clone()
                } else if let Some(s) = e.downcast_ref::<&str>() {
                    s.to_string()
                } else {
                    "unknown panic".to_string()
                };
                failed.push((i, msg));
            }
        }
    }

    let total = passed + failed.len();
    let pass_rate = if total > 0 { passed as f64 / total as f64 } else { 0.0 };

    eprintln!(
        "\nAMSnet structural round-trip: {}/{} passed, {} failed, {} skipped",
        passed, total, failed.len(), skipped,
    );

    if !failed.is_empty() {
        eprintln!("\nFirst 10 failures:");
        for (i, msg) in failed.iter().take(10) {
            eprintln!("  circuit {}: {}", i, &msg[..msg.len().min(200)]);
        }
    }

    assert!(
        pass_rate >= 0.95,
        "AMSnet pass rate {:.1}% ({}/{}) below 95% threshold",
        pass_rate * 100.0, passed, total,
    );
}
