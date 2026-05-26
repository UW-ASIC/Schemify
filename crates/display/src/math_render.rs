use eframe::egui;

// ── LaTeX-to-Unicode symbol table ────────────────────────────────────────────

fn latex_symbol(cmd: &str) -> Option<&'static str> {
    Some(match cmd {
        // Greek lowercase
        "alpha" => "\u{03B1}",
        "beta" => "\u{03B2}",
        "gamma" => "\u{03B3}",
        "delta" => "\u{03B4}",
        "epsilon" | "varepsilon" => "\u{03B5}",
        "zeta" => "\u{03B6}",
        "eta" => "\u{03B7}",
        "theta" | "vartheta" => "\u{03B8}",
        "iota" => "\u{03B9}",
        "kappa" => "\u{03BA}",
        "lambda" => "\u{03BB}",
        "mu" => "\u{03BC}",
        "nu" => "\u{03BD}",
        "xi" => "\u{03BE}",
        "pi" | "varpi" => "\u{03C0}",
        "rho" | "varrho" => "\u{03C1}",
        "sigma" | "varsigma" => "\u{03C3}",
        "tau" => "\u{03C4}",
        "upsilon" => "\u{03C5}",
        "phi" | "varphi" => "\u{03C6}",
        "chi" => "\u{03C7}",
        "psi" => "\u{03C8}",
        "omega" => "\u{03C9}",
        // Greek uppercase
        "Gamma" => "\u{0393}",
        "Delta" => "\u{0394}",
        "Theta" => "\u{0398}",
        "Lambda" => "\u{039B}",
        "Xi" => "\u{039E}",
        "Pi" => "\u{03A0}",
        "Sigma" => "\u{03A3}",
        "Phi" => "\u{03A6}",
        "Psi" => "\u{03A8}",
        "Omega" => "\u{03A9}",
        // Operators and relations
        "times" => "\u{00D7}",
        "div" => "\u{00F7}",
        "cdot" => "\u{22C5}",
        "pm" => "\u{00B1}",
        "mp" => "\u{2213}",
        "leq" | "le" => "\u{2264}",
        "geq" | "ge" => "\u{2265}",
        "neq" | "ne" => "\u{2260}",
        "approx" => "\u{2248}",
        "equiv" => "\u{2261}",
        "sim" => "\u{223C}",
        "propto" => "\u{221D}",
        "infty" => "\u{221E}",
        "partial" => "\u{2202}",
        "nabla" => "\u{2207}",
        "sum" => "\u{2211}",
        "prod" => "\u{220F}",
        "int" => "\u{222B}",
        "iint" => "\u{222C}",
        "iiint" => "\u{222D}",
        "oint" => "\u{222E}",
        "sqrt" => "\u{221A}",
        "forall" => "\u{2200}",
        "exists" => "\u{2203}",
        "nexists" => "\u{2204}",
        "in" => "\u{2208}",
        "notin" => "\u{2209}",
        "subset" => "\u{2282}",
        "supset" => "\u{2283}",
        "subseteq" => "\u{2286}",
        "supseteq" => "\u{2287}",
        "cup" => "\u{222A}",
        "cap" => "\u{2229}",
        "emptyset" | "varnothing" => "\u{2205}",
        "land" | "wedge" => "\u{2227}",
        "lor" | "vee" => "\u{2228}",
        "neg" | "lnot" => "\u{00AC}",
        // Arrows
        "to" | "rightarrow" => "\u{2192}",
        "leftarrow" => "\u{2190}",
        "leftrightarrow" => "\u{2194}",
        "Rightarrow" => "\u{21D2}",
        "Leftarrow" => "\u{21D0}",
        "Leftrightarrow" | "iff" => "\u{21D4}",
        "uparrow" => "\u{2191}",
        "downarrow" => "\u{2193}",
        "mapsto" => "\u{21A6}",
        // Misc
        "ldots" | "dots" => "\u{2026}",
        "cdots" => "\u{22EF}",
        "vdots" => "\u{22EE}",
        "ddots" => "\u{22F1}",
        "circ" => "\u{2218}",
        "bullet" => "\u{2022}",
        "star" => "\u{22C6}",
        "dagger" => "\u{2020}",
        "ddagger" => "\u{2021}",
        "hbar" => "\u{210F}",
        "ell" => "\u{2113}",
        "Re" => "\u{211C}",
        "Im" => "\u{2111}",
        "aleph" => "\u{2135}",
        "angle" => "\u{2220}",
        "triangle" => "\u{25B3}",
        "diamond" => "\u{25C7}",
        // Brackets
        "langle" => "\u{27E8}",
        "rangle" => "\u{27E9}",
        "lceil" => "\u{2308}",
        "rceil" => "\u{2309}",
        "lfloor" => "\u{230A}",
        "rfloor" => "\u{230B}",
        "lvert" | "vert" => "|",
        "rvert" => "|",
        "lVert" | "Vert" => "\u{2016}",
        "rVert" => "\u{2016}",
        // Spaces
        "quad" => "\u{2003}",
        "qquad" => "\u{2003}\u{2003}",
        "," | "thinspace" => "\u{2009}",
        ";" | "thickspace" => "\u{2004}",
        "!" => "",
        // Accents (combining characters — appended after base char)
        _ => return None,
    })
}

