//! XSchem `.sch` / `.sym` file parser.
//!
//! Parses the line-based format into `XSchemDoc`. Handles brace-delimited
//! property blocks that may span multiple lines.

use super::types::{XSchemDoc, XSchemElement};
use crate::ParseError;

/// Parse an XSchem `.sch` or `.sym` file from its text content.
pub fn parse_xschem(input: &str) -> Result<XSchemDoc, ParseError> {
    let mut doc = XSchemDoc::default();
    let mut lines = input.lines().enumerate().peekable();

    while let Some((line_num, line)) = lines.next() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let first_char = match trimmed.chars().next() {
            Some(c) => c,
            None => continue,
        };

        match first_char {
            'v' => {
                // Version line: v {xschem version=X.Y.Z ...}
                if let Some(content) = extract_braces(trimmed, 1, line_num)? {
                    doc.version = Some(content.clone());
                    doc.elements.push(XSchemElement::Version(content));
                }
            }
            'C' => {
                parse_component(trimmed, line_num, &mut lines, &mut doc)?;
            }
            'N' => {
                parse_wire(trimmed, line_num, &mut lines, &mut doc)?;
            }
            'T' => {
                parse_text(trimmed, line_num, &mut lines, &mut doc)?;
            }
            'L' => {
                parse_line(trimmed, line_num, &mut doc)?;
            }
            'B' => {
                parse_box(trimmed, line_num, &mut lines, &mut doc)?;
            }
            'A' => {
                parse_arc(trimmed, line_num, &mut doc)?;
            }
            'P' => {
                parse_pin(trimmed, line_num, &mut lines, &mut doc)?;
            }
            'G' | 'K' | 'V' | 'S' | 'E' => {
                // Metadata blocks -- store raw content.
                let content = collect_braces_after(trimmed, 1, line_num, &mut lines)?;
                if first_char == 'S' && !content.trim().is_empty() {
                    doc.elements.push(XSchemElement::Spice(content.clone()));
                }
                doc.metadata.push((first_char, content));
            }
            '#' => {
                // Comment -- skip
            }
            _ => {
                // Unknown line -- skip silently for forward compatibility
            }
        }
    }

    Ok(doc)
}

// -- Component (C) --

fn parse_component<'a, I>(
    line: &str,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
    doc: &mut XSchemDoc,
) -> Result<(), ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    // C {symbol_path} x y rotation flip {props}
    let after_c = line[1..].trim_start();

    // Extract symbol path from braces
    let (symbol, rest) = extract_braced_token(after_c, line_num)?;

    // Parse: x y rotation flip
    let tokens: Vec<&str> = rest.trim().splitn(5, char::is_whitespace).collect();
    if tokens.len() < 4 {
        return Err(ParseError(format!(
            "line {}: C command needs at least x y rotation flip after symbol",
            line_num + 1
        )));
    }

    let x = parse_i32(tokens[0], line_num, "C.x")?;
    let y = parse_i32(tokens[1], line_num, "C.y")?;
    let rotation = parse_u8(tokens[2], line_num, "C.rotation")?;
    let flip = parse_bool_flag(tokens[3], line_num, "C.flip")?;

    // Remaining text after the 4 numeric tokens may contain inline props
    let remaining = if tokens.len() > 4 { tokens[4] } else { "" };
    let props = if remaining.starts_with('{') {
        extract_inline_or_multiline_braces(remaining, line_num, lines)?
    } else {
        // Props might be on the next line(s) in braces
        collect_next_braces(lines)
    };

    doc.elements.push(XSchemElement::Component {
        symbol,
        x,
        y,
        rotation,
        flip,
        props,
    });
    Ok(())
}

// -- Wire (N) --

