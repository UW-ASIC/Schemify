//! SPICE netlist parser (ngspice-compatible subset).
//!
//! Merged port of the old `parser/{mod,expr,params}.rs` modules:
//! line pre-processing (continuation joining, comment stripping), device-card
//! dispatch, `.subckt` scope handling, dot-command categorization, the
//! parameter expression evaluator, and `.param` resolution/substitution.

use std::collections::HashMap;

use thiserror::Error;

use crate::ir::{
    Circuit, DiagnosticKind, InstId, Instance, Model, NetId, ParseDiagnostic, Pin, PinDir, PinIdx,
    PinRef, Primitive, Subcircuit,
};

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("unknown element prefix: {0}")]
    UnknownElement(char),
    #[error("missing pins for device `{0}`")]
    MissingPins(String),
    #[error("invalid syntax on line {line}: {message}")]
    InvalidSyntax { line: usize, message: String },
}

#[derive(Debug, Error)]
pub enum ExprError {
    #[error("undefined variable: `{0}`")]
    UndefinedVariable(String),
    #[error("unexpected character: `{0}`")]
    UnexpectedChar(char),
    #[error("unexpected end of expression")]
    UnexpectedEnd,
    #[error("unknown function: `{0}`")]
    UnknownFunction(String),
    #[error("expected `{0}`")]
    Expected(String),
    #[error("invalid number: `{0}`")]
    InvalidNumber(String),
    #[error("division by zero")]
    DivisionByZero,
    #[error("math domain error in `{0}`")]
    MathDomainError(String),
}

// ---------------------------------------------------------------------------
// SpiceParser
// ---------------------------------------------------------------------------

/// SPICE netlist parser.  After [`SpiceParser::parse`], the auxiliary data
/// (`.param` key-value pairs and `.global` nets) is available through
/// accessor methods.
#[derive(Default)]
pub struct SpiceParser {
    /// `.param` key-value pairs (raw strings) collected during parsing.
    params: HashMap<String, String>,
    /// `.param` values resolved to f64 via expression evaluation.
    resolved_params: HashMap<String, f64>,
    /// `.global` net names.
    globals: Vec<String>,
    /// Scope stack for subcircuit nesting (empty = top-level).
    scope_stack: Vec<String>,
    /// True while inside a `.control` / `.endc` block.
    in_control_block: bool,
    /// Accumulator for lines inside the current `.control` block.
    control_buf: String,
}

