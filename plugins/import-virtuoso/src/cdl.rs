//! CDL (Circuit Description Language) netlist parser.
//!
//! CDL is a subset of SPICE used by Cadence Virtuoso.
//! Supports `.SUBCKT` / `.ENDS`, device instances (M, R, C, Q, X, etc.),
//! line continuations ('+'), and inline parameters.

/// Parsed CDL circuit (top-level or subcircuit).
#[derive(Debug, Clone, Default)]
pub struct CdlCircuit {
    pub name: String,
    pub ports: Vec<String>,
    pub instances: Vec<CdlInstance>,
    pub subcircuits: Vec<CdlCircuit>,
}

/// A single device or subcircuit instance within a CDL circuit.
#[derive(Debug, Clone)]
pub struct CdlInstance {
    pub name: String,
    pub nodes: Vec<String>,
    pub model_or_subckt: String,
    pub params: Vec<(String, String)>,
    /// SPICE prefix character (R, C, M, Q, X, etc.)
    pub prefix: char,
}

/// Parse a CDL netlist string into a `CdlCircuit`.
///
/// The returned circuit acts as a wrapper: top-level instances live in
/// `circuit.instances`, and `.SUBCKT` blocks are collected in
/// `circuit.subcircuits`.
///
/// # Errors
///
/// Returns an error string for malformed lines or mismatched
/// `.SUBCKT` / `.ENDS` blocks.
pub fn parse_cdl(input: &str) -> Result<CdlCircuit, String> {
    let lines = join_continuation_lines(input);
    let mut top = CdlCircuit {
        name: String::from("top"),
        ..Default::default()
    };
    let mut stack: Vec<CdlCircuit> = Vec::new();

    for (line_no, line) in lines.iter().enumerate() {
        let trimmed = line.trim();

        // Skip empty lines, comments, and CDL-specific directives we don't parse
        if trimmed.is_empty() || trimmed.starts_with('*') || trimmed.starts_with("//") {
            continue;
        }

        let upper = trimmed.to_ascii_uppercase();

        if upper.starts_with(".SUBCKT") {
            let subckt = parse_subckt_header(trimmed, line_no)?;
            stack.push(subckt);
        } else if upper.starts_with(".ENDS") {
            let finished = stack.pop().ok_or_else(|| {
                format!("line {}: .ENDS without matching .SUBCKT", line_no + 1)
            })?;
            if stack.is_empty() {
                top.subcircuits.push(finished);
            } else {
                // Nested subcircuit
                stack.last_mut().unwrap().subcircuits.push(finished);
            }
        } else if upper.starts_with(".GLOBAL")
            || upper.starts_with(".PARAM")
            || upper.starts_with(".INCLUDE")
            || upper.starts_with(".LIB")
            || upper.starts_with(".END")
            || upper.starts_with(".OPTION")
        {
            // Skip known directives
            continue;
        } else if trimmed.starts_with('.') {
            // Unknown directive -- skip
            continue;
        } else {
            // Instance line
            let inst = parse_instance_line(trimmed, line_no)?;
            if let Some(current) = stack.last_mut() {
                current.instances.push(inst);
            } else {
                top.instances.push(inst);
            }
        }
    }

    if !stack.is_empty() {
        return Err(format!(
            "unclosed .SUBCKT: {}",
            stack.last().unwrap().name
        ));
    }

    Ok(top)
}

/// Join continuation lines (lines starting with '+') into their predecessor.
fn join_continuation_lines(input: &str) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();

    for raw_line in input.lines() {
        let trimmed = raw_line.trim();
        if trimmed.starts_with('+') {
            // Continuation -- append to previous line
            if let Some(prev) = result.last_mut() {
                prev.push(' ');
                prev.push_str(trimmed[1..].trim());
            } else {
                // Orphan continuation, treat as new line
                result.push(trimmed[1..].trim().to_string());
            }
        } else {
            result.push(raw_line.to_string());
        }
    }

    result
}

/// Parse `.SUBCKT name port1 port2 ... [param=val ...]`
fn parse_subckt_header(line: &str, line_no: usize) -> Result<CdlCircuit, String> {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.len() < 2 {
        return Err(format!(
            "line {}: .SUBCKT missing name",
            line_no + 1
        ));
    }

    let name = tokens[1].to_string();
    let mut ports = Vec::new();

    for &tok in &tokens[2..] {
        // Stop at parameters (key=value pairs)
        if tok.contains('=') {
            break;
        }
        ports.push(tok.to_string());
    }

    Ok(CdlCircuit {
        name,
        ports,
        instances: Vec::new(),
        subcircuits: Vec::new(),
    })
}

