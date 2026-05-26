pub mod expr;
pub mod params;

use std::collections::HashMap;

use thiserror::Error;

use crate::s2s::ir::{Circuit, Instance, Model, Pin, PinDir, PinRef, Primitive, Subcircuit};

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("unexpected token: {0}")]
    UnexpectedToken(String),
    #[error("unknown element prefix: {0}")]
    UnknownElement(char),
    #[error("missing pins for device `{0}`")]
    MissingPins(String),
    #[error("invalid syntax on line {line}: {message}")]
    InvalidSyntax { line: usize, message: String },
}

// ---------------------------------------------------------------------------
// Pragma representation
// ---------------------------------------------------------------------------

/// A structured pragma parsed from `* .xs_pragma <directive> <args...>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pragma {
    pub directive: String,
    pub args: Vec<String>,
}

// ---------------------------------------------------------------------------
// SpiceParser
// ---------------------------------------------------------------------------

/// SPICE netlist parser (ngspice-compatible subset).
///
/// After calling [`parse`], the auxiliary data (`.param` key-value pairs,
/// `.global` nets, and custom pragmas) is available through accessor methods
/// on the parser struct.
pub struct SpiceParser {
    /// `.param` key-value pairs (raw strings) collected during parsing.
    params: HashMap<String, String>,
    /// `.param` values resolved to f64 via expression evaluation.
    resolved_params: HashMap<String, f64>,
    /// `.global` net names.
    globals: Vec<String>,
    /// Custom `* .xs_pragma` directives.
    pragmas: Vec<Pragma>,
    /// Scope stack for subcircuit nesting.  `None` means top-level.
    /// Each entry is the name of the subcircuit currently being parsed.
    scope_stack: Vec<String>,
    /// True while inside a `.control` / `.endc` block.
    in_control_block: bool,
    /// Accumulator for lines inside the current `.control` block.
    control_buf: String,
}

impl SpiceParser {
    pub fn new() -> Self {
        Self {
            params: HashMap::new(),
            resolved_params: HashMap::new(),
            globals: Vec::new(),
            pragmas: Vec::new(),
            scope_stack: Vec::new(),
            in_control_block: false,
            control_buf: String::new(),
        }
    }

    // -- Accessors for auxiliary data --------------------------------------

    pub fn params(&self) -> &HashMap<String, String> {
        &self.params
    }

    pub fn resolved_params(&self) -> &HashMap<String, f64> {
        &self.resolved_params
    }

    pub fn globals(&self) -> &[String] {
        &self.globals
    }

    pub fn pragmas(&self) -> &[Pragma] {
        &self.pragmas
    }

    // -- Main entry point --------------------------------------------------

    /// Parse a SPICE netlist from `source` and return the populated [`Circuit`].
    pub fn parse(&mut self, source: &str) -> Result<Circuit, ParseError> {
        let mut circuit = Circuit::new("top");

        // Reset auxiliary state so the parser is reusable.
        self.params.clear();
        self.resolved_params.clear();
        self.globals.clear();
        self.pragmas.clear();
        self.scope_stack.clear();
        self.in_control_block = false;

        // -- Pre-processing: join continuation lines, strip comments --------
        let joined_lines = preprocess(source);

        for (line_no, line) in joined_lines.iter().enumerate() {
            self.parse_line(&mut circuit, line, line_no + 1)?;
        }

        // -- Resolve .param expressions to f64 values -----------------------
        self.resolved_params = params::resolve_params(&self.params);

        // -- Substitute resolved params in device parameters ----------------
        params::substitute_params(&mut circuit, &self.resolved_params);

        // -- Reclassify X-instances that are PDK-wrapped MOSFETs -----------
        reclassify_subckt_mosfets(&mut circuit);

        // Mark global nets.
        for gname in &self.globals {
            // Check top-level nets.
            for net in &mut circuit.top.nets {
                if net.name == *gname {
                    net.is_global = true;
                }
            }
            // Check subcircuit nets too.
            for sub in circuit.subcircuits.values_mut() {
                for net in &mut sub.nets {
                    if net.name == *gname {
                        net.is_global = true;
                    }
                }
            }
        }

        Ok(circuit)
    }

    // -- Scope helpers -----------------------------------------------------

    /// Returns `true` when inside a `.subckt` scope.
    fn in_subckt(&self) -> bool {
        !self.scope_stack.is_empty()
    }

    /// Name of the current subcircuit scope (panics if not in one).
    fn current_subckt_name(&self) -> &str {
        self.scope_stack.last().unwrap()
    }
}

// ---------------------------------------------------------------------------
// Pre-processing (continuation, comments, pragmas extraction)
// ---------------------------------------------------------------------------

/// Join continuation lines (`+` prefix), strip full-line (`*`) and inline
/// (`;`) comments, and return the logical lines ready for parsing.
///
/// Pragma comment lines (`* .xs_pragma ...`) are **not** discarded — they are
/// returned with a special `#pragma ` prefix so the main parser can pick
/// them up.
fn preprocess(source: &str) -> Vec<String> {
    let mut logical_lines: Vec<String> = Vec::new();

    for raw in source.lines() {
        let trimmed = raw.trim();

        if trimmed.is_empty() {
            continue;
        }

        // Full-line comment.
        if trimmed.starts_with('*') {
            // Check for pragma: `* .xs_pragma ...`
            let after_star = trimmed[1..].trim();
            if after_star
                .to_ascii_lowercase()
                .starts_with(".xs_pragma")
            {
                // Encode as a synthetic line the main parser will recognise.
                logical_lines.push(format!("#pragma {}", after_star));
            }
            continue;
        }

        // Strip inline comment (`;` or `$`).
        let effective = strip_inline_comment(trimmed);

        if effective.is_empty() {
            continue;
        }

        // Continuation line.
        if effective.starts_with('+') {
            if let Some(last) = logical_lines.last_mut() {
                last.push(' ');
                last.push_str(effective[1..].trim());
            }
            continue;
        }

        logical_lines.push(effective.to_string());
    }

    logical_lines
}

// ---------------------------------------------------------------------------
// Line dispatcher
// ---------------------------------------------------------------------------

