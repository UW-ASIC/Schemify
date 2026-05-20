//! Spectre netlist parser.
//!
//! Spectre is Cadence's proprietary circuit simulator format.
//! Differs from SPICE/CDL in key ways:
//! - `subckt name (ports)` ... `ends name`
//! - Instance: `name (nodes) model [params]`
//! - Parameters use `key=value` (no SPICE prefix letters on instances)
//! - Line continuation with `\` at end of line
//!
//! We reuse `CdlCircuit` / `CdlInstance` as the intermediate representation,
//! inferring the SPICE prefix from the model/component name.

use crate::cdl::{CdlCircuit, CdlInstance};

/// Parse a Spectre netlist string into a `CdlCircuit`.
///
/// # Errors
///
/// Returns an error string for malformed lines or mismatched
/// `subckt` / `ends` blocks.
pub fn parse_spectre(input: &str) -> Result<CdlCircuit, String> {
    let lines = join_spectre_continuations(input);
    let mut top = CdlCircuit {
        name: String::from("top"),
        ..Default::default()
    };
    let mut stack: Vec<CdlCircuit> = Vec::new();

    for (line_no, line) in lines.iter().enumerate() {
        let trimmed = line.trim();

        // Skip empty lines, comments
        if trimmed.is_empty()
            || trimmed.starts_with("//")
            || trimmed.starts_with('*')
            || trimmed.starts_with("simulator")
        {
            continue;
        }

        // Skip include/library directives
        if trimmed.starts_with("include")
            || trimmed.starts_with("library")
            || trimmed.starts_with("section")
            || trimmed.starts_with("endsection")
            || trimmed.starts_with("endlibrary")
            || trimmed.starts_with("parameters")
            || trimmed.starts_with("global")
        {
            continue;
        }

        let first_word = trimmed.split_whitespace().next().unwrap_or("");

        if first_word == "subckt" {
            let subckt = parse_spectre_subckt_header(trimmed, line_no)?;
            stack.push(subckt);
        } else if first_word == "ends" {
            let finished = stack.pop().ok_or_else(|| {
                format!(
                    "line {}: 'ends' without matching 'subckt'",
                    line_no + 1
                )
            })?;
            if stack.is_empty() {
                top.subcircuits.push(finished);
            } else {
                stack.last_mut().unwrap().subcircuits.push(finished);
            }
        } else if first_word == "inline" {
            // `inline subckt ...` -- treat same as subckt
            let rest = trimmed.strip_prefix("inline").unwrap_or(trimmed).trim();
            if rest.starts_with("subckt") {
                let subckt = parse_spectre_subckt_header(rest, line_no)?;
                stack.push(subckt);
            }
        } else if first_word == "model" || first_word == "real" || first_word == "ahdl_include" {
            // Skip model definitions and ahdl includes
            continue;
        } else {
            // Instance line
            if let Some(inst) = parse_spectre_instance(trimmed, line_no)? {
                if let Some(current) = stack.last_mut() {
                    current.instances.push(inst);
                } else {
                    top.instances.push(inst);
                }
            }
        }
    }

    if !stack.is_empty() {
        return Err(format!(
            "unclosed subckt: {}",
            stack.last().unwrap().name
        ));
    }

    Ok(top)
}

/// Join Spectre continuation lines (lines ending with `\`).
fn join_spectre_continuations(input: &str) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    let mut continuing = false;

    for raw_line in input.lines() {
        let trimmed = raw_line.trim_end();
        if trimmed.ends_with('\\') {
            // Continuation -- strip the backslash and accumulate
            let content = trimmed[..trimmed.len() - 1].trim();
            if continuing {
                if let Some(prev) = result.last_mut() {
                    prev.push(' ');
                    prev.push_str(content);
                }
            } else {
                result.push(content.to_string());
            }
            continuing = true;
        } else if continuing {
            // End of continuation -- append to previous
            if let Some(prev) = result.last_mut() {
                prev.push(' ');
                prev.push_str(raw_line.trim());
            }
            continuing = false;
        } else {
            result.push(raw_line.to_string());
            continuing = false;
        }
    }

    result
}

/// Parse `subckt name (port1 port2 ...)` or `subckt name port1 port2 ...`
fn parse_spectre_subckt_header(line: &str, line_no: usize) -> Result<CdlCircuit, String> {
    // Remove "subckt" keyword
    let rest = line
        .strip_prefix("subckt")
        .unwrap_or(line)
        .trim();

    let tokens: Vec<&str> = rest.split_whitespace().collect();
    if tokens.is_empty() {
        return Err(format!(
            "line {}: subckt missing name",
            line_no + 1
        ));
    }

    let name = tokens[0].to_string();

    // Extract ports -- may be in parentheses or bare
    let ports = if let (Some(open), Some(close)) = (rest.find('('), rest.find(')')) {
        let port_str = &rest[open + 1..close];
        port_str
            .split_whitespace()
            .map(|s| s.to_string())
            .collect()
    } else {
        // Bare ports after name, stop at '=' params
        tokens[1..]
            .iter()
            .take_while(|t| !t.contains('='))
            .map(|s| s.to_string())
            .collect()
    };

    Ok(CdlCircuit {
        name,
        ports,
        instances: Vec::new(),
        subcircuits: Vec::new(),
    })
}

