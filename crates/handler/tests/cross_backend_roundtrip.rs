//! Cross-backend netlist comparison test.
//!
//! For each circuit:
//! 1. Parse .cir -> S2S pipeline -> IR (shared by both backends)
//! 2. Schemify path: emit SPICE netlist directly from the S2S IR
//! 3. XSchem path:   emit .sch -> xschem --netlist -> .spice
//! 4. Compare connectivity partitions of both netlists
//!
//! This verifies that the schemify .chn backend and XSchem .sch backend
//! produce semantically equivalent netlists from the same IR.
//!
//! Requires xschem on PATH — run inside `nix develop`:
//!   nix develop --command cargo test -p schemify-handler --test cross_backend_roundtrip -- --ignored --nocapture

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use schemify_handler::s2s::annotation::annotate;
use schemify_handler::s2s::ir::{Circuit, Primitive, Subcircuit};
use schemify_handler::s2s::output::xschem::XschemBackend;
use schemify_handler::s2s::parser::SpiceParser;
use schemify_handler::s2s::placement::place;
use schemify_handler::s2s::recognition::recognize_subcircuit;
use schemify_handler::s2s::routing::Router;

// ---------------------------------------------------------------------------
// S2S IR -> SPICE netlister (schemify path)
// ---------------------------------------------------------------------------

/// Emit a SPICE netlist from the S2S IR.
/// This is what "schemify -> netlist" produces.
fn emit_spice(subckt: &Subcircuit) -> String {
    let mut buf = String::new();
    writeln!(buf, "* Schemify netlist").unwrap();

    for inst in &subckt.instances {
        let name = &inst.name;

        // Collect net names for each pin
        let nets: Vec<&str> = inst
            .pins
            .iter()
            .map(|p| {
                p.net_idx
                    .and_then(|idx| subckt.nets.get(idx as usize))
                    .map(|n| n.name.as_str())
                    .unwrap_or("?")
            })
            .collect();

        match inst.primitive {
            Primitive::Nmos | Primitive::Pmos => {
                // M<name> <D> <G> <S> <B> <model> [params]
                if nets.len() >= 4 {
                    let model = if inst.primitive == Primitive::Nmos {
                        "nmos"
                    } else {
                        "pmos"
                    };
                    write!(
                        buf,
                        "{} {} {} {} {} {}",
                        name, nets[0], nets[1], nets[2], nets[3], model
                    )
                    .unwrap();
                    for (k, v) in &inst.params {
                        write!(buf, " {}={}", k, v).unwrap();
                    }
                    writeln!(buf).unwrap();
                }
            }
            Primitive::Npn | Primitive::Pnp => {
                // Q<name> <C> <B> <E> <model>
                if nets.len() >= 3 {
                    let model = if inst.primitive == Primitive::Npn {
                        "npn"
                    } else {
                        "pnp"
                    };
                    writeln!(
                        buf,
                        "{} {} {} {} {}",
                        name, nets[0], nets[1], nets[2], model
                    )
                    .unwrap();
                }
            }
            Primitive::Resistor => {
                if nets.len() >= 2 {
                    let val = inst.params.get("value").map(|s| s.as_str()).unwrap_or("1k");
                    writeln!(buf, "{} {} {} {}", name, nets[0], nets[1], val).unwrap();
                }
            }
            Primitive::Capacitor => {
                if nets.len() >= 2 {
                    let val = inst.params.get("value").map(|s| s.as_str()).unwrap_or("1p");
                    writeln!(buf, "{} {} {} {}", name, nets[0], nets[1], val).unwrap();
                }
            }
            Primitive::Inductor => {
                if nets.len() >= 2 {
                    let val = inst.params.get("value").map(|s| s.as_str()).unwrap_or("1n");
                    writeln!(buf, "{} {} {} {}", name, nets[0], nets[1], val).unwrap();
                }
            }
            Primitive::Vsource => {
                if nets.len() >= 2 {
                    let val = inst.params.get("value").map(|s| s.as_str()).unwrap_or("0");
                    writeln!(buf, "{} {} {} {}", name, nets[0], nets[1], val).unwrap();
                }
            }
            Primitive::Isource => {
                if nets.len() >= 2 {
                    let val = inst.params.get("value").map(|s| s.as_str()).unwrap_or("0");
                    writeln!(buf, "{} {} {} {}", name, nets[0], nets[1], val).unwrap();
                }
            }
            Primitive::Diode => {
                if nets.len() >= 2 {
                    writeln!(buf, "{} {} {} diode", name, nets[0], nets[1]).unwrap();
                }
            }
            Primitive::Vcvs | Primitive::Vccs | Primitive::Ccvs | Primitive::Cccs => {
                // E/G/F/H: name np nm ncp ncm value [params]
                if nets.len() >= 4 {
                    write!(
                        buf,
                        "{} {} {} {} {}",
                        name, nets[0], nets[1], nets[2], nets[3]
                    )
                    .unwrap();
                    if let Some(val) = inst.params.get("value") {
                        write!(buf, " {}", val).unwrap();
                    }
                    writeln!(buf).unwrap();
                }
            }
            Primitive::Jfet => {
                if nets.len() >= 3 {
                    let model = inst
                        .params
                        .get("model")
                        .map(|s| s.as_str())
                        .unwrap_or("jmod");
                    writeln!(buf, "{} {} {} {} {}", name, nets[0], nets[1], nets[2], model)
                        .unwrap();
                }
            }
            Primitive::BehavioralSource => {
                if nets.len() >= 2 {
                    write!(buf, "{} {} {}", name, nets[0], nets[1]).unwrap();
                    for (k, v) in &inst.params {
                        write!(buf, " {}={}", k, v).unwrap();
                    }
                    writeln!(buf).unwrap();
                }
            }
            Primitive::Subcircuit => {
                let sym = &inst.symbol;
                write!(buf, "{} ", name).unwrap();
                for n in &nets {
                    write!(buf, "{} ", n).unwrap();
                }
                writeln!(buf, "{}", sym).unwrap();
            }
        }
    }

    writeln!(buf, ".end").unwrap();
    buf
}

