//! SPICE netlist → schematic pipeline (s2s).
//!
//! Parse, placement, AND routing run in the `cktimg` library: Schemify's pin
//! geometry is installed into cktimg (anchor overrides + 10-grid config), and
//! cktimg's router upholds the host-geometry contract (no wire through a
//! foreign pin, no geometric shorts), so its output converts 1:1 (`cktimg`).
//! `emit` holds the schematic adapter, pin geometry, and validation; the
//! hypergraph IR lives in `ir`.

pub mod cktimg;
pub mod emit;
pub mod ir;

pub use crate::cktimg::HostSymbol;

use crate::ir::Circuit;

/// Parse a SPICE netlist and produce a laid-out circuit.
///
/// cktimg flattens `.subckt`s into a single top-level schematic; lines cktimg
/// could not represent land in `Circuit::diagnostics`. Host symbols with
/// runtime pin lists (testbench DUTs) go through
/// [`cktimg::netlist_to_circuit_with`].
///
/// The returned `Circuit` has placement coordinates, wires, and labels filled
/// in; pass it to `emit` for schematic conversion.
pub fn netlist_to_circuit(source: &str) -> anyhow::Result<Circuit> {
    cktimg::netlist_to_circuit(source)
}

/// A netlist that is exactly one `.subckt` definition (plus comments and
/// directives) is a *cell*: unwrap the body for import and declare every
/// port via PININFO so it comes out as a directional pin symbol. Ports not
/// covered by an existing `*.PININFO` line inside the body default to `B`
/// (inout). Returns `(inlined source, subckt name)`; None when the netlist
/// has top-level cards or is not a single subckt.
pub fn unwrap_lone_subckt(source: &str) -> Option<(String, String)> {
    let mut name = String::new();
    let mut ports: Vec<String> = Vec::new();
    let mut body: Vec<&str> = Vec::new();
    let mut subckts = 0usize;
    let mut inside = false;
    let mut header_open = false; // last line was the .subckt header (for `+`)

    for line in source.lines() {
        let t = line.trim();
        let lower = t.to_ascii_lowercase();
        if lower.starts_with(".subckt") {
            subckts += 1;
            if subckts > 1 {
                return None;
            }
            let mut toks = t.split_whitespace().skip(1);
            name = toks.next()?.to_string();
            ports.extend(
                toks.take_while(|s| !s.contains('='))
                    .map(|s| s.to_ascii_lowercase()),
            );
            inside = true;
            header_open = true;
            continue;
        }
        if lower.starts_with(".ends") {
            inside = false;
            header_open = false;
            continue;
        }
        if inside {
            // `+` continuation right after the header extends the port list.
            if header_open && t.starts_with('+') {
                ports.extend(
                    t[1..]
                        .split_whitespace()
                        .take_while(|s| !s.contains('='))
                        .map(|s| s.to_ascii_lowercase()),
                );
                continue;
            }
            header_open = false;
            body.push(line);
            continue;
        }
        // Outside any subckt: comments/blank/directives are fine, a device
        // card means this is a full circuit, not a lone cell.
        if !t.is_empty() && !t.starts_with('*') && !t.starts_with('.') && !t.starts_with('+') {
            return None;
        }
    }
    if subckts != 1 || ports.is_empty() {
        return None;
    }

    // Ports the body's own PININFO already covers keep their direction.
    let declared = emit::parse_pininfo(source);
    let missing: Vec<String> = ports
        .iter()
        .filter(|p| !declared.contains_key(*p))
        .map(|p| format!("{p}:B"))
        .collect();
    let mut out = format!("* cell {name}\n");
    if !missing.is_empty() {
        out.push_str(&format!("*.PININFO {}\n", missing.join(" ")));
    }
    out.push_str(&body.join("\n"));
    out.push('\n');
    Some((out, name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::PinDir;

    #[test]
    fn lone_subckt_unwraps_with_port_pininfo() {
        let src = ".subckt rc_filter in out\n*.PININFO in:I out:O\nR1 in out 1k\nC1 out 0 159n\n.ends\n";
        let (inlined, name) = unwrap_lone_subckt(src).expect("unwraps");
        assert_eq!(name, "rc_filter");
        assert!(inlined.contains("R1 in out 1k"));
        assert!(!inlined.to_lowercase().contains(".subckt"));
        // Body PININFO covers both ports; no synthesized line needed.
        assert!(!inlined.contains(":B"));

        // Without PININFO, ports default to inout.
        let src = ".subckt div a b mid\nR1 a mid 1k\nR2 mid b 1k\n.ends";
        let (inlined, _) = unwrap_lone_subckt(src).expect("unwraps");
        let ports = emit::parse_pininfo(&inlined);
        assert_eq!(ports.get("a"), Some(&PinDir::Inout));
        assert_eq!(ports.get("mid"), Some(&PinDir::Inout));

        // Continuation header ports.
        let src = ".subckt big a b\n+ c d\nR1 a b 1k\n.ends";
        let (inlined, _) = unwrap_lone_subckt(src).expect("unwraps");
        assert!(inlined.contains("c:B") && inlined.contains("d:B"));

        // Full circuits and multi-subckt netlists pass through untouched.
        assert!(unwrap_lone_subckt("R1 in out 1k\nC1 out 0 1n").is_none());
        assert!(unwrap_lone_subckt(
            ".subckt a x y\nR1 x y 1\n.ends\n.subckt b p q\nR1 p q 1\n.ends"
        )
        .is_none());
        assert!(unwrap_lone_subckt(".subckt a x y\nR1 x y 1\n.ends\nX1 n1 n2 a").is_none());
    }
}