fn parse_wire<'a, I>(
    line: &str,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
    doc: &mut XSchemDoc,
) -> Result<(), ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    // N x0 y0 x1 y1 {props}
    let after_n = line[1..].trim_start();
    let tokens: Vec<&str> = after_n.splitn(6, char::is_whitespace).collect();
    if tokens.len() < 4 {
        return Err(ParseError(format!(
            "line {}: N command needs x0 y0 x1 y1",
            line_num + 1
        )));
    }

    let x0 = parse_i32(tokens[0], line_num, "N.x0")?;
    let y0 = parse_i32(tokens[1], line_num, "N.y0")?;
    let x1 = parse_i32(tokens[2], line_num, "N.x1")?;
    let y1 = parse_i32(tokens[3], line_num, "N.y1")?;

    let remaining = if tokens.len() > 4 {
        tokens[4..].join(" ")
    } else {
        String::new()
    };
    let props = if remaining.starts_with('{') {
        extract_inline_or_multiline_braces(&remaining, line_num, lines)?
    } else {
        collect_next_braces(lines)
    };

    doc.elements.push(XSchemElement::Wire {
        x0,
        y0,
        x1,
        y1,
        props,
    });
    Ok(())
}

// -- Text (T) --

fn parse_text<'a, I>(
    line: &str,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
    doc: &mut XSchemDoc,
) -> Result<(), ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    // T {content} x y rotation flip size ... {props}
    let after_t = line[1..].trim_start();

    let (content, rest) = extract_braced_token(after_t, line_num)?;

    let tokens: Vec<&str> = rest.trim().splitn(6, char::is_whitespace).collect();
    if tokens.len() < 5 {
        return Err(ParseError(format!(
            "line {}: T command needs x y rotation flip size after content",
            line_num + 1
        )));
    }

    let x = parse_i32(tokens[0], line_num, "T.x")?;
    let y = parse_i32(tokens[1], line_num, "T.y")?;
    let rotation = parse_u8(tokens[2], line_num, "T.rotation")?;
    let flip = parse_bool_flag(tokens[3], line_num, "T.flip")?;
    let size = parse_f32(tokens[4], line_num, "T.size")?;

    let remaining = if tokens.len() > 5 { tokens[5] } else { "" };
    let props = if remaining.starts_with('{') {
        extract_inline_or_multiline_braces(remaining, line_num, lines)?
    } else {
        collect_next_braces(lines)
    };

    doc.elements.push(XSchemElement::Text {
        content,
        x,
        y,
        rotation,
        flip,
        size,
        props,
    });
    Ok(())
}

// -- Line (L) --

fn parse_line(line: &str, line_num: usize, doc: &mut XSchemDoc) -> Result<(), ParseError> {
    // L layer x0 y0 x1 y1 ...
    let after_l = line[1..].trim_start();
    let tokens: Vec<&str> = after_l.split_whitespace().collect();
    if tokens.len() < 5 {
        return Err(ParseError(format!(
            "line {}: L command needs layer x0 y0 x1 y1",
            line_num + 1
        )));
    }

    let layer = parse_u8(tokens[0], line_num, "L.layer")?;
    let x0 = parse_i32(tokens[1], line_num, "L.x0")?;
    let y0 = parse_i32(tokens[2], line_num, "L.y0")?;
    let x1 = parse_i32(tokens[3], line_num, "L.x1")?;
    let y1 = parse_i32(tokens[4], line_num, "L.y1")?;

    doc.elements.push(XSchemElement::Line {
        layer,
        x0,
        y0,
        x1,
        y1,
    });
    Ok(())
}

// -- Box (B) --

fn parse_box<'a, I>(
    line: &str,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
    doc: &mut XSchemDoc,
) -> Result<(), ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    // B layer x0 y0 x1 y1 {props}
    let after_b = line[1..].trim_start();
    let tokens: Vec<&str> = after_b.splitn(7, char::is_whitespace).collect();
    if tokens.len() < 5 {
        return Err(ParseError(format!(
            "line {}: B command needs layer x0 y0 x1 y1",
            line_num + 1
        )));
    }

    let layer = parse_u8(tokens[0], line_num, "B.layer")?;
    let x0 = parse_i32(tokens[1], line_num, "B.x0")?;
    let y0 = parse_i32(tokens[2], line_num, "B.y0")?;
    let x1 = parse_i32(tokens[3], line_num, "B.x1")?;
    let y1 = parse_i32(tokens[4], line_num, "B.y1")?;

    // B can also have props in braces (e.g., for filled rects with attributes)
    let remaining = if tokens.len() > 5 {
        tokens[5..].join(" ")
    } else {
        String::new()
    };

    // Consume any trailing braces block (some B lines have attribute props)
    if remaining.contains('{') {
        let _ = extract_inline_or_multiline_braces(&remaining, line_num, lines)?;
    } else {
        let _ = collect_next_braces(lines);
    }

    doc.elements.push(XSchemElement::Box {
        layer,
        x0,
        y0,
        x1,
        y1,
    });
    Ok(())
}

