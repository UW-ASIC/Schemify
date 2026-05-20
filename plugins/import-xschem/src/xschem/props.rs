//! XSchem property string parser.
//!
//! XSchem properties are `key=value` pairs separated by whitespace.
//! Values may be quoted with double quotes to include spaces.
//! Multi-line properties use newlines as separators.

use std::collections::HashMap;

/// Parse an XSchem property string into a key-value map.
///
/// Format: `key=value key2="value with spaces" key3=simple`
/// - Keys are alphanumeric + underscore
/// - Values without quotes end at next whitespace
/// - Values with double quotes capture everything until closing quote
/// - Newlines act as separators (multi-line property blocks)
pub fn parse_props(input: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    let mut chars = input.char_indices().peekable();

    while chars.peek().is_some() {
        // Skip whitespace and newlines
        skip_ws(&mut chars);
        if chars.peek().is_none() {
            break;
        }

        // Read key (until '=' or whitespace or end)
        let key_start = match chars.peek() {
            Some(&(i, _)) => i,
            None => break,
        };

        let mut key_end = key_start;
        while let Some(&(i, ch)) = chars.peek() {
            if ch == '=' || ch.is_whitespace() {
                key_end = i;
                break;
            }
            key_end = i + ch.len_utf8();
            chars.next();
        }

        let key = &input[key_start..key_end];
        if key.is_empty() {
            chars.next();
            continue;
        }

        // Check for '='
        if chars.peek().map(|&(_, c)| c) != Some('=') {
            // Bare key with no value -- store as key="" (flag-style)
            result.insert(key.to_string(), String::new());
            continue;
        }
        chars.next(); // consume '='

        // Read value
        let value = match chars.peek() {
            Some(&(_, '"')) => {
                // Quoted value
                chars.next(); // consume opening quote
                let val_start = match chars.peek() {
                    Some(&(i, _)) => i,
                    None => {
                        result.insert(key.to_string(), String::new());
                        continue;
                    }
                };
                let mut val_end = val_start;
                let mut found_close = false;
                while let Some(&(i, ch)) = chars.peek() {
                    if ch == '"' {
                        val_end = i;
                        chars.next();
                        found_close = true;
                        break;
                    }
                    val_end = i + ch.len_utf8();
                    chars.next();
                }
                if !found_close {
                    val_end = input.len();
                }
                input[val_start..val_end].to_string()
            }
            Some(&(i, ch)) if !ch.is_whitespace() => {
                // Unquoted value -- read until whitespace or newline
                let val_start = i;
                let mut val_end = val_start;
                while let Some(&(i, ch)) = chars.peek() {
                    if ch.is_whitespace() {
                        val_end = i;
                        break;
                    }
                    val_end = i + ch.len_utf8();
                    chars.next();
                }
                input[val_start..val_end].to_string()
            }
            _ => String::new(),
        };

        result.insert(key.to_string(), value);
    }

    result
}

/// Extract a specific property value, returning None if not found.
pub fn get_prop<'a>(props: &'a HashMap<String, String>, key: &str) -> Option<&'a str> {
    props.get(key).map(|s| s.as_str()).filter(|s| !s.is_empty())
}

fn skip_ws(chars: &mut std::iter::Peekable<std::str::CharIndices<'_>>) {
    while let Some(&(_, ch)) = chars.peek() {
        if ch.is_whitespace() {
            chars.next();
        } else {
            break;
        }
    }
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_props() {
        let props = parse_props("name=R1 value=10k");
        assert_eq!(props.get("name").unwrap(), "R1");
        assert_eq!(props.get("value").unwrap(), "10k");
    }

    #[test]
    fn quoted_values() {
        let props = parse_props(r#"name=R1 value="10k ohm" model=res"#);
        assert_eq!(props.get("name").unwrap(), "R1");
        assert_eq!(props.get("value").unwrap(), "10k ohm");
        assert_eq!(props.get("model").unwrap(), "res");
    }

    #[test]
    fn multiline_props() {
        let props = parse_props("name=R1\nvalue=10k\nmodel=res");
        assert_eq!(props.get("name").unwrap(), "R1");
        assert_eq!(props.get("value").unwrap(), "10k");
        assert_eq!(props.get("model").unwrap(), "res");
    }

    #[test]
    fn empty_props() {
        let props = parse_props("");
        assert!(props.is_empty());
    }

    #[test]
    fn whitespace_only() {
        let props = parse_props("   \n  \t  ");
        assert!(props.is_empty());
    }

    #[test]
    fn special_keys() {
        let props = parse_props("spice_prefix=M device=nmos");
        assert_eq!(props.get("spice_prefix").unwrap(), "M");
        assert_eq!(props.get("device").unwrap(), "nmos");
    }

    #[test]
    fn value_with_equals() {
        let props = parse_props(r#"name=R1 spice="R1 net1 net2 10k""#);
        assert_eq!(props.get("name").unwrap(), "R1");
        assert_eq!(props.get("spice").unwrap(), "R1 net1 net2 10k");
    }

    #[test]
    fn empty_value() {
        let props = parse_props("name= value=10k");
        assert_eq!(props.get("name").unwrap(), "");
        assert_eq!(props.get("value").unwrap(), "10k");
    }

    #[test]
    fn get_prop_helper() {
        let props = parse_props("name=R1 value=10k");
        assert_eq!(get_prop(&props, "name"), Some("R1"));
        assert_eq!(get_prop(&props, "nonexistent"), None);
    }

    #[test]
    fn complex_xschem_props() {
        let input = r#"name=M1 model=sky130_fd_pr__nfet_01v8 w=0.42 l=0.15 nf=1 mult=1 ad="'int((nf+1)/2) * W/nf * 0.29'" pd="'2*int((nf+1)/2) * (W/nf + 0.29)'"  as="'int((nf+2)/2) * W/nf * 0.29'" ps="'2*int((nf+2)/2) * (W/nf + 0.29)'" nrd="'0.29 / W'" nrs="'0.29 / W'" sa=0 sb=0 sd=0 spiceprefix=X"#;
        let props = parse_props(input);
        assert_eq!(props.get("name").unwrap(), "M1");
        assert_eq!(props.get("model").unwrap(), "sky130_fd_pr__nfet_01v8");
        assert_eq!(props.get("w").unwrap(), "0.42");
        assert_eq!(props.get("l").unwrap(), "0.15");
    }
}