impl SpiceParser {
    fn parse_line(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        line_no: usize,
    ) -> Result<(), ParseError> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Ok(());
        }

        // Inside a .control block — capture everything until .endc.
        if self.in_control_block {
            if trimmed.eq_ignore_ascii_case(".endc") {
                // Close current control block: join accumulated lines.
                self.control_buf.push_str(".endc");
                circuit
                    .analysis
                    .control_blocks
                    .push(std::mem::take(&mut self.control_buf));
                self.in_control_block = false;
            } else {
                self.control_buf.push_str(trimmed);
                self.control_buf.push('\n');
            }
            return Ok(());
        }

        // Synthetic pragma line from preprocessor.
        if trimmed.starts_with("#pragma ") {
            self.parse_pragma(&trimmed["#pragma ".len()..]);
            return Ok(());
        }

        // Dot command.
        if trimmed.starts_with('.') {
            return self.parse_dot_command(circuit, trimmed, line_no);
        }

        let prefix = trimmed
            .chars()
            .next()
            .unwrap()
            .to_ascii_lowercase();

        match prefix {
            'm' => self.parse_mosfet(circuit, trimmed, line_no),
            'q' => self.parse_bjt(circuit, trimmed, line_no),
            'r' => self.parse_two_terminal(circuit, trimmed, Primitive::Resistor, line_no),
            'c' => self.parse_two_terminal(circuit, trimmed, Primitive::Capacitor, line_no),
            'l' => self.parse_two_terminal(circuit, trimmed, Primitive::Inductor, line_no),
            'd' => self.parse_diode(circuit, trimmed, line_no),
            'v' => self.parse_two_terminal(circuit, trimmed, Primitive::Vsource, line_no),
            'i' => self.parse_two_terminal(circuit, trimmed, Primitive::Isource, line_no),
            'e' => self.parse_vcvs(circuit, trimmed, line_no),
            'g' => self.parse_vccs(circuit, trimmed, line_no),
            'f' => self.parse_cccs(circuit, trimmed, line_no),
            'h' => self.parse_ccvs(circuit, trimmed, line_no),
            'x' => self.parse_subckt_instance(circuit, trimmed, line_no),
            _ => {
                // Silently ignore unknown device prefixes (matches Zig behaviour).
                Ok(())
            }
        }
    }

    // -- Scope-aware helpers for adding instances/nets ---------------------

    /// Add an instance to the correct scope (current subckt or top-level).
    fn add_instance_scoped(&self, circuit: &mut Circuit, inst: Instance) -> u32 {
        if self.in_subckt() {
            let sub = circuit.subcircuits.get_mut(self.current_subckt_name()).unwrap();
            let idx = sub.instances.len() as u32;
            sub.instances.push(inst);
            idx
        } else {
            circuit.add_instance(inst)
        }
    }

    /// Get or create a net in the correct scope.
    fn get_or_create_net_scoped(&self, circuit: &mut Circuit, name: &str) -> u32 {
        if self.in_subckt() {
            let sub = circuit.subcircuits.get_mut(self.current_subckt_name()).unwrap();
            for (i, net) in sub.nets.iter().enumerate() {
                if net.name == name {
                    return i as u32;
                }
            }
            let idx = sub.nets.len() as u32;
            sub.nets.push(crate::s2s::ir::Net::new(name));
            idx
        } else {
            circuit.get_or_create_net(name)
        }
    }

    /// Connect a pin to a net in the correct scope.
    fn connect_scoped(&self, circuit: &mut Circuit, net_idx: u32, pin_ref: PinRef) {
        if self.in_subckt() {
            let sub = circuit.subcircuits.get_mut(self.current_subckt_name()).unwrap();
            sub.nets[net_idx as usize].pins.push(pin_ref);
            sub.instances[pin_ref.instance_idx as usize].pins[pin_ref.pin_idx as usize].net_idx =
                Some(net_idx);
        } else {
            circuit.connect(net_idx, pin_ref);
        }
    }
}

// ---------------------------------------------------------------------------
// Dot-command parsing
// ---------------------------------------------------------------------------

impl SpiceParser {
    fn parse_dot_command(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.is_empty() {
            return Ok(());
        }
        let cmd = tokens[0];

        if cmd.eq_ignore_ascii_case(".subckt") {
            if tokens.len() < 2 {
                return Ok(());
            }
            let name = tokens[1].to_ascii_lowercase();
            let mut ports: Vec<String> = Vec::new();
            for tok in &tokens[2..] {
                if tok.contains('=') {
                    break;
                }
                ports.push(tok.to_ascii_lowercase());
            }
            let mut sub = Subcircuit::new(&name);
            sub.ports = ports;
            circuit.subcircuits.insert(name.clone(), sub);
            self.scope_stack.push(name);
        } else if cmd.eq_ignore_ascii_case(".ends") {
            // Pop the current subcircuit scope.
            self.scope_stack.pop();
        } else if cmd.eq_ignore_ascii_case(".end") {
            // End of netlist — pop all remaining scopes.
            self.scope_stack.clear();
        } else if cmd.eq_ignore_ascii_case(".global") {
            for tok in &tokens[1..] {
                self.globals.push(tok.to_ascii_lowercase());
            }
        } else if cmd.eq_ignore_ascii_case(".param") {
            // `.param key=value` or `.param key = value`
            let rest = &line[cmd.len()..].trim();
            for pair in split_params(rest) {
                if let Some((k, v)) = pair.split_once('=') {
                    let k = k.trim().to_ascii_lowercase();
                    let v = v.trim().to_ascii_lowercase();
                    if !k.is_empty() {
                        self.params.insert(k, v);
                    }
                }
            }
        } else if cmd.eq_ignore_ascii_case(".model") {
            // `.model name type (param1=val1 param2=val2 ...)`
            if tokens.len() >= 3 {
                let model_name = tokens[1].to_ascii_lowercase();
                // The type token may have a trailing '(' or the params may be
                // on the same line in parentheses.
                let model_type_raw = tokens[2];
                let model_type = model_type_raw
                    .trim_start_matches('(')
                    .trim_end_matches(')')
                    .to_ascii_lowercase();

                // Parse remaining tokens for key=value params.
                let mut model_params = HashMap::new();
                // Join remaining tokens and strip outer parens.
                let rest: String = tokens[3..]
                    .iter()
                    .map(|t| t.to_ascii_lowercase())
                    .collect::<Vec<_>>()
                    .join(" ");
                let rest = rest.trim().trim_start_matches('(').trim_end_matches(')');
                for pair in split_params(rest) {
                    if let Some((k, v)) = pair.split_once('=') {
                        let k = k.trim().to_string();
                        let v = v.trim().to_string();
                        if !k.is_empty() {
                            model_params.insert(k, v);
                        }
                    }
                }

                let model = Model {
                    name: model_name.clone(),
                    model_type,
                    params: model_params,
                };
                circuit.models.insert(model_name, model);
            }
        } else if cmd.eq_ignore_ascii_case(".include")
            || cmd.eq_ignore_ascii_case(".lib")
        {
            circuit.analysis.includes.push(line.to_string());
        } else if cmd.eq_ignore_ascii_case(".control") {
            self.control_buf = format!("{line}\n");
            self.in_control_block = true;
        } else if let Some(cat) = stimulus_category(cmd) {
            match cat {
                StimulusCategory::Analysis => {
                    circuit.analysis.analyses.push(line.to_string());
                }
                StimulusCategory::Output => {
                    circuit.analysis.outputs.push(line.to_string());
                }
                StimulusCategory::Measurement => {
                    circuit.analysis.measurements.push(line.to_string());
                }
                StimulusCategory::InitialCond => {
                    circuit.analysis.initial_conds.push(line.to_string());
                }
                StimulusCategory::Option => {
                    circuit.analysis.options.push(line.to_string());
                }
                StimulusCategory::Other => {
                    circuit.analysis.other.push(line.to_string());
                }
            }
        }

        Ok(())
    }