// -- Arc (A) --

fn parse_arc(line: &str, line_num: usize, doc: &mut XSchemDoc) -> Result<(), ParseError> {
    // A layer cx cy r start_angle sweep_angle ...
    let after_a = line[1..].trim_start();
    let tokens: Vec<&str> = after_a.split_whitespace().collect();
    if tokens.len() < 6 {
        return Err(ParseError(format!(
            "line {}: A command needs layer cx cy r start sweep",
            line_num + 1
        )));
    }

    let layer = parse_u8(tokens[0], line_num, "A.layer")?;
    let cx = parse_i32(tokens[1], line_num, "A.cx")?;
    let cy = parse_i32(tokens[2], line_num, "A.cy")?;
    let r = parse_i32(tokens[3], line_num, "A.r")?;
    let start = parse_f32(tokens[4], line_num, "A.start")?;
    let sweep = parse_f32(tokens[5], line_num, "A.sweep")?;

    doc.elements.push(XSchemElement::Arc {
        layer,
        cx,
        cy,
        r,
        start,
        sweep,
    });
    Ok(())
}

// -- Pin (P) --

fn parse_pin<'a, I>(
    line: &str,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
    doc: &mut XSchemDoc,
) -> Result<(), ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    // P layer npins x0 y0 x1 y1 ... {props}
    let after_p = line[1..].trim_start();
    let tokens: Vec<&str> = after_p.split_whitespace().collect();
    if tokens.len() < 5 {
        return Err(ParseError(format!(
            "line {}: P command needs layer npins x0 y0 x1 y1",
            line_num + 1
        )));
    }

    let layer = parse_u8(tokens[0], line_num, "P.layer")?;
    // tokens[1] = npins (number of pin vertices, usually 2)
    let x = parse_i32(tokens[2], line_num, "P.x0")?;
    let y = parse_i32(tokens[3], line_num, "P.y0")?;

    // Collect props from next line(s)
    let props = collect_next_braces(lines);

    // Extract direction from props
    let parsed = super::props::parse_props(&props);
    let direction = parsed
        .get("dir")
        .cloned()
        .unwrap_or_else(|| "inout".to_string());

    doc.elements.push(XSchemElement::Pin {
        layer,
        x,
        y,
        direction,
        props,
    });
    Ok(())
}

// -- Brace extraction helpers --

/// Extract a brace-delimited `{...}` token starting at offset `skip` into `s`.
fn extract_braces(s: &str, skip: usize, line_num: usize) -> Result<Option<String>, ParseError> {
    let rest = s[skip..].trim_start();
    if !rest.starts_with('{') {
        return Ok(None);
    }
    let start = 1;
    let mut depth = 1u32;
    for (i, ch) in rest[start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Ok(Some(rest[start..start + i].to_string()));
                }
            }
            _ => {}
        }
    }
    Err(ParseError(format!(
        "line {}: unmatched opening brace",
        line_num + 1
    )))
}

/// Extract a `{...}` token and return `(content, rest_of_line_after_closing_brace)`.
fn extract_braced_token(s: &str, line_num: usize) -> Result<(String, &str), ParseError> {
    if !s.starts_with('{') {
        return Err(ParseError(format!(
            "line {}: expected opening brace, got '{}'",
            line_num + 1,
            s.chars().next().unwrap_or('?')
        )));
    }
    let start = 1;
    let mut depth = 1u32;
    for (i, ch) in s[start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    let content = s[start..start + i].to_string();
                    let rest = &s[start + i + 1..];
                    return Ok((content, rest));
                }
            }
            _ => {}
        }
    }
    Err(ParseError(format!(
        "line {}: unmatched opening brace",
        line_num + 1
    )))
}