impl SpiceParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn params(&self) -> &HashMap<String, String> {
        &self.params
    }

    pub fn resolved_params(&self) -> &HashMap<String, f64> {
        &self.resolved_params
    }

    pub fn globals(&self) -> &[String] {
        &self.globals
    }

    /// Parse a SPICE netlist from `source` and return the populated [`Circuit`].
    pub fn parse(&mut self, source: &str) -> Result<Circuit, ParseError> {
        let mut circuit = Circuit::new("top");

        // Reset auxiliary state so the parser is reusable.
        self.params.clear();
        self.resolved_params.clear();
        self.globals.clear();
        self.scope_stack.clear();
        self.in_control_block = false;

        for (line_no, line) in preprocess(source).iter().enumerate() {
            self.parse_line(&mut circuit, line, line_no + 1)?;
        }

        self.resolved_params = resolve_params(&self.params);
        substitute_params(&mut circuit, &self.resolved_params);
        reclassify_subckt_mosfets(&mut circuit);

        // Mark global nets in the top scope and all subcircuits.
        for gname in &self.globals {
            for net in &mut circuit.top.nets {
                if net.name == *gname {
                    net.is_global = true;
                }
            }
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

    fn in_subckt(&self) -> bool {
        !self.scope_stack.is_empty()
    }

    fn current_subckt_name(&self) -> &str {
        self.scope_stack.last().unwrap()
    }
}

// ---------------------------------------------------------------------------
// Pre-processing (continuation, comments)
// ---------------------------------------------------------------------------

/// Join continuation lines (`+` prefix), strip full-line (`*`) and inline
/// (`;` / `$`) comments, and return the logical lines ready for parsing.
fn preprocess(source: &str) -> Vec<String> {
    let mut logical_lines: Vec<String> = Vec::new();

    for raw in source.lines() {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('*') {
            continue;
        }

        let effective = strip_inline_comment(trimmed);
        if effective.is_empty() {
            continue;
        }

        if let Some(rest) = effective.strip_prefix('+') {
            if let Some(last) = logical_lines.last_mut() {
                last.push(' ');
                last.push_str(rest.trim());
            }
            continue;
        }

        logical_lines.push(effective.to_string());
    }

    logical_lines
}

/// Strip the first inline comment delimiter (`;` or `$`) and everything after.
///
/// The `$` delimiter is used by ngspice and KLayout-extracted netlists.
/// A `$` preceded by `\` is part of an escaped net name (`\$13`), not a
/// comment, and `$` immediately followed by a non-space, non-`*` character
/// is treated as part of an identifier token.
pub fn strip_inline_comment(line: &str) -> &str {
    let bytes = line.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        if b == b';' {
            return line[..i].trim_end();
        }
        if b == b'$' {
            if i > 0 && bytes[i - 1] == b'\\' {
                continue;
            }
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

// ---------------------------------------------------------------------------
// Line dispatcher and scoped helpers
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

        if trimmed.starts_with('.') {
            return self.parse_dot_command(circuit, trimmed, line_no);
        }

        let prefix = trimmed.chars().next().unwrap().to_ascii_lowercase();
        match prefix {
            'm' => self.parse_mosfet(circuit, trimmed),
            'q' => self.parse_bjt(circuit, trimmed),
            'r' => self.parse_two_terminal(circuit, trimmed, Primitive::Resistor),
            'c' => self.parse_two_terminal(circuit, trimmed, Primitive::Capacitor),
            'l' => self.parse_two_terminal(circuit, trimmed, Primitive::Inductor),
            'd' => self.parse_diode(circuit, trimmed),
            'v' => self.parse_two_terminal(circuit, trimmed, Primitive::Vsource),
            'i' => self.parse_two_terminal(circuit, trimmed, Primitive::Isource),
            'e' => self.parse_vc_source(circuit, trimmed, Primitive::Vcvs),
            'g' => self.parse_vc_source(circuit, trimmed, Primitive::Vccs),
            'f' => self.parse_cc_source(circuit, trimmed, Primitive::Cccs),
            'h' => self.parse_cc_source(circuit, trimmed, Primitive::Ccvs),
            'j' => self.parse_jfet(circuit, trimmed),
            'b' => self.parse_behavioral_source(circuit, trimmed),
            'x' => self.parse_subckt_instance(circuit, trimmed),
            other => {
                circuit.diagnostics.push(ParseDiagnostic {
                    line_no,
                    kind: DiagnosticKind::UnknownDevicePrefix(other),
                });
                Ok(())
            }
        }
    }

    /// Add an instance to the correct scope (current subckt or top-level).
    fn add_instance_scoped(&self, circuit: &mut Circuit, inst: Instance) -> InstId {
        if self.in_subckt() {
            let sub = circuit
                .subcircuits
                .get_mut(self.current_subckt_name())
                .unwrap();
            let idx = InstId(sub.instances.len() as u32);
            sub.instances.push(inst);
            idx
        } else {
            circuit.add_instance(inst)
        }
    }

    /// Get or create a net in the correct scope.
    fn get_or_create_net_scoped(&self, circuit: &mut Circuit, name: &str) -> NetId {
        if self.in_subckt() {
            let sub = circuit
                .subcircuits
                .get_mut(self.current_subckt_name())
                .unwrap();
            for (i, net) in sub.nets.iter().enumerate() {
                if net.name == name {
                    return NetId(i as u32);
                }
            }
            let idx = NetId(sub.nets.len() as u32);
            sub.nets.push(crate::ir::Net::new(name));
            idx
        } else {
            circuit.get_or_create_net(name)
        }
    }

    /// Connect a pin to a net in the correct scope.
    fn connect_scoped(&self, circuit: &mut Circuit, net_idx: NetId, pin_ref: PinRef) {
        if self.in_subckt() {
            let sub = circuit
                .subcircuits
                .get_mut(self.current_subckt_name())
                .unwrap();
            sub[net_idx].pins.push(pin_ref);
            sub[pin_ref.instance_idx].pins[pin_ref.pin_idx.index()].net_idx = Some(net_idx);
        } else {
            circuit.connect(net_idx, pin_ref);
        }
    }

    /// Build an instance, add it to the current scope, and connect each of
    /// `net_names` to the pin of matching index.
    #[allow(clippy::too_many_arguments)]
    fn add_device(
        &self,
        circuit: &mut Circuit,
        name: String,
        primitive: Primitive,
        symbol: String,
        pins: Vec<Pin>,
        params: HashMap<String, String>,
        net_names: &[String],
    ) {
        let inst = Instance {
            name,
            primitive,
            symbol,
            pins,
            params,
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        };
        let idx = self.add_instance_scoped(circuit, inst);
        for (pin_i, net_name) in net_names.iter().enumerate() {
            let net_idx = self.get_or_create_net_scoped(circuit, net_name);
            self.connect_scoped(
                circuit,
                net_idx,
                PinRef {
                    instance_idx: idx,
                    pin_idx: PinIdx(pin_i as u16),
                },
            );
        }
    }
}

/// Build a pin list from parallel name/direction slices.
fn mk_pins(names: &[&str], dirs: &[PinDir]) -> Vec<Pin> {
    names
        .iter()
        .zip(dirs)
        .map(|(n, &dir)| Pin {
            name: n.to_string(),
            dir,
            net_idx: None,
        })
        .collect()
}

/// Collect trailing device tokens: `key=value` tokens go into `params`
/// (values lowercased unless `keep_value_case`); bare tokens are joined,
/// lowercased, and stored as the `value` param (multi-token stimulus specs
/// like `PULSE(0 1.8 0 1n)` or `DC 1.8 AC 1`).
fn collect_kv_and_value(
    tokens: &[&str],
    params: &mut HashMap<String, String>,
    keep_value_case: bool,
) {
    let mut value_parts: Vec<&str> = Vec::new();
    for tok in tokens {
        if let Some((k, v)) = tok.split_once('=') {
            let v = if keep_value_case {
                v.to_string()
            } else {
                v.to_ascii_lowercase()
            };
            params.insert(k.to_ascii_lowercase(), v);
        } else {
            value_parts.push(tok);
        }
    }
    let value = value_parts.join(" ").to_ascii_lowercase();
    if !value.is_empty() {
        params.insert("value".to_string(), value);
    }
}

fn missing_pins(tokens: &[&str], fallback: &str) -> ParseError {
    ParseError::MissingPins(tokens.first().unwrap_or(&fallback).to_ascii_lowercase())
}

// ---------------------------------------------------------------------------
// Dot-command parsing
// ---------------------------------------------------------------------------

impl SpiceParser {
    fn parse_dot_command(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        line_no: usize,
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
            self.scope_stack.pop();
        } else if cmd.eq_ignore_ascii_case(".end") {
            self.scope_stack.clear();
        } else if cmd.eq_ignore_ascii_case(".global") {
            for tok in &tokens[1..] {
                self.globals.push(tok.to_ascii_lowercase());
            }
        } else if cmd.eq_ignore_ascii_case(".param") {
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
                let model_type = tokens[2]
                    .trim_start_matches('(')
                    .trim_end_matches(')')
                    .to_ascii_lowercase();

                let mut model_params = HashMap::new();
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

                circuit.models.insert(
                    model_name.clone(),
                    Model {
                        name: model_name,
                        model_type,
                        params: model_params,
                    },
                );
            }
        } else if cmd.eq_ignore_ascii_case(".include") || cmd.eq_ignore_ascii_case(".lib") {
            circuit.analysis.includes.push(line.to_string());
        } else if cmd.eq_ignore_ascii_case(".control") {
            self.control_buf = format!("{line}\n");
            self.in_control_block = true;
        } else if let Some(cat) = stimulus_category(cmd) {
            let bucket = match cat {
                StimulusCategory::Analysis => &mut circuit.analysis.analyses,
                StimulusCategory::Output => &mut circuit.analysis.outputs,
                StimulusCategory::Measurement => &mut circuit.analysis.measurements,
                StimulusCategory::InitialCond => &mut circuit.analysis.initial_conds,
                StimulusCategory::Option => &mut circuit.analysis.options,
                StimulusCategory::Other => &mut circuit.analysis.other,
            };
            bucket.push(line.to_string());
        } else {
            circuit.diagnostics.push(ParseDiagnostic {
                line_no,
                kind: DiagnosticKind::UnknownDotCommand(cmd.to_string()),
            });
        }

        Ok(())
    }
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
    match cmd.to_ascii_lowercase().as_str() {
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

// ---------------------------------------------------------------------------
// Device-card parsers
// ---------------------------------------------------------------------------

impl SpiceParser {
    /// `Mname d g s b model [k=v ...]`
    fn parse_mosfet(&mut self, circuit: &mut Circuit, line: &str) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 6 {
            return Err(missing_pins(&tokens, "M?"));
        }
        let nets: Vec<String> = tokens[1..5].iter().map(|t| t.to_ascii_lowercase()).collect();
        let model = tokens[5].to_ascii_lowercase();
        let primitive = if is_nmos(&model) {
            Primitive::Nmos
        } else {
            Primitive::Pmos
        };

        let mut params = HashMap::new();
        params.insert("model".to_string(), model);
        for tok in &tokens[6..] {
            if let Some((k, v)) = tok.split_once('=') {
                params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
            }
        }

        let pins = mk_pins(
            &["D", "G", "S", "B"],
            &[PinDir::Inout, PinDir::Input, PinDir::Inout, PinDir::Bulk],
        );
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            primitive,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// `Qname c b e model`
    fn parse_bjt(&mut self, circuit: &mut Circuit, line: &str) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 5 {
            return Err(missing_pins(&tokens, "Q?"));
        }
        let nets: Vec<String> = tokens[1..4].iter().map(|t| t.to_ascii_lowercase()).collect();
        let model = tokens[4].to_ascii_lowercase();
        let primitive = if is_npn(&model) {
            Primitive::Npn
        } else {
            Primitive::Pnp
        };

        let mut params = HashMap::new();
        params.insert("model".to_string(), model);

        let pins = mk_pins(
            &["C", "B", "E"],
            &[PinDir::Inout, PinDir::Input, PinDir::Inout],
        );
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            primitive,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// `Jname d g s model [k=v ...]`
    fn parse_jfet(&mut self, circuit: &mut Circuit, line: &str) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 5 {
            return Err(missing_pins(&tokens, "J?"));
        }
        let nets: Vec<String> = tokens[1..4].iter().map(|t| t.to_ascii_lowercase()).collect();

        let mut params = HashMap::new();
        params.insert("model".to_string(), tokens[4].to_ascii_lowercase());
        for tok in &tokens[5..] {
            if let Some((k, v)) = tok.split_once('=') {
                params.insert(k.to_ascii_lowercase(), v.to_ascii_lowercase());
            }
        }

        let pins = mk_pins(
            &["D", "G", "S"],
            &[PinDir::Inout, PinDir::Input, PinDir::Inout],
        );
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            Primitive::Jfet,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// `Bname p n V={expr}` / `Bname p n I={expr}` — expression case preserved.
    fn parse_behavioral_source(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 4 {
            return Err(missing_pins(&tokens, "B?"));
        }
        let nets: Vec<String> = tokens[1..3].iter().map(|t| t.to_ascii_lowercase()).collect();

        let mut params = HashMap::new();
        collect_kv_and_value(&tokens[3..], &mut params, true);

        let pins = mk_pins(&["p", "n"], &[PinDir::Inout, PinDir::Inout]);
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            Primitive::BehavioralSource,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// `Rname p n value [k=v ...]` — also C, L, V, I.
    fn parse_two_terminal(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        primitive: Primitive,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 3 {
            return Err(missing_pins(&tokens, "?"));
        }
        let nets: Vec<String> = tokens[1..3].iter().map(|t| t.to_ascii_lowercase()).collect();

        let mut params = HashMap::new();
        collect_kv_and_value(&tokens[3..], &mut params, false);

        let pins = mk_pins(&["p", "n"], &[PinDir::Inout, PinDir::Inout]);
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            primitive,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// `Dname anode cathode [model]`
    fn parse_diode(&mut self, circuit: &mut Circuit, line: &str) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 3 {
            return Err(missing_pins(&tokens, "D?"));
        }
        let nets: Vec<String> = tokens[1..3].iter().map(|t| t.to_ascii_lowercase()).collect();

        let mut params = HashMap::new();
        if let Some(model) = tokens.get(3) {
            params.insert("model".to_string(), model.to_ascii_lowercase());
        }

        let pins = mk_pins(&["A", "K"], &[PinDir::Inout, PinDir::Inout]);
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            Primitive::Diode,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// Voltage-controlled sources (E = VCVS, G = VCCS):
    /// `name np nm ncp ncm value [k=v ...]`
    fn parse_vc_source(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        primitive: Primitive,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 6 {
            return Err(missing_pins(&tokens, "?"));
        }
        let nets: Vec<String> = tokens[1..5].iter().map(|t| t.to_ascii_lowercase()).collect();

        let mut params = HashMap::new();
        collect_kv_and_value(&tokens[5..], &mut params, false);

        let pins = mk_pins(
            &["p", "n", "cp", "cn"],
            &[
                PinDir::Output,
                PinDir::Output,
                PinDir::Input,
                PinDir::Input,
            ],
        );
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            primitive,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// Current-controlled sources (F = CCCS, H = CCVS):
    /// `name np nm vsource value [k=v ...]` — the sensing source is stored
    /// as the `vsense` param.
    fn parse_cc_source(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
        primitive: Primitive,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 5 {
            return Err(missing_pins(&tokens, "?"));
        }
        let nets: Vec<String> = tokens[1..3].iter().map(|t| t.to_ascii_lowercase()).collect();

        let mut params = HashMap::new();
        params.insert("vsense".to_string(), tokens[3].to_ascii_lowercase());
        collect_kv_and_value(&tokens[4..], &mut params, false);

        let pins = mk_pins(&["p", "n"], &[PinDir::Output, PinDir::Output]);
        self.add_device(
            circuit,
            tokens[0].to_ascii_lowercase(),
            primitive,
            String::new(),
            pins,
            params,
            &nets,
        );
        Ok(())
    }

    /// `Xname net1 net2 ... subckt_name [k=v ...]`
    fn parse_subckt_instance(
        &mut self,
        circuit: &mut Circuit,
        line: &str,
    ) -> Result<(), ParseError> {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 3 {
            return Err(missing_pins(&tokens, "X?"));
        }
        let name = tokens[0].to_ascii_lowercase();
        let rest = &tokens[1..];

        // The subcircuit model name is the last non-param token.
        let param_start = rest
            .iter()
            .position(|t| t.contains('='))
            .unwrap_or(rest.len());
        if param_start == 0 {
            return Err(ParseError::MissingPins(name));
        }
        let subckt_name = rest[param_start - 1].to_ascii_lowercase();
        let port_nets: Vec<String> = rest[..param_start - 1]
            .iter()
            .map(|t| t.to_ascii_lowercase())
            .collect();

        let pins: Vec<Pin> = port_nets
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

        self.add_device(
            circuit,
            name,
            Primitive::Subcircuit,
            subckt_name,
            pins,
            params,
            &port_nets,
        );
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Post-parse helpers
// ---------------------------------------------------------------------------

/// Reclassify X-instances whose subcircuit name matches a known MOSFET model.
///
/// Many PDKs (SKY130, IHP SG13G2, GF180MCU) wrap transistors in subcircuits,
/// so the netlist uses `X` lines instead of `M`.  This pass detects 4-port
/// X-instances whose model name contains `nfet`/`pfet`/`nmos`/`pmos` and
/// converts them to MOSFET primitives with labelled D/G/S/B pins.
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
        inst.params.insert("model".to_string(), model.clone());
        let pin_names = ["D", "G", "S", "B"];
        let pin_dirs = [PinDir::Inout, PinDir::Input, PinDir::Inout, PinDir::Bulk];
        for (i, pin) in inst.pins.iter_mut().enumerate().take(4) {
            pin.name = pin_names[i].to_string();
            pin.dir = pin_dirs[i];
        }
    }
}

/// Check if a subcircuit name looks like a PDK MOSFET wrapper.
fn is_mosfet_subckt_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.contains("nfet")
        || lower.contains("pfet")
        || lower.contains("nmos")
        || lower.contains("pmos")
}

/// Case-insensitive check: does the model string indicate NMOS?
///
/// First checks for well-known substrings (`nfet`/`pfet`/`nmos`/`pmos`) which
/// handles PDK subcircuit names like `sky130_fd_pr__nfet_01v8` where a stray
/// 'p' in `pr` would fool a naive first-character scan.  Falls back to
/// scanning for the first 'n' or 'p'.  Defaults to NMOS.
fn is_nmos(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    let has_n = lower.contains("nfet") || lower.contains("nmos");
    let has_p = lower.contains("pfet") || lower.contains("pmos");
    if has_n && !has_p {
        return true;
    }
    if has_p && !has_n {
        return false;
    }
    for ch in lower.chars() {
        match ch {
            'n' => return true,
            'p' => return false,
            _ => {}
        }
    }
    true
}

fn is_npn(model: &str) -> bool {
    model.to_ascii_lowercase().contains("npn")
}

/// Split a parameter string into individual `key=value` chunks.
///
/// Handles both `key1=val1 key2=val2` and spaced `key = val` forms by
/// re-joining around `=`.
fn split_params(s: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();

    for tok in s.split_whitespace() {
        if tok.contains('=') {
            if !current.is_empty() {
                if !current.contains('=') {
                    // `current` was a bare key; this token is `=value` or `=`.
                    current.push_str(tok);
                    result.push(std::mem::take(&mut current));
                    continue;
                } else {
                    result.push(std::mem::take(&mut current));
                }
            }
            current = tok.to_string();
            if let Some((_k, v)) = tok.split_once('=') {
                if !v.is_empty() {
                    result.push(std::mem::take(&mut current));
                    continue;
                }
            }
        } else if !current.is_empty() {
            // Bare value after `key=`.
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
// Expression evaluator (tokenize -> parse -> eval)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Number(f64),
    Ident(String),
    Plus,
    Minus,
    Star,
    Slash,
    DoubleStar,
    LParen,
    RParen,
    Comma,
}

fn tokenize(input: &str) -> Result<Vec<Token>, ExprError> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = input.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        let ch = chars[i];
        if ch.is_ascii_whitespace() {
            i += 1;
            continue;
        }

        match ch {
            '+' => {
                tokens.push(Token::Plus);
                i += 1;
            }
            '-' => {
                tokens.push(Token::Minus);
                i += 1;
            }
            '*' => {
                if i + 1 < len && chars[i + 1] == '*' {
                    tokens.push(Token::DoubleStar);
                    i += 2;
                } else {
                    tokens.push(Token::Star);
                    i += 1;
                }
            }
            '/' => {
                tokens.push(Token::Slash);
                i += 1;
            }
            '(' => {
                tokens.push(Token::LParen);
                i += 1;
            }
            ')' => {
                tokens.push(Token::RParen);
                i += 1;
            }
            ',' => {
                tokens.push(Token::Comma);
                i += 1;
            }
            _ if ch.is_ascii_digit() || ch == '.' => {
                // Number with optional scientific notation and eng suffix.
                let start = i;
                while i < len
                    && (chars[i].is_ascii_digit()
                        || chars[i] == '.'
                        || chars[i] == 'e'
                        || chars[i] == 'E')
                {
                    if (chars[i] == 'e' || chars[i] == 'E')
                        && i + 1 < len
                        && (chars[i + 1] == '+' || chars[i + 1] == '-')
                    {
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
                let num_str: String = chars[start..i].iter().collect();

                let (suffix_mult, suffix_len) = parse_eng_suffix(&chars, i);
                i += suffix_len;

                let base_val: f64 = num_str
                    .parse()
                    .map_err(|_| ExprError::InvalidNumber(num_str.clone()))?;
                tokens.push(Token::Number(base_val * suffix_mult));
            }
            _ if ch.is_ascii_alphabetic() || ch == '_' => {
                let start = i;
                while i < len && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
                tokens.push(Token::Ident(chars[start..i].iter().collect()));
            }
            _ => return Err(ExprError::UnexpectedChar(ch)),
        }
    }

    Ok(tokens)
}

/// Try to parse an engineering suffix starting at position `i` in `chars`.
/// Returns (multiplier, number_of_chars_consumed).
fn parse_eng_suffix(chars: &[char], i: usize) -> (f64, usize) {
    // Multi-character suffix first (longest match): `meg`.
    let is_meg = chars[i..]
        .iter()
        .take(3)
        .map(|c| c.to_ascii_lowercase())
        .eq("meg".chars());
    if is_meg && (i + 3 >= chars.len() || !chars[i + 3].is_ascii_alphabetic()) {
        return (1e6, 3);
    }

    if i < chars.len() {
        // Single-char suffixes — only when not followed by an alphanumeric
        // (to avoid eating part of a longer identifier).
        let is_standalone = i + 1 >= chars.len() || !chars[i + 1].is_ascii_alphanumeric();
        if is_standalone {
            match chars[i].to_ascii_lowercase() {
                't' => return (1e12, 1),
                'g' => return (1e9, 1),
                'k' => return (1e3, 1),
                'm' => return (1e-3, 1),
                'u' => return (1e-6, 1),
                'n' => return (1e-9, 1),
                'p' => return (1e-12, 1),
                'f' => return (1e-15, 1),
                _ => {}
            }
        }
    }

    (1.0, 0)
}

/// Recursive-descent expression evaluator.
///
/// Grammar:
///   expr     -> term (('+' | '-') term)*
///   term     -> power (('*' | '/') power)*
///   power    -> unary ('**' power)?       (right-associative)
///   unary    -> ('-' | '+') unary | primary
///   primary  -> NUMBER | IDENT | IDENT '(' args ')' | '(' expr ')'
struct ExprParser<'a> {
    tokens: Vec<Token>,
    pos: usize,
    ctx: &'a HashMap<String, f64>,
}

impl<'a> ExprParser<'a> {
    fn new(tokens: Vec<Token>, ctx: &'a HashMap<String, f64>) -> Self {
        Self {
            tokens,
            pos: 0,
            ctx,
        }
    }

    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.pos)
    }

    fn advance(&mut self) -> Option<Token> {
        let tok = self.tokens.get(self.pos).cloned();
        if tok.is_some() {
            self.pos += 1;
        }
        tok
    }

    fn expect_rparen(&mut self) -> Result<(), ExprError> {
        match self.advance() {
            Some(Token::RParen) => Ok(()),
            _ => Err(ExprError::Expected(")".to_string())),
        }
    }

    fn expect_comma(&mut self) -> Result<(), ExprError> {
        match self.advance() {
            Some(Token::Comma) => Ok(()),
            _ => Err(ExprError::Expected(",".to_string())),
        }
    }

    fn parse_expr(&mut self) -> Result<f64, ExprError> {
        let mut left = self.parse_term()?;
        loop {
            match self.peek() {
                Some(Token::Plus) => {
                    self.advance();
                    left += self.parse_term()?;
                }
                Some(Token::Minus) => {
                    self.advance();
                    left -= self.parse_term()?;
                }
                _ => break,
            }
        }
        Ok(left)
    }

    fn parse_term(&mut self) -> Result<f64, ExprError> {
        let mut left = self.parse_power()?;
        loop {
            match self.peek() {
                Some(Token::Star) => {
                    self.advance();
                    left *= self.parse_power()?;
                }
                Some(Token::Slash) => {
                    self.advance();
                    let right = self.parse_power()?;
                    if right == 0.0 {
                        return Err(ExprError::DivisionByZero);
                    }
                    left /= right;
                }
                _ => break,
            }
        }
        Ok(left)
    }

    fn parse_power(&mut self) -> Result<f64, ExprError> {
        let base = self.parse_unary()?;
        if let Some(Token::DoubleStar) = self.peek() {
            self.advance();
            // Right-associative.
            let exp = self.parse_power()?;
            Ok(base.powf(exp))
        } else {
            Ok(base)
        }
    }

    fn parse_unary(&mut self) -> Result<f64, ExprError> {
        match self.peek() {
            Some(Token::Minus) => {
                self.advance();
                Ok(-self.parse_unary()?)
            }
            Some(Token::Plus) => {
                self.advance();
                self.parse_unary()
            }
            _ => self.parse_primary(),
        }
    }

    fn parse_primary(&mut self) -> Result<f64, ExprError> {
        match self.advance() {
            Some(Token::Number(n)) => Ok(n),
            Some(Token::LParen) => {
                let val = self.parse_expr()?;
                self.expect_rparen()?;
                Ok(val)
            }
            Some(Token::Ident(name)) => {
                if let Some(Token::LParen) = self.peek() {
                    self.advance(); // consume '('
                    self.call_function(&name)
                } else {
                    self.ctx
                        .get(&name)
                        .copied()
                        .ok_or(ExprError::UndefinedVariable(name))
                }
            }
            Some(other) => Err(ExprError::UnexpectedChar(
                format!("{:?}", other).chars().next().unwrap_or('?'),
            )),
            None => Err(ExprError::UnexpectedEnd),
        }
    }

    fn call_function(&mut self, name: &str) -> Result<f64, ExprError> {
        match name.to_ascii_lowercase().as_str() {
            "min" => {
                let a = self.parse_expr()?;
                self.expect_comma()?;
                let b = self.parse_expr()?;
                self.expect_rparen()?;
                Ok(a.min(b))
            }
            "max" => {
                let a = self.parse_expr()?;
                self.expect_comma()?;
                let b = self.parse_expr()?;
                self.expect_rparen()?;
                Ok(a.max(b))
            }
            "abs" => {
                let a = self.parse_expr()?;
                self.expect_rparen()?;
                Ok(a.abs())
            }
            "sqrt" => {
                let a = self.parse_expr()?;
                self.expect_rparen()?;
                if a < 0.0 {
                    return Err(ExprError::MathDomainError("sqrt".to_string()));
                }
                Ok(a.sqrt())
            }
            "log" => {
                let a = self.parse_expr()?;
                self.expect_rparen()?;
                if a <= 0.0 {
                    return Err(ExprError::MathDomainError("log".to_string()));
                }
                Ok(a.ln())
            }
            "exp" => {
                let a = self.parse_expr()?;
                self.expect_rparen()?;
                Ok(a.exp())
            }
            _ => Err(ExprError::UnknownFunction(name.to_string())),
        }
    }
}

/// Evaluate a SPICE parameter expression string.
///
/// Supports arithmetic (`+ - * / **`, unary `-`), parentheses, the functions
/// `min/max/abs/sqrt/log/exp`, engineering suffixes (`T G meg k m u n p f`),
/// variable references from `ctx`, and SPICE `'expr'` / `"expr"` quoting.
pub fn eval_expr(input: &str, ctx: &HashMap<String, f64>) -> Result<f64, ExprError> {
    let stripped = strip_quotes(input.trim());
    if stripped.is_empty() {
        return Err(ExprError::UnexpectedEnd);
    }

    let tokens = tokenize(stripped)?;
    if tokens.is_empty() {
        return Err(ExprError::UnexpectedEnd);
    }

    let mut parser = ExprParser::new(tokens, ctx);
    let result = parser.parse_expr()?;

    if parser.pos < parser.tokens.len() {
        return Err(ExprError::Expected("end of expression".to_string()));
    }

    Ok(result)
}

fn strip_quotes(trimmed: &str) -> &str {
    if trimmed.len() >= 2
        && ((trimmed.starts_with('\'') && trimmed.ends_with('\''))
            || (trimmed.starts_with('"') && trimmed.ends_with('"')))
    {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    }
}

/// Try to parse a SPICE value string as a plain number with optional
/// engineering suffix.  Returns `None` if the string is not a simple number.
pub fn parse_spice_number(input: &str) -> Option<f64> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    let stripped = strip_quotes(trimmed);

    let chars: Vec<char> = stripped.chars().collect();
    let len = chars.len();

    let mut i = 0;
    if i < len && (chars[i] == '+' || chars[i] == '-') {
        i += 1;
    }
    while i < len && (chars[i].is_ascii_digit() || chars[i] == '.') {
        i += 1;
    }
    if i < len && (chars[i] == 'e' || chars[i] == 'E') {
        i += 1;
        if i < len && (chars[i] == '+' || chars[i] == '-') {
            i += 1;
        }
        while i < len && chars[i].is_ascii_digit() {
            i += 1;
        }
    }

    let num_str: String = chars[..i].iter().collect();
    let base_val: f64 = num_str.parse().ok()?;

    let (suffix_mult, suffix_len) = parse_eng_suffix(&chars, i);
    if i + suffix_len != len {
        return None; // Trailing characters — not a simple number.
    }

    Some(base_val * suffix_mult)
}

// ---------------------------------------------------------------------------
// .param resolution and substitution
// ---------------------------------------------------------------------------

/// Resolve raw `.param` string values to f64 via fixed-point iteration.
///
/// Handles dependency ordering: iterates until no new params resolve,
/// up to `params.len() + 1` iterations (sufficient for any DAG).
pub fn resolve_params(params: &HashMap<String, String>) -> HashMap<String, f64> {
    let mut resolved = HashMap::new();
    for _ in 0..=params.len() {
        let mut changed = false;
        for (key, val_str) in params {
            if resolved.contains_key(key) {
                continue;
            }
            if let Some(num) = parse_spice_number(val_str) {
                resolved.insert(key.clone(), num);
                changed = true;
            } else if let Ok(num) = eval_expr(val_str, &resolved) {
                resolved.insert(key.clone(), num);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    resolved
}

/// Substitute resolved param values into all instance parameters in a circuit.
pub fn substitute_params(circuit: &mut Circuit, resolved: &HashMap<String, f64>) {
    substitute_in_instances(&mut circuit.top.instances, resolved);
    for sub in circuit.subcircuits.values_mut() {
        substitute_in_instances(&mut sub.instances, resolved);
    }
}

fn substitute_in_instances(instances: &mut [Instance], resolved: &HashMap<String, f64>) {
    for inst in instances.iter_mut() {
        let keys: Vec<String> = inst.params.keys().cloned().collect();
        for key in keys {
            let val_str = inst.params[&key].clone();
            let lower = val_str.to_ascii_lowercase();
            if let Some(&num) = resolved.get(&lower) {
                // Whole value is a param reference.
                inst.params.insert(key, format!("{}", num));
            } else if parse_spice_number(&val_str).is_none() {
                if let Ok(num) = eval_expr(&val_str, resolved) {
                    inst.params.insert(key, format!("{}", num));
                } else if let Some(subst) = substitute_param_tokens(&val_str, resolved) {
                    // Not directly evaluable (e.g. `{w*2}` braces): substitute
                    // param references on identifier-token boundaries and try
                    // again, falling back to the textually substituted form.
                    match eval_expr(&subst, resolved) {
                        Ok(num) => inst.params.insert(key, format!("{}", num)),
                        Err(_) => inst.params.insert(key, subst),
                    };
                }
            }
        }
    }
}

/// Substitute resolved parameter names appearing as whole identifier tokens
/// in `value`.  Returns `Some(new)` only when at least one substitution was
/// made.
///
/// Matching is strictly on token boundaries: an identifier is a maximal
/// `[A-Za-z_][A-Za-z0-9_]*` run not preceded by an alphanumeric, `_`, or `.`
/// character.  This avoids the classic substring hazard where a param `w=5`
/// would corrupt `w2` or the suffix of `5u`.  Identifiers immediately
/// followed by `(` are function calls and are left untouched.
fn substitute_param_tokens(value: &str, resolved: &HashMap<String, f64>) -> Option<String> {
    let chars: Vec<char> = value.chars().collect();
    let len = chars.len();
    let mut out = String::with_capacity(value.len());
    let mut changed = false;
    let mut i = 0;

    while i < len {
        let ch = chars[i];
        let prev_joins = i > 0
            && (chars[i - 1].is_ascii_alphanumeric() || chars[i - 1] == '_' || chars[i - 1] == '.');
        if (ch.is_ascii_alphabetic() || ch == '_') && !prev_joins {
            let start = i;
            while i < len && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let ident: String = chars[start..i].iter().collect();
            let is_call = i < len && chars[i] == '(';
            if !is_call {
                if let Some(num) = resolved.get(&ident.to_ascii_lowercase()) {
                    out.push_str(&format!("{}", num));
                    changed = true;
                    continue;
                }
            }
            out.push_str(&ident);
        } else {
            out.push(ch);
            i += 1;
        }
    }

    changed.then_some(out)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(input: &str) -> (SpiceParser, Circuit) {
        let mut parser = SpiceParser::new();
        let circuit = parser.parse(input).unwrap();
        (parser, circuit)
    }

    // -- Combined netlist: resistor divider + .subckt + .param expr ---------

    #[test]
    fn parse_divider_subckt_param() {
        let input = "\
* resistor divider feeding a buffer
.param rtop=10k
.param rbot=rtop/2
.global vdd vss
.subckt buf in out vdd vss
M1 out in vdd vdd pmos_model w=2u l=100n
M2 out in vss vss nmos_model w=1u l=100n
.ends buf
R1 vdd mid rtop
R2 mid vss rbot
X1 mid out buf vdd vss buf
.tran 1n 1u
.end
";
        let (parser, circuit) = parse(input);

        // Top-level instance and net counts.
        assert_eq!(circuit.top.instances.len(), 3); // R1, R2, X1
        let top_nets: Vec<&str> = circuit.top.nets.iter().map(|n| n.name.as_str()).collect();
        assert!(top_nets.contains(&"vdd"));
        assert!(top_nets.contains(&"mid"));
        assert!(top_nets.contains(&"vss"));
        assert!(top_nets.contains(&"out"));

        // Scope nesting: subckt instances are inside the subcircuit.
        let sub = &circuit.subcircuits["buf"];
        assert_eq!(sub.ports, vec!["in", "out", "vdd", "vss"]);
        assert_eq!(sub.instances.len(), 2);
        assert_eq!(sub.instances[0].name, "m1");
        assert_eq!(sub.instances[0].primitive, Primitive::Pmos);
        assert_eq!(sub.instances[1].primitive, Primitive::Nmos);

        // Param evaluation (expression referencing another param).
        let resolved = parser.resolved_params();
        assert!((resolved["rtop"] - 10e3).abs() < 1e-9);
        assert!((resolved["rbot"] - 5e3).abs() < 1e-9);

        // Substitution: R1/R2 values replaced by resolved numbers.
        assert_eq!(circuit.top.instances[0].params["value"], "10000");
        assert_eq!(circuit.top.instances[1].params["value"], "5000");

        // Globals marked in both scopes.
        assert!(circuit.top.nets.iter().any(|n| n.name == "vdd" && n.is_global));
        assert!(sub.nets.iter().any(|n| n.name == "vdd" && n.is_global));

        // Analysis categorized.
        assert_eq!(circuit.analysis.analyses, &[".tran 1n 1u"]);
    }

    // -- Device cards --------------------------------------------------------

    #[test]
    fn parse_mosfet_pins_and_params() {
        let (_, circuit) = parse("M1 drain gate source bulk nmos_model w=1u l=100n\n");
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.name, "m1");
        assert_eq!(inst.primitive, Primitive::Nmos);
        let names: Vec<&str> = inst.pins.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["D", "G", "S", "B"]);
        assert_eq!(inst.params["model"], "nmos_model");
        assert_eq!(inst.params["w"], "1u");

        let drain = circuit.top.nets.iter().find(|n| n.name == "drain").unwrap();
        assert!(drain
            .pins
            .iter()
            .any(|p| p.instance_idx == InstId(0) && p.pin_idx == PinIdx(0)));
    }

    #[test]
    fn parse_continuation_and_comments() {
        let input = "\
* full-line comment
M1 drain gate
+ source bulk
+ nmos_model w=1u l=100n ; inline comment
";
        let (_, circuit) = parse(input);
        assert_eq!(circuit.top.instances.len(), 1);
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.params["w"], "1u");
        assert_eq!(inst.params["l"], "100n");
        assert_eq!(inst.params["model"], "nmos_model");
    }

    #[test]
    fn strip_inline_comment_dollar_rules() {
        assert_eq!(strip_inline_comment("R1 a b 1k $ note"), "R1 a b 1k");
        assert_eq!(strip_inline_comment("R1 a \\$13 1k"), "R1 a \\$13 1k");
        assert_eq!(strip_inline_comment("R1 a $13 1k"), "R1 a $13 1k");
        assert_eq!(strip_inline_comment("R1 a b 1k ; note"), "R1 a b 1k");
    }

    #[test]
    fn parse_bjt_diode_jfet_sources() {
        let input = "\
Q1 c b e npn_model
D1 a k dmod
J1 d g s jmod
E1 out 0 a b 10
F1 out 0 vsense1 2
V1 inp 0 PULSE(0 1.8 0 1n 1n 5u 10u)
B1 bo 0 I={V(a)*gm}
";
        let (_, circuit) = parse(input);
        assert_eq!(circuit.top.instances.len(), 7);
        assert_eq!(circuit.top.instances[0].primitive, Primitive::Npn);
        assert_eq!(circuit.top.instances[1].primitive, Primitive::Diode);
        assert_eq!(circuit.top.instances[2].primitive, Primitive::Jfet);
        assert_eq!(circuit.top.instances[3].primitive, Primitive::Vcvs);
        assert_eq!(circuit.top.instances[3].pins.len(), 4);
        assert_eq!(circuit.top.instances[4].primitive, Primitive::Cccs);
        assert_eq!(circuit.top.instances[4].params["vsense"], "vsense1");
        assert_eq!(
            circuit.top.instances[5].params["value"],
            "pulse(0 1.8 0 1n 1n 5u 10u)"
        );
        // Behavioral source preserves expression case.
        assert_eq!(circuit.top.instances[6].params["i"], "{V(a)*gm}");
        assert!(circuit.diagnostics.is_empty());
    }

    #[test]
    fn missing_pins_error() {
        let mut parser = SpiceParser::new();
        match parser.parse("M1 drain gate\n").unwrap_err() {
            ParseError::MissingPins(name) => assert_eq!(name, "m1"),
            other => panic!("expected MissingPins, got {:?}", other),
        }
    }

    #[test]
    fn unknown_prefix_and_dot_command_diagnostics() {
        let (_, circuit) = parse("K1 L1 L2 0.99\n.banana 42\nR1 a b 1k\n");
        assert_eq!(circuit.top.instances.len(), 1);
        assert_eq!(circuit.diagnostics.len(), 2);
        assert!(matches!(
            circuit.diagnostics[0].kind,
            DiagnosticKind::UnknownDevicePrefix('k')
        ));
        assert!(matches!(
            &circuit.diagnostics[1].kind,
            DiagnosticKind::UnknownDotCommand(cmd) if cmd == ".banana"
        ));
    }

    #[test]
    fn reclassify_pdk_wrapped_mosfet() {
        let (_, circuit) = parse("X1 d g s b sky130_fd_pr__nfet_01v8 w=1u\n");
        let inst = &circuit.top.instances[0];
        assert_eq!(inst.primitive, Primitive::Nmos);
        assert_eq!(inst.pins[0].name, "D");
        assert_eq!(inst.params["model"], "sky130_fd_pr__nfet_01v8");
    }

    #[test]
    fn control_block_and_includes() {
        let input = "\
.include \"/pdk/models.lib\"
.control
tran 1n 100u
.endc
R1 a b 1k
";
        let (_, circuit) = parse(input);
        assert_eq!(circuit.analysis.includes.len(), 1);
        assert_eq!(
            circuit.analysis.control_blocks,
            &[".control\ntran 1n 100u\n.endc"]
        );
    }

    #[test]
    fn nested_subckt_scope_pops_correctly() {
        let input = "\
.subckt outer a b
M1 a b 0 0 nmos_model
.ends outer
R1 x y 1k
";
        let (_, circuit) = parse(input);
        assert_eq!(circuit.subcircuits["outer"].instances.len(), 1);
        assert_eq!(circuit.top.instances.len(), 1);
        assert_eq!(circuit.top.instances[0].name, "r1");
    }

    // -- Expression evaluator -------------------------------------------------

    #[test]
    fn expr_arithmetic_and_precedence() {
        let ctx = HashMap::new();
        assert!((eval_expr("2+3*4", &ctx).unwrap() - 14.0).abs() < 1e-12);
        assert!((eval_expr("(2+3)*4", &ctx).unwrap() - 20.0).abs() < 1e-12);
        assert!((eval_expr("2**3", &ctx).unwrap() - 8.0).abs() < 1e-12);
        assert!((eval_expr("3 + -2", &ctx).unwrap() - 1.0).abs() < 1e-12);
        assert!(eval_expr("1/0", &ctx).is_err());
    }

    #[test]
    fn expr_functions_and_variables() {
        let mut ctx = HashMap::new();
        ctx.insert("w_n".to_string(), 10e-6);
        assert!((eval_expr("w_n*2", &ctx).unwrap() - 20e-6).abs() < 1e-18);
        assert!((eval_expr("max(min(5,10),3)", &ctx).unwrap() - 5.0).abs() < 1e-12);
        assert!((eval_expr("sqrt(4)", &ctx).unwrap() - 2.0).abs() < 1e-12);
        assert!((eval_expr("'1+2'", &ctx).unwrap() - 3.0).abs() < 1e-12);
        assert!(matches!(
            eval_expr("nope", &HashMap::new()),
            Err(ExprError::UndefinedVariable(_))
        ));
    }

    #[test]
    fn expr_engineering_suffixes() {
        let ctx = HashMap::new();
        let cases = [
            ("1k", 1e3),
            ("1u", 1e-6),
            ("1meg", 1e6),
            ("1m", 1e-3),
            ("100n", 100e-9),
            ("1p", 1e-12),
            ("1f", 1e-15),
            ("2T", 2e12),
            ("3G", 3e9),
        ];
        for (s, expected) in cases {
            let v = eval_expr(s, &ctx).unwrap();
            assert!(
                ((v - expected) / expected).abs() < 1e-12,
                "{s}: {v} != {expected}"
            );
        }
    }

    #[test]
    fn spice_number_parsing() {
        assert!((parse_spice_number("1k").unwrap() - 1000.0).abs() < 1e-12);
        assert!((parse_spice_number("1.8").unwrap() - 1.8).abs() < 1e-12);
        assert!((parse_spice_number("1meg").unwrap() - 1e6).abs() < 1e-6);
        assert!(parse_spice_number("abc").is_none());
        assert!(parse_spice_number("1kx").is_none());
    }

    // -- Param substitution token boundaries ---------------------------------

    #[test]
    fn param_substitution_token_boundaries() {
        let mut resolved = HashMap::new();
        resolved.insert("w".to_string(), 5.0);

        // `w` as a whole token is substituted; `w2`, `5u`, and `w(` are not.
        assert_eq!(
            substitute_param_tokens("{w*2}", &resolved).unwrap(),
            "{5*2}"
        );
        assert!(substitute_param_tokens("w2+1", &resolved).is_none());
        assert!(substitute_param_tokens("5u", &resolved).is_none());
        assert!(substitute_param_tokens("w(1)", &resolved).is_none());
    }

    #[test]
    fn param_substitution_in_circuit() {
        let input = "\
.param wval=5u
M1 d g s b nmos_model w=wval l='wval/5'
";
        let (_, circuit) = parse(input);
        let inst = &circuit.top.instances[0];
        assert!((inst.params["w"].parse::<f64>().unwrap() - 5e-6).abs() < 1e-18);
        assert!((inst.params["l"].parse::<f64>().unwrap() - 1e-6).abs() < 1e-18);
        // A literal `5u` value must NOT be corrupted by substitution.
        assert_eq!(inst.params.get("model").unwrap(), "nmos_model");
    }
}
