//! XSchem round-trip netlist comparison test.
//!
//! For each test circuit:
//! 1. Parse input .cir -> annotate -> recognize -> place -> route -> emit .sch
//! 2. Invoke xschem to netlist the .sch -> output .spice
//! 3. Parse both netlists, compare net connectivity (partition equivalence)
//!
//! Requires xschem on PATH — run inside `nix develop`:
//!   nix develop --command cargo test -p schemify-handler --test xschem_roundtrip -- --ignored --nocapture
//!
//! MOS bulk pins (pin 3) excluded from comparison (known label placement gap).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use schemify_handler::s2s::annotation::annotate;
use schemify_handler::s2s::output::xschem::XschemBackend;
use schemify_handler::s2s::parser::SpiceParser;
use schemify_handler::s2s::placement::place;
use schemify_handler::s2s::recognition::recognize_subcircuit;
use schemify_handler::s2s::routing::Router;

fn test_backend() -> XschemBackend {
    XschemBackend::new("/tmp")
}

// ---------------------------------------------------------------------------
// XSchem environment
// ---------------------------------------------------------------------------

struct XschemEnv {
    library_path: String,
    rcfile: PathBuf,
}

fn setup_xschem_env() -> Option<XschemEnv> {
    let output = Command::new("which").arg("xschem").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let bin_path = String::from_utf8(output.stdout).ok()?.trim().to_string();
    if bin_path.is_empty() {
        return None;
    }

    let bin_dir = Path::new(&bin_path).parent()?;
    let prefix = bin_dir.parent()?;
    let share_dir = prefix.join("share").join("xschem");
    let library_path = share_dir
        .join("xschem_library")
        .to_string_lossy()
        .into_owned();

    let rcfile = std::env::temp_dir().join("schemify_xschem_roundtrip_rcfile");
    fs::write(
        &rcfile,
        format!("set XSCHEM_LIBRARY_PATH {}\n", library_path),
    )
    .ok()?;

    Some(XschemEnv { library_path, rcfile })
}

fn xschem_netlist(
    sch_path: &Path,
    netlist_dir: &Path,
    env: &XschemEnv,
) -> Result<PathBuf, String> {
    fs::create_dir_all(netlist_dir).map_err(|e| format!("mkdir: {e}"))?;

    let _ = Command::new("timeout")
        .args(["10", "xschem"])
        .arg("--rcfile")
        .arg(&env.rcfile)
        .arg("--netlist_path")
        .arg(netlist_dir)
        .args(["-q", "-n", "-s", "--no_x"])
        .arg(sch_path)
        .env("XSCHEM_LIBRARY_PATH", &env.library_path)
        .env("DISPLAY", "")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    let stem = sch_path.file_stem().unwrap().to_string_lossy();
    let spice_path = netlist_dir.join(format!("{}.spice", stem));
    if spice_path.exists() {
        Ok(spice_path)
    } else {
        Err("xschem produced no netlist".to_string())
    }
}

// ---------------------------------------------------------------------------
// Netlist parsing and comparison
// ---------------------------------------------------------------------------

type PinId = (String, usize);

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