/// Unicode superscript digits/letters for simple cases.
fn superscript_char(c: char) -> Option<char> {
    Some(match c {
        '0' => '\u{2070}',
        '1' => '\u{00B9}',
        '2' => '\u{00B2}',
        '3' => '\u{00B3}',
        '4' => '\u{2074}',
        '5' => '\u{2075}',
        '6' => '\u{2076}',
        '7' => '\u{2077}',
        '8' => '\u{2078}',
        '9' => '\u{2079}',
        '+' => '\u{207A}',
        '-' => '\u{207B}',
        '=' => '\u{207C}',
        '(' => '\u{207D}',
        ')' => '\u{207E}',
        'n' => '\u{207F}',
        'i' => '\u{2071}',
        _ => return None,
    })
}

/// Unicode subscript digits/letters for simple cases.
fn subscript_char(c: char) -> Option<char> {
    Some(match c {
        '0' => '\u{2080}',
        '1' => '\u{2081}',
        '2' => '\u{2082}',
        '3' => '\u{2083}',
        '4' => '\u{2084}',
        '5' => '\u{2085}',
        '6' => '\u{2086}',
        '7' => '\u{2087}',
        '8' => '\u{2088}',
        '9' => '\u{2089}',
        '+' => '\u{208A}',
        '-' => '\u{208B}',
        '=' => '\u{208C}',
        '(' => '\u{208D}',
        ')' => '\u{208E}',
        'a' => '\u{2090}',
        'e' => '\u{2091}',
        'o' => '\u{2092}',
        'x' => '\u{2093}',
        'h' => '\u{2095}',
        'k' => '\u{2096}',
        'l' => '\u{2097}',
        'm' => '\u{2098}',
        'n' => '\u{2099}',
        'p' => '\u{209A}',
        's' => '\u{209B}',
        't' => '\u{209C}',
        _ => return None,
    })
}

/// Try to convert a simple string to Unicode super/subscript.
fn to_unicode_script(s: &str, sup: bool) -> Option<String> {
    let mapper = if sup { superscript_char } else { subscript_char };
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match mapper(c) {
            Some(sc) => out.push(sc),
            None => return None,
        }
    }
    Some(out)
}

// ── AST ──────────────────────────────────────────────────────────────────────

#[derive(Debug)]
enum MathNode {
    Text(String),
    Symbol(String),
    Sup(Vec<MathNode>, Vec<MathNode>),  // base, exponent
    Sub(Vec<MathNode>, Vec<MathNode>),  // base, subscript
    SubSup(Vec<MathNode>, Vec<MathNode>, Vec<MathNode>), // base, sub, sup
    Frac(Vec<MathNode>, Vec<MathNode>), // numerator, denominator
    Sqrt(Vec<MathNode>),
    Group(Vec<MathNode>),
    Operator(String), // sin, cos, etc. — upright
    Space,
    Left(String),     // \left delimiter
    Right(String),    // \right delimiter
}

// ── Parser ───────────────────────────────────────────────────────────────────

struct MathParser<'a> {
    src: &'a str,
    pos: usize,
}

