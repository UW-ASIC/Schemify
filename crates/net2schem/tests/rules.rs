//! Integration tests enforcing the schematic-quality rules (MIGRATION.md
//! "Schematic rules": R1-R8 + Q1-Q5, ALL hard-fail) over the PySpice fixtures
//! in `tests/fixture/`.
//!
//! Each fixture `.py` is executed with `python3` (PYTHONPATH from the
//! `PYSPICE_MODULE_DIR` env var, i.e. inside `nix develop`); its stdout is the
//! SPICE netlist, which is fed through `netlist_to_circuit` → `layout_circuit`
//! (the latter is implied by the former) and every resulting subcircuit
//! (top + definitions) is checked against all rules. Violations are collected
//! per category and reported in one panic so failures localize but never hide
//! each other.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use lasso::Rodeo;

use schemify_net2schem::emit::{
    self, pin_position, SchemifyBackend, Severity, ValidationError,
};
use schemify_net2schem::ir::{NetClass, PinDir, Primitive, Subcircuit, Wire};
use schemify_net2schem::route::{classify_nets, NetStrategy};
use schemify_net2schem::shared::{is_ground_name, is_power_name};

// ===========================================================================
// Per-category test entry points
// ===========================================================================

#[test]
fn test_basic() {
    run_category("basic");
}

#[test]
fn test_bjt() {
    run_category("bjt");
}

#[test]
fn test_bus() {
    run_category("bus");
}

#[test]
fn test_digital() {
    run_category("digital");
}

#[test]
fn test_mixed_signal() {
    run_category("mixed_signal");
}

#[test]
fn test_mosfet() {
    run_category("mosfet");
}

#[test]
fn test_opamp() {
    run_category("opamp");
}

#[test]
fn test_power() {
    run_category("power");
}

#[test]
fn test_testbench() {
    run_category("testbench");
}

// ===========================================================================
// Harness
// ===========================================================================

/// Max violation detail lines printed per category (counts are always full).
/// High enough that per-rule breakdowns of dense categories are not truncated.
const MAX_REPORT_LINES: usize = 10_000;

fn run_category(category: &str) {
    let pyspice_dir = std::env::var("PYSPICE_MODULE_DIR")
        .unwrap_or_else(|_| panic!("set PYSPICE_MODULE_DIR — run inside `nix develop`"));

    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixture")
        .join(category);
    let mut fixtures: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("reading fixture dir {}: {e}", dir.display()))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "py"))
        .collect();
    fixtures.sort();
    assert!(
        !fixtures.is_empty(),
        "no .py fixtures found in {}",
        dir.display()
    );

    let backend = SchemifyBackend::new("");
    let mut violations: Vec<String> = Vec::new();

    for fixture in &fixtures {
        let fname = fixture
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or_default();

        let t0 = std::time::Instant::now();
        let netlist = match generate_netlist(fixture, &pyspice_dir) {
            Ok(n) => n,
            Err(e) => {
                violations.push(format!("{fname} GEN: {e}"));
                continue;
            }
        };
        let t_gen = t0.elapsed();

        let t1 = std::time::Instant::now();
        let circuit = match schemify_net2schem::netlist_to_circuit(&netlist) {
            Ok(c) => c,
            Err(e) => {
                violations.push(format!("{fname} PARSE: {e}"));
                continue;
            }
        };
        let t_layout = t1.elapsed();
        eprintln!(
            "[rules] {fname}: gen {:?}, parse+layout {:?}",
            t_gen, t_layout
        );

        // Check top + every subcircuit definition (sorted for stable output).
        let mut scopes: Vec<(String, &Subcircuit)> = vec![("top".to_string(), &circuit.top)];
        let mut sub_names: Vec<&String> = circuit.subcircuits.keys().collect();
        sub_names.sort();
        for name in sub_names {
            scopes.push((format!("subckt {name}"), &circuit.subcircuits[name]));
        }

        for (scope, sub) in scopes {
            for v in check_subcircuit(sub, &backend) {
                violations.push(format!("{fname} [{scope}] {v}"));
            }
        }
    }

    if violations.is_empty() {
        return;
    }

    // Per-rule counts: first whitespace token shaped like `R6:`/`Q2:`
    // (message text may contain ']'/':' freely).
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for v in &violations {
        let rule = v
            .split_whitespace()
            .find_map(|tok| {
                let id = tok.strip_suffix(':').unwrap_or(tok);
                let mut ch = id.chars();
                (matches!(ch.next(), Some('R' | 'Q'))
                    && id.len() <= 3
                    && ch.all(|c| c.is_ascii_digit())
                    && id.len() > 1)
                    .then(|| id.to_string())
            })
            .unwrap_or_else(|| "OTHER".to_string());
        *counts.entry(rule).or_insert(0) += 1;
    }
    let count_summary: Vec<String> = counts.iter().map(|(r, c)| format!("{r}={c}")).collect();

    let shown = violations.len().min(MAX_REPORT_LINES);
    let mut body = violations[..shown].join("\n");
    if violations.len() > shown {
        body.push_str(&format!(
            "\n... ({} more violations suppressed)",
            violations.len() - shown
        ));
    }

    panic!(
        "category '{category}': {} schematic-rule violations across {} fixtures\nper-rule: {}\n\n{body}",
        violations.len(),
        fixtures.len(),
        count_summary.join("  "),
    );
}