    fn parse_pragma(&mut self, text: &str) {
        // text is like `.xs_pragma <directive> <arg1> <arg2> ...`
        let tokens: Vec<&str> = text.split_whitespace().collect();
        // tokens[0] == ".xs_pragma"
        if tokens.len() < 2 {
            return;
        }
        let directive = tokens[1].to_string();
        let args: Vec<String> = tokens[2..].iter().map(|s| s.to_string()).collect();
        self.pragmas.push(Pragma { directive, args });
    }
}

// ---------------------------------------------------------------------------
// Device-card parsers
// ---------------------------------------------------------------------------

impl SpiceParser {
    fn parse_mosfet(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 6 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"M?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();
        let drain = tokens[1].to_ascii_lowercase();
        let gate = tokens[2].to_ascii_lowercase();
        let source = tokens[3].to_ascii_lowercase();
        let bulk = tokens[4].to_ascii_lowercase();
        let model = tokens[5].to_ascii_lowercase();

        let primitive = if is_nmos(&model) {
            Primitive::Nmos
        } else {
            Primitive::Pmos
        };

        let pins = vec![
            Pin { name: "D".to_string(), dir: PinDir::Inout, net_idx: None },
            Pin { name: "G".to_string(), dir: PinDir::Input, net_idx: None },
            Pin { name: "S".to_string(), dir: PinDir::Inout, net_idx: None },
            Pin { name: "B".to_string(), dir: PinDir::Bulk, net_idx: None },
        ];

        let mut params = HashMap::new();
        params.insert("model".to_string(), model);
        for tok in &tokens[6..] {
            if let Some((k, v)) = tok.split_once('=') {
                params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
            }
        }

        let inst = Instance {
            name,
            primitive,
            symbol: String::new(),
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        let net_names = [drain, gate, source, bulk];
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }

    fn parse_bjt(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 5 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"Q?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();
        let collector = tokens[1].to_ascii_lowercase();
        let base = tokens[2].to_ascii_lowercase();
        let emitter = tokens[3].to_ascii_lowercase();
        let model = tokens[4].to_ascii_lowercase();

        let primitive = if is_npn(&model) {
            Primitive::Npn
        } else {
            Primitive::Pnp
        };

        let pins = vec![
            Pin { name: "C".to_string(), dir: PinDir::Inout, net_idx: None },
            Pin { name: "B".to_string(), dir: PinDir::Input, net_idx: None },
            Pin { name: "E".to_string(), dir: PinDir::Inout, net_idx: None },
        ];

        let mut params = HashMap::new();
        params.insert("model".to_string(), model);

        let inst = Instance {
            name,
            primitive,
            symbol: String::new(),
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        let net_names = [collector, base, emitter];
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }

    fn parse_two_terminal(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        primitive: Primitive,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 3 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();
        let plus = tokens[1].to_ascii_lowercase();
        let minus = tokens[2].to_ascii_lowercase();

        let pins = vec![
            Pin { name: "p".to_string(), dir: PinDir::Inout, net_idx: None },
            Pin { name: "n".to_string(), dir: PinDir::Inout, net_idx: None },
        ];

        // For V/I sources the "value" can be a multi-token stimulus spec like
        // `PULSE(0 1.8 0 1n 1n 5u 10u)` or `DC 1.8 AC 1`.  Collect all
        // non-param tokens (no '=') after the two net nodes into a single
        // value string, and real key=value tokens into params.
        let mut params = HashMap::new();
        let mut value_parts: Vec<&str> = Vec::new();
        for tok in tokens.iter().skip(3) {
            if tok.contains('=') {
                if let Some((k, v)) = tok.split_once('=') {
                    params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
                }
            } else {
                value_parts.push(tok);
            }
        }
        let value = value_parts.join(" ").to_ascii_lowercase();
        if !value.is_empty() {
            params.insert("value".to_string(), value);
        }

        let inst = Instance {
            name,
            primitive,
            symbol: String::new(),
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        let net_names = [plus, minus];
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }

    fn parse_diode(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 3 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"D?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();
        let anode = tokens[1].to_ascii_lowercase();
        let cathode = tokens[2].to_ascii_lowercase();
        let model = tokens
            .get(3)
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();

        let pins = vec![
            Pin { name: "A".to_string(), dir: PinDir::Inout, net_idx: None },
            Pin { name: "K".to_string(), dir: PinDir::Inout, net_idx: None },
        ];

        let mut params = HashMap::new();
        if !model.is_empty() {
            params.insert("model".to_string(), model);
        }

        let inst = Instance {
            name,
            primitive: Primitive::Diode,
            symbol: String::new(),
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        let net_names = [anode, cathode];
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }

    /// Parse voltage-controlled voltage source: `Ename np nm ncp ncm gain [params]`
    fn parse_vcvs(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        self.parse_vc_source(circuit, line, Primitive::Vcvs)
    }

    /// Parse voltage-controlled current source: `Gname np nm ncp ncm gain [params]`
    fn parse_vccs(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        self.parse_vc_source(circuit, line, Primitive::Vccs)
    }

    /// Parse current-controlled current source: `Fname np nm vsource gain [params]`
    fn parse_cccs(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        self.parse_cc_source(circuit, line, Primitive::Cccs)
    }

    /// Parse current-controlled voltage source: `Hname np nm vsource gain [params]`
    fn parse_ccvs(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        self.parse_cc_source(circuit, line, Primitive::Ccvs)
    }

    /// Shared parser for voltage-controlled sources (E, G).
    /// SPICE syntax: `name np nm ncp ncm value [params]`
    /// 4-pin device with output (p, n) and control (cp, cn) nets.
    fn parse_vc_source(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        primitive: Primitive,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 6 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();
        let np = tokens[1].to_ascii_lowercase();
        let nm = tokens[2].to_ascii_lowercase();
        let ncp = tokens[3].to_ascii_lowercase();
        let ncm = tokens[4].to_ascii_lowercase();

        let pins = vec![
            Pin { name: "p".to_string(), dir: PinDir::Output, net_idx: None },
            Pin { name: "n".to_string(), dir: PinDir::Output, net_idx: None },
            Pin { name: "cp".to_string(), dir: PinDir::Input, net_idx: None },
            Pin { name: "cn".to_string(), dir: PinDir::Input, net_idx: None },
        ];

        let mut params = HashMap::new();
        let mut value_parts: Vec<&str> = Vec::new();
        for tok in tokens.iter().skip(5) {
            if tok.contains('=') {
                if let Some((k, v)) = tok.split_once('=') {
                    params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
                }
            } else {
                value_parts.push(tok);
            }
        }
        let value = value_parts.join(" ").to_ascii_lowercase();
        if !value.is_empty() {
            params.insert("value".to_string(), value);
        }

        let inst = Instance {
            name,
            primitive,
            symbol: String::new(),
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        let net_names = [np, nm, ncp, ncm];
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }

    /// Shared parser for current-controlled sources (F, H).
    /// SPICE syntax: `name np nm vsource_name value [params]`
    /// 2-pin device; the sensing voltage source is stored as a `vsense` param.
    fn parse_cc_source(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        primitive: Primitive,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 5 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();
        let np = tokens[1].to_ascii_lowercase();
        let nm = tokens[2].to_ascii_lowercase();
        let vsense = tokens[3].to_ascii_lowercase();

        let pins = vec![
            Pin { name: "p".to_string(), dir: PinDir::Output, net_idx: None },
            Pin { name: "n".to_string(), dir: PinDir::Output, net_idx: None },
        ];

        let mut params = HashMap::new();
        params.insert("vsense".to_string(), vsense);

        let mut value_parts: Vec<&str> = Vec::new();
        for tok in tokens.iter().skip(4) {
            if tok.contains('=') {
                if let Some((k, v)) = tok.split_once('=') {
                    params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
                }
            } else {
                value_parts.push(tok);
            }
        }
        let value = value_parts.join(" ").to_ascii_lowercase();
        if !value.is_empty() {
            params.insert("value".to_string(), value);
        }

        let inst = Instance {
            name,
            primitive,
            symbol: String::new(),
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        let net_names = [np, nm];
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }

    fn parse_subckt_instance(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        _line_no: usize,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 3 {
            return Err(ParseError::MissingPins(
                tokens.first().unwrap_or(&"X?").to_ascii_lowercase(),
            ));
        }
        let name = tokens[0].to_ascii_lowercase();

        // Everything after the name: port nets, then subcircuit name, then
        // optional key=value params.  The subcircuit name is the last
        // non-param token.
        let rest = &tokens[1..];

        // Find where params start (first token containing '=').
        let param_start = rest
            .iter()
            .position(|t| t.contains('='))
            .unwrap_or(rest.len());

        // The subcircuit model name is the last token before params.
        if param_start == 0 {
            return Err(ParseError::MissingPins(name));
        }
        let subckt_name_idx = param_start - 1;
        let subckt_name = rest[subckt_name_idx].to_ascii_lowercase();
        let port_tokens: Vec<String> = rest[..subckt_name_idx]
            .iter()
            .map(|t| t.to_ascii_lowercase())
            .collect();

        let pins: Vec<Pin> = port_tokens
            .iter()
            .map(|tok| Pin {
                name: tok.clone(),
                dir: PinDir::Inout,
                net_idx: None,
            })
            .collect();

        let mut params = HashMap::new();
        for tok in &rest[param_start..] {
            if let Some((k, v)) = tok.split_once('=') {
                params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
            }
        }

        let inst = Instance {
            name,
            primitive: Primitive::Subcircuit,
            symbol: subckt_name,
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };

        let idx = self.add_instance_scoped(circuit, inst);
        for (pin_i, tok) in port_tokens.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, tok);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: pin_i as u32,
                },
            );
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Strip the first inline comment delimiter (`;` or `$`) and everything after it.
///
/// The `$` delimiter is used by ngspice and KLayout-extracted netlists.
/// We must be careful not to strip `$` inside escaped net names like `\$13`;
/// a `$` preceded by `\` is part of the identifier, not a comment.
/// Reclassify X-instances whose subcircuit name matches a known MOSFET model.
///
/// Many PDKs (SKY130, IHP SG13G2, GF180MCU) wrap transistors in subcircuits,
/// so the SPICE netlist uses `X` lines instead of `M`.  The parser initially
/// marks these as `Primitive::Subcircuit`.  This pass detects 4-port X-instances
/// whose model name contains `nfet`/`pfet`/`nmos`/`pmos` and converts them to
/// proper MOSFET primitives with labelled D/G/S/B pins.
fn reclassify_subckt_mosfets(circuit: &mut Circuit) {
    reclassify_instances(&mut circuit.top.instances);
    for sub in circuit.subcircuits.values_mut() {
        reclassify_instances(&mut sub.instances);
    }
}

fn reclassify_instances(instances: &mut [Instance]) {
    for inst in instances.iter_mut() {
        if inst.primitive != Primitive::Subcircuit || inst.pins.len() != 4 {
            continue;
        }
        let model = &inst.symbol;
        if !is_mosfet_subckt_name(model) {
            continue;
        }
        inst.primitive = if is_nmos(model) {
            Primitive::Nmos
        } else {
            Primitive::Pmos
        };
        // Store original subcircuit name as model param.
        inst.params.insert("model".to_string(), model.clone());
        // Relabel pins from generic port names to MOSFET convention.
        let pin_names = ["D", "G", "S", "B"];
        let pin_dirs = [PinDir::Inout, PinDir::Input, PinDir::Inout, PinDir::Bulk];
        for (i, pin) in inst.pins.iter_mut().enumerate() {
            if i < 4 {
                pin.name = pin_names[i].to_string();
                pin.dir = pin_dirs[i];
            }
        }
    }
}

/// Check if a subcircuit name looks like a PDK MOSFET wrapper.
fn is_mosfet_subckt_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.contains("nfet") || lower.contains("pfet")
        || lower.contains("nmos") || lower.contains("pmos")
}

fn strip_inline_comment(line: &str) -> &str {
    let bytes = line.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        if b == b';' {
            return line[..i].trim_end();
        }
        if b == b'$' {
            // `\$` is an escaped net name, not a comment.
            if i > 0 && bytes[i - 1] == b'\\' {
                continue;
            }
            // `$` immediately followed by an alphanumeric or `_` is likely
            // an escaped identifier token (e.g. `$13`), not a comment.
            // Treat as comment only when followed by space, EOL, or `*`.
            if let Some(&next) = bytes.get(i + 1) {
                if next != b' ' && next != b'\t' && next != b'*' {
                    continue;
                }
            }
            return line[..i].trim_end();
        }
    }
    line
}

/// Category of a stimulus/analysis dot-command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StimulusCategory {
    Analysis,
    Output,
    Measurement,
    InitialCond,
    Option,
    Other,
}

/// Classify a dot-command into its stimulus category, or `None` if it's not
/// a stimulus command.
fn stimulus_category(cmd: &str) -> Option<StimulusCategory> {
    let lower = cmd.to_ascii_lowercase();
    match lower.as_str() {
        ".tran" | ".ac" | ".dc" | ".op" | ".noise" | ".pz" | ".sens" | ".tf" => {
            Some(StimulusCategory::Analysis)
        }
        ".save" | ".print" | ".plot" | ".probe" => Some(StimulusCategory::Output),
        ".meas" | ".measure" => Some(StimulusCategory::Measurement),
        ".ic" | ".nodeset" => Some(StimulusCategory::InitialCond),
        ".options" | ".option" | ".temp" => Some(StimulusCategory::Option),
        ".step" | ".four" | ".func" | ".csparam" => Some(StimulusCategory::Other),
        _ => None,
    }
}

/// Case-insensitive check: does the model string indicate NMOS?
///
/// First checks for well-known substrings (`nfet`/`pfet`/`nmos`/`pmos`) which
/// handles PDK subcircuit names like `sky130_fd_pr__nfet_01v8` where a stray
/// 'p' in `pr` would fool a naive first-character scan.  Falls back to
/// scanning for the first 'n' or 'p'.  Defaults to NMOS.
fn is_nmos(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    // Explicit substring match — reliable for PDK model names.
    let has_n = lower.contains("nfet") || lower.contains("nmos");
    let has_p = lower.contains("pfet") || lower.contains("pmos");
    if has_n && !has_p {
        return true;
    }
    if has_p && !has_n {
        return false;
    }
    // Ambiguous or no keyword — fall back to first n/p character scan.
    for ch in lower.chars() {
        match ch {
            'n' => return true,
            'p' => return false,
            _ => {}
        }
    }
    true
}

/// Case-insensitive check: does the model string contain "npn"?
fn is_npn(model: &str) -> bool {
    model.to_ascii_lowercase().contains("npn")
}

/// Split a parameter string into individual `key=value` chunks.
///
/// Handles both `key1=val1 key2=val2` and bare `key = val` forms by
/// re-joining around `=`.
fn split_params(s: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();

    for tok in s.split_whitespace() {
        if tok.contains('=') {
            if !current.is_empty() {
                // `current` was the key and this token is `=value` or `key=value`.
                // If current has no '=', merge.
                if !current.contains('=') {
                    current.push_str(tok);
                    result.push(std::mem::take(&mut current));
                    continue;
                } else {
                    result.push(std::mem::take(&mut current));
                }
            }
            current = tok.to_string();
            // If the token has both key and value (e.g. `k=v`), push it.
            if let Some((_k, v)) = tok.split_once('=') {
                if !v.is_empty() {
                    result.push(std::mem::take(&mut current));
                    continue;
                }
            }
        } else if !current.is_empty() {
            // Bare value after `key=`
            current.push_str(tok);
            result.push(std::mem::take(&mut current));
        } else {
            // Bare key before `=` — buffer it.
            current = tok.to_string();
        }
    }
    if !current.is_empty() && current.contains('=') {
        result.push(current);
    }
    result
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // 1. Parse single NMOS line (names lowercased)
    #[test]
    fn parse_single_nmos() {
        let input = "M1 drain gate source bulk nmos_model w=1u l=100n\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "m1"); // lowercased
        assert_eq!(inst.primitive, Primitive::Nmos);
        assert_eq!(inst.pins.len(), 4);
        assert_eq!(inst.pins[0].name, "D");
        assert_eq!(inst.pins[1].name, "G");
        assert_eq!(inst.pins[2].name, "S");
        assert_eq!(inst.pins[3].name, "B");
        assert_eq!(inst.params.get("model").unwrap(), "nmos_model");
        assert_eq!(inst.params.get("w").unwrap(), "1u");
        assert_eq!(inst.params.get("l").unwrap(), "100n");

        // Verify net connections (net names lowercased).
        let drain_net = circuit
            .top
            .nets
            .iter()
            .find(|n| n.name == "drain")
            .unwrap();
        assert!(drain_net.pins.iter().any(|p| p.instance_idx == 0 && p.pin_idx == 0));
    }

    // 2. Parse diff pair (2 NMOS) — shared source net
    #[test]
    fn parse_diff_pair_shared_source() {
        let input = "\
M1 out1 inp  tail bulk nmos_model w=2u l=100n
M2 out2 inn  tail bulk nmos_model w=2u l=100n
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 2);
        assert_eq!(circuit.top.instances[0].name, "m1"); // lowercased
        assert_eq!(circuit.top.instances[1].name, "m2");

        // The "tail" net should be connected to both instances' source pins (pin_idx=2).
        let tail_net = circuit
            .top
            .nets
            .iter()
            .find(|n| n.name == "tail")
            .unwrap();
        assert_eq!(tail_net.pins.len(), 2);
        assert!(tail_net.pins.iter().any(|p| p.instance_idx == 0 && p.pin_idx == 2));
        assert!(tail_net.pins.iter().any(|p| p.instance_idx == 1 && p.pin_idx == 2));
    }

    // 3. Parse with line continuation
    #[test]
    fn parse_line_continuation() {
        let input = "\
M1 drain gate source bulk
+ nmos_model w=1u l=100n
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "m1"); // lowercased
        assert_eq!(inst.primitive, Primitive::Nmos);
        assert_eq!(inst.params.get("w").unwrap(), "1u");
    }

