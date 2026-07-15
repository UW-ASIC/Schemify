//! `.chn` reader — degrades gracefully: malformed fields warn and default.

use lasso::Rodeo;

use crate::*;

/// Parse a CHN file, also returning non-fatal warnings (malformed values,
/// skipped sections) with 1-based line numbers. Parsing never fails outright:
/// malformed fields fall back to defaults, but each fallback is reported here
/// instead of being silently swallowed.
pub fn read_chn_report(data: &str, interner: &mut Rodeo) -> (Schematic, Vec<ParseWarning>) {
    let mut sch = Schematic::default();
    let mut w = Warnings::default();
    parse_chn(&mut sch, data, interner, &mut w);
    (sch, w.list)
}

/// A non-fatal problem found while parsing a CHN file.
#[derive(Debug, Clone)]
pub struct ParseWarning {
    /// 1-based source line.
    pub line: u32,
    pub msg: String,
}

impl std::fmt::Display for ParseWarning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}: {}", self.line, self.msg)
    }
}

/// Warning accumulator threaded through the section parsers.
/// `line` is kept current by the main parse loop.
#[derive(Default)]
struct Warnings {
    list: Vec<ParseWarning>,
    line: u32,
}

impl Warnings {
    fn warn(&mut self, msg: String) {
        self.list.push(ParseWarning {
            line: self.line,
            msg,
        });
    }

    /// Parse a present token; warn and fall back to `default` if malformed.
    fn num<T: std::str::FromStr + Copy>(&mut self, field: &str, v: &str, default: T) -> T {
        v.parse().unwrap_or_else(|_| {
            self.warn(format!("invalid {field} '{v}'"));
            default
        })
    }

    /// Optional positional token: absent is fine (silent default, the format
    /// allows omission); present-but-malformed warns.
    fn opt_num<T: std::str::FromStr + Copy>(
        &mut self,
        field: &str,
        v: Option<&str>,
        default: T,
    ) -> T {
        match v {
            None => default,
            Some(s) => self.num(field, s, default),
        }
    }

    /// Required positional token: warns when absent or malformed.
    fn req_num<T: std::str::FromStr + Copy>(
        &mut self,
        field: &str,
        v: Option<&str>,
        default: T,
    ) -> T {
        match v {
            None => {
                self.warn(format!("missing {field}"));
                default
            }
            Some(s) => self.num(field, s, default),
        }
    }

    fn hex_color(&mut self, hex: &str) -> Color {
        Color::from_hex(hex).unwrap_or_else(|_| {
            self.warn(format!("invalid color '#{hex}'"));
            Color::NONE
        })
    }
}

#[derive(Default, PartialEq)]
enum Section {
    #[default]
    None,
    Pins,
    Params,
    Instances,
    TypeTable,
    Wires,
    Buses,
    BusRippers,
    Drawing,
    Analyses,
    Measures,
    CodeBlock,
    Annotations,
    Generate,
    Plugin,
    PluginMultiline,
    Pyspice,
    Documentation,
    /// Unknown section -- skip lines for forward compatibility.
    Skip,
}

#[derive(Default)]
struct TypeTableState {
    symbol: String,
    columns: Vec<String>,
    kind: DeviceKind,
}

#[derive(Default)]
struct GenState {
    var_name: String,
    range_start: i32,
    range_end: i32,
    lines: Vec<String>,
}

#[derive(Default)]
struct PluginMLState {
    plugin_idx: usize,
    key: String,
    lines: Vec<String>,
}