/// Parse a Spectre instance line.
///
/// Format: `name (node1 node2 ...) model_or_component [key=val ...]`
/// Or:     `name node1 node2 ... model_or_component [key=val ...]`
///
/// Returns `None` for lines that don't look like valid instances.
fn parse_spectre_instance(
    line: &str,
    line_no: usize,
) -> Result<Option<CdlInstance>, String> {
    let trimmed = line.trim();

    // Must start with an identifier
    let first_char = trimmed.chars().next().unwrap_or(' ');
    if !first_char.is_ascii_alphanumeric() && first_char != '_' {
        return Ok(None);
    }

    if let (Some(open), Some(close)) = (trimmed.find('('), trimmed.find(')')) {
        // Parenthesized node list
        parse_spectre_paren_instance(trimmed, open, close, line_no).map(Some)
    } else {
        // Non-parenthesized -- `name node1 ... model [params]`
        parse_spectre_bare_instance(trimmed, line_no).map(Some)
    }
}

/// Parse `name (nodes) model [params]`
fn parse_spectre_paren_instance(
    line: &str,
    open: usize,
    close: usize,
    _line_no: usize,
) -> Result<CdlInstance, String> {
    let name = line[..open].trim().to_string();
    let node_str = &line[open + 1..close];
    let nodes: Vec<String> = node_str
        .split_whitespace()
        .map(|s| s.to_string())
        .collect();

    let after_paren = line[close + 1..].trim();
    let tokens: Vec<&str> = after_paren.split_whitespace().collect();

    let model_or_subckt = tokens.first().map(|s| s.to_string()).unwrap_or_default();

    let mut params = Vec::new();
    for &tok in tokens.iter().skip(1) {
        if let Some((k, v)) = tok.split_once('=') {
            params.push((k.to_string(), v.to_string()));
        }
    }

    let prefix = infer_spectre_prefix(&name, &model_or_subckt);

    Ok(CdlInstance {
        name,
        nodes,
        model_or_subckt,
        params,
        prefix,
    })
}

/// Parse bare (non-parenthesized) instance line.
fn parse_spectre_bare_instance(
    line: &str,
    line_no: usize,
) -> Result<CdlInstance, String> {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.len() < 2 {
        return Err(format!(
            "line {}: instance line too short",
            line_no + 1
        ));
    }

    let name = tokens[0].to_string();

    // Find the model: last non-param token
    let mut model_idx = tokens.len() - 1;
    while model_idx > 1 && tokens[model_idx].contains('=') {
        model_idx -= 1;
    }

    let model_or_subckt = tokens[model_idx].to_string();
    let nodes: Vec<String> = tokens[1..model_idx]
        .iter()
        .map(|s| s.to_string())
        .collect();

    let mut params = Vec::new();
    for &tok in &tokens[model_idx + 1..] {
        if let Some((k, v)) = tok.split_once('=') {
            params.push((k.to_string(), v.to_string()));
        }
    }

    let prefix = infer_spectre_prefix(&name, &model_or_subckt);

    Ok(CdlInstance {
        name,
        nodes,
        model_or_subckt,
        params,
        prefix,
    })
}

/// Infer a SPICE-like prefix from the Spectre model name or instance name.
pub fn infer_spectre_prefix(name: &str, model: &str) -> char {
    let model_lower = model.to_ascii_lowercase();

    // Check model name first
    if model_lower == "resistor" || model_lower.starts_with("res") {
        return 'R';
    }
    if model_lower == "capacitor" || model_lower.starts_with("cap") {
        return 'C';
    }
    if model_lower == "inductor" || model_lower.starts_with("ind") {
        return 'L';
    }
    if model_lower.contains("nmos") || model_lower.contains("nfet") || model_lower == "nch" {
        return 'M';
    }
    if model_lower.contains("pmos") || model_lower.contains("pfet") || model_lower == "pch" {
        return 'M';
    }
    if model_lower.contains("npn") || model_lower.contains("pnp") {
        return 'Q';
    }
    if model_lower == "diode" || model_lower.starts_with("dio") {
        return 'D';
    }
    if model_lower == "vsource"
        || model_lower == "vdc"
        || model_lower == "vsin"
        || model_lower == "vpulse"
    {
        return 'V';
    }
    if model_lower == "isource"
        || model_lower == "idc"
        || model_lower == "isin"
        || model_lower == "ipulse"
    {
        return 'I';
    }
    if model_lower.starts_with("njfet")
        || model_lower.starts_with("pjfet")
        || model_lower == "jfet"
    {
        return 'J';
    }
    if model_lower == "tline" || model_lower == "transmission_line" {
        return 'T';
    }
    if model_lower == "vcvs"
        || model_lower == "vccs"
        || model_lower == "ccvs"
        || model_lower == "cccs"
    {
        return match model_lower.as_str() {
            "vcvs" => 'E',
            "vccs" => 'G',
            "ccvs" => 'H',
            "cccs" => 'F',
            _ => 'E',
        };
    }

    // Fall back to instance name prefix (some Spectre netlists use SPICE-like naming)
    let first = name.chars().next().unwrap_or('X').to_ascii_uppercase();
    if "RCLDMQJVIEGHFTXZSKO".contains(first) {
        return first;
    }

    'X' // Default to subcircuit
}

