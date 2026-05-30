//! Hierarchical subcircuit import tests.
//!
//! Verifies that `import_spice_hierarchical` produces parent + child schematics
//! and that the full roundtrip (SPICE → Schematics → CircuitIR → SPICE) preserves
//! subcircuit structure and component connectivity.

use lasso::Rodeo;

use schemify_core::types::DeviceKind;
use schemify_handler::spice_import::{import_spice_hierarchical, ImportResult};
use schemify_sim::codegen::emit_netlist;

// ---------------------------------------------------------------------------
// Fixtures: real SPICE netlists with subcircuits
// ---------------------------------------------------------------------------

const INVERTER_WITH_TB: &str = "\
* Inverter testbench
.subckt inv in out vdd vss
Mp1 out in vdd vdd pmos W=2u L=180n
Mn1 out in vss vss nmos W=1u L=180n
.ends inv

Xinv1 input output vdd gnd inv
Vdd vdd gnd 1.8
Vin input gnd 0.9
.end
";

const BUFFER_NESTED: &str = "\
* Buffer = two inverters
.subckt inv in out vdd vss
Mp1 out in vdd vdd pmos W=2u L=180n
Mn1 out in vss vss nmos W=1u L=180n
.ends inv

.subckt buf in out vdd vss
Xinv1 in mid vdd vss inv
Xinv2 mid out vdd vss inv
.ends buf

Xbuf1 input output vdd gnd buf
Vdd vdd gnd 1.8
Vin input gnd 0.9
.end
";

const TRIPLE_NESTED: &str = "\
* Three levels deep
.subckt inv in out vdd vss
Mp1 out in vdd vdd pmos W=2u L=180n
Mn1 out in vss vss nmos W=1u L=180n
.ends inv

.subckt buf in out vdd vss
Xinv1 in mid vdd vss inv
Xinv2 mid out vdd vss inv
.ends buf

.subckt driver in out vdd vss
Xbuf1 in out vdd vss buf
.ends driver

Xdrv1 input output vdd gnd driver
Vdd vdd gnd 1.8
Vin input gnd 0.9
.end
";

// ---------------------------------------------------------------------------
// Test: single subckt → 2 schematics (parent + 1 child)
// ---------------------------------------------------------------------------

#[test]
fn single_subckt_produces_two_schematics() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(INVERTER_WITH_TB, &mut int).unwrap();

    assert_eq!(result.children.len(), 1, "expected 1 child schematic");
    assert_eq!(result.children[0].name, "inv");
}

#[test]
fn parent_x_instance_references_child_symbol() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(INVERTER_WITH_TB, &mut int).unwrap();

    let has_subckt_inst = (0..result.top.instances.len()).any(|i| {
        result.top.instances.kind[i] == DeviceKind::Subckt
            && int.resolve(&result.top.instances.symbol[i]) == "inv"
    });
    assert!(
        has_subckt_inst,
        "parent should have X-instance referencing 'inv'"
    );
}

#[test]
fn child_schematic_has_devices() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(INVERTER_WITH_TB, &mut int).unwrap();

    let child = &result.children[0];
    let nmos_count = (0..child.instances.len())
        .filter(|&i| child.instances.kind[i] == DeviceKind::Nmos4)
        .count();
    let pmos_count = (0..child.instances.len())
        .filter(|&i| child.instances.kind[i] == DeviceKind::Pmos4)
        .count();
    assert_eq!(nmos_count, 1, "child inv should have 1 NMOS");
    assert_eq!(pmos_count, 1, "child inv should have 1 PMOS");
}

// ---------------------------------------------------------------------------
// Test: nested subckts → N+1 schematics
// ---------------------------------------------------------------------------

#[test]
fn two_subckts_produce_three_schematics() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(BUFFER_NESTED, &mut int).unwrap();

    assert_eq!(
        result.children.len(),
        2,
        "expected 2 child schematics (inv + buf)"
    );

    let names: Vec<&str> = result.children.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"inv"), "missing child 'inv'");
    assert!(names.contains(&"buf"), "missing child 'buf'");
}

#[test]
fn triple_nested_produces_four_schematics() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(TRIPLE_NESTED, &mut int).unwrap();

    assert_eq!(
        result.children.len(),
        3,
        "expected 3 children (inv + buf + driver)"
    );
}

// ---------------------------------------------------------------------------
// Test: port-net continuity across subckt boundary
// ---------------------------------------------------------------------------

#[test]
fn port_net_continuity() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(INVERTER_WITH_TB, &mut int).unwrap();

    // The X-instance in the parent connects nets to child ports.
    // Find the Subckt instance and check its pin connections map to child port names.
    let child = &result.children[0];

    // Child should have port labels (LabPin instances) named "in", "out", "vdd", "vss"
    let label_names: Vec<String> = (0..child.instances.len())
        .filter(|&i| child.instances.kind[i].is_label())
        .map(|i| int.resolve(&child.instances.name[i]).to_owned())
        .collect();

    assert!(
        label_names.contains(&"in".to_string()),
        "child missing port label 'in'"
    );
    assert!(
        label_names.contains(&"out".to_string()),
        "child missing port label 'out'"
    );
}

