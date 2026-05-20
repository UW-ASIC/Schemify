//! Verilog-A module interface parser.
//!
//! Parses module declarations to extract port lists, directions, and
//! parameters. Does NOT parse the full `analog begin` behavioral block --
//! only the structural interface needed to generate a symbol.

use crate::result::*;

// -- IR Types -----------------------------------------------------------------

/// Parsed Verilog-A module interface.
#[derive(Debug, Clone)]
pub struct VerilogAModule {
    pub name: String,
    pub ports: Vec<VerilogAPort>,
    pub params: Vec<VerilogAParam>,
}

/// A port in a Verilog-A module.
#[derive(Debug, Clone)]
pub struct VerilogAPort {
    pub name: String,
    pub direction: PortDirection,
}

/// Port direction in Verilog-A.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortDirection {
    Input,
    Output,
    InOut,
}

impl PortDirection {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Input => "input",
            Self::Output => "output",
            Self::InOut => "inout",
        }
    }
}

/// A parameter declaration in a Verilog-A module.
#[derive(Debug, Clone)]
pub struct VerilogAParam {
    pub name: String,
    pub param_type: String,
    pub default: Option<String>,
}

// -- Parser -------------------------------------------------------------------

/// Parse a Verilog-A source string, extracting the module interface.
///
/// Extracts: module name, port list, port directions, and parameters.
/// Ignores `analog begin` blocks and other behavioral content.
///
/// # Errors
///
/// Returns an error string if no valid `module` declaration is found
/// or the syntax is malformed.
pub fn parse_verilog_a(input: &str) -> Result<VerilogAModule, String> {
    let cleaned = strip_comments(input);
    let lines: Vec<&str> = cleaned.lines().collect();

    let mut module_name = String::new();
    let mut port_names: Vec<String> = Vec::new();
    let mut port_dirs: std::collections::HashMap<String, PortDirection> =
        std::collections::HashMap::new();
    let mut params: Vec<VerilogAParam> = Vec::new();
    let mut found_module = false;

    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();

        // Skip preprocessor directives and empty lines
        if trimmed.is_empty() || trimmed.starts_with('`') {
            i += 1;
            continue;
        }

        // Module declaration: `module name(port1, port2, ...);`
        if !found_module {
            if let Some(rest) = trimmed.strip_prefix("module") {
                let rest = rest.trim();
                // May span multiple lines -- collect until ';'
                let mut decl = rest.to_string();
                while !decl.contains(';') {
                    i += 1;
                    if i >= lines.len() {
                        return Err("module declaration missing ';'".into());
                    }
                    decl.push(' ');
                    decl.push_str(lines[i].trim());
                }

                // Parse "name(port1, port2, ...)"
                let decl = decl.trim_end_matches(';').trim();
                if let Some(paren_open) = decl.find('(') {
                    module_name = decl[..paren_open].trim().to_string();
                    if let Some(paren_close) = decl.find(')') {
                        let port_str = &decl[paren_open + 1..paren_close];
                        port_names = port_str
                            .split(',')
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                            .collect();
                    }
                } else {
                    // Module with no ports
                    module_name = decl.to_string();
                }

                found_module = true;
                i += 1;
                continue;
            }
        }

        // Port direction declarations
        if found_module {
            if let Some(rest) = trimmed.strip_prefix("input") {
                for name in parse_port_names(rest) {
                    port_dirs.insert(name, PortDirection::Input);
                }
            } else if let Some(rest) = trimmed.strip_prefix("output") {
                for name in parse_port_names(rest) {
                    port_dirs.insert(name, PortDirection::Output);
                }
            } else if let Some(rest) = trimmed.strip_prefix("inout") {
                for name in parse_port_names(rest) {
                    port_dirs.insert(name, PortDirection::InOut);
                }
            }

            // Parameter declarations
            if let Some(rest) = trimmed.strip_prefix("parameter") {
                if let Some(param) = parse_parameter(rest) {
                    params.push(param);
                }
            }

            // Stop at endmodule
            if trimmed.starts_with("endmodule") {
                break;
            }
        }

        i += 1;
    }

    if !found_module {
        return Err("no 'module' declaration found in Verilog-A source".into());
    }

    // Build ports with directions
    let ports: Vec<VerilogAPort> = port_names
        .into_iter()
        .map(|name| {
            let direction = port_dirs
                .get(&name)
                .copied()
                .unwrap_or(PortDirection::InOut);
            VerilogAPort { name, direction }
        })
        .collect();

    Ok(VerilogAModule {
        name: module_name,
        ports,
        params,
    })
}

