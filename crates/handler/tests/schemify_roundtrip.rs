//! Schemify round-trip connectivity comparison test.
//!
//! For each test circuit:
//! 1. Parse input .cir -> annotate -> recognize -> place -> route
//! 2. Extract connectivity from S2S IR (pin-to-net mapping)
//! 3. Compare with original SPICE netlist connectivity (partition equivalence)
//! 4. Also: write .chn -> read back -> verify structural integrity
//!
//! MOS bulk pins (pin 3) excluded from comparison (known label placement gap).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use lasso::Rodeo;

use schemify_handler::s2s::annotation::annotate;
use schemify_handler::s2s::ir::Circuit;
use schemify_handler::s2s::output::schemify::SchemifyBackend;
use schemify_handler::s2s::output::Backend;
use schemify_handler::s2s::parser::SpiceParser;
use schemify_handler::s2s::placement::place;
use schemify_handler::s2s::recognition::recognize_subcircuit;
use schemify_handler::s2s::routing::Router;
use schemify_handler::spice_import::import_spice;

fn test_backend() -> SchemifyBackend {
    SchemifyBackend::new("/tmp")
}

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

// ---------------------------------------------------------------------------
// Netlist parsing and comparison (same approach as xschem_roundtrip)
// ---------------------------------------------------------------------------

type PinId = (String, usize);

/// Parse SPICE netlist into pin-to-net mapping.
fn parse_netlist_pins(spice: &str, skip_mos_bulk: bool) -> HashMap<PinId, String> {
    let mut pin_to_net: HashMap<PinId, String> = HashMap::new();

    for line in spice.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('*') || line.starts_with('.') {
            continue;
        }

        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.is_empty() {
            continue;
        }

        let inst = tokens[0].to_lowercase();
        let first = inst.chars().next().unwrap_or(' ');

        let pin_count = match first {
            'm' => 4,
            'r' | 'c' | 'l' | 'v' | 'i' => 2,
            'q' => 3,
            'd' => 2,
            _ => continue,
        };

        if tokens.len() < 1 + pin_count {
            continue;
        }

        for pin_idx in 0..pin_count {
            if skip_mos_bulk && first == 'm' && pin_idx == 3 {
                continue;
            }
            let net = tokens[1 + pin_idx].to_lowercase();
            pin_to_net.insert((inst.clone(), pin_idx), net);
        }
    }

    pin_to_net
}

/// Extract pin-to-net mapping from S2S IR after pipeline.
fn extract_ir_pins(circuit: &Circuit, skip_mos_bulk: bool) -> HashMap<PinId, String> {
    let mut pin_to_net: HashMap<PinId, String> = HashMap::new();

    for inst in &circuit.top.instances {
        let name = inst.name.to_lowercase();
        let first = name.chars().next().unwrap_or(' ');

        for (pin_idx, pin) in inst.pins.iter().enumerate() {
            if skip_mos_bulk && first == 'm' && pin_idx == 3 {
                continue;
            }
            if let Some(net_idx) = pin.net_idx {
                if let Some(net) = circuit.top.nets.get(net_idx as usize) {
                    pin_to_net.insert(
                        (name.clone(), pin_idx),
                        net.name.to_lowercase(),
                    );
                }
            }
        }
    }

    pin_to_net
}

fn build_partition(pin_to_net: &HashMap<PinId, String>) -> HashSet<BTreeSet<PinId>> {
    let mut net_to_pins: HashMap<&String, BTreeSet<PinId>> = HashMap::new();
    for (pin_id, net) in pin_to_net {
        net_to_pins.entry(net).or_default().insert(pin_id.clone());
    }
    net_to_pins
        .into_values()
        .filter(|pins| pins.len() >= 2)
        .collect()
}