/// Parse an instance line: `Mname node1 node2 ... model [key=val ...]`
///
/// The SPICE prefix determines how many nodes to expect before the model name:
/// - M (MOSFET): 4 nodes (d g s b), then model
/// - Q (BJT): 3-4 nodes (c b e [s]), then model
/// - R (resistor): 2 nodes, then model/value
/// - C (capacitor): 2 nodes, then model/value
/// - L (inductor): 2 nodes, then model/value
/// - D (diode): 2 nodes, then model
/// - J (JFET): 3 nodes, then model
/// - X (subcircuit): nodes until model (heuristic: first non-node-like token)
/// - V/I (sources): 2 nodes, then value/type
fn parse_instance_line(line: &str, line_no: usize) -> Result<CdlInstance, String> {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.is_empty() {
        return Err(format!(
            "line {}: empty instance line",
            line_no + 1
        ));
    }

    let name = tokens[0].to_string();
    let prefix = name
        .chars()
        .next()
        .ok_or_else(|| format!("line {}: empty instance name", line_no + 1))?
        .to_ascii_uppercase();

    let min_nodes = match prefix {
        'M' => 4,
        'Q' => 3,
        'R' | 'C' | 'L' | 'D' | 'V' | 'I' => 2,
        'J' | 'Z' => 3,
        'E' | 'G' | 'H' | 'F' | 'T' => 4,
        'K' => 0,
        'X' => 0, // variable -- handled below
        _ => 2,   // default assumption
    };

    if prefix == 'X' {
        return parse_subckt_instance(&tokens, prefix, line_no);
    }

    // For non-X instances: take min_nodes nodes, then model, then params
    if tokens.len() < 1 + min_nodes + 1 {
        return Err(format!(
            "line {}: not enough tokens for {} instance '{}'",
            line_no + 1,
            prefix,
            name
        ));
    }

    let nodes: Vec<String> = tokens[1..1 + min_nodes]
        .iter()
        .map(|s| s.to_string())
        .collect();

    // For BJTs, check if there's an extra substrate node before the model
    let (model_idx, actual_nodes) = if prefix == 'Q' && tokens.len() > 1 + min_nodes + 1 {
        // If token at position 4 (0-indexed) doesn't look like a model
        // (i.e., doesn't contain '=' and next token is not a param), it might
        // be a 4th node. Use heuristic: if token after the 3 nodes + 1
        // doesn't contain '=' and the one after that also doesn't, treat
        // the first as a 4th node.
        let candidate = tokens[1 + min_nodes];
        let next = tokens.get(1 + min_nodes + 1);
        if !candidate.contains('=') && next.is_some_and(|n| !n.contains('=')) {
            // 4-terminal BJT
            let mut n = nodes;
            n.push(candidate.to_string());
            (1 + min_nodes + 1, n)
        } else {
            (1 + min_nodes, nodes)
        }
    } else {
        (1 + min_nodes, nodes)
    };

    let model_or_subckt = tokens
        .get(model_idx)
        .map(|s| s.to_string())
        .unwrap_or_default();

    let mut params = Vec::new();
    for &tok in &tokens[model_idx + 1..] {
        if let Some((k, v)) = tok.split_once('=') {
            params.push((k.to_string(), v.to_string()));
        }
        // CDL sometimes has bare values (e.g., resistor value) -- skip them
    }

    Ok(CdlInstance {
        name,
        nodes: actual_nodes,
        model_or_subckt,
        params,
        prefix,
    })
}

/// Parse subcircuit instance: `Xname node1 node2 ... subckt_name [param=val ...]`
///
/// Heuristic: walk backwards from the last non-parameter token to find the
/// subcircuit model name.
fn parse_subckt_instance(
    tokens: &[&str],
    prefix: char,
    line_no: usize,
) -> Result<CdlInstance, String> {
    if tokens.len() < 3 {
        return Err(format!(
            "line {}: subcircuit instance needs at least name, one node, and model",
            line_no + 1
        ));
    }

    let name = tokens[0].to_string();

    // Find the last token that is NOT a key=value parameter.
    // That is the subcircuit model name.
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

    Ok(CdlInstance {
        name,
        nodes,
        model_or_subckt,
        params,
        prefix,
    })
}

// -- Tests --------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_subcircuit() {
        let input = r#"