// ---------------------------------------------------------------------------
// XSchem environment (same as xschem_roundtrip.rs)
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

    let rcfile = std::env::temp_dir().join("schemify_cross_backend_rcfile");
    fs::write(
        &rcfile,
        format!("set XSCHEM_LIBRARY_PATH {}\n", library_path),
    )
    .ok()?;

    Some(XschemEnv {
        library_path,
        rcfile,
    })
}

fn xschem_netlist(sch_path: &Path, netlist_dir: &Path, env: &XschemEnv) -> Result<PathBuf, String> {
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
// Connectivity comparison
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
    a_pins: &HashMap<PinId, String>,
    b_pins: &HashMap<PinId, String>,
) -> (usize, usize, usize, Vec<String>) {
    let a_part = build_partition(a_pins);
    let b_part = build_partition(b_pins);

    let matched = a_part.intersection(&b_part).count();
    let a_only = a_part.difference(&b_part).count();
    let b_only = b_part.difference(&a_part).count();

    let mut details = Vec::new();
    for group in a_part.difference(&b_part) {
        let s: Vec<String> = group
            .iter()
            .map(|(inst, pin)| format!("{}:{}", inst, pin))
            .collect();
        details.push(format!("SCHEMIFY_ONLY {{{}}}", s.join(", ")));
    }
    for group in b_part.difference(&a_part) {
        let s: Vec<String> = group
            .iter()
            .map(|(inst, pin)| format!("{}:{}", inst, pin))
            .collect();
        details.push(format!("XSCHEM_ONLY {{{}}}", s.join(", ")));
    }

    (matched, a_part.len() + a_only, b_only, details)
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
        place(subckt, &blocks, &XschemBackend::new("/tmp"));
        Router::new().route(subckt, &XschemBackend::new("/tmp"));
    }

    let blocks = recognize_subcircuit(&circuit.top);
    place(&mut circuit.top, &blocks, &XschemBackend::new("/tmp"));
    Router::new().route(&mut circuit.top, &XschemBackend::new("/tmp"));

    Ok(circuit)
}