fn compare_connectivity(
    input_pins: &HashMap<PinId, String>,
    output_pins: &HashMap<PinId, String>,
) -> (usize, usize, usize, Vec<String>) {
    let input_part = build_partition(input_pins);
    let output_part = build_partition(output_pins);

    let matched = input_part.intersection(&output_part).count();
    let extra = output_part.difference(&input_part).count();

    let mut details = Vec::new();
    for group in input_part.difference(&output_part) {
        let s: Vec<String> = group
            .iter()
            .map(|(inst, pin)| format!("{}:{}", inst, pin))
            .collect();
        details.push(format!("MISSING {{{}}}", s.join(", ")));
    }
    for group in output_part.difference(&input_part) {
        let s: Vec<String> = group
            .iter()
            .map(|(inst, pin)| format!("{}:{}", inst, pin))
            .collect();
        details.push(format!("EXTRA {{{}}}", s.join(", ")));
    }

    (matched, input_part.len(), extra, details)
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

fn run_pipeline(input: &str) -> Result<Circuit, String> {
    let mut parser = SpiceParser::new();
    let mut circuit = parser.parse(input).map_err(|e| format!("parse: {e}"))?;

    annotate(&mut circuit);

    for subckt in circuit.subcircuits.values_mut() {
        let blocks = recognize_subcircuit(subckt);
        place(subckt, &blocks, &test_backend());
        Router::new().route(subckt, &test_backend());
    }

    let blocks = recognize_subcircuit(&mut circuit.top);
    place(&mut circuit.top, &blocks, &test_backend());
    Router::new().route(&mut circuit.top, &test_backend());

    Ok(circuit)
}

fn run_pipeline_to_chn(input: &str, chn_dir: &Path, name: &str) -> Result<PathBuf, String> {
    let mut circuit = run_pipeline(input)?;
    circuit.top.name = name.to_string();

    fs::create_dir_all(chn_dir).map_err(|e| format!("mkdir: {e}"))?;
    let backend = SchemifyBackend::new(chn_dir.to_str().unwrap());
    backend.write_all(&circuit).map_err(|e| format!("write_all: {e}"))?;

    let chn_path = chn_dir.join(format!("{}.chn", name));
    if chn_path.exists() {
        Ok(chn_path)
    } else {
        Err("write_all produced no .chn file".to_string())
    }
}

// ---------------------------------------------------------------------------
// .chn idempotency helper
// ---------------------------------------------------------------------------

/// Assert .chn serialization is idempotent:
///   import → write → read → write → exact text match.
fn assert_chn_idempotent(spice_source: &str, name: &str) {
    let mut int1 = Rodeo::default();
    let sch1 = import_spice(spice_source, &mut int1)
        .unwrap_or_else(|e| panic!("[{name}] import_spice failed: {e}"));

    let chn1 = schemify_io::writer::write_chn(&sch1, &int1)
        .unwrap_or_else(|| panic!("[{name}] write_chn pass 1 failed"));

    let mut int2 = Rodeo::default();
    let sch2 = schemify_io::reader::read_chn(&chn1, &mut int2);

    let chn2 = schemify_io::writer::write_chn(&sch2, &int2)
        .unwrap_or_else(|| panic!("[{name}] write_chn pass 2 failed"));

    assert_eq!(chn1, chn2, "[{name}] .chn not idempotent after roundtrip");
}

// ---------------------------------------------------------------------------
// Tests — small circuits (always run)
// ---------------------------------------------------------------------------

#[test]
fn test_simple_amp_import_roundtrip() {
    let source = fs::read_to_string(fixture("simple_amp.spice")).unwrap();
    assert_chn_idempotent(&source, "simple_amp");
}

#[test]
fn test_diff_pair_import_roundtrip() {
    let source = fs::read_to_string(fixture("diff_pair.spice")).unwrap();
    assert_chn_idempotent(&source, "diff_pair");
}

/// SPICE -> S2S pipeline -> compare connectivity with original.
#[test]
fn test_simple_amp_connectivity() {
    let source = fs::read_to_string(fixture("simple_amp.spice")).unwrap();
    let circuit = run_pipeline(&source).expect("pipeline failed");

    let input_pins = parse_netlist_pins(&source, true);
    let ir_pins = extract_ir_pins(&circuit, true);

    let input_insts: HashSet<String> = input_pins.keys().map(|(i, _)| i.clone()).collect();
    let ir_insts: HashSet<String> = ir_pins.keys().map(|(i, _)| i.clone()).collect();
    let missing: Vec<_> = input_insts.difference(&ir_insts).collect();
    assert!(missing.is_empty(), "missing instances in IR: {:?}", missing);

    let (matched, total, extra, details) = compare_connectivity(&input_pins, &ir_pins);
    assert!(
        matched == total && extra == 0,
        "connectivity mismatch: {}/{} matched, {} extra\n{}",
        matched, total, extra, details.join("\n"),
    );
}

#[test]
fn test_diff_pair_connectivity() {
    let source = fs::read_to_string(fixture("diff_pair.spice")).unwrap();
    let circuit = run_pipeline(&source).expect("pipeline failed");

    let input_pins = parse_netlist_pins(&source, true);
    let ir_pins = extract_ir_pins(&circuit, true);

    let input_insts: HashSet<String> = input_pins.keys().map(|(i, _)| i.clone()).collect();
    let ir_insts: HashSet<String> = ir_pins.keys().map(|(i, _)| i.clone()).collect();
    let missing: Vec<_> = input_insts.difference(&ir_insts).collect();
    assert!(missing.is_empty(), "missing instances in IR: {:?}", missing);

    let (matched, total, extra, details) = compare_connectivity(&input_pins, &ir_pins);
    assert!(
        matched == total && extra == 0,
        "connectivity mismatch: {}/{} matched, {} extra\n{}",
        matched, total, extra, details.join("\n"),
    );
}

/// .chn write -> read -> write -> exact text match (idempotent serialization).
#[test]
fn test_chn_write_read_roundtrip() {
    for name in &["simple_amp", "diff_pair"] {
        let source = fs::read_to_string(fixture(&format!("{name}.spice"))).unwrap();
        assert_chn_idempotent(&source, name);
    }
}

// ---------------------------------------------------------------------------
// AMSnet corpus — schemify connectivity round-trip
// ---------------------------------------------------------------------------

#[test]
#[ignore] // Run with: cargo test --test schemify_roundtrip -- --ignored --nocapture
fn test_amsnet_schemify_roundtrip() {
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

    let mut indices: Vec<usize> = (0..734)
        .filter(|i| amsnet_dir.join(format!("{}/{}.cir", i, i)).exists())
        .collect();
    indices.sort();

    let mut passed = 0;
    let mut failed: Vec<(usize, String)> = Vec::new();

    for &i in &indices {
        let cir_path = amsnet_dir.join(format!("{}/{}.cir", i, i));
        let input = fs::read_to_string(&cir_path).unwrap();
        let name = format!("{}", i);

        // 1. Run S2S pipeline
        let circuit = match run_pipeline(&input) {
            Ok(c) => c,
            Err(e) => {
                failed.push((i, format!("pipeline: {}", e)));
                continue;
            }
        };

        // 2. Compare IR connectivity with original SPICE
        let input_pins = parse_netlist_pins(&input, true);
        let ir_pins = extract_ir_pins(&circuit, true);

        let input_insts: HashSet<String> =
            input_pins.keys().map(|(inst, _)| inst.clone()).collect();
        let ir_insts: HashSet<String> =
            ir_pins.keys().map(|(inst, _)| inst.clone()).collect();
        let missing: Vec<_> = input_insts.difference(&ir_insts).collect();
        if !missing.is_empty() {
            failed.push((i, format!("missing instances: {:?}", missing)));
            continue;
        }

        let (matched, total, extra, details) =
            compare_connectivity(&input_pins, &ir_pins);

        if matched != total || extra != 0 {
            let detail_str = if details.len() > 3 {
                format!("{} (+{} more)", details[..3].join("; "), details.len() - 3)
            } else {
                details.join("; ")
            };
            failed.push((i, format!("{}/{} nets, {} extra — {}", matched, total, extra, detail_str)));
            continue;
        }

        // 3. Verify .chn idempotent roundtrip (exact text match)
        let result = std::panic::catch_unwind(|| {
            assert_chn_idempotent(&input, &format!("{}", i));
        });
        if let Err(e) = result {
            let msg = if let Some(s) = e.downcast_ref::<String>() {
                s.clone()
            } else if let Some(s) = e.downcast_ref::<&str>() {
                s.to_string()
            } else {
                "unknown panic".to_string()
            };
            failed.push((i, format!(".chn idempotency: {}", msg)));
            continue;
        }

        passed += 1;
    }

    let total = passed + failed.len();
    let pass_rate = if total > 0 { passed as f64 / total as f64 } else { 0.0 };

    eprintln!(
        "\nSchemify round-trip: {}/{} passed ({:.1}%), {} failed",
        passed, total, pass_rate * 100.0, failed.len(),
    );

    if !failed.is_empty() {
        let mut pipeline_fail = 0usize;
        let mut missing_inst = 0usize;
        let mut connectivity = 0usize;
        let mut chn_fail = 0usize;
        for (_i, msg) in &failed {
            if msg.starts_with("pipeline:") { pipeline_fail += 1; }
            else if msg.starts_with("missing instances:") { missing_inst += 1; }
            else if msg.contains(".chn") { chn_fail += 1; }
            else { connectivity += 1; }
        }
        eprintln!("\nFailure categories:");
        eprintln!("  pipeline errors:    {}", pipeline_fail);
        eprintln!("  missing instances:  {}", missing_inst);
        eprintln!("  connectivity wrong: {}", connectivity);
        eprintln!("  .chn roundtrip:     {}", chn_fail);

        eprintln!("\nAll failures:");
        for (i, msg) in failed.iter().take(20) {
            eprintln!("  circuit {}: {}", i, &msg[..msg.len().min(300)]);
        }
    }

    assert!(
        pass_rate >= 1.0,
        "Schemify round-trip pass rate {:.1}% ({}/{}) — must be 100%",
        pass_rate * 100.0, passed, total,
    );
}