    // 4. Parse .subckt definition — instances go into subcircuit, not top-level
    #[test]
    fn parse_subckt_definition() {
        let input = "\
.subckt inv in out vdd vss
M1 out in vdd vdd pmos_model w=2u l=100n
M2 out in vss vss nmos_model w=1u l=100n
.ends inv
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert!(circuit.subcircuits.contains_key("inv"));
        let sub = &circuit.subcircuits["inv"];
        assert_eq!(sub.ports, vec!["in", "out", "vdd", "vss"]);

        // Instances are now inside the subcircuit (scoped parsing).
        assert_eq!(sub.instances.len(), 2);
        assert_eq!(sub.instances[0].name, "m1");
        assert_eq!(sub.instances[1].name, "m2");

        // Top-level should have NO instances from the subcircuit body.
        assert_eq!(circuit.top.instances.len(), 0);
    }

    // 5. Parse X (subcircuit instance)
    #[test]
    fn parse_subckt_instance() {
        let input = "X1 in out vdd vss inv m=1\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "x1"); // lowercased
        assert_eq!(inst.primitive, Primitive::Subcircuit);
        assert_eq!(inst.symbol, "inv");
        assert_eq!(inst.pins.len(), 4);
        assert_eq!(inst.params.get("m").unwrap(), "1");

        // Verify net connections.
        let in_net = circuit.top.nets.iter().find(|n| n.name == "in").unwrap();
        assert!(in_net.pins.iter().any(|p| p.instance_idx == 0 && p.pin_idx == 0));
    }