/// Run the fixture script through python3, returning the SPICE netlist (stdout).
fn generate_netlist(fixture: &Path, pyspice_dir: &str) -> Result<String, String> {
    let mut pythonpath = pyspice_dir.to_string();
    if let Ok(existing) = std::env::var("PYTHONPATH") {
        if !existing.is_empty() {
            pythonpath = format!("{pythonpath}:{existing}");
        }
    }

    let output = Command::new("python3")
        .arg(fixture)
        .env("PYTHONPATH", pythonpath)
        .output()
        .map_err(|e| format!("spawning python3: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "python3 exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Run all rules on one laid-out subcircuit, collecting violations.
fn check_subcircuit(sub: &Subcircuit, backend: &SchemifyBackend) -> Vec<String> {
    let mut out = Vec::new();
    rule_r1_to_r4_and_r7(sub, &mut out);
    rule_r5_pin_connectivity(sub, backend, &mut out);
    rule_r6_wire_clearance(sub, backend, &mut out);
    rule_r8_connectivity_roundtrip(sub, backend, &mut out);
    rule_q1_signal_flow(sub, backend, &mut out);
    rule_q2_power_orientation(sub, backend, &mut out);
    rule_q4_wire_crossings(sub, &mut out);
    rule_q5_wire_vs_label(sub, backend, &mut out);
    out
}

// ===========================================================================
// Geometry helpers
// ===========================================================================

type Pt = (i32, i32);

/// True if `p` lies on segment a-b (collinear and within bounding box).
fn on_segment(p: Pt, a: Pt, b: Pt) -> bool {
    let cross = (b.0 - a.0) as i64 * (p.1 - a.1) as i64 - (b.1 - a.1) as i64 * (p.0 - a.0) as i64;
    cross == 0
        && p.0 >= a.0.min(b.0)
        && p.0 <= a.0.max(b.0)
        && p.1 >= a.1.min(b.1)
        && p.1 <= a.1.max(b.1)
}

/// Manhattan distance from point to an orthogonal segment (exact for
/// horizontal/vertical segments, conservative otherwise).
fn dist_to_segment(p: Pt, a: Pt, b: Pt) -> i32 {
    let cx = p.0.clamp(a.0.min(b.0), a.0.max(b.0));
    let cy = p.1.clamp(a.1.min(b.1), a.1.max(b.1));
    (p.0 - cx).abs() + (p.1 - cy).abs()
}

fn manhattan(a: Pt, b: Pt) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}

fn mean(values: &[i32]) -> f64 {
    values.iter().map(|&v| v as f64).sum::<f64>() / values.len() as f64
}

// ===========================================================================
// R1-R4 + R7 — emit's public check_* validators (ALL severities hard-fail)
// ===========================================================================

fn rule_r1_to_r4_and_r7(sub: &Subcircuit, out: &mut Vec<String>) {
    let push_all = |rule: &str, errors: Vec<ValidationError>, out: &mut Vec<String>| {
        for e in errors {
            let sev = match e.severity {
                Severity::Error => "error",
                Severity::Warning => "warning",
            };
            out.push(format!("{rule}: [{sev}] {}", e.message));
        }
    };

    let mut errs = Vec::new();
    emit::check_unique_names(sub, &mut errs);
    push_all("R1", std::mem::take(&mut errs), out);

    emit::check_grid_alignment(sub, &mut errs);
    push_all("R2", std::mem::take(&mut errs), out);

    emit::check_rotation_values(sub, &mut errs);
    push_all("R3", std::mem::take(&mut errs), out);

    emit::check_wire_orthogonality(sub, &mut errs);
    push_all("R4", std::mem::take(&mut errs), out);
    emit::check_no_duplicate_wires(sub, &mut errs);
    push_all("R4", std::mem::take(&mut errs), out);
    // R4 also requires nonzero length, which the emit checks do not cover.
    for (i, w) in sub.wires.iter().enumerate() {
        if w.x1 == w.x2 && w.y1 == w.y2 {
            out.push(format!(
                "R4: wire {i} has zero length at ({}, {})",
                w.x1, w.y1
            ));
        }
    }

    emit::check_net_label_consistency(sub, &mut errs);
    push_all("R7", std::mem::take(&mut errs), out);
}

// ===========================================================================
// R5 — every connected pin sits exactly on a same-net wire or label
// ===========================================================================

fn rule_r5_pin_connectivity(sub: &Subcircuit, backend: &SchemifyBackend, out: &mut Vec<String>) {
    for inst in &sub.instances {
        for (pi, pin) in inst.pins.iter().enumerate() {
            let Some(net_id) = pin.net_idx else { continue };
            let pos = pin_position(backend, inst, pi);

            let wired = sub
                .wires
                .iter()
                .filter(|w| w.net_idx == net_id)
                .any(|w| on_segment(pos, (w.x1, w.y1), (w.x2, w.y2)));
            let labelled = sub
                .labels
                .iter()
                .filter(|l| l.net_idx == net_id)
                .any(|l| (l.x, l.y) == pos);
            if wired || labelled {
                continue;
            }

            // Not connected: measure nearest same-net routing for diagnostics.
            let mut min_dist = i32::MAX;
            for w in sub.wires.iter().filter(|w| w.net_idx == net_id) {
                min_dist = min_dist.min(dist_to_segment(pos, (w.x1, w.y1), (w.x2, w.y2)));
            }
            for l in sub.labels.iter().filter(|l| l.net_idx == net_id) {
                min_dist = min_dist.min(manhattan(pos, (l.x, l.y)));
            }

            let net_name = &sub.nets[net_id.index()].name;
            if min_dist == i32::MAX {
                out.push(format!(
                    "R5: pin {}.{pi} ('{}', net '{net_name}') at ({}, {}) — net has no wires or labels at all",
                    inst.name, pin.name, pos.0, pos.1
                ));
            } else if min_dist < 10 {
                out.push(format!(
                    "R5: pin {}.{pi} ('{}', net '{net_name}') at ({}, {}) — near-miss, nearest same-net routing is off by {min_dist}",
                    inst.name, pin.name, pos.0, pos.1
                ));
            } else {
                out.push(format!(
                    "R5: pin {}.{pi} ('{}', net '{net_name}') at ({}, {}) dangling — nearest same-net routing {min_dist} away",
                    inst.name, pin.name, pos.0, pos.1
                ));
            }
        }
    }
}

// ===========================================================================
// Bulk-stub exemption (shared by R6 and Q5)
// ===========================================================================

/// Same-instance source→bulk stub on a power/ground-class net.
///
/// The router replaces a second stacked rail symbol with a short stub wire
/// between two pins of one device (bulk tied to source on vdd/gnd). Such a
/// wire is identified structurally: its net is power/ground-class and both
/// (grid-snapped) endpoints coincide with pin positions of the SAME instance
/// on that net. These stubs are exempt from Q5's "Label nets carry no wires"
/// and from R6 clearance.
fn is_power_stub_wire(sub: &Subcircuit, backend: &SchemifyBackend, w: &Wire) -> bool {
    let Some(net) = sub.nets.get(w.net_idx.index()) else {
        return false;
    };
    let powerish = matches!(net.classification, NetClass::Power | NetClass::Ground)
        || is_power_name(&net.name)
        || is_ground_name(&net.name);
    if !powerish {
        return false;
    }
    // Router emits stub endpoints snapped to the 10-unit grid.
    let snap = |v: i32| (v + 5).div_euclid(10) * 10;
    let a = (snap(w.x1), snap(w.y1));
    let b = (snap(w.x2), snap(w.y2));
    // Both endpoints must be pins of one single instance on this net.
    let mut per_inst: HashMap<u32, (bool, bool)> = HashMap::new();
    for pr in &net.pins {
        let inst = &sub[pr.instance_idx];
        let p = pin_position(backend, inst, pr.pin_idx.index());
        let p = (snap(p.0), snap(p.1));
        let entry = per_inst.entry(pr.instance_idx.0).or_default();
        if p == a {
            entry.0 = true;
        }
        if p == b {
            entry.1 = true;
        }
    }
    per_inst.values().any(|&(hits_a, hits_b)| hits_a && hits_b)
}

// ===========================================================================
// R6 — no wire through a foreign pin or a foreign instance body
// ===========================================================================

struct InstBody {
    name: String,
    x_min: i32,
    x_max: i32,
    y_min: i32,
    y_max: i32,
    nets: HashSet<u32>,
}

/// Per-instance body bbox from transformed pin positions (plus origin).
/// Zero-extent dimensions are widened to one grid (±10) so two-terminal
/// devices (whose pins are collinear) still have a body interior.
fn instance_bodies(sub: &Subcircuit, backend: &SchemifyBackend) -> Vec<InstBody> {
    sub.instances
        .iter()
        .map(|inst| {
            let mut x_min = inst.x;
            let mut x_max = inst.x;
            let mut y_min = inst.y;
            let mut y_max = inst.y;
            for pi in 0..inst.pins.len() {
                let (px, py) = pin_position(backend, inst, pi);
                x_min = x_min.min(px);
                x_max = x_max.max(px);
                y_min = y_min.min(py);
                y_max = y_max.max(py);
            }
            if x_min == x_max {
                x_min -= 10;
                x_max += 10;
            }
            if y_min == y_max {
                y_min -= 10;
                y_max += 10;
            }
            let nets: HashSet<u32> = inst.pins.iter().filter_map(|p| p.net_idx.map(|n| n.0)).collect();
            InstBody {
                name: inst.name.clone(),
                x_min,
                x_max,
                y_min,
                y_max,
                nets,
            }
        })
        .collect()
}

/// True if an orthogonal segment a-b has a point strictly inside the open rect.
fn seg_enters_open_rect(a: Pt, b: Pt, body: &InstBody) -> bool {
    if a.1 == b.1 {
        // Horizontal at y = a.1
        let y = a.1;
        if y <= body.y_min || y >= body.y_max {
            return false;
        }
        let (lo, hi) = (a.0.min(b.0), a.0.max(b.0));
        lo < body.x_max && hi > body.x_min
    } else if a.0 == b.0 {
        // Vertical at x = a.0
        let x = a.0;
        if x <= body.x_min || x >= body.x_max {
            return false;
        }
        let (lo, hi) = (a.1.min(b.1), a.1.max(b.1));
        lo < body.y_max && hi > body.y_min
    } else {
        // Diagonal wires are already R4 violations; skip here.
        false
    }
}

fn rule_r6_wire_clearance(sub: &Subcircuit, backend: &SchemifyBackend, out: &mut Vec<String>) {
    let bodies = instance_bodies(sub, backend);

    // Pin position -> set of nets connected there (plus an example pin name).
    let mut pin_map: HashMap<Pt, (HashSet<u32>, String)> = HashMap::new();
    for inst in &sub.instances {
        for (pi, pin) in inst.pins.iter().enumerate() {
            let Some(net_id) = pin.net_idx else { continue };
            let pos = pin_position(backend, inst, pi);
            let entry = pin_map
                .entry(pos)
                .or_insert_with(|| (HashSet::new(), format!("{}.{pi}", inst.name)));
            entry.0.insert(net_id.0);
        }
    }

    for (wi, w) in sub.wires.iter().enumerate() {
        // Sanctioned same-instance source→bulk rail stubs are exempt.
        if is_power_stub_wire(sub, backend, w) {
            continue;
        }
        let a = (w.x1, w.y1);
        let b = (w.x2, w.y2);
        let net_name = sub
            .nets
            .get(w.net_idx.index())
            .map(|n| n.name.as_str())
            .unwrap_or("?");

        // Body check: foreign = instance not connected to this wire's net.
        for body in &bodies {
            if body.nets.contains(&w.net_idx.0) {
                continue;
            }
            if seg_enters_open_rect(a, b, body) {
                out.push(format!(
                    "R6: wire {wi} (net '{net_name}') ({}, {})-({}, {}) passes through body of foreign instance '{}' [({}, {})-({}, {})]",
                    a.0, a.1, b.0, b.1, body.name, body.x_min, body.y_min, body.x_max, body.y_max
                ));
            }
        }

        // Foreign-pin check: pin of a different net strictly inside the segment.
        for (&pos, (nets, example)) in &pin_map {
            if nets.contains(&w.net_idx.0) {
                continue;
            }
            if pos != a && pos != b && on_segment(pos, a, b) {
                out.push(format!(
                    "R6: wire {wi} (net '{net_name}') ({}, {})-({}, {}) passes through foreign pin {example} at ({}, {})",
                    a.0, a.1, b.0, b.1, pos.0, pos.1
                ));
            }
        }
    }
}

// ===========================================================================
// R8 — connectivity roundtrip via the schematic adapter
// ===========================================================================

type PinKey = (String, usize); // (instance name, pin index)
type Partition = BTreeSet<BTreeSet<PinKey>>;

fn rule_r8_connectivity_roundtrip(
    sub: &Subcircuit,
    backend: &SchemifyBackend,
    out: &mut Vec<String>,
) {
    // Original partition: each net -> set of (instance_name, pin_index).
    let mut original: Partition = BTreeSet::new();
    let mut pin_universe: BTreeSet<PinKey> = BTreeSet::new();
    for net in &sub.nets {
        let mut group: BTreeSet<PinKey> = BTreeSet::new();
        for pr in &net.pins {
            if let Some(inst) = sub.instances.get(pr.instance_idx.index()) {
                let key = (inst.name.clone(), pr.pin_idx.index());
                group.insert(key.clone());
                pin_universe.insert(key);
            }
        }
        if !group.is_empty() {
            original.insert(group);
        }
    }
    if original.is_empty() {
        return;
    }

    // Roundtrip through the core Schematic adapter. The reverse adapter does
    // not restore pin->net bindings (that is the connectivity engine's job),
    // so connectivity is recovered geometrically: wires + labels + exact pin
    // positions. This is exactly what makes R8 the real correctness test.
    //
    // The schematic form carries no per-instance pin lists for subcircuit (X)
    // instances — the app resolves those from project symbols. Supply the pin
    // counts observed on this scope's own X instances so the reverse adapter
    // reconstructs them (an X-instance pin list is exactly its definition's
    // port list).
    let mut subckt_pin_counts: HashMap<String, usize> = HashMap::new();
    for inst in &sub.instances {
        if inst.primitive == Primitive::Subcircuit {
            subckt_pin_counts.insert(inst.symbol.clone(), inst.pins.len());
        }
    }
    let mut rodeo = Rodeo::default();
    let sch = emit::schematic_from_subcircuit(sub, &mut rodeo);
    let rt = emit::subcircuit_from_schematic_with_symbols(&sch, &rodeo, &subckt_pin_counts);

    let groups = geometric_partition(&rt, backend);

    // Restrict roundtrip groups to pins present in the original universe
    // (the reverse adapter synthesizes default pin lists per device kind).
    let restrict = |groups: Vec<BTreeSet<PinKey>>| -> Partition {
        let mut part: Partition = BTreeSet::new();
        for g in groups {
            let restricted: BTreeSet<PinKey> =
                g.into_iter().filter(|k| pin_universe.contains(k)).collect();
            if !restricted.is_empty() {
                part.insert(restricted);
            }
        }
        part
    };
    let roundtrip = restrict(groups);

    if original == roundtrip {
        return;
    }

    // Attribution: if the geometric partition of the ORIGINAL laid-out
    // subcircuit equals the roundtripped one, the adapter is a faithful
    // geometry/label transport and the mismatch already exists in the routed
    // layout (router/placer collision) — report the witnessing cross-net
    // contact so the defect is actionable. Otherwise the adapter itself
    // altered connectivity. Both cases stay hard R8 violations.
    let orig_geo = restrict(geometric_partition(sub, backend));
    let cause = if orig_geo == roundtrip {
        "layout"
    } else {
        "adapter"
    };

    // (instance name, pin index) -> original net index.
    let mut pin_net: HashMap<PinKey, usize> = HashMap::new();
    for (ni, net) in sub.nets.iter().enumerate() {
        for pr in &net.pins {
            if let Some(inst) = sub.instances.get(pr.instance_idx.index()) {
                pin_net.insert((inst.name.clone(), pr.pin_idx.index()), ni);
            }
        }
    }

    let contacts = if cause == "layout" {
        cross_net_contacts(sub, backend)
    } else {
        Vec::new()
    };
    let witnesses = |nets: &BTreeSet<usize>, any_side: bool| -> String {
        let hits: Vec<&str> = contacts
            .iter()
            .filter(|(a, b, _)| {
                if any_side {
                    nets.contains(a) || nets.contains(b)
                } else {
                    nets.contains(a) && nets.contains(b)
                }
            })
            .map(|(_, _, d)| d.as_str())
            .take(3)
            .collect();
        if hits.is_empty() {
            String::new()
        } else {
            format!("; contact: {}", hits.join(" | "))
        }
    };

    let fmt_group = |g: &BTreeSet<PinKey>| -> String {
        let items: Vec<String> = g.iter().map(|(n, p)| format!("{n}.{p}")).collect();
        format!("{{{}}}", items.join(", "))
    };
    let group_nets = |g: &BTreeSet<PinKey>| -> BTreeSet<usize> {
        g.iter().filter_map(|k| pin_net.get(k).copied()).collect()
    };

    for missing in original.difference(&roundtrip) {
        let nets = group_nets(missing);
        out.push(format!(
            "R8: net grouping {} lost in roundtrip (pins not geometrically connected as one net) [cause: {cause}]{}",
            fmt_group(missing),
            witnesses(&nets, true),
        ));
    }
    for extra in roundtrip.difference(&original) {
        let nets = group_nets(extra);
        // A multi-net group is a short (witness = contact between its nets);
        // a single-net group is a split (no contact to show).
        out.push(format!(
            "R8: roundtrip produced spurious grouping {} (pins shorted or split vs source netlist) [cause: {cause}]{}",
            fmt_group(extra),
            witnesses(&nets, false),
        ));
    }
}

/// Find points where routing/pins/labels of two DIFFERENT nets touch in the
/// laid-out subcircuit. The core connectivity engine (`resolve_connectivity`)
/// joins wires sharing a point, wire endpoints on wire interiors, pins lying
/// anywhere on a wire, coincident pins, and labels by name — so each contact
/// listed here is a genuine electrical short in the emitted schematic.
/// Returns (net_a, net_b, description) with net_a < net_b, deduplicated.
fn cross_net_contacts(
    sub: &Subcircuit,
    backend: &SchemifyBackend,
) -> Vec<(usize, usize, String)> {
    let net_name = |ni: usize| sub.nets[ni].name.as_str();
    let mut seen: BTreeSet<(usize, usize, String)> = BTreeSet::new();
    let mut push = |a: usize, b: usize, desc: String| {
        let (a, b) = if a <= b { (a, b) } else { (b, a) };
        seen.insert((a, b, desc));
    };

    // All pins with positions and owning net.
    let mut pins: Vec<(String, usize, Pt, usize)> = Vec::new(); // (inst, pin, pos, net)
    for (ni, net) in sub.nets.iter().enumerate() {
        for pr in &net.pins {
            let Some(inst) = sub.instances.get(pr.instance_idx.index()) else {
                continue;
            };
            let pos = pin_position(backend, inst, pr.pin_idx.index());
            pins.push((inst.name.clone(), pr.pin_idx.index(), pos, ni));
        }
    }

    // Wire-wire: any shared point (equal endpoints or endpoint on interior).
    for (i, wa) in sub.wires.iter().enumerate() {
        for wb in sub.wires.iter().skip(i + 1) {
            if wa.net_idx == wb.net_idx {
                continue;
            }
            let (a1, b1) = ((wa.x1, wa.y1), (wa.x2, wa.y2));
            let (a2, b2) = ((wb.x1, wb.y1), (wb.x2, wb.y2));
            let touch = [a2, b2]
                .into_iter()
                .find(|&p| on_segment(p, a1, b1))
                .or_else(|| [a1, b1].into_iter().find(|&p| on_segment(p, a2, b2)));
            if let Some(p) = touch {
                push(
                    wa.net_idx.index(),
                    wb.net_idx.index(),
                    format!(
                        "wire '{}' ({},{})-({},{}) touches wire '{}' ({},{})-({},{}) at ({},{})",
                        net_name(wa.net_idx.index()),
                        a1.0, a1.1, b1.0, b1.1,
                        net_name(wb.net_idx.index()),
                        a2.0, a2.1, b2.0, b2.1,
                        p.0, p.1
                    ),
                );
            }
        }
    }

    // Pin on a foreign net's wire (anywhere on the segment).
    for (inst, pi, pos, ni) in &pins {
        for w in &sub.wires {
            if w.net_idx.index() == *ni {
                continue;
            }
            if on_segment(*pos, (w.x1, w.y1), (w.x2, w.y2)) {
                push(
                    *ni,
                    w.net_idx.index(),
                    format!(
                        "pin {inst}.{pi} (net '{}') at ({},{}) lies on wire '{}' ({},{})-({},{})",
                        net_name(*ni),
                        pos.0, pos.1,
                        net_name(w.net_idx.index()),
                        w.x1, w.y1, w.x2, w.y2
                    ),
                );
            }
        }
    }

    // Coincident pins of different nets.
    for (i, (ia, pa, pos_a, na)) in pins.iter().enumerate() {
        for (ib, pb, pos_b, nb) in pins.iter().skip(i + 1) {
            if na != nb && pos_a == pos_b {
                push(
                    *na,
                    *nb,
                    format!(
                        "pin {ia}.{pa} (net '{}') and pin {ib}.{pb} (net '{}') coincide at ({},{})",
                        net_name(*na),
                        net_name(*nb),
                        pos_a.0,
                        pos_a.1
                    ),
                );
            }
        }
    }

    // Label of one net sitting on a foreign net's wire or pin.
    for l in &sub.labels {
        let ln = l.net_idx.index();
        let lp = (l.x, l.y);
        for w in &sub.wires {
            if w.net_idx.index() != ln && on_segment(lp, (w.x1, w.y1), (w.x2, w.y2)) {
                push(
                    ln,
                    w.net_idx.index(),
                    format!(
                        "label '{}' at ({},{}) lies on wire '{}' ({},{})-({},{})",
                        net_name(ln),
                        lp.0, lp.1,
                        net_name(w.net_idx.index()),
                        w.x1, w.y1, w.x2, w.y2
                    ),
                );
            }
        }
        for (inst, pi, pos, ni) in &pins {
            if *ni != ln && *pos == lp {
                push(
                    ln,
                    *ni,
                    format!(
                        "label '{}' at ({},{}) sits on pin {inst}.{pi} (net '{}')",
                        net_name(ln),
                        lp.0,
                        lp.1,
                        net_name(*ni)
                    ),
                );
            }
        }
    }

    seen.into_iter().collect()
}

/// Tiny union-find.
struct Dsu {
    parent: Vec<usize>,
}

impl Dsu {
    fn new(n: usize) -> Self {
        Self {
            parent: (0..n).collect(),
        }
    }
    fn find(&mut self, x: usize) -> usize {
        if self.parent[x] != x {
            let root = self.find(self.parent[x]);
            self.parent[x] = root;
        }
        self.parent[x]
    }
    fn union(&mut self, a: usize, b: usize) {
        let (ra, rb) = (self.find(a), self.find(b));
        if ra != rb {
            self.parent[ra] = rb;
        }
    }
}

/// Recover net groupings of instance pins purely from geometry:
/// wires touching wires (shared endpoint or T-junction), pins on wires,
/// labels on pins/wires, labels unified by name, stacked pins.
fn geometric_partition(sub: &Subcircuit, backend: &SchemifyBackend) -> Vec<BTreeSet<PinKey>> {
    // Node layout: [pins..][wires..][label names..]
    let mut pins: Vec<(PinKey, Pt)> = Vec::new();
    for inst in &sub.instances {
        for pi in 0..inst.pins.len() {
            pins.push((
                (inst.name.clone(), pi),
                pin_position(backend, inst, pi),
            ));
        }
    }
    let n_pins = pins.len();
    let n_wires = sub.wires.len();

    let mut label_name_node: HashMap<String, usize> = HashMap::new();
    let mut labels: Vec<(usize, Pt)> = Vec::new(); // (name node, position)
    let mut next = n_pins + n_wires;
    for l in &sub.labels {
        let Some(net) = sub.nets.get(l.net_idx.index()) else {
            continue;
        };
        let node = *label_name_node.entry(net.name.clone()).or_insert_with(|| {
            let n = next;
            next += 1;
            n
        });
        labels.push((node, (l.x, l.y)));
    }

    let mut dsu = Dsu::new(next);
    let wire_seg = |i: usize| -> (Pt, Pt) {
        let w = &sub.wires[i];
        ((w.x1, w.y1), (w.x2, w.y2))
    };

    // Wire-wire: shared endpoint or endpoint of one on the other.
    for i in 0..n_wires {
        let (a1, b1) = wire_seg(i);
        for j in (i + 1)..n_wires {
            let (a2, b2) = wire_seg(j);
            if on_segment(a2, a1, b1)
                || on_segment(b2, a1, b1)
                || on_segment(a1, a2, b2)
                || on_segment(b1, a2, b2)
            {
                dsu.union(n_pins + i, n_pins + j);
            }
        }
    }

    // Pin-wire and pin-pin.
    for (pi, (_, pos)) in pins.iter().enumerate() {
        for wi in 0..n_wires {
            let (a, b) = wire_seg(wi);
            if on_segment(*pos, a, b) {
                dsu.union(pi, n_pins + wi);
            }
        }
        for (pj, (_, pos2)) in pins.iter().enumerate().skip(pi + 1) {
            if pos == pos2 {
                dsu.union(pi, pj);
            }
        }
    }

    // Labels: join their name node to whatever sits at the label position.
    for (node, pos) in &labels {
        for (pi, (_, ppos)) in pins.iter().enumerate() {
            if ppos == pos {
                dsu.union(*node, pi);
            }
        }
        for wi in 0..n_wires {
            let (a, b) = wire_seg(wi);
            if on_segment(*pos, a, b) {
                dsu.union(*node, n_pins + wi);
            }
        }
    }

    // Collect pin groups by DSU root.
    let mut groups: HashMap<usize, BTreeSet<PinKey>> = HashMap::new();
    for (pi, (key, _)) in pins.iter().enumerate() {
        groups.entry(dsu.find(pi)).or_default().insert(key.clone());
    }
    groups.into_values().collect()
}

// ===========================================================================
// Q1 — signal flow: inputs left of outputs
// ===========================================================================

fn rule_q1_signal_flow(sub: &Subcircuit, backend: &SchemifyBackend, out: &mut Vec<String>) {
    if sub.ports.is_empty() {
        return;
    }

    let xs_for_port = |port: &str| -> Vec<i32> {
        let Some((ni, net)) = sub
            .nets
            .iter()
            .enumerate()
            .find(|(_, n)| n.name == port)
        else {
            return Vec::new();
        };
        let mut xs: Vec<i32> = net
            .pins
            .iter()
            .filter_map(|pr| {
                sub.instances
                    .get(pr.instance_idx.index())
                    .map(|inst| pin_position(backend, inst, pr.pin_idx.index()).0)
            })
            .collect();
        if xs.is_empty() {
            // Fall back to label positions for pinless port nets.
            xs = sub
                .labels
                .iter()
                .filter(|l| l.net_idx.index() == ni)
                .map(|l| l.x)
                .collect();
        }
        xs
    };

    let mut input_xs = Vec::new();
    let mut output_xs = Vec::new();
    for (i, port) in sub.ports.iter().enumerate() {
        match sub.port_directions.get(i) {
            Some(PinDir::Input) => input_xs.extend(xs_for_port(port)),
            Some(PinDir::Output) => output_xs.extend(xs_for_port(port)),
            _ => {}
        }
    }

    if input_xs.is_empty() || output_xs.is_empty() {
        return; // Rule applies only with both Input and Output ports placed.
    }

    let mean_in = mean(&input_xs);
    let mean_out = mean(&output_xs);
    if mean_in >= mean_out {
        out.push(format!(
            "Q1: signal flow not left-to-right — mean input-port x {mean_in:.1} >= mean output-port x {mean_out:.1}"
        ));
    }
}

// ===========================================================================
// Q2 — power rails above ground (power placed in earlier/upper layers,
//      y grows downward through layers per place.rs power DAG)
// ===========================================================================

fn rule_q2_power_orientation(sub: &Subcircuit, backend: &SchemifyBackend, out: &mut Vec<String>) {
    let pin_ys = |class: NetClass| -> Vec<i32> {
        sub.nets
            .iter()
            .filter(|n| n.classification == class)
            .flat_map(|n| n.pins.iter())
            .filter_map(|pr| {
                sub.instances
                    .get(pr.instance_idx.index())
                    .map(|inst| pin_position(backend, inst, pr.pin_idx.index()).1)
            })
            .collect()
    };

    let power_ys = pin_ys(NetClass::Power);
    let ground_ys = pin_ys(NetClass::Ground);
    if power_ys.is_empty() || ground_ys.is_empty() {
        return;
    }

    let mean_power = mean(&power_ys);
    let mean_ground = mean(&ground_ys);
    // place.rs: power-flow DAG layers VDD top (layer 0, smallest y) -> GND
    // bottom (largest y). Power must be strictly on the smaller-y side.
    if mean_power >= mean_ground {
        out.push(format!(
            "Q2: power rail not above ground — mean power pin y {mean_power:.1} >= mean ground pin y {mean_ground:.1}"
        ));
    }
}

// ===========================================================================
// Q4 — wire crossing count under threshold
// ===========================================================================

fn rule_q4_wire_crossings(sub: &Subcircuit, out: &mut Vec<String>) {
    let mut crossings = 0usize;
    for (i, wa) in sub.wires.iter().enumerate() {
        for wb in sub.wires.iter().skip(i + 1) {
            if wa.net_idx == wb.net_idx {
                continue;
            }
            // Proper crossing: one horizontal, one vertical, intersection
            // strictly interior to BOTH (excludes shared endpoints and Ts).
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
                crossings += 1;
            }
        }
    }

    let threshold = 10usize.max(sub.wires.len() / 4);
    if crossings > threshold {
        out.push(format!(
            "Q4: {crossings} wire crossings between different nets exceeds threshold {threshold} ({} wires total)",
            sub.wires.len()
        ));
    }
}

// ===========================================================================
// Q5 — routed output matches classify_nets strategy
// ===========================================================================

fn rule_q5_wire_vs_label(sub: &Subcircuit, backend: &SchemifyBackend, out: &mut Vec<String>) {
    let strategies = classify_nets(sub, backend);

    for (ni, strategy) in strategies.iter().enumerate() {
        let net = &sub.nets[ni];
        if net.pins.is_empty() {
            continue;
        }
        let has_wire = sub.wires.iter().any(|w| w.net_idx.index() == ni);
        let has_label = sub.labels.iter().any(|l| l.net_idx.index() == ni);

        match strategy {
            NetStrategy::Wire => {
                if net.pins.len() >= 2 && !has_wire {
                    out.push(format!(
                        "Q5: net '{}' ({} pins) classified Wire but routed with no wire segments (labels present: {has_label})",
                        net.name,
                        net.pins.len()
                    ));
                }
            }
            NetStrategy::Label => {
                if !has_label {
                    out.push(format!(
                        "Q5: net '{}' ({} pins) classified Label but has no labels",
                        net.name,
                        net.pins.len()
                    ));
                }
                // Same-instance source→bulk rail stubs are sanctioned wires
                // on Label-strategy power/ground nets.
                let has_nonstub_wire = sub
                    .wires
                    .iter()
                    .any(|w| w.net_idx.index() == ni && !is_power_stub_wire(sub, backend, w));
                if has_nonstub_wire {
                    out.push(format!(
                        "Q5: net '{}' ({} pins) classified Label but was routed with wires",
                        net.name,
                        net.pins.len()
                    ));
                }
            }
        }
    }
}