// -- Symbol Generation --------------------------------------------------------

/// Generate a symbol `ImportResult` from a parsed Verilog-A module.
///
/// Creates a rectangular symbol with pins placed on the sides:
/// - Input pins on the left
/// - Output pins on the right
/// - InOut pins on the left (below inputs)
///
/// The symbol body is a rectangle with the module name as a text label.
pub fn module_to_symbol(module: &VerilogAModule) -> ImportResult {
    let mut result = ImportResult::new_symbol(module.name.clone());

    let pin_spacing = 80;
    let margin = 40;

    // Separate pins by direction
    let inputs: Vec<_> = module
        .ports
        .iter()
        .filter(|p| p.direction == PortDirection::Input)
        .collect();
    let outputs: Vec<_> = module
        .ports
        .iter()
        .filter(|p| p.direction == PortDirection::Output)
        .collect();
    let inouts: Vec<_> = module
        .ports
        .iter()
        .filter(|p| p.direction == PortDirection::InOut)
        .collect();

    let left_count = inputs.len() + inouts.len();
    let right_count = outputs.len();
    let max_side = left_count.max(right_count).max(1);

    let body_height = (max_side as i32) * pin_spacing + 2 * margin;
    let body_width = 320;
    let body_x = 0;
    let body_y = 0;

    // Symbol body rectangle
    result.rects.push(RectResult {
        x: body_x,
        y: body_y,
        width: body_width,
        height: body_height,
    });

    // Module name label
    result.texts.push(TextResult {
        x: body_x + body_width / 2,
        y: body_y - 20,
        content: module.name.clone(),
        font_size: 0.4,
        rotation: 0,
    });

    // Place left-side pins (inputs, then inouts)
    let mut pin_number = 0u32;
    let mut left_y = body_y + margin;

    for port in inputs.iter().chain(inouts.iter()) {
        let pin_x = body_x - 40;
        let pin_y = left_y + pin_spacing / 2;

        let dir = port.direction.as_str().to_string();

        result.pins.push(PinResult {
            name: port.name.clone(),
            x: pin_x,
            y: pin_y,
            direction: dir,
            width: 1,
        });

        // Pin stub line from body edge to pin point
        result.lines.push(LineResult {
            x0: body_x,
            y0: pin_y,
            x1: pin_x,
            y1: pin_y,
        });

        pin_number += 1;
        left_y += pin_spacing;
    }

    // Place right-side pins (outputs)
    let mut right_y = body_y + margin;

    for port in &outputs {
        let pin_x = body_x + body_width + 40;
        let pin_y = right_y + pin_spacing / 2;

        result.pins.push(PinResult {
            name: port.name.clone(),
            x: pin_x,
            y: pin_y,
            direction: "output".to_string(),
            width: 1,
        });

        // Pin stub line
        result.lines.push(LineResult {
            x0: body_x + body_width,
            y0: pin_y,
            x1: pin_x,
            y1: pin_y,
        });

        pin_number += 1;
        right_y += pin_spacing;
    }

    // Store parameters as properties
    for param in &module.params {
        let val_str = param.default.as_deref().unwrap_or("");
        result.properties.push(PropertyResult {
            key: param.name.clone(),
            value: val_str.to_string(),
        });
    }

    let _ = pin_number; // suppress unused warning

    result
}

/// Convert a parsed module to a `VerilogAResult` including the generated symbol.
pub fn module_to_result(module: &VerilogAModule) -> VerilogAResult {
    let symbol = module_to_symbol(module);

    VerilogAResult {
        name: module.name.clone(),
        ports: module
            .ports
            .iter()
            .map(|p| VerilogAPortResult {
                name: p.name.clone(),
                direction: p.direction.as_str().to_string(),
            })
            .collect(),
        params: module
            .params
            .iter()
            .map(|p| VerilogAParamResult {
                name: p.name.clone(),
                param_type: p.param_type.clone(),
                default: p.default.clone(),
            })
            .collect(),
        symbol,
    }
}

// -- Helper functions ---------------------------------------------------------