fn parse_chn(s: &mut Schematic, data: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut section = Section::None;
    let mut tt = TypeTableState::default();
    let mut gen = GenState::default();
    let mut pml = PluginMLState::default();
    let mut pyspice_buf = String::new();
    let mut doc_buf = String::new();
    let mut code_buf = String::new();

    for (lineno, raw) in data.lines().enumerate() {
        w.line = lineno as u32 + 1;
        let full = raw.trim_end();
        let line = strip_comment(full);
        if line.is_empty() {
            continue;
        }
        let trimmed = line.trim_start();
        let indent = indent_level(line);

        // --- Multiline accumulators ---
        match section {
            Section::Pyspice if indent >= 1 => {
                accumulate(&mut pyspice_buf, trimmed);
                continue;
            }
            Section::Pyspice => {
                s.pyspice_source = std::mem::take(&mut pyspice_buf);
                section = Section::None;
            }
            Section::Documentation if indent >= 1 => {
                accumulate(&mut doc_buf, trimmed);
                continue;
            }
            Section::Documentation => {
                s.documentation = std::mem::take(&mut doc_buf);
                section = Section::None;
            }
            Section::CodeBlock if indent >= 2 => {
                accumulate(&mut code_buf, trimmed);
                continue;
            }
            Section::CodeBlock => {
                s.spice_body = std::mem::take(&mut code_buf);
                section = Section::None;
            }
            Section::PluginMultiline if indent >= 2 => {
                pml.lines.push(trimmed.to_string());
                continue;
            }
            Section::PluginMultiline => {
                flush_plugin_ml(s, &mut pml, int);
                section = Section::Plugin;
            }
            Section::Generate if indent >= 2 => {
                gen.lines.push(trimmed.to_string());
                continue;
            }
            Section::Generate => {
                expand_generate(s, &gen, int, w);
                gen = GenState::default();
                section = Section::None;
            }
            _ => {}
        }

        // --- Indent 0: top-level declarations ---
        if indent == 0 {
            if trimmed.starts_with("chn_prim") {
                s.stype = SchematicType::Primitive;
            } else if trimmed.starts_with("chn_testbench") {
                s.stype = SchematicType::Testbench;
            } else if let Some(rest) = trimmed.strip_prefix("SYMBOL ") {
                s.name = rest.trim().to_string();
                s.stype = SchematicType::Symbol;
            } else if let Some(rest) = trimmed.strip_prefix("TESTBENCH ") {
                s.name = rest.trim().to_string();
                s.stype = SchematicType::Testbench;
            } else if let Some(rest) = trimmed.strip_prefix("SCHEMATIC ") {
                s.name = rest.trim().to_string();
                s.stype = SchematicType::Schematic;
            } else if trimmed == "SCHEMATIC" {
                s.stype = SchematicType::Schematic;
            } else if let Some(rest) = trimmed.strip_prefix("PLUGIN ") {
                let name = rest.trim();
                s.plugin_blocks.push(PluginBlock {
                    name: int.get_or_intern(name),
                    entries: Vec::new(),
                });
                section = Section::Plugin;
                continue;
            } else if trimmed == "PYSPICE" {
                section = Section::Pyspice;
                continue;
            } else if trimmed == "DOCUMENTATION" {
                section = Section::Documentation;
                continue;
            }
            section = Section::None;
            continue;
        }

        // --- Indent 1: section headers or plugin entries ---
        if indent == 1 {
            // Plugin entries at indent 1
            if section == Section::Plugin {
                parse_plugin_entry(s, trimmed, &mut pml, &mut section, int);
                continue;
            }

            // Symbol metadata
            if let Some(rest) = trimmed.strip_prefix("desc: ") {
                s.sym_properties.push(Property {
                    key: int.get_or_intern("description"),
                    value: int.get_or_intern(rest.trim()),
                });
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("type: ") {
                s.sym_properties.push(Property {
                    key: int.get_or_intern("type"),
                    value: int.get_or_intern(rest.trim()),
                });
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("stimulus_lang: ") {
                if let Some(lang) = StimulusLang::from_name(rest.trim()) {
                    s.stimulus_lang = lang;
                }
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("sim_backend: ") {
                if let Some(be) = SpiceBackend::from_name(rest.trim()) {
                    s.sim_backend = be;
                }
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("sim_corner: ") {
                s.sim_corner = rest.trim().to_string();
                continue;
            }

            let sec_name = trimmed.trim_end_matches(':');
            section = match sec_name {
                "pins" => Section::Pins,
                "params" | "parameters" => Section::Params,
                "instances" => Section::Instances,
                "wires" => Section::Wires,
                "buses" => Section::Buses,
                "bus_rippers" => Section::BusRippers,
                "drawing" => Section::Drawing,
                "analyses" => Section::Analyses,
                "measures" | "measurements" => Section::Measures,
                "code" | "code_block" | "spice_code" => Section::CodeBlock,
                "annotations" => Section::Annotations,
                _ => {
                    if trimmed.contains('{') && trimmed.contains('}') {
                        if let Some(parsed) = parse_type_table_header(trimmed) {
                            tt = parsed;
                            Section::TypeTable
                        } else {
                            w.warn(format!(
                                "malformed type table header '{trimmed}', section skipped"
                            ));
                            Section::Skip
                        }
                    } else if trimmed.starts_with("generate ") {
                        if let Some(g) = parse_generate_header(trimmed) {
                            gen = g;
                            Section::Generate
                        } else {
                            w.warn(format!(
                                "malformed generate header '{trimmed}', section skipped"
                            ));
                            Section::Skip
                        }
                    } else {
                        w.warn(format!("unknown section '{sec_name}', contents skipped"));
                        Section::Skip
                    }
                }
            };
            continue;
        }

        // --- Indent 2+: section content ---
        match section {
            Section::Pins => parse_pin(s, trimmed, int, w),
            Section::Params => parse_param(s, trimmed, int),
            Section::Instances => parse_instance(s, trimmed, int, w),
            Section::TypeTable => parse_type_table_row(s, &tt, trimmed, int, w),
            Section::Wires => parse_wire(s, trimmed, int, w),
            Section::Buses => parse_bus(s, trimmed, int, w),
            Section::BusRippers => parse_bus_ripper(s, trimmed, w),
            Section::Drawing => parse_drawing(s, trimmed, int, w),
            Section::Analyses => parse_prefixed(s, "analysis.", trimmed, int),
            Section::Measures => parse_prefixed(s, "measure.", trimmed, int),
            Section::Annotations => parse_prefixed(s, "ann.", trimmed, int),
            Section::Plugin => parse_plugin_entry(s, trimmed, &mut pml, &mut section, int),
            Section::Skip => {} // silently ignore content in unknown sections
            _ => {}
        }
    }

    // Flush remaining accumulators
    if !pyspice_buf.is_empty() {
        s.pyspice_source = pyspice_buf;
    }
    if !doc_buf.is_empty() {
        s.documentation = doc_buf;
    }
    if !code_buf.is_empty() {
        s.spice_body = code_buf;
    }
    if !pml.lines.is_empty() {
        flush_plugin_ml(s, &mut pml, int);
    }
    if !gen.lines.is_empty() {
        expand_generate(s, &gen, int, w);
    }
}

// ── Section parsers ─────────────────────────────────────────────────────────

/// Pin: `name dir [x=X] [y=Y] [width=N]`
fn parse_pin(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let name = match tok.next() {
        Some(n) => n,
        None => return,
    };
    let dir_str = tok.next().unwrap_or("inout");
    let direction = match dir_str {
        "in" | "input" => PinDirection::Input,
        "out" | "output" => PinDirection::Output,
        "inout" => PinDirection::InOut,
        "power" => PinDirection::Power,
        "ground" | "gnd" => PinDirection::Ground,
        other => {
            w.warn(format!("unknown pin direction '{other}', using inout"));
            PinDirection::InOut
        }
    };
    let mut x = 0i32;
    let mut y = 0i32;
    let mut width = 1u8;
    for attr in tok {
        if let Some(v) = attr.strip_prefix("x=") {
            x = w.num("pin x", v, 0);
        } else if let Some(v) = attr.strip_prefix("y=") {
            y = w.num("pin y", v, 0);
        } else if let Some(v) = attr.strip_prefix("width=") {
            width = w.num("pin width", v, 1);
        }
    }
    s.pins.push(Pin {
        name: int.get_or_intern(name),
        x,
        y,
        width,
        direction,
    });
}

/// Param: `key = value`
fn parse_param(s: &mut Schematic, line: &str, int: &mut Rodeo) {
    let Some(eq) = line.find('=') else { return };
    let key = line[..eq].trim();
    let val = line[eq + 1..].trim();
    if key.is_empty() {
        return;
    }
    s.sym_properties.push(Property {
        key: int.get_or_intern(key),
        value: int.get_or_intern(val),
    });
}

/// Instance: `name symbol [x=X] [y=Y] [rot=R] [flip=1] [key=val...]`
fn parse_instance(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let name = match tok.next() {
        Some(n) => n,
        None => return,
    };
    let symbol = match tok.next() {
        Some(sym) => sym,
        None => return,
    };

    let mut x = 0i32;
    let mut y = 0i32;
    let mut rotation = 0u8;
    let mut flip = false;
    let prop_start = s.properties.len() as u32;

    // Check for .parameters{} block
    let rest: String = tok.collect::<Vec<_>>().join(" ");
    let (attrs, params_block) = if let Some(start) = rest.find(".parameters{") {
        let end = rest[start..]
            .find('}')
            .map(|e| start + e + 1)
            .unwrap_or(rest.len());
        let block = &rest[start + 12..end.saturating_sub(1)];
        let before = rest[..start].to_string();
        (before, Some(block.to_string()))
    } else {
        (rest, None)
    };

    for attr in split_kv_attrs(&attrs) {
        if let Some(v) = attr.strip_prefix("x=") {
            x = w.num("instance x", v, 0);
        } else if let Some(v) = attr.strip_prefix("y=") {
            y = w.num("instance y", v, 0);
        } else if let Some(v) = attr.strip_prefix("rot=") {
            rotation = w.num("instance rot", v, 0);
        } else if attr == "flip=1" {
            flip = true;
        } else if attr.starts_with("sym=") {
            // Symbol override -- skip, already have symbol
        } else if let Some(eq) = attr.find('=') {
            let k = &attr[..eq];
            let v = attr[eq + 1..].trim_matches('"');
            s.properties.push(Property {
                key: int.get_or_intern(k),
                value: int.get_or_intern(v),
            });
        }
    }

    // Parse .parameters{} block
    if let Some(block) = params_block {
        for param in block.split_whitespace() {
            if let Some(eq) = param.find('=') {
                let k = &param[..eq];
                let v = &param[eq + 1..];
                s.properties.push(Property {
                    key: int.get_or_intern(k),
                    value: int.get_or_intern(v),
                });
            }
        }
    }

    let prop_count = (s.properties.len() as u32 - prop_start) as u16;
    let kind = symbol_to_kind(symbol);

    s.instances.push(Instance {
        name: int.get_or_intern(name),
        symbol: int.get_or_intern(symbol),
        x,
        y,
        kind,
        flags: InstanceFlags::new(rotation, flip),
        prop_start,
        prop_count,
    });
}

/// Type table row: values matched to column headers
fn parse_type_table_row(
    s: &mut Schematic,
    tt: &TypeTableState,
    line: &str,
    int: &mut Rodeo,
    w: &mut Warnings,
) {
    let vals: Vec<&str> = line.split_whitespace().collect();
    if vals.is_empty() {
        return;
    }

    let mut x = 0i32;
    let mut y = 0i32;
    let mut rotation = 0u8;
    let mut flip = false;
    let mut name = "";
    let prop_start = s.properties.len() as u32;

    for (i, col) in tt.columns.iter().enumerate() {
        let val = vals.get(i).copied().unwrap_or("");
        match col.as_str() {
            "name" => name = val,
            "x" => x = w.num("x", val, 0),
            "y" => y = w.num("y", val, 0),
            "rot" => rotation = w.num("rot", val, 0),
            "flip" => flip = val == "1",
            _ => {
                s.properties.push(Property {
                    key: int.get_or_intern(col),
                    value: int.get_or_intern(val),
                });
            }
        }
    }

    let prop_count = (s.properties.len() as u32 - prop_start) as u16;

    s.instances.push(Instance {
        name: int.get_or_intern(name),
        symbol: int.get_or_intern(&tt.symbol),
        x,
        y,
        kind: tt.kind,
        flags: InstanceFlags::new(rotation, flip),
        prop_start,
        prop_count,
    });
}

/// Wire: `x0 y0 x1 y1 [net_name] [bus=1] [color=#RRGGBB]`
fn parse_wire(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let x0: i32 = w.req_num("wire x0", tok.next(), 0);
    let y0: i32 = w.req_num("wire y0", tok.next(), 0);
    let x1: i32 = w.req_num("wire x1", tok.next(), 0);
    let y1: i32 = w.req_num("wire y1", tok.next(), 0);

    // Skip zero-length wires
    if x0 == x1 && y0 == y1 {
        return;
    }

    let mut color = Color::NONE;

    for attr in tok {
        if attr == "bus=1" {
            // bus field removed -- ignore for backward compat
        } else if let Some(hex) = attr.strip_prefix("color=#") {
            color = w.hex_color(hex);
        }
    }

    // Net name: bare word after coordinates, before key=value attrs.
    let net_sym: Option<Sym> = line
        .split_whitespace()
        .nth(4)
        .filter(|attr| !attr.contains('='))
        .map(|attr| int.get_or_intern(attr));

    s.wires.push(Wire {
        net_name: net_sym,
        x0,
        y0,
        x1,
        y1,
        color,
        thickness: 0,
    });
}

/// Bus: `label width start_bit x0 y0 x1 y1 [color=#RRGGBB]`
fn parse_bus(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let label = match tok.next() {
        Some(l) => l,
        None => return,
    };
    let width: u16 = w.req_num("bus width", tok.next(), 1);
    let start_bit: u16 = w.req_num("bus start_bit", tok.next(), 0);
    let x0: i32 = w.req_num("bus x0", tok.next(), 0);
    let y0: i32 = w.req_num("bus y0", tok.next(), 0);
    let x1: i32 = w.req_num("bus x1", tok.next(), 0);
    let y1: i32 = w.req_num("bus y1", tok.next(), 0);

    let mut color = Color::NONE;
    for attr in tok {
        if let Some(hex) = attr.strip_prefix("color=#") {
            color = w.hex_color(hex);
        }
    }

    s.buses.push(Bus {
        label: int.get_or_intern(label),
        width,
        start_bit,
        x0,
        y0,
        x1,
        y1,
        color,
        thickness: 0,
    });
}

/// BusRipper: `bus_idx bit x y dir=D stub=S`
fn parse_bus_ripper(s: &mut Schematic, line: &str, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let bus_idx: u32 = w.req_num("ripper bus_idx", tok.next(), 0);
    let bit: u16 = w.req_num("ripper bit", tok.next(), 0);
    let x: i32 = w.req_num("ripper x", tok.next(), 0);
    let y: i32 = w.req_num("ripper y", tok.next(), 0);

    let mut direction: u8 = 0;
    let mut stub_len: i16 = 20;
    for attr in tok {
        if let Some(v) = attr.strip_prefix("dir=") {
            // Valid domain is 0-3; mask once at the parse boundary.
            direction = w.num::<u8>("ripper dir", v, 0) & 0x03;
        } else if let Some(v) = attr.strip_prefix("stub=") {
            stub_len = w.num("ripper stub", v, 20);
        }
    }

    s.bus_rippers.push(BusRipper {
        bus_idx,
        bit,
        x,
        y,
        direction,
        stub_len,
    });
}

/// Drawing: `line|rect|circle|arc|text|polygon ...`
fn parse_drawing(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let shape = match tok.next() {
        Some(s) => s,
        None => return,
    };

    match shape {
        "text" => parse_text_item(s, line, int, w),
        "polygon" => parse_polygon_item(s, line, w),
        _ => {
            let nums: Vec<i32> = tok.filter_map(|v| v.parse().ok()).collect();
            match shape {
                "line" if nums.len() >= 4 => {
                    s.lines.push(Line {
                        x0: nums[0],
                        y0: nums[1],
                        x1: nums[2],
                        y1: nums[3],
                        color: Color::NONE,
                        thickness: 0,
                    });
                }
                "rect" if nums.len() >= 4 => {
                    s.rects.push(Rect {
                        x: nums[0],
                        y: nums[1],
                        width: nums[2] - nums[0],
                        height: nums[3] - nums[1],
                        fill: Color::NONE,
                        stroke: Color::NONE,
                        thickness: 0,
                    });
                }
                "circle" if nums.len() >= 3 => {
                    s.circles.push(Circle {
                        cx: nums[0],
                        cy: nums[1],
                        radius: nums[2],
                        fill: Color::NONE,
                        stroke: Color::NONE,
                        thickness: 0,
                    });
                }
                "arc" if nums.len() >= 5 => {
                    s.arcs.push(Arc {
                        cx: nums[0],
                        cy: nums[1],
                        radius: nums[2],
                        start_angle: nums[3] as f32,
                        sweep_angle: nums[4] as f32,
                        stroke: Color::NONE,
                        thickness: 0,
                    });
                }
                "line" | "rect" | "circle" | "arc" => {
                    w.warn(format!("{shape} needs more coordinates, skipped"));
                }
                other => {
                    w.warn(format!("unknown drawing shape '{other}', skipped"));
                }
            }
        }
    }
}

/// Text: `text x y font_size rotation "content" [color=#RRGGBB]`
fn parse_text_item(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let rest = match line.strip_prefix("text ") {
        Some(r) => r.trim_start(),
        None => return,
    };

    let mut tok = rest.split_whitespace();
    let x: i32 = w.req_num("text x", tok.next(), 0);
    let y: i32 = w.req_num("text y", tok.next(), 0);
    let font_size_i: i32 = w.opt_num("text font size", tok.next(), 12);
    let rotation: u8 = w.opt_num("text rotation", tok.next(), 0);

    // Extract quoted content from the rest of the line
    let after_rotation = rest
        .splitn(5, char::is_whitespace)
        .nth(4)
        .unwrap_or("")
        .trim_start();

    let (content, trailing) = if let Some(after_quote) = after_rotation.strip_prefix('"') {
        // Find the closing quote
        if let Some(end) = after_quote.find('"') {
            (&after_quote[..end], &after_quote[end + 1..])
        } else {
            // No closing quote -- take everything
            (after_quote, "")
        }
    } else {
        // No quotes -- take the next token
        let end = after_rotation
            .find(char::is_whitespace)
            .unwrap_or(after_rotation.len());
        (&after_rotation[..end], &after_rotation[end..])
    };

    let mut color = Color::NONE;
    for attr in trailing.split_whitespace() {
        if let Some(hex) = attr.strip_prefix("color=#") {
            color = w.hex_color(hex);
        }
    }

    s.texts.push(Text {
        x,
        y,
        content: int.get_or_intern(content),
        font_size: font_size_i as f32,
        color,
        rotation,
    });
}

/// Polygon: `polygon x0,y0 x1,y1 ... [thickness=N] [fill=#RRGGBB] [stroke=#RRGGBB]`
fn parse_polygon_item(s: &mut Schematic, line: &str, w: &mut Warnings) {
    let rest = match line.strip_prefix("polygon ") {
        Some(r) => r.trim_start(),
        None => return,
    };

    let mut points = Vec::new();
    let mut thickness: u8 = 0;
    let mut fill = Color::NONE;
    let mut stroke = Color::NONE;

    for tok in rest.split_whitespace() {
        if let Some(v) = tok.strip_prefix("thickness=") {
            thickness = w.num("polygon thickness", v, 0);
        } else if let Some(hex) = tok.strip_prefix("fill=#") {
            fill = w.hex_color(hex);
        } else if let Some(hex) = tok.strip_prefix("stroke=#") {
            stroke = w.hex_color(hex);
        } else if let Some(comma) = tok.find(',') {
            let xv: i32 = w.num("polygon x", &tok[..comma], 0);
            let yv: i32 = w.num("polygon y", &tok[comma + 1..], 0);
            points.push([xv, yv]);
        }
    }

    if points.len() >= 3 {
        s.polygons.push(Polygon {
            points,
            fill,
            stroke,
            thickness,
        });
    } else if !points.is_empty() {
        w.warn(format!(
            "polygon needs >= 3 points, got {}, skipped",
            points.len()
        ));
    }
}

/// Prefixed property: `key: value` -> stored with prefix in sym_properties
fn parse_prefixed(s: &mut Schematic, prefix: &str, line: &str, int: &mut Rodeo) {
    let sep = if line.contains(": ") { ": " } else { ":" };
    let Some(idx) = line.find(sep) else { return };
    let key = line[..idx].trim();
    let val = line[idx + sep.len()..].trim();
    if key.is_empty() {
        return;
    }
    let full_key = format!("{prefix}{key}");
    s.sym_properties.push(Property {
        key: int.get_or_intern(&full_key),
        value: int.get_or_intern(val),
    });
}

/// Plugin entry: `key: value` or `key: |` (start multiline)
fn parse_plugin_entry(
    s: &mut Schematic,
    line: &str,
    pml: &mut PluginMLState,
    section: &mut Section,
    int: &mut Rodeo,
) {
    let Some(colon) = line.find(':') else { return };
    let key = line[..colon].trim();
    let val = line[colon + 1..].trim();

    let plugin_idx = s.plugin_blocks.len().saturating_sub(1);

    if val == "|" {
        // Start multiline
        pml.plugin_idx = plugin_idx;
        pml.key = key.to_string();
        pml.lines.clear();
        *section = Section::PluginMultiline;
        return;
    }

    if let Some(block) = s.plugin_blocks.get_mut(plugin_idx) {
        block.entries.push(Property {
            key: int.get_or_intern(key),
            value: int.get_or_intern(val),
        });
    }
}

// ── Generate block expansion ────────────────────────────────────────────────

fn parse_generate_header(line: &str) -> Option<GenState> {
    // `generate i: range 0..3`
    let rest = line.strip_prefix("generate ")?.trim();
    let colon = rest.find(':')?;
    let var_name = rest[..colon].trim().to_string();
    let range_part = rest[colon + 1..].trim().strip_prefix("range ")?.trim();
    let dots = range_part.find("..")?;
    let start: i32 = range_part[..dots].trim().parse().ok()?;
    let end: i32 = range_part[dots + 2..].trim().parse().ok()?;
    Some(GenState {
        var_name,
        range_start: start,
        range_end: end,
        lines: Vec::new(),
    })
}

fn expand_generate(s: &mut Schematic, gen: &GenState, int: &mut Rodeo, w: &mut Warnings) {
    let placeholder = format!("{{{}}}", gen.var_name);
    for i in gen.range_start..=gen.range_end {
        let i_str = i.to_string();
        for line in &gen.lines {
            let expanded = line.replace(&placeholder, &i_str);
            let trimmed = expanded.trim();
            // Route expanded lines through the instance parser
            if trimmed.contains(" x=") || trimmed.contains(" y=") {
                parse_instance(s, trimmed, int, w);
            }
        }
    }
}

// ── Type table header parser ────────────────────────────────────────────────

fn parse_type_table_header(line: &str) -> Option<TypeTableState> {
    // `nmos4 [5] {name x y rot flip W L}:`
    let open_brace = line.find('{')?;
    let close_brace = line.find('}')?;
    let symbol = line[..open_brace].trim();
    // Strip optional count: `nmos4 [5]` -> `nmos4`
    let symbol = symbol.split('[').next()?.trim();
    let cols_str = &line[open_brace + 1..close_brace];
    let columns: Vec<String> = cols_str.split_whitespace().map(String::from).collect();
    if columns.is_empty() {
        return None;
    }
    Some(TypeTableState {
        kind: symbol_to_kind(symbol),
        symbol: symbol.to_string(),
        columns,
    })
}

fn flush_plugin_ml(s: &mut Schematic, pml: &mut PluginMLState, int: &mut Rodeo) {
    let joined = pml.lines.join("\n");
    if let Some(block) = s.plugin_blocks.get_mut(pml.plugin_idx) {
        block.entries.push(Property {
            key: int.get_or_intern(&pml.key),
            value: int.get_or_intern(&joined),
        });
    }
    pml.lines.clear();
}

// ── Reader helpers ──────────────────────────────────────────────────────────

fn indent_level(line: &str) -> usize {
    let spaces = line.len() - line.trim_start().len();
    spaces / 2
}

fn strip_comment(line: &str) -> &str {
    for (i, c) in line.char_indices() {
        if c == '#' && (i == 0 || line.as_bytes()[i - 1] == b' ' || line.as_bytes()[i - 1] == b'\t')
        {
            return line[..i].trim_end();
        }
    }
    line
}

fn accumulate(buf: &mut String, content: &str) {
    if !buf.is_empty() {
        buf.push('\n');
    }
    buf.push_str(content);
}

fn split_kv_attrs(s: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut in_quote = false;
    for ch in s.chars() {
        if ch == '"' {
            in_quote = !in_quote;
            current.push(ch);
        } else if ch.is_whitespace() && !in_quote {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

fn symbol_to_kind(name: &str) -> DeviceKind {
    match DeviceKind::from_name(name) {
        // Not a built-in name: runtime-registered symbols (project prims /
        // project subcircuits) carry their own kind.
        DeviceKind::Unknown => find_by_name(name)
            .map(|p| p.kind)
            .unwrap_or(DeviceKind::Unknown),
        k => k,
    }
}

// ====================================================
// .chn Writer (sections mirror the reader exactly)
// ====================================================


