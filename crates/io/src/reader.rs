use lasso::Rodeo;

use schemify_core::schematic::*;
use schemify_core::simulation::{SpiceBackend, StimulusLang};
use schemify_core::types::*;

/// Parse a CHN file into a Schematic.
/// All strings are interned via the provided `Rodeo`.
pub fn read_chn(data: &str, interner: &mut Rodeo) -> Schematic {
    let mut sch = Schematic::default();
    parse(&mut sch, data, interner);
    sch
}

// ====================================================
// Parse State
// ====================================================

#[derive(Default, PartialEq)]
enum Section {
    #[default]
    None,
    Pins,
    Params,
    Instances,
    TypeTable,
    Nets,
    Wires,
    Drawing,
    Includes,
    Analyses,
    Measures,
    CodeBlock,
    Annotations,
    Generate,
    Plugin,
    PluginMultiline,
    Pyspice,
    Documentation,
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

// ====================================================
// Main Parser (line-by-line state machine)
// ====================================================

fn parse(s: &mut Schematic, data: &str, int: &mut Rodeo) {
    let mut section = Section::None;
    let mut tt = TypeTableState::default();
    let mut gen = GenState::default();
    let mut pml = PluginMLState::default();
    let mut pyspice_buf = String::new();
    let mut doc_buf = String::new();
    let mut code_buf = String::new();

    for raw in data.lines() {
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
                expand_generate(s, &gen, int);
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
            } else if trimmed.starts_with("SYMBOL ") {
                s.name = trimmed[7..].trim().to_string();
                s.stype = SchematicType::Symbol;
            } else if trimmed.starts_with("TESTBENCH ") {
                s.name = trimmed[10..].trim().to_string();
                s.stype = SchematicType::Testbench;
            } else if trimmed.starts_with("PLUGIN ") {
                let name = trimmed[7..].trim();
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
            if trimmed.starts_with("desc: ") {
                s.sym_properties.push(Property {
                    key: int.get_or_intern("description"),
                    value: int.get_or_intern(trimmed[6..].trim()),
                });
                continue;
            }
            if trimmed.starts_with("type: ") {
                s.sym_properties.push(Property {
                    key: int.get_or_intern("type"),
                    value: int.get_or_intern(trimmed[6..].trim()),
                });
                continue;
            }
            if trimmed.starts_with("stimulus_lang: ") {
                if let Some(lang) = StimulusLang::from_name(trimmed[15..].trim()) {
                    s.stimulus_lang = lang;
                }
                continue;
            }
            if trimmed.starts_with("sim_backend: ") {
                if let Some(be) = SpiceBackend::from_name(trimmed[13..].trim()) {
                    s.sim_backend = be;
                }
                continue;
            }

            let sec_name = trimmed.trim_end_matches(':');
            section = match sec_name {
                "pins" => Section::Pins,
                "params" | "parameters" => Section::Params,
                "instances" => Section::Instances,
                "nets" | "connections" => Section::Nets,
                "wires" => Section::Wires,
                "drawing" => Section::Drawing,
                "includes" => Section::Includes,
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
                            Section::None
                        }
                    } else if trimmed.starts_with("generate ") {
                        if let Some(g) = parse_generate_header(trimmed) {
                            gen = g;
                            Section::Generate
                        } else {
                            Section::None
                        }
                    } else {
                        Section::None
                    }
                }
            };
            continue;
        }

        // --- Indent 2+: section content ---
        match section {
            Section::Pins => parse_pin(s, trimmed, int),
            Section::Params => parse_param(s, trimmed, int),
            Section::Instances => parse_instance(s, trimmed, int),
            Section::TypeTable => parse_type_table_row(s, &tt, trimmed, int),
            Section::Wires => parse_wire(s, trimmed, int),
            Section::Drawing => parse_drawing(s, trimmed),
            Section::Analyses => parse_prefixed(s, "analysis.", trimmed, int),
            Section::Measures => parse_prefixed(s, "measure.", trimmed, int),
            Section::Annotations => parse_prefixed(s, "ann.", trimmed, int),
            Section::Plugin => parse_plugin_entry(s, trimmed, &mut pml, &mut section, int),
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
        expand_generate(s, &gen, int);
    }
}

// ====================================================
// Section Parsers
// ====================================================