// ---------------------------------------------------------------------------
// ROUNDTRIP: SPICE → import → to_circuit_ir → emit_netlist → compare
// ---------------------------------------------------------------------------

#[test]
fn roundtrip_single_subckt() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(INVERTER_WITH_TB, &mut int).unwrap();
    let ir = to_circuit_ir_hierarchical(&result, &int);
    let output = emit_netlist(&ir, "roundtrip");

    // Output must contain .subckt definition
    assert!(
        output.contains(".subckt inv"),
        "output missing .subckt inv:\n{output}"
    );
    assert!(
        output.contains(".ends inv"),
        "output missing .ends inv:\n{output}"
    );

    // Output must contain the PMOS and NMOS inside the subckt
    assert!(
        output.contains("Mp1 out in vdd vdd pmos"),
        "missing pmos in subckt:\n{output}"
    );
    assert!(
        output.contains("Mn1 out in vss vss nmos"),
        "missing nmos in subckt:\n{output}"
    );

    // Output must contain the X-instance in top level
    let has_x_inv = output.lines().any(|l| {
        let lower = l.to_lowercase();
        lower.starts_with("x") && lower.contains("inv")
    });
    assert!(has_x_inv, "output missing X-instance of inv:\n{output}");
}

#[test]
fn roundtrip_nested_subckts() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(BUFFER_NESTED, &mut int).unwrap();
    let ir = to_circuit_ir_hierarchical(&result, &int);
    let output = emit_netlist(&ir, "roundtrip");

    assert!(
        output.contains(".subckt inv"),
        "output missing .subckt inv:\n{output}"
    );
    assert!(
        output.contains(".subckt buf"),
        "output missing .subckt buf:\n{output}"
    );
    assert!(
        output.contains(".ends inv"),
        "output missing .ends inv:\n{output}"
    );
    assert!(
        output.contains(".ends buf"),
        "output missing .ends buf:\n{output}"
    );

    // buf should instantiate inv
    let in_buf_section = extract_subckt_body(&output, "buf");
    assert!(
        in_buf_section
            .iter()
            .any(|l| l.to_lowercase().contains("inv")),
        "buf should instantiate inv:\n{output}"
    );
}

#[test]
fn roundtrip_preserves_all_components() {
    let mut int = Rodeo::default();
    let result = import_spice_hierarchical(INVERTER_WITH_TB, &mut int).unwrap();
    let ir = to_circuit_ir_hierarchical(&result, &int);
    let output = emit_netlist(&ir, "roundtrip");

    // Voltage sources in top should survive
    let has_vdd = output.lines().any(|l| {
        let lower = l.trim().to_lowercase();
        lower.starts_with("v") && lower.contains("vdd")
    });
    assert!(has_vdd, "missing Vdd source in output:\n{output}");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a CircuitIR from an ImportResult (top + children).
/// This is the function that needs to exist in schemify-handler.
fn to_circuit_ir_hierarchical(
    result: &ImportResult,
    interner: &Rodeo,
) -> schemify_sim::ir::CircuitIR {
    use schemify_handler::netlist::to_circuit_ir;

    let mut ir = to_circuit_ir(&result.top, interner);

    for child in &result.children {
        let child_ir = to_circuit_ir(child, interner);
        // The child's "top" becomes a subcircuit_def
        let mut sub_def = child_ir.top;
        // Set ports from the child schematic's label instances
        if sub_def.ports.is_empty() {
            let ports: Vec<schemify_sim::ir::Port> = (0..child.instances.len())
                .filter(|&i| child.instances.kind[i].is_label())
                .map(|i| schemify_sim::ir::Port {
                    name: interner.resolve(&child.instances.name[i]).to_owned(),
                    direction: schemify_sim::ir::PortDirection::InOut,
                })
                .collect();
            sub_def.ports = ports;
        }
        sub_def.name = child.name.clone();
        ir.subcircuit_defs.push(sub_def);
    }

    ir
}

/// Extract lines between `.subckt name ...` and `.ends name`.
fn extract_subckt_body(spice: &str, name: &str) -> Vec<String> {
    let mut inside = false;
    let mut lines = Vec::new();
    for line in spice.lines() {
        let lower = line.trim().to_lowercase();
        if lower.starts_with(".subckt") && lower.contains(name) {
            inside = true;
            continue;
        }
        if inside && lower.starts_with(".ends") {
            break;
        }
        if inside {
            lines.push(line.to_string());
        }
    }
    lines
}