fn write_sch(circuit: &Circuit, sch_dir: &Path, name: &str) -> Result<PathBuf, String> {
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

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Cross-backend comparison for a single circuit.
/// Returns Ok(()) on match, Err(detail) on mismatch.
fn compare_backends(
    input: &str,
    name: &str,
    tmp_base: &Path,
    env: &XschemEnv,
) -> Result<(), String> {
    let circuit = run_pipeline(input)?;

    // Schemify path: emit SPICE from S2S IR
    let schemify_spice = emit_spice(&circuit.top);
    let schemify_pins = parse_netlist_pins(&schemify_spice, true);

    // XSchem path: .sch -> xschem --netlist -> .spice
    let test_dir = tmp_base.join(name);
    let sch_path = write_sch(&circuit, &test_dir.join("sch"), name)?;
    let xschem_spice_path = xschem_netlist(&sch_path, &test_dir.join("netlist"), env)?;
    let xschem_spice =
        fs::read_to_string(&xschem_spice_path).map_err(|e| format!("read xschem netlist: {e}"))?;
    let xschem_pins = parse_netlist_pins(&xschem_spice, true);

    // Check both have the same instances
    let s_insts: HashSet<String> = schemify_pins.keys().map(|(i, _)| i.clone()).collect();
    let x_insts: HashSet<String> = xschem_pins.keys().map(|(i, _)| i.clone()).collect();
    let s_missing: Vec<_> = x_insts.difference(&s_insts).collect();
    let x_missing: Vec<_> = s_insts.difference(&x_insts).collect();
    if !s_missing.is_empty() || !x_missing.is_empty() {
        return Err(format!(
            "instance mismatch: schemify missing {:?}, xschem missing {:?}",
            s_missing, x_missing,
        ));
    }

    // Compare connectivity partitions
    let (matched, total, extra, details) = compare_connectivity(&schemify_pins, &xschem_pins);
    if matched == total && extra == 0 {
        Ok(())
    } else {
        let detail_str = if details.len() > 5 {
            format!("{} (+{} more)", details[..5].join("; "), details.len() - 5)
        } else {
            details.join("; ")
        };
        Err(format!(
            "{}/{} matched, {} extra — {}",
            matched, total, extra, detail_str
        ))
    }
}

#[test]
#[ignore] // Requires xschem on PATH
fn test_simple_amp_cross_backend() {
    let env = match setup_xschem_env() {
        Some(e) => e,
        None => {
            eprintln!("xschem not on PATH — skipping");
            return;
        }
    };

    let source = fs::read_to_string(fixture("simple_amp.spice")).unwrap();
    let tmp = std::env::temp_dir().join("schemify_cross_simple_amp");
    let _ = fs::remove_dir_all(&tmp);

    compare_backends(&source, "simple_amp", &tmp, &env).expect("simple_amp cross-backend mismatch");
    eprintln!("simple_amp: schemify == xschem");
}

#[test]
#[ignore]
fn test_diff_pair_cross_backend() {
    let env = match setup_xschem_env() {
        Some(e) => e,
        None => {
            eprintln!("xschem not on PATH — skipping");
            return;
        }
    };

    let source = fs::read_to_string(fixture("diff_pair.spice")).unwrap();
    let tmp = std::env::temp_dir().join("schemify_cross_diff_pair");
    let _ = fs::remove_dir_all(&tmp);

    compare_backends(&source, "diff_pair", &tmp, &env).expect("diff_pair cross-backend mismatch");
    eprintln!("diff_pair: schemify == xschem");
}

#[test]
#[ignore]
fn test_amsnet_cross_backend() {
    let env = match setup_xschem_env() {
        Some(e) => e,
        None => {
            eprintln!("xschem not on PATH — skipping");
            return;
        }
    };

    let amsnet_dir = {
        let local = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/amsnet");
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

    let tmp_base = std::env::temp_dir().join("schemify_cross_backend_amsnet");
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
        let name = format!("{}", i);

        match compare_backends(&input, &name, &tmp_base, &env) {
            Ok(()) => passed += 1,
            Err(e) => failed.push((i, e)),
        }
    }

    let total = passed + failed.len();
    let pass_rate = if total > 0 {
        passed as f64 / total as f64
    } else {
        0.0
    };

    eprintln!(
        "\nCross-backend (schemify vs xschem): {}/{} passed ({:.1}%), {} failed",
        passed,
        total,
        pass_rate * 100.0,
        failed.len(),
    );

    if !failed.is_empty() {
        let mut pipeline_fail = 0usize;
        let mut instance_mismatch = 0usize;
        let mut connectivity = 0usize;
        let mut xschem_fail = 0usize;
        for (_i, msg) in &failed {
            if msg.starts_with("pipeline:") {
                pipeline_fail += 1;
            } else if msg.starts_with("instance mismatch") {
                instance_mismatch += 1;
            } else if msg.contains("xschem") {
                xschem_fail += 1;
            } else {
                connectivity += 1;
            }
        }
        eprintln!("\nFailure categories:");
        eprintln!("  pipeline errors:      {}", pipeline_fail);
        eprintln!("  instance mismatch:    {}", instance_mismatch);
        eprintln!("  xschem errors:        {}", xschem_fail);
        eprintln!("  connectivity differs: {}", connectivity);

        eprintln!("\nAll failures:");
        for (i, msg) in failed.iter().take(20) {
            eprintln!("  circuit {}: {}", i, &msg[..msg.len().min(300)]);
        }
    }

    assert!(
        pass_rate >= 1.0,
        "Cross-backend pass rate {:.1}% ({}/{}) — must be 100%",
        pass_rate * 100.0,
        passed,
        total,
    );
}