/// Pin: `name dir [x=X] [y=Y] [width=N]`
fn parse_pin(s: &mut Schematic, line: &str, int: &mut Rodeo) {
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
        _ => PinDirection::InOut,
    };
    let mut x = 0i32;
    let mut y = 0i32;
    let mut width = 1u8;
    for attr in tok {
        if let Some(v) = attr.strip_prefix("x=") {
            x = v.parse().unwrap_or(0);
        } else if let Some(v) = attr.strip_prefix("y=") {
            y = v.parse().unwrap_or(0);
        } else if let Some(v) = attr.strip_prefix("width=") {
            width = v.parse().unwrap_or(1);
        }
    }
    s.pins.push(Pin {
        name: int.get_or_intern(name),
        x,
        y,
        number: s.pins.len() as u32,
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
fn parse_instance(s: &mut Schematic, line: &str, int: &mut Rodeo) {
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
        let end = rest[start..].find('}').map(|e| start + e + 1).unwrap_or(rest.len());
        let block = &rest[start + 12..end.saturating_sub(1)];
        let before = rest[..start].to_string();
        (before, Some(block.to_string()))
    } else {
        (rest, None)
    };

    for attr in attrs.split_whitespace() {
        if let Some(v) = attr.strip_prefix("x=") {
            x = v.parse().unwrap_or(0);
        } else if let Some(v) = attr.strip_prefix("y=") {
            y = v.parse().unwrap_or(0);
        } else if let Some(v) = attr.strip_prefix("rot=") {
            rotation = v.parse().unwrap_or(0);
        } else if attr == "flip=1" {
            flip = true;
        } else if attr.starts_with("sym=") {
            // Symbol override — skip, already have symbol
        } else if let Some(eq) = attr.find('=') {
            let k = &attr[..eq];
            let v = &attr[eq + 1..];
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
        spice_line: int.get_or_intern(""),
        x,
        y,
        kind,
        flags: InstanceFlags::new(rotation, flip, false),
        prop_start,
        prop_count,
        name_offset: [0, 0],
        param_offset: [0, 0],
    });
}

/// Type table row: values matched to column headers
fn parse_type_table_row(s: &mut Schematic, tt: &TypeTableState, line: &str, int: &mut Rodeo) {
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
            "x" => x = val.parse().unwrap_or(0),
            "y" => y = val.parse().unwrap_or(0),
            "rot" => rotation = val.parse().unwrap_or(0),
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
        spice_line: int.get_or_intern(""),
        x,
        y,
        kind: tt.kind,
        flags: InstanceFlags::new(rotation, flip, false),
        prop_start,
        prop_count,
        name_offset: [0, 0],
        param_offset: [0, 0],
    });
}

/// Wire: `x0 y0 x1 y1 [bus=1] [color=#RRGGBB] [net_name]`
fn parse_wire(s: &mut Schematic, line: &str, int: &mut Rodeo) {
    let mut tok = line.split_whitespace();
    let x0: i32 = tok.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let y0: i32 = tok.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let x1: i32 = tok.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let y1: i32 = tok.next().and_then(|v| v.parse().ok()).unwrap_or(0);

    // Skip zero-length wires
    if x0 == x1 && y0 == y1 {
        return;
    }

    let mut bus = false;
    let mut color = Color::NONE;
    let mut net_name = "";

    for attr in tok {
        if attr == "bus=1" {
            bus = true;
        } else if let Some(hex) = attr.strip_prefix("color=#") {
            color = parse_hex_color(hex);
        } else if !attr.contains('=') {
            net_name = attr;
        }
    }

    s.wires.push(Wire {
        net_name: int.get_or_intern(net_name),
        x0,
        y0,
        x1,
        y1,
        color,
        thickness: 0,
        bus,
    });
}

/// Drawing: `line|rect|circle|arc x0 y0 ...`
fn parse_drawing(s: &mut Schematic, line: &str) {
    let mut tok = line.split_whitespace();
    let shape = match tok.next() {
        Some(s) => s,
        None => return,
    };
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
        _ => {}
    }
}

/// Prefixed property: `key: value` → stored with prefix in sym_properties
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

// ====================================================
// Generate Block Expansion
// ====================================================

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

fn expand_generate(s: &mut Schematic, gen: &GenState, int: &mut Rodeo) {
    let placeholder = format!("{{{}}}", gen.var_name);
    for i in gen.range_start..=gen.range_end {
        let i_str = i.to_string();
        for line in &gen.lines {
            let expanded = line.replace(&placeholder, &i_str);
            let trimmed = expanded.trim();
            // Route expanded lines through instance/wire parsers
            if trimmed.contains(" x=") || trimmed.contains(" y=") {
                parse_instance(s, trimmed, int);
            }
        }
    }
}

// ====================================================
// Type Table Header Parser
// ====================================================

fn parse_type_table_header(line: &str) -> Option<TypeTableState> {
    // `nmos4 [5] {name x y rot flip W L}:`
    let open_brace = line.find('{')?;
    let close_brace = line.find('}')?;
    let symbol = line[..open_brace].trim();
    // Strip optional count: `nmos4 [5]` → `nmos4`
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

// ====================================================
// Plugin Multiline Flush
// ====================================================

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

// ====================================================
// Helpers
// ====================================================

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

fn parse_hex_color(hex: &str) -> Color {
    if hex.len() < 6 {
        return Color::NONE;
    }
    let r = u8::from_str_radix(&hex[0..2], 16).unwrap_or(0);
    let g = u8::from_str_radix(&hex[2..4], 16).unwrap_or(0);
    let b = u8::from_str_radix(&hex[4..6], 16).unwrap_or(0);
    Color::rgb(r, g, b)
}

fn symbol_to_kind(name: &str) -> DeviceKind {
    DeviceKind::from_name(name)
}