/// Extract brace content that may span multiple lines.
fn extract_inline_or_multiline_braces<'a, I>(
    s: &str,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
) -> Result<String, ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    let brace_start = match s.find('{') {
        Some(pos) => pos,
        None => return Ok(String::new()),
    };

    let after_open = &s[brace_start + 1..];
    let mut depth = 1u32;
    let mut content = String::new();

    for (i, ch) in after_open.char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Ok(after_open[..i].to_string());
                }
            }
            _ => {}
        }
    }

    // Braces span multiple lines
    content.push_str(after_open);
    content.push('\n');

    while let Some((ln, next_line)) = lines.next() {
        for (i, ch) in next_line.char_indices() {
            match ch {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        content.push_str(&next_line[..i]);
                        return Ok(content);
                    }
                }
                _ => {}
            }
        }
        content.push_str(next_line);
        content.push('\n');

        // Safety: prevent runaway on malformed input
        if ln > line_num + 1000 {
            return Err(ParseError(format!(
                "line {}: brace block exceeds 1000 lines",
                line_num + 1
            )));
        }
    }

    Err(ParseError(format!(
        "line {}: unterminated brace block",
        line_num + 1
    )))
}

/// Collect braces content starting from the next line(s) in the iterator.
fn collect_next_braces<'a, I>(lines: &mut std::iter::Peekable<I>) -> String
where
    I: Iterator<Item = (usize, &'a str)>,
{
    if let Some(&(_, next)) = lines.peek() {
        let trimmed = next.trim();
        if trimmed.starts_with('{') {
            // Consume the peeked line
            let (ln, _) = lines.next().unwrap();
            if let Ok(content) =
                extract_inline_or_multiline_braces(trimmed, ln, lines)
            {
                return content;
            }
        }
    }
    String::new()
}

/// Collect braces content from the remainder of `s` and subsequent lines.
fn collect_braces_after<'a, I>(
    s: &str,
    skip: usize,
    line_num: usize,
    lines: &mut std::iter::Peekable<I>,
) -> Result<String, ParseError>
where
    I: Iterator<Item = (usize, &'a str)>,
{
    let rest = s[skip..].trim_start();
    if rest.starts_with('{') {
        extract_inline_or_multiline_braces(rest, line_num, lines)
    } else {
        Ok(collect_next_braces(lines))
    }
}

// -- Numeric parsers --

fn parse_i32(s: &str, line_num: usize, field: &str) -> Result<i32, ParseError> {
    if let Ok(v) = s.parse::<i32>() {
        return Ok(v);
    }
    if let Ok(v) = s.parse::<f64>() {
        return Ok(v as i32);
    }
    Err(ParseError(format!(
        "line {}: invalid integer for {}: '{}'",
        line_num + 1,
        field,
        s
    )))
}

fn parse_u8(s: &str, line_num: usize, field: &str) -> Result<u8, ParseError> {
    s.parse::<u8>().map_err(|_| {
        ParseError(format!(
            "line {}: invalid u8 for {}: '{}'",
            line_num + 1,
            field,
            s
        ))
    })
}

fn parse_f32(s: &str, line_num: usize, field: &str) -> Result<f32, ParseError> {
    s.parse::<f32>().map_err(|_| {
        ParseError(format!(
            "line {}: invalid float for {}: '{}'",
            line_num + 1,
            field,
            s
        ))
    })
}

fn parse_bool_flag(s: &str, line_num: usize, field: &str) -> Result<bool, ParseError> {
    match s {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(ParseError(format!(
            "line {}: invalid bool flag for {}: '{}' (expected 0 or 1)",
            line_num + 1,
            field,
            s
        ))),
    }
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_version() {
        let input = "v {xschem version=3.4.5 file_version=1.2}\n";
        let doc = parse_xschem(input).unwrap();
        assert!(doc.version.is_some());
        assert!(doc.version.unwrap().contains("xschem"));
    }

    #[test]
    fn parse_component() {
        let input = r#"v {xschem version=3.4.5}
C {devices/res.sym} 100 200 0 0 {name=R1 value=10k}
"#;
        let doc = parse_xschem(input).unwrap();
        let comp = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Component { .. }));
        assert!(comp.is_some());
        if let Some(XSchemElement::Component {
            symbol,
            x,
            y,
            rotation,
            flip,
            props,
        }) = comp
        {
            assert_eq!(symbol, "devices/res.sym");
            assert_eq!(*x, 100);
            assert_eq!(*y, 200);
            assert_eq!(*rotation, 0);
            assert!(!flip);
            assert!(props.contains("name=R1"));
        }
    }

    #[test]
    fn parse_wire() {
        let input = "N 100 200 300 400 {lab=VCC}\n";
        let doc = parse_xschem(input).unwrap();
        let wire = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Wire { .. }));
        assert!(wire.is_some());
        if let Some(XSchemElement::Wire {
            x0, y0, x1, y1, props,
        }) = wire
        {
            assert_eq!(*x0, 100);
            assert_eq!(*y0, 200);
            assert_eq!(*x1, 300);
            assert_eq!(*y1, 400);
            assert!(props.contains("lab=VCC"));
        }
    }

    #[test]
    fn parse_text() {
        let input = "T {Hello World} 50 60 0 0 0.4 0.4 {}\n";
        let doc = parse_xschem(input).unwrap();
        let text = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Text { .. }));
        assert!(text.is_some());
        if let Some(XSchemElement::Text { content, x, y, size, .. }) = text {
            assert_eq!(content, "Hello World");
            assert_eq!(*x, 50);
            assert_eq!(*y, 60);
            assert!(*size > 0.3);
        }
    }

    #[test]
    fn parse_line_element() {
        let input = "L 4 100 200 300 400\n";
        let doc = parse_xschem(input).unwrap();
        let line = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Line { .. }));
        assert!(line.is_some());
        if let Some(XSchemElement::Line { layer, x0, y0, x1, y1 }) = line {
            assert_eq!(*layer, 4);
            assert_eq!(*x0, 100);
            assert_eq!(*y0, 200);
            assert_eq!(*x1, 300);
            assert_eq!(*y1, 400);
        }
    }

    #[test]
    fn parse_box_element() {
        let input = "B 5 0 0 100 200\n";
        let doc = parse_xschem(input).unwrap();
        let b = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Box { .. }));
        assert!(b.is_some());
    }

    #[test]
    fn parse_arc_element() {
        let input = "A 4 100 200 50 0 360\n";
        let doc = parse_xschem(input).unwrap();
        let arc = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Arc { .. }));
        assert!(arc.is_some());
        if let Some(XSchemElement::Arc { layer, cx, cy, r, start, sweep }) = arc {
            assert_eq!(*layer, 4);
            assert_eq!(*cx, 100);
            assert_eq!(*cy, 200);
            assert_eq!(*r, 50);
            assert_eq!(*start, 0.0);
            assert_eq!(*sweep, 360.0);
        }
    }

    #[test]
    fn parse_multiline_props() {
        let input = "v {xschem version=3.4.5}\nC {devices/res.sym} 100 200 0 0 {name=R1\nvalue=10k\nmodel=res}\n";
        let doc = parse_xschem(input).unwrap();
        let comp = doc
            .elements
            .iter()
            .find(|e| matches!(e, XSchemElement::Component { .. }));
        assert!(comp.is_some());
        if let Some(XSchemElement::Component { props, .. }) = comp {
            assert!(props.contains("name=R1"));
            assert!(props.contains("value=10k"));
        }
    }

    #[test]
    fn parse_empty_input() {
        let doc = parse_xschem("").unwrap();
        assert!(doc.elements.is_empty());
    }

    #[test]
    fn parse_comments_ignored() {
        let input = "# this is a comment\nN 0 0 100 100 {}\n";
        let doc = parse_xschem(input).unwrap();
        assert_eq!(
            doc.elements
                .iter()
                .filter(|e| matches!(e, XSchemElement::Wire { .. }))
                .count(),
            1
        );
    }

    #[test]
    fn parse_multiple_elements() {
        let input = "v {xschem version=3.4.5}\nC {devices/res.sym} 100 200 0 0 {name=R1 value=10k}\nC {devices/cap.sym} 300 400 1 1 {name=C1 value=1u}\nN 100 200 300 200 {}\nN 300 400 500 400 {lab=net1}\n";
        let doc = parse_xschem(input).unwrap();
        let components: Vec<_> = doc
            .elements
            .iter()
            .filter(|e| matches!(e, XSchemElement::Component { .. }))
            .collect();
        let wires: Vec<_> = doc
            .elements
            .iter()
            .filter(|e| matches!(e, XSchemElement::Wire { .. }))
            .collect();
        assert_eq!(components.len(), 2);
        assert_eq!(wires.len(), 2);
    }
}