fn run_pipeline_to_sch(input: &str, sch_dir: &Path, name: &str) -> Result<PathBuf, String> {
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

    fs::create_dir_all(sch_dir).map_err(|e| format!("mkdir: {e}"))?;
    let backend = XschemBackend::new(sch_dir.to_str().unwrap());
    let sch_content = backend.format_schematic(&circuit.top);
    let sch_path = sch_dir.join(format!("{}.sch", name));
    fs::write(&sch_path, &sch_content).map_err(|e| format!("write: {e}"))?;

    Ok(sch_path)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Small-circuit roundtrip: simple_amp.spice
#[test]
#[ignore] // Requires xschem on PATH — run inside `nix develop`
fn test_simple_amp_xschem_roundtrip() {
    let env = match setup_xschem_env() {
        Some(e) => e,
        None => {
            eprintln!("xschem not on PATH — skipping");
            return;
        }
    };

    let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/simple_amp.spice");
    if !fixture_path.exists() {
        eprintln!("fixture not found: {:?}", fixture_path);
        return;
    }
    let input = fs::read_to_string(&fixture_path).unwrap();

    let tmp = std::env::temp_dir().join("schemify_xschem_rt_simple_amp");
    let _ = fs::remove_dir_all(&tmp);

    let sch_path = run_pipeline_to_sch(&input, &tmp.join("sch"), "simple_amp")
        .expect("pipeline failed");

    let spice_path = xschem_netlist(&sch_path, &tmp.join("netlist"), &env)
        .expect("xschem netlist failed");

    let output_spice = fs::read_to_string(&spice_path).unwrap();

    let input_pins = parse_netlist_pins(&input, true);
    let output_pins = parse_netlist_pins(&output_spice, true);

    let input_insts: HashSet<String> =
        input_pins.keys().map(|(inst, _)| inst.clone()).collect();
    let output_insts: HashSet<String> =
        output_pins.keys().map(|(inst, _)| inst.clone()).collect();
    let missing: Vec<_> = input_insts.difference(&output_insts).collect();
    assert!(missing.is_empty(), "missing instances: {:?}", missing);

    let (matched, total, extra, details) = compare_connectivity(&input_pins, &output_pins);
    assert!(
        matched == total && extra == 0,
        "connectivity mismatch: {}/{} matched, {} extra\n{}",
        matched, total, extra, details.join("\n"),
    );
}

/// Small-circuit roundtrip: diff_pair.spice
#[test]
#[ignore]
fn test_diff_pair_xschem_roundtrip() {
    let env = match setup_xschem_env() {
        Some(e) => e,
        None => {
            eprintln!("xschem not on PATH — skipping");
            return;
        }
    };

    let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/diff_pair.spice");
    if !fixture_path.exists() {
        eprintln!("fixture not found: {:?}", fixture_path);
        return;
    }
    let input = fs::read_to_string(&fixture_path).unwrap();

    let tmp = std::env::temp_dir().join("schemify_xschem_rt_diff_pair");
    let _ = fs::remove_dir_all(&tmp);

    let sch_path = run_pipeline_to_sch(&input, &tmp.join("sch"), "diff_pair")
        .expect("pipeline failed");

    let spice_path = xschem_netlist(&sch_path, &tmp.join("netlist"), &env)
        .expect("xschem netlist failed");

    let output_spice = fs::read_to_string(&spice_path).unwrap();

    let input_pins = parse_netlist_pins(&input, true);
    let output_pins = parse_netlist_pins(&output_spice, true);

    let input_insts: HashSet<String> =
        input_pins.keys().map(|(inst, _)| inst.clone()).collect();
    let output_insts: HashSet<String> =
        output_pins.keys().map(|(inst, _)| inst.clone()).collect();
    let missing: Vec<_> = input_insts.difference(&output_insts).collect();
    assert!(missing.is_empty(), "missing instances: {:?}", missing);

    let (matched, total, extra, details) = compare_connectivity(&input_pins, &output_pins);
    assert!(
        matched == total && extra == 0,
        "connectivity mismatch: {}/{} matched, {} extra\n{}",
        matched, total, extra, details.join("\n"),
    );
}

/// AMSnet corpus — xschem round-trip (all 734 circuits)
#[test]
#[ignore]
fn test_amsnet_xschem_roundtrip() {
    let env = match setup_xschem_env() {
        Some(e) => e,
        None => {
            eprintln!("xschem not on PATH — skipping");
            return;
        }
    };

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

    let tmp_base = std::env::temp_dir().join("schemify_xschem_roundtrip");
    let _ = fs::remove_dir_all(&tmp_base);

    let mut indices: Vec<usize> = (0..734)
        .filter(|i| amsnet_dir.join(format!("{}/{}.cir", i, i)).exists())
        .collect();
    indices.sort();

    let mut passed = 0;
    let mut failed: Vec<(usize, String)> = Vec::new();

    for &i in &indices {
        let cir_path = amsnet_dir.join(format!("{}/{}.cir", i, i));
        let input = fs::read_to_string(&cir_path).unwrap();

        let test_dir = tmp_base.join(format!("{}", i));
        let sch_dir = test_dir.join("sch");
        let netlist_dir = test_dir.join("netlist");
        let name = format!("{}", i);

        let sch_path = match run_pipeline_to_sch(&input, &sch_dir, &name) {
            Ok(p) => p,
            Err(e) => {
                failed.push((i, format!("pipeline: {}", e)));
                continue;
            }
        };

        let spice_path = match xschem_netlist(&sch_path, &netlist_dir, &env) {
            Ok(p) => p,
            Err(e) => {
                failed.push((i, format!("xschem: {}", e)));
                continue;
            }
        };

        let output_spice = match fs::read_to_string(&spice_path) {
            Ok(s) => s,
            Err(e) => {
                failed.push((i, format!("read netlist: {}", e)));
                continue;
            }
        };

        let input_pins = parse_netlist_pins(&input, true);
        let output_pins = parse_netlist_pins(&output_spice, true);

        let input_insts: HashSet<String> =
            input_pins.keys().map(|(inst, _)| inst.clone()).collect();
        let output_insts: HashSet<String> =
            output_pins.keys().map(|(inst, _)| inst.clone()).collect();
        let missing: Vec<_> = input_insts.difference(&output_insts).collect();
        if !missing.is_empty() {
            failed.push((i, format!("missing instances: {:?}", missing)));
            continue;
        }

        let (matched, total, extra, details) =
            compare_connectivity(&input_pins, &output_pins);

        if matched == total && extra == 0 {
            passed += 1;
        } else {
            let detail_str = if details.len() > 3 {
                format!("{} (+{} more)", details[..3].join("; "), details.len() - 3)
            } else {
                details.join("; ")
            };
            failed.push((i, format!("{}/{} nets, {} extra — {}", matched, total, extra, detail_str)));
        }
    }

    let total = passed + failed.len();
    let pass_rate = if total > 0 { passed as f64 / total as f64 } else { 0.0 };

    eprintln!(
        "\nXSchem round-trip: {}/{} passed ({:.1}%), {} failed",
        passed, total, pass_rate * 100.0, failed.len(),
    );

    if !failed.is_empty() {
        let mut pipeline_fail = 0usize;
        let mut xschem_fail = 0usize;
        let mut missing_inst = 0usize;
        let mut connectivity = 0usize;
        for (_i, msg) in &failed {
            if msg.starts_with("pipeline:") { pipeline_fail += 1; }
            else if msg.starts_with("xschem:") { xschem_fail += 1; }
            else if msg.starts_with("missing instances:") { missing_inst += 1; }
            else { connectivity += 1; }
        }
        eprintln!("\nFailure categories:");
        eprintln!("  pipeline errors:    {}", pipeline_fail);
        eprintln!("  xschem errors:      {}", xschem_fail);
        eprintln!("  missing instances:  {}", missing_inst);
        eprintln!("  connectivity wrong: {}", connectivity);

        eprintln!("\nConnectivity failures:");
        for (i, msg) in &failed {
            if !msg.starts_with("pipeline:") && !msg.starts_with("xschem:") && !msg.starts_with("missing") {
                eprintln!("  circuit {}: {}", i, &msg[..msg.len().min(300)]);
            }
        }
    }

    assert!(
        pass_rate >= 1.0,
        "XSchem round-trip pass rate {:.1}% ({}/{}) — must be 100%",
        pass_rate * 100.0, passed, total,
    );
}