impl<'a> MathParser<'a> {
    fn new(src: &'a str) -> Self {
        Self { src, pos: 0 }
    }

    fn peek(&self) -> Option<char> {
        self.src[self.pos..].chars().next()
    }

    fn advance(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += c.len_utf8();
        Some(c)
    }

    fn skip_whitespace(&mut self) {
        while let Some(c) = self.peek() {
            if c.is_ascii_whitespace() {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn parse_group(&mut self) -> Vec<MathNode> {
        // Expects '{' already consumed, reads until '}'.
        let mut nodes = Vec::new();
        loop {
            match self.peek() {
                None | Some('}') => {
                    self.advance(); // consume '}'
                    break;
                }
                _ => {
                    if let Some(node) = self.parse_atom() {
                        nodes.push(node);
                    }
                }
            }
        }
        nodes
    }

    fn parse_command(&mut self) -> Option<MathNode> {
        // '\' already consumed. Read command name.
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c.is_ascii_alphabetic() {
                self.advance();
            } else {
                break;
            }
        }
        let cmd = &self.src[start..self.pos];

        match cmd {
            "frac" | "dfrac" | "tfrac" => {
                self.skip_whitespace();
                let num = if self.peek() == Some('{') {
                    self.advance();
                    self.parse_group()
                } else {
                    vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                };
                self.skip_whitespace();
                let den = if self.peek() == Some('{') {
                    self.advance();
                    self.parse_group()
                } else {
                    vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                };
                Some(MathNode::Frac(num, den))
            }
            "sqrt" => {
                self.skip_whitespace();
                let body = if self.peek() == Some('{') {
                    self.advance();
                    self.parse_group()
                } else {
                    vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                };
                Some(MathNode::Sqrt(body))
            }
            "left" => {
                let delim = self.advance().map(|c| c.to_string()).unwrap_or_default();
                Some(MathNode::Left(delim))
            }
            "right" => {
                let delim = self.advance().map(|c| c.to_string()).unwrap_or_default();
                Some(MathNode::Right(delim))
            }
            "sin" | "cos" | "tan" | "cot" | "sec" | "csc" | "arcsin" | "arccos"
            | "arctan" | "sinh" | "cosh" | "tanh" | "log" | "ln" | "exp" | "lim"
            | "max" | "min" | "sup" | "inf" | "det" | "dim" | "ker" | "gcd"
            | "deg" | "arg" | "hom" | "mod" => {
                Some(MathNode::Operator(cmd.to_string()))
            }
            "text" | "mathrm" | "textrm" => {
                self.skip_whitespace();
                if self.peek() == Some('{') {
                    self.advance();
                    let start = self.pos;
                    let mut depth = 1;
                    while let Some(c) = self.advance() {
                        if c == '{' { depth += 1; }
                        if c == '}' { depth -= 1; if depth == 0 { break; } }
                    }
                    let end = self.pos - 1;
                    Some(MathNode::Operator(self.src[start..end].to_string()))
                } else {
                    Some(MathNode::Text(cmd.to_string()))
                }
            }
            "mathbf" | "mathbb" | "mathcal" | "mathit" | "mathtt" | "boldsymbol" => {
                // Read group, render as text (styling not fully supported in egui monospace)
                self.skip_whitespace();
                if self.peek() == Some('{') {
                    self.advance();
                    Some(MathNode::Group(self.parse_group()))
                } else {
                    None
                }
            }
            _ => {
                // Try symbol lookup.
                if let Some(sym) = latex_symbol(cmd) {
                    Some(MathNode::Symbol(sym.to_string()))
                } else {
                    // Unknown command — render as text.
                    Some(MathNode::Text(format!("\\{cmd}")))
                }
            }
        }
    }

    fn parse_atom(&mut self) -> Option<MathNode> {
        self.skip_whitespace();
        let c = self.peek()?;

        let mut node = match c {
            '\\' => {
                self.advance();
                self.parse_command()?
            }
            '{' => {
                self.advance();
                MathNode::Group(self.parse_group())
            }
            '}' => return None, // end of group
            '_' | '^' => {
                // Script without base — use empty text.
                MathNode::Text(String::new())
            }
            _ => {
                self.advance();
                MathNode::Text(c.to_string())
            }
        };

        // Check for sub/superscript after atom.
        loop {
            self.skip_whitespace();
            match self.peek() {
                Some('^') => {
                    self.advance();
                    self.skip_whitespace();
                    let sup = if self.peek() == Some('{') {
                        self.advance();
                        self.parse_group()
                    } else {
                        vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                    };
                    // Check for additional subscript.
                    self.skip_whitespace();
                    if self.peek() == Some('_') {
                        self.advance();
                        self.skip_whitespace();
                        let sub = if self.peek() == Some('{') {
                            self.advance();
                            self.parse_group()
                        } else {
                            vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                        };
                        node = MathNode::SubSup(vec![node], sub, sup);
                    } else {
                        node = MathNode::Sup(vec![node], sup);
                    }
                }
                Some('_') => {
                    self.advance();
                    self.skip_whitespace();
                    let sub = if self.peek() == Some('{') {
                        self.advance();
                        self.parse_group()
                    } else {
                        vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                    };
                    // Check for additional superscript.
                    self.skip_whitespace();
                    if self.peek() == Some('^') {
                        self.advance();
                        self.skip_whitespace();
                        let sup = if self.peek() == Some('{') {
                            self.advance();
                            self.parse_group()
                        } else {
                            vec![MathNode::Text(self.advance().map(|c| c.to_string()).unwrap_or_default())]
                        };
                        node = MathNode::SubSup(vec![node], sub, sup);
                    } else {
                        node = MathNode::Sub(vec![node], sub);
                    }
                }
                _ => break,
            }
        }

        Some(node)
    }

    fn parse_all(&mut self) -> Vec<MathNode> {
        let mut nodes = Vec::new();
        while self.pos < self.src.len() {
            if let Some(node) = self.parse_atom() {
                nodes.push(node);
            } else {
                break;
            }
        }
        nodes
    }
}

// ── Rendering ────────────────────────────────────────────────────────────────

fn nodes_to_string(nodes: &[MathNode]) -> String {
    let mut out = String::new();
    for node in nodes {
        match node {
            MathNode::Text(s) => out.push_str(s),
            MathNode::Symbol(s) => out.push_str(s),
            MathNode::Operator(s) => out.push_str(s),
            MathNode::Group(children) => out.push_str(&nodes_to_string(children)),
            MathNode::Space => out.push(' '),
            MathNode::Left(d) | MathNode::Right(d) => out.push_str(d),
            _ => {}
        }
    }
    out
}

fn render_nodes(ui: &mut egui::Ui, nodes: &[MathNode], size: f32) {
    for node in nodes {
        render_node(ui, node, size);
    }
}

fn render_node(ui: &mut egui::Ui, node: &MathNode, size: f32) {
    match node {
        MathNode::Text(s) => {
            if !s.is_empty() {
                ui.label(egui::RichText::new(s).size(size).italics());
            }
        }
        MathNode::Symbol(s) => {
            ui.label(egui::RichText::new(s).size(size));
        }
        MathNode::Operator(s) => {
            ui.label(egui::RichText::new(s).size(size));
        }
        MathNode::Space => {
            ui.add_space(size * 0.3);
        }
        MathNode::Left(d) => {
            let delim = match d.as_str() {
                "(" => "(",
                "[" => "[",
                "\\{" | "{" => "{",
                "|" => "|",
                "." => "",
                other => other,
            };
            if !delim.is_empty() {
                ui.label(egui::RichText::new(delim).size(size));
            }
        }
        MathNode::Right(d) => {
            let delim = match d.as_str() {
                ")" => ")",
                "]" => "]",
                "\\}" | "}" => "}",
                "|" => "|",
                "." => "",
                other => other,
            };
            if !delim.is_empty() {
                ui.label(egui::RichText::new(delim).size(size));
            }
        }
        MathNode::Group(children) => {
            render_nodes(ui, children, size);
        }
        MathNode::Sup(base, sup) => {
            // Try Unicode superscript for simple cases.
            let sup_str = nodes_to_string(sup);
            if let Some(uni) = to_unicode_script(&sup_str, true) {
                render_nodes(ui, base, size);
                ui.label(egui::RichText::new(uni).size(size));
            } else {
                // Fallback: base then small superscript.
                render_nodes(ui, base, size);
                ui.vertical(|ui| {
                    render_nodes(ui, sup, size * 0.65);
                    ui.add_space(size * 0.35);
                });
            }
        }
        MathNode::Sub(base, sub) => {
            let sub_str = nodes_to_string(sub);
            if let Some(uni) = to_unicode_script(&sub_str, false) {
                render_nodes(ui, base, size);
                ui.label(egui::RichText::new(uni).size(size));
            } else {
                render_nodes(ui, base, size);
                ui.vertical(|ui| {
                    ui.add_space(size * 0.35);
                    render_nodes(ui, sub, size * 0.65);
                });
            }
        }
        MathNode::SubSup(base, sub, sup) => {
            render_nodes(ui, base, size);
            ui.vertical(|ui| {
                render_nodes(ui, sup, size * 0.6);
                render_nodes(ui, sub, size * 0.6);
            });
        }
        MathNode::Frac(num, den) => {
            let child_size = size * 0.85;
            ui.vertical(|ui| {
                ui.horizontal(|ui| {
                    render_nodes(ui, num, child_size);
                });
                ui.separator();
                ui.horizontal(|ui| {
                    render_nodes(ui, den, child_size);
                });
            });
        }
        MathNode::Sqrt(body) => {
            ui.label(egui::RichText::new("\u{221A}").size(size));
            // Overline approximation via group.
            ui.label(egui::RichText::new("\u{0305}").size(size)); // combining overline
            render_nodes(ui, body, size);
        }
    }
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Render inline math (`$...$`) within a horizontal layout.
pub fn render_inline(ui: &mut egui::Ui, latex: &str) {
    let mut parser = MathParser::new(latex);
    let nodes = parser.parse_all();
    render_nodes(ui, &nodes, 14.0);
}

/// Render display math (`$$...$$`) centered on its own line.
pub fn render_display(ui: &mut egui::Ui, latex: &str) {
    let mut parser = MathParser::new(latex);
    let nodes = parser.parse_all();
    ui.add_space(4.0);
    ui.horizontal(|ui| {
        ui.add_space(ui.available_width() * 0.1);
        render_nodes(ui, &nodes, 16.0);
    });
    ui.add_space(4.0);
}

/// Parse a line for inline math spans and render them mixed with text.
/// Returns true if any math was rendered.
pub fn render_text_with_math(ui: &mut egui::Ui, text: &str) -> bool {
    if !text.contains('$') {
        return false;
    }

    let mut has_math = false;
    let mut parts: Vec<(bool, &str)> = Vec::new();
    let mut pos = 0;
    let bytes = text.as_bytes();

    while pos < bytes.len() {
        if bytes[pos] == b'$' {
            // Check for escaped dollar.
            if pos > 0 && bytes[pos - 1] == b'\\' {
                pos += 1;
                continue;
            }
            // Find closing $.
            if let Some(end) = text[pos + 1..].find('$') {
                let end = pos + 1 + end;
                // Add preceding text.
                if pos > 0 {
                    let text_start = parts.iter().map(|(_, s)| s.len()).sum::<usize>()
                        + parts.iter().filter(|(is_math, _)| *is_math).count() * 2;
                    let preceding = &text[text_start..pos];
                    if !preceding.is_empty() {
                        parts.push((false, preceding));
                    }
                }
                parts.push((true, &text[pos + 1..end]));
                has_math = true;
                pos = end + 1;
            } else {
                pos += 1;
            }
        } else {
            pos += 1;
        }
    }

    if !has_math {
        return false;
    }

    // Collect any trailing text.
    let consumed: usize = parts.iter().map(|(is_math, s)| {
        if *is_math { s.len() + 2 } else { s.len() }
    }).sum();
    if consumed < text.len() {
        parts.push((false, &text[consumed..]));
    }

    ui.horizontal_wrapped(|ui| {
        for (is_math, content) in &parts {
            if *is_math {
                render_inline(ui, content);
            } else {
                ui.label(*content);
            }
        }
    });
    true
}