/// Strip C-style (`/* ... */`) and line (`//`) comments from Verilog-A source.
fn strip_comments(input: &str) -> String {
    let mut result = String::with_capacity(input.len());
    let chars: Vec<char> = input.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        if i + 1 < len && chars[i] == '/' && chars[i + 1] == '/' {
            // Line comment -- skip to end of line
            while i < len && chars[i] != '\n' {
                i += 1;
            }
        } else if i + 1 < len && chars[i] == '/' && chars[i + 1] == '*' {
            // Block comment -- skip to */
            i += 2;
            while i + 1 < len && !(chars[i] == '*' && chars[i + 1] == '/') {
                i += 1;
            }
            i += 2; // skip */
        } else {
            result.push(chars[i]);
            i += 1;
        }
    }

    result
}

/// Parse comma-separated port names from a direction declaration.
/// Input: ` port1, port2, port3;`
fn parse_port_names(rest: &str) -> Vec<String> {
    let rest = rest.trim().trim_end_matches(';');
    rest.split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Parse a `parameter` declaration line.
/// Formats:
///   `parameter real gain = 1000;`
///   `parameter integer count = 10;`
///   `parameter real bw = 1e6;`
fn parse_parameter(rest: &str) -> Option<VerilogAParam> {
    let rest = rest.trim().trim_end_matches(';').trim();
    let tokens: Vec<&str> = rest.split_whitespace().collect();

    if tokens.is_empty() {
        return None;
    }

    // Determine if first token is a type keyword
    let (param_type, name_start) = if tokens[0] == "real"
        || tokens[0] == "integer"
        || tokens[0] == "string"
    {
        (tokens[0].to_string(), 1)
    } else {
        ("real".to_string(), 0)
    };

    if name_start >= tokens.len() {
        return None;
    }

    let name = tokens[name_start].to_string();

    // Look for '=' to find default value
    let default = if let Some(eq_pos) = tokens.iter().position(|t| *t == "=") {
        let val_tokens: Vec<&str> = tokens[eq_pos + 1..].to_vec();
        if val_tokens.is_empty() {
            None
        } else {
            Some(val_tokens.join(" "))
        }
    } else if let Some(tok) = tokens.get(name_start) {
        // Check if name contains '=' e.g. "gain=1000"
        if let Some((n, v)) = tok.split_once('=') {
            return Some(VerilogAParam {
                name: n.to_string(),
                param_type,
                default: Some(v.to_string()),
            });
        }
        None
    } else {
        None
    };

    Some(VerilogAParam {
        name,
        param_type,
        default,
    })
}

// -- Tests --------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_basic_module() {
        let input = r#"
`include "constants.vams"
module opamp(inp, inn, out, vdd, vss);
    inout inp, inn, out, vdd, vss;
    electrical inp, inn, out, vdd, vss;
    parameter real gain = 1000;
    parameter real bw = 1e6;
    analog begin
        V(out) <+ gain * V(inp, inn);
    end
endmodule
"#;
        let module = parse_verilog_a(input).unwrap();
        assert_eq!(module.name, "opamp");
        assert_eq!(module.ports.len(), 5);
        assert_eq!(module.params.len(), 2);

        assert_eq!(module.ports[0].name, "inp");
        assert_eq!(module.ports[0].direction, PortDirection::InOut);

        assert_eq!(module.params[0].name, "gain");
        assert_eq!(module.params[0].param_type, "real");
        assert_eq!(module.params[0].default, Some("1000".to_string()));

        assert_eq!(module.params[1].name, "bw");
        assert_eq!(module.params[1].default, Some("1e6".to_string()));
    }

    #[test]
    fn parse_module_with_directions() {
        let input = r#"
module buffer(in, out, vdd, vss);
    input in;
    output out;
    inout vdd, vss;
    electrical in, out, vdd, vss;
    analog begin
        V(out) <+ V(in);
    end
endmodule
"#;
        let module = parse_verilog_a(input).unwrap();
        assert_eq!(module.name, "buffer");
        assert_eq!(module.ports.len(), 4);

        assert_eq!(module.ports[0].name, "in");
        assert_eq!(module.ports[0].direction, PortDirection::Input);

        assert_eq!(module.ports[1].name, "out");
        assert_eq!(module.ports[1].direction, PortDirection::Output);

        assert_eq!(module.ports[2].name, "vdd");
        assert_eq!(module.ports[2].direction, PortDirection::InOut);

        assert_eq!(module.ports[3].name, "vss");
        assert_eq!(module.ports[3].direction, PortDirection::InOut);
    }

    #[test]
    fn parse_module_with_integer_param() {
        let input = r#"
module counter(clk, out);
    input clk;
    output out;
    electrical clk, out;
    parameter integer bits = 8;
endmodule
"#;
        let module = parse_verilog_a(input).unwrap();
        assert_eq!(module.params.len(), 1);
        assert_eq!(module.params[0].name, "bits");
        assert_eq!(module.params[0].param_type, "integer");
        assert_eq!(module.params[0].default, Some("8".to_string()));
    }

    #[test]
    fn parse_no_module_error() {
        let input = "// just a comment\n";
        let result = parse_verilog_a(input);
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains("no 'module' declaration"));
    }

    #[test]
    fn parse_strips_comments() {
        let input = r#"
/* Block comment */
module test(a, b);
    inout a, b; // line comment
    electrical a, b;
    /* another
       multiline comment */
    parameter real r = 100;
endmodule
"#;
        let module = parse_verilog_a(input).unwrap();
        assert_eq!(module.name, "test");
        assert_eq!(module.ports.len(), 2);
        assert_eq!(module.params.len(), 1);
    }

    #[test]
    fn module_to_symbol_basic() {
        let module = VerilogAModule {
            name: "opamp".to_string(),
            ports: vec![
                VerilogAPort {
                    name: "inp".to_string(),
                    direction: PortDirection::Input,
                },
                VerilogAPort {
                    name: "inn".to_string(),
                    direction: PortDirection::Input,
                },
                VerilogAPort {
                    name: "out".to_string(),
                    direction: PortDirection::Output,
                },
                VerilogAPort {
                    name: "vdd".to_string(),
                    direction: PortDirection::InOut,
                },
                VerilogAPort {
                    name: "vss".to_string(),
                    direction: PortDirection::InOut,
                },
            ],
            params: vec![VerilogAParam {
                name: "gain".to_string(),
                param_type: "real".to_string(),
                default: Some("1000".to_string()),
            }],
        };

        let sym = module_to_symbol(&module);

        assert_eq!(sym.name, "opamp");
        assert_eq!(sym.schematic_type, "symbol");
        assert_eq!(sym.pins.len(), 5); // inp, inn, out, vdd, vss
        assert_eq!(sym.rects.len(), 1); // body rect
        assert_eq!(sym.texts.len(), 1); // name label
        assert_eq!(sym.properties.len(), 1); // gain param

        // Check pin directions
        assert_eq!(sym.pins[0].direction, "input"); // inp
        assert_eq!(sym.pins[1].direction, "input"); // inn
        assert_eq!(sym.pins[2].direction, "inout"); // vdd (inout on left)
        assert_eq!(sym.pins[3].direction, "inout"); // vss (inout on left)
        assert_eq!(sym.pins[4].direction, "output"); // out
    }

    #[test]
    fn module_to_symbol_no_ports() {
        let module = VerilogAModule {
            name: "empty".to_string(),
            ports: vec![],
            params: vec![],
        };

        let sym = module_to_symbol(&module);

        assert_eq!(sym.name, "empty");
        assert_eq!(sym.pins.len(), 0);
        assert_eq!(sym.rects.len(), 1); // still has body
    }

    #[test]
    fn strip_comments_block() {
        let input = "before /* comment */ after";
        let result = strip_comments(input);
        assert_eq!(result, "before  after");
    }

    #[test]
    fn strip_comments_line() {
        let input = "code // comment\nnext line";
        let result = strip_comments(input);
        assert_eq!(result, "code \nnext line");
    }

    #[test]
    fn parse_module_no_ports() {
        let input = "module test;\nendmodule\n";
        let module = parse_verilog_a(input).unwrap();
        assert_eq!(module.name, "test");
        assert_eq!(module.ports.len(), 0);
    }

    #[test]
    fn module_to_result_basic() {
        let module = VerilogAModule {
            name: "amp".to_string(),
            ports: vec![
                VerilogAPort {
                    name: "in".to_string(),
                    direction: PortDirection::Input,
                },
                VerilogAPort {
                    name: "out".to_string(),
                    direction: PortDirection::Output,
                },
            ],
            params: vec![VerilogAParam {
                name: "gain".to_string(),
                param_type: "real".to_string(),
                default: Some("10".to_string()),
            }],
        };

        let result = module_to_result(&module);
        assert_eq!(result.name, "amp");
        assert_eq!(result.ports.len(), 2);
        assert_eq!(result.params.len(), 1);
        assert_eq!(result.symbol.pins.len(), 2);
    }
}