.SUBCKT opamp INP INN OUT VDD VSS
M1 net1 INP net3 VSS nmos W=1u L=180n
M2 net1 INN net4 VSS nmos W=1u L=180n
R1 VDD net1 10k
.ENDS opamp
"#;
        let circuit = parse_cdl(input).unwrap();
        assert_eq!(circuit.subcircuits.len(), 1);
        let sub = &circuit.subcircuits[0];
        assert_eq!(sub.name, "opamp");
        assert_eq!(sub.ports, vec!["INP", "INN", "OUT", "VDD", "VSS"]);
        assert_eq!(sub.instances.len(), 3);
    }

    #[test]
    fn parse_mosfet_instance() {
        let input = r#"
.SUBCKT test A B
M1 drain gate source bulk nmos W=1u L=180n
.ENDS test
"#;
        let circuit = parse_cdl(input).unwrap();
        let m = &circuit.subcircuits[0].instances[0];
        assert_eq!(m.name, "M1");
        assert_eq!(m.prefix, 'M');
        assert_eq!(m.nodes, vec!["drain", "gate", "source", "bulk"]);
        assert_eq!(m.model_or_subckt, "nmos");
        assert_eq!(m.params.len(), 2);
        assert_eq!(m.params[0], ("W".to_string(), "1u".to_string()));
        assert_eq!(m.params[1], ("L".to_string(), "180n".to_string()));
    }

    #[test]
    fn parse_resistor_instance() {
        let input = r#"
.SUBCKT test A B
R1 VDD net1 10k
.ENDS test
"#;
        let circuit = parse_cdl(input).unwrap();
        let r = &circuit.subcircuits[0].instances[0];
        assert_eq!(r.name, "R1");
        assert_eq!(r.prefix, 'R');
        assert_eq!(r.nodes, vec!["VDD", "net1"]);
        assert_eq!(r.model_or_subckt, "10k");
    }

    #[test]
    fn parse_nested_subcircuits() {
        let input = r#"
.SUBCKT inner A B
R1 A B 1k
.ENDS inner

.SUBCKT outer X Y
X1 X Y inner
.ENDS outer
"#;
        let circuit = parse_cdl(input).unwrap();
        assert_eq!(circuit.subcircuits.len(), 2);
        assert_eq!(circuit.subcircuits[0].name, "inner");
        assert_eq!(circuit.subcircuits[1].name, "outer");

        let x1 = &circuit.subcircuits[1].instances[0];
        assert_eq!(x1.name, "X1");
        assert_eq!(x1.prefix, 'X');
        assert_eq!(x1.model_or_subckt, "inner");
        assert_eq!(x1.nodes, vec!["X", "Y"]);
    }

    #[test]
    fn parse_continuation_lines() {
        let input = r#"
.SUBCKT test A B
M1 drain gate source bulk nmos
+ W=1u L=180n
.ENDS test
"#;
        let circuit = parse_cdl(input).unwrap();
        let m = &circuit.subcircuits[0].instances[0];
        assert_eq!(m.name, "M1");
        assert_eq!(m.params.len(), 2);
    }

    #[test]
    fn parse_comments_skipped() {
        let input = r#"
* This is a comment
.SUBCKT test A B
* Another comment
R1 A B 1k
.ENDS test
"#;
        let circuit = parse_cdl(input).unwrap();
        assert_eq!(circuit.subcircuits.len(), 1);
        assert_eq!(circuit.subcircuits[0].instances.len(), 1);
    }

    #[test]
    fn parse_unclosed_subckt_error() {
        let input = r#"
.SUBCKT oops A B
R1 A B 1k
"#;
        let result = parse_cdl(input);
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains("unclosed .SUBCKT"));
    }

    #[test]
    fn parse_ends_without_subckt_error() {
        let input = ".ENDS orphan\n";
        let result = parse_cdl(input);
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains(".ENDS without matching .SUBCKT"));
    }

    #[test]
    fn parse_subckt_instance_with_params() {
        let input = r#"
.SUBCKT test A B
X1 A B net1 net2 my_subckt param1=100 param2=200
.ENDS test
"#;
        let circuit = parse_cdl(input).unwrap();
        let x = &circuit.subcircuits[0].instances[0];
        assert_eq!(x.name, "X1");
        assert_eq!(x.prefix, 'X');
        assert_eq!(x.model_or_subckt, "my_subckt");
        assert_eq!(x.nodes, vec!["A", "B", "net1", "net2"]);
        assert_eq!(x.params.len(), 2);
    }

    #[test]
    fn parse_top_level_instances() {
        let input = r#"
R1 VDD net1 1k
C1 net1 GND 1p
"#;
        let circuit = parse_cdl(input).unwrap();
        assert_eq!(circuit.instances.len(), 2);
        assert_eq!(circuit.instances[0].name, "R1");
        assert_eq!(circuit.instances[1].name, "C1");
    }

    #[test]
    fn parse_case_insensitive_directives() {
        let input = r#"
.subckt test A B
R1 A B 1k
.ends test
"#;
        let circuit = parse_cdl(input).unwrap();
        assert_eq!(circuit.subcircuits.len(), 1);
    }

    #[test]
    fn parse_capacitor_instance() {
        let input = r#"
.SUBCKT test A B
C1 net1 GND cap_mim C=1p
.ENDS test
"#;
        let circuit = parse_cdl(input).unwrap();
        let c = &circuit.subcircuits[0].instances[0];
        assert_eq!(c.name, "C1");
        assert_eq!(c.prefix, 'C');
        assert_eq!(c.nodes, vec!["net1", "GND"]);
        assert_eq!(c.model_or_subckt, "cap_mim");
    }
}