    // 6. Parse two-terminal devices (R, C, V) — names lowercased
    #[test]
    fn parse_two_terminal_devices() {
        let input = "\
R1 a b 1k
C1 b gnd 1p
V1 vdd gnd 1.8
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 3);

        let r = &circuit.top.instances[0];
        assert_eq!(r.name, "r1"); // lowercased
        assert_eq!(r.primitive, Primitive::Resistor);
        assert_eq!(r.params.get("value").unwrap(), "1k");

        let c = &circuit.top.instances[1];
        assert_eq!(c.name, "c1");
        assert_eq!(c.primitive, Primitive::Capacitor);
        assert_eq!(c.params.get("value").unwrap(), "1p");

        let v = &circuit.top.instances[2];
        assert_eq!(v.name, "v1");
        assert_eq!(v.primitive, Primitive::Vsource);
        assert_eq!(v.params.get("value").unwrap(), "1.8");
    }

    // 7. Parse BJT (Q)
    #[test]
    fn parse_bjt() {
        let input = "Q1 collector base emitter npn_model\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "q1"); // lowercased
        assert_eq!(inst.primitive, Primitive::Npn);
        assert_eq!(inst.pins.len(), 3);
        assert_eq!(inst.pins[0].name, "C");
        assert_eq!(inst.pins[1].name, "B");
        assert_eq!(inst.pins[2].name, "E");
        assert_eq!(inst.params.get("model").unwrap(), "npn_model");
    }

    // 8. Parse diode (D)
    #[test]
    fn parse_diode() {
        let input = "D1 anode cathode diode_model\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "d1"); // lowercased
        assert_eq!(inst.primitive, Primitive::Diode);
        assert_eq!(inst.pins.len(), 2);
        assert_eq!(inst.pins[0].name, "A");
        assert_eq!(inst.pins[1].name, "K");
        assert_eq!(inst.params.get("model").unwrap(), "diode_model");
    }

    // 9. Parse .global directive
    #[test]
    fn parse_global_directive() {
        let input = "\
.global VDD VSS
M1 out in VDD VDD nmos_model
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert!(parser.globals().contains(&"vdd".to_string())); // lowercased
        assert!(parser.globals().contains(&"vss".to_string()));

        // Nets that were actually used and declared global should be marked.
        let vdd_net = circuit.top.nets.iter().find(|n| n.name == "vdd").unwrap();
        assert!(vdd_net.is_global);
    }

    // 10. Parse comments (skip * lines, strip ; inline)
    #[test]
    fn parse_comments() {
        let input = "\
* This is a comment
M1 drain gate source bulk nmos_model ; inline comment here
* Another comment
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "m1"); // lowercased
        assert_eq!(inst.primitive, Primitive::Nmos);
        // The inline comment must not pollute the model or params.
        assert_eq!(inst.params.get("model").unwrap(), "nmos_model");
    }

    // 11. Parse .param lines (store key=value, lowercased)
    #[test]
    fn parse_param_lines() {
        let input = "\
.param vdd_val=1.8
.param ibias=10u gm=1m
";
        let mut parser = SpiceParser::new();
        let _circuit = parser.parse(input).unwrap();

        assert_eq!(parser.params().get("vdd_val").unwrap(), "1.8");
        assert_eq!(parser.params().get("ibias").unwrap(), "10u");
        assert_eq!(parser.params().get("gm").unwrap(), "1m");
    }

    // 12. Parse custom pragmas
    #[test]
    fn parse_custom_pragmas() {
        let input = "\
* .xs_pragma mirror M1 M2
* .xs_pragma diffpair M3 M4 symmetry=true
M1 d g s b nmos_model
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(parser.pragmas().len(), 2);
        assert_eq!(parser.pragmas()[0].directive, "mirror");
        assert_eq!(parser.pragmas()[0].args, vec!["M1", "M2"]);
        assert_eq!(parser.pragmas()[1].directive, "diffpair");
        assert_eq!(
            parser.pragmas()[1].args,
            vec!["M3", "M4", "symmetry=true"]
        );

        // The device line should still parse.
        assert_eq!(circuit.top.instances.len(), 1);
    }

    // 13. Error on malformed input (missing pins)
    #[test]
    fn error_missing_pins() {
        // MOSFET needs at least 6 tokens (name + 4 pins + model).
        let input = "M1 drain gate\n";
        let mut parser = SpiceParser::new();
        let result = parser.parse(input);
        assert!(result.is_err());
        match result.unwrap_err() {
            ParseError::MissingPins(name) => assert_eq!(name, "m1"), // lowercased
            other => panic!("expected MissingPins, got {:?}", other),
        }
    }

    // Extra: PNP BJT detection
    #[test]
    fn parse_pnp_bjt() {
        let input = "Q2 c b e pnp_model\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances[0].primitive, Primitive::Pnp);
    }

    // Extra: PMOS detection
    #[test]
    fn parse_pmos() {
        let input = "M1 d g s b pmos_3v3 w=4u l=300n\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances[0].primitive, Primitive::Pmos);
    }

    // Extra: inductor
    #[test]
    fn parse_inductor() {
        let input = "L1 a b 10n\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances[0].primitive, Primitive::Inductor);
        assert_eq!(circuit.top.instances[0].params.get("value").unwrap(), "10n");
    }

    // Extra: current source
    #[test]
    fn parse_isource() {
        let input = "I1 vdd tail 100u\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances[0].primitive, Primitive::Isource);
    }

    // Extra: empty input
    #[test]
    fn parse_empty_input() {
        let mut parser = SpiceParser::new();
        let circuit = parser.parse("").unwrap();
        assert!(circuit.top.instances.is_empty());
        assert!(circuit.top.nets.is_empty());
    }

    // Extra: multiple continuations
    #[test]
    fn parse_multiple_continuations() {
        let input = "\
M1 drain gate
+ source bulk
+ nmos_model w=1u
+ l=100n
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.params.get("w").unwrap(), "1u");
        assert_eq!(inst.params.get("l").unwrap(), "100n");
    }

    // Extra: subcircuit instance without params
    #[test]
    fn parse_subckt_instance_no_params() {
        let input = "X1 in out vdd vss myamp\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.symbol, "myamp");
        assert_eq!(inst.pins.len(), 4);
        assert!(inst.params.is_empty());
    }

    // Extra: case insensitivity of device prefix
    #[test]
    fn parse_case_insensitive_prefix() {
        let input = "m1 d g s b NMOS_MODEL\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances.len(), 1);
        assert_eq!(circuit.top.instances[0].primitive, Primitive::Nmos);
    }

    // Extra: .end is not an error
    #[test]
    fn parse_dot_end() {
        let input = "\
M1 d g s b nmos_model
.end
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        assert_eq!(circuit.top.instances.len(), 1);
    }

    // -----------------------------------------------------------------------
    // New Phase 1 tests
    // -----------------------------------------------------------------------

    // 14. Case normalization: "VDD" parsed as "vdd" in net names
    #[test]
    fn case_normalization_net_names() {
        let input = "M1 OUT IN VDD VDD NMOS_MODEL w=1u\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "m1");
        assert_eq!(inst.params.get("model").unwrap(), "nmos_model");

        // All net names should be lowercase.
        let net_names: Vec<&str> = circuit.top.nets.iter().map(|n| n.name.as_str()).collect();
        assert!(net_names.contains(&"out"));
        assert!(net_names.contains(&"in"));
        assert!(net_names.contains(&"vdd"));
        assert!(!net_names.contains(&"VDD"));
        assert!(!net_names.contains(&"OUT"));
    }

    // 15. .model parsing: extract type and params
    #[test]
    fn parse_model_definition() {
        let input = ".model nmos_3v3 nmos (vth0=0.5 tox=7n)\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert!(circuit.models.contains_key("nmos_3v3"));
        let model = &circuit.models["nmos_3v3"];
        assert_eq!(model.model_type, "nmos");
        assert_eq!(model.params.get("vth0").unwrap(), "0.5");
        assert_eq!(model.params.get("tox").unwrap(), "7n");
    }

    // 16. .model without params
    #[test]
    fn parse_model_no_params() {
        let input = ".model pmos_model PMOS\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert!(circuit.models.contains_key("pmos_model"));
        let model = &circuit.models["pmos_model"];
        assert_eq!(model.model_type, "pmos");
        assert!(model.params.is_empty());
    }

    // 17. Subcircuit scoping: instances inside .subckt go to that subcircuit
    #[test]
    fn subckt_scoping() {
        let input = "\
.subckt amp inp inn out vdd vss
M1 out inp vdd vdd pmos_model w=4u l=100n
M2 out inn vss vss nmos_model w=2u l=100n
.ends amp
R1 a b 1k
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        // M1 and M2 should be inside the subcircuit, not top-level.
        assert!(circuit.subcircuits.contains_key("amp"));
        let sub = &circuit.subcircuits["amp"];
        assert_eq!(sub.instances.len(), 2);
        assert_eq!(sub.instances[0].name, "m1");
        assert_eq!(sub.instances[1].name, "m2");

        // R1 is top-level (after .ends).
        assert_eq!(circuit.top.instances.len(), 1);
        assert_eq!(circuit.top.instances[0].name, "r1");
    }

    // 18. .param evaluation: param values resolved to f64
    #[test]
    fn param_evaluation() {
        let input = "\
.param width=10u
.param length=100n
.param ratio=width/length
";
        let mut parser = SpiceParser::new();
        let _circuit = parser.parse(input).unwrap();

        let resolved = parser.resolved_params();
        assert!((resolved["width"] - 10e-6).abs() < 1e-18);
        assert!((resolved["length"] - 100e-9).abs() < 1e-21);
        assert!((resolved["ratio"] - 100.0).abs() < 1e-6);
    }

    // 19. .param with expression
    #[test]
    fn param_expression_evaluation() {
        let input = "\
.param vdd_nom=1.8
.param half_vdd=vdd_nom/2
";
        let mut parser = SpiceParser::new();
        let _circuit = parser.parse(input).unwrap();

        let resolved = parser.resolved_params();
        assert!((resolved["vdd_nom"] - 1.8).abs() < 1e-12);
        assert!((resolved["half_vdd"] - 0.9).abs() < 1e-12);
    }

    // 20. Nested subcircuits with scoping
    #[test]
    fn nested_subcircuit_scoping() {
        let input = "\
.subckt outer a b
M1 a b 0 0 nmos_model
.ends outer
.subckt inner c d
M2 c d 0 0 pmos_model
.ends inner
X1 net1 net2 outer
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        // Each subcircuit should contain its own instances.
        assert_eq!(circuit.subcircuits["outer"].instances.len(), 1);
        assert_eq!(circuit.subcircuits["outer"].instances[0].name, "m1");
        assert_eq!(circuit.subcircuits["inner"].instances.len(), 1);
        assert_eq!(circuit.subcircuits["inner"].instances[0].name, "m2");

        // X1 is top-level.
        assert_eq!(circuit.top.instances.len(), 1);
        assert_eq!(circuit.top.instances[0].name, "x1");
    }

    // 21. Subcircuit nets are scoped
    #[test]
    fn subckt_nets_scoped() {
        let input = "\
.subckt inv in out vdd vss
M1 out in vdd vdd pmos_model
M2 out in vss vss nmos_model
.ends inv
M3 top_net1 top_net2 0 0 nmos_model
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        let sub = &circuit.subcircuits["inv"];
        let sub_net_names: Vec<&str> = sub.nets.iter().map(|n| n.name.as_str()).collect();
        assert!(sub_net_names.contains(&"out"));
        assert!(sub_net_names.contains(&"in"));
        assert!(sub_net_names.contains(&"vdd"));
        assert!(sub_net_names.contains(&"vss"));

        // Top-level nets should NOT contain the subcircuit's nets.
        let top_net_names: Vec<&str> = circuit.top.nets.iter().map(|n| n.name.as_str()).collect();
        assert!(top_net_names.contains(&"top_net1"));
        assert!(top_net_names.contains(&"top_net2"));
        assert!(top_net_names.contains(&"0"));
    }

    // 22. Stimulus/analysis commands are categorized
    #[test]
    fn stimulus_lines_collected() {
        let input = "\
R1 a b 1k
V1 a 0 1.8
.tran 1n 100u
.ac dec 10 1 1G
.dc V1 0 5 0.1
.op
.meas tran vout_avg AVG V(b) FROM=10u TO=100u
.save all
.print tran V(a) V(b)
.ic V(b)=0
.options reltol=1e-4
.end
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.top.instances.len(), 2);
        let a = &circuit.analysis;
        assert_eq!(a.analyses, &[".tran 1n 100u", ".ac dec 10 1 1G", ".dc V1 0 5 0.1", ".op"]);
        assert_eq!(a.measurements, &[".meas tran vout_avg AVG V(b) FROM=10u TO=100u"]);
        assert_eq!(a.outputs, &[".save all", ".print tran V(a) V(b)"]);
        assert_eq!(a.initial_conds, &[".ic V(b)=0"]);
        assert_eq!(a.options, &[".options reltol=1e-4"]);
        assert!(a.control_blocks.is_empty());
        assert!(a.includes.is_empty());
    }

    // 23. Control block is captured as single joined string
    #[test]
    fn control_block_captured() {
        let input = "\
R1 a b 1k
.control
tran 1n 100u
plot V(a) V(b)
.endc
.end
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.analysis.control_blocks.len(), 1);
        assert_eq!(
            circuit.analysis.control_blocks[0],
            ".control\ntran 1n 100u\nplot V(a) V(b)\n.endc"
        );
    }

    // 24. Source value spec (PULSE/SIN/etc.) captured fully
    #[test]
    fn source_value_full_spec() {
        let input = "V1 inp 0 PULSE(0 1.8 0 1n 1n 5u 10u)\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        let v = &circuit.top.instances[0];
        assert_eq!(v.primitive, Primitive::Vsource);
        assert_eq!(
            v.params.get("value").unwrap(),
            "pulse(0 1.8 0 1n 1n 5u 10u)"
        );
    }

    // 25. Source with DC + AC spec captured
    #[test]
    fn source_dc_ac_spec() {
        let input = "V1 a 0 DC 1.8 AC 1\n";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        let v = &circuit.top.instances[0];
        assert_eq!(v.params.get("value").unwrap(), "dc 1.8 ac 1");
    }

    // 26. .include and .lib go into includes (not analysis)
    #[test]
    fn include_lib_preserved() {
        let input = "\
.include \"/pdk/models.lib\"
.lib \"/pdk/corners.lib\" tt
R1 a b 1k
.end
";
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();

        assert_eq!(circuit.analysis.includes.len(), 2);
        assert!(circuit.analysis.includes[0].contains(".include"));
        assert!(circuit.analysis.includes[1].contains(".lib"));
        // Not in analyses
        assert!(circuit.analysis.analyses.is_empty());
    }
}