// -- Tests --------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_spectre_subcircuit() {
        let input = r#"
subckt opamp (INP INN OUT VDD VSS)
m1 (net1 INP net3 VSS) nmos w=1u l=180n
m2 (net1 INN net4 VSS) nmos w=1u l=180n
r1 (VDD net1) resistor r=10k
ends opamp
"#;
        let circuit = parse_spectre(input).unwrap();
        assert_eq!(circuit.subcircuits.len(), 1);
        let sub = &circuit.subcircuits[0];
        assert_eq!(sub.name, "opamp");
        assert_eq!(sub.ports, vec!["INP", "INN", "OUT", "VDD", "VSS"]);
        assert_eq!(sub.instances.len(), 3);
    }

    #[test]
    fn parse_spectre_paren_nodes() {
        let input = r#"
subckt test (A B)
m1 (drain gate source bulk) nmos w=1u l=180n
ends test
"#;
        let circuit = parse_spectre(input).unwrap();
        let m = &circuit.subcircuits[0].instances[0];
        assert_eq!(m.name, "m1");
        assert_eq!(m.nodes, vec!["drain", "gate", "source", "bulk"]);
        assert_eq!(m.model_or_subckt, "nmos");
        assert_eq!(m.prefix, 'M');
        assert_eq!(m.params.len(), 2);
    }

    #[test]
    fn parse_spectre_resistor() {
        let input = r#"
subckt test (A B)
r1 (VDD net1) resistor r=10k
ends test
"#;
        let circuit = parse_spectre(input).unwrap();
        let r = &circuit.subcircuits[0].instances[0];
        assert_eq!(r.name, "r1");
        assert_eq!(r.prefix, 'R');
        assert_eq!(r.nodes, vec!["VDD", "net1"]);
        assert_eq!(r.model_or_subckt, "resistor");
    }

    #[test]
    fn parse_spectre_comments_skipped() {
        let input = r#"
// This is a Spectre comment
subckt test (A B)
// Another comment
r1 (A B) resistor r=1k
ends test
"#;
        let circuit = parse_spectre(input).unwrap();
        assert_eq!(circuit.subcircuits.len(), 1);
    }

    #[test]
    fn parse_spectre_bare_ports() {
        let input = r#"
subckt amp IN OUT VDD VSS
r1 (IN OUT) resistor r=1k
ends amp
"#;
        let circuit = parse_spectre(input).unwrap();
        let sub = &circuit.subcircuits[0];
        assert_eq!(sub.name, "amp");
        assert_eq!(sub.ports, vec!["IN", "OUT", "VDD", "VSS"]);
    }

    #[test]
    fn parse_spectre_unclosed_subckt_error() {
        let input = r#"
subckt oops (A B)
r1 (A B) resistor r=1k
"#;
        let result = parse_spectre(input);
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains("unclosed subckt"));
    }

    #[test]
    fn parse_spectre_ends_without_subckt_error() {
        let input = "ends orphan\n";
        let result = parse_spectre(input);
        assert!(result.is_err());
    }

    #[test]
    fn infer_prefix_from_model() {
        assert_eq!(infer_spectre_prefix("i0", "resistor"), 'R');
        assert_eq!(infer_spectre_prefix("i0", "capacitor"), 'C');
        assert_eq!(infer_spectre_prefix("i0", "inductor"), 'L');
        assert_eq!(infer_spectre_prefix("i0", "nmos"), 'M');
        assert_eq!(infer_spectre_prefix("i0", "pmos"), 'M');
        assert_eq!(infer_spectre_prefix("i0", "vsource"), 'V');
        assert_eq!(infer_spectre_prefix("i0", "diode"), 'D');
        // "i0" starts with 'I', which matches the instance name prefix fallback
        assert_eq!(infer_spectre_prefix("i0", "my_custom_subckt"), 'I');
        // Use a truly unknown prefix for subcircuit detection
        assert_eq!(infer_spectre_prefix("u0", "my_custom_subckt"), 'X');
    }

    #[test]
    fn parse_spectre_subckt_instance() {
        let input = r#"
subckt top (A B)
x1 (A B net1) my_subckt gain=10
ends top
"#;
        let circuit = parse_spectre(input).unwrap();
        let x = &circuit.subcircuits[0].instances[0];
        assert_eq!(x.name, "x1");
        assert_eq!(x.model_or_subckt, "my_subckt");
        assert_eq!(x.nodes, vec!["A", "B", "net1"]);
        assert_eq!(x.params, vec![("gain".to_string(), "10".to_string())]);
    }
}
