//! Minimal TCL tokenizer.
//!
//! Splits TCL source into tokens: words, brace-delimited blocks,
//! bracket-delimited substitutions, and quoted strings.

/// A single TCL token.
#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    /// A bare word (command name, variable name, value).
    Word(String),
    /// Brace-delimited block `{...}` -- no substitution performed inside.
    Braces(String),
    /// Bracket-delimited command substitution `[...]`.
    Bracket(String),
    /// Double-quoted string `"..."` -- substitution performed inside.
    Quoted(String),
    /// End of command (newline or semicolon).
    EndOfCommand,
}

/// Tokenize a single TCL line (or multi-line string) into tokens.
pub fn tokenize(input: &str) -> Result<Vec<Token>, String> {
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();

    loop {
        // Skip whitespace (not newlines)
        while let Some(&ch) = chars.peek() {
            if ch == ' ' || ch == '\t' {
                chars.next();
            } else {
                break;
            }
        }

        match chars.peek() {
            None => break,
            Some(&ch) => match ch {
                '\n' | ';' => {
                    chars.next();
                    if tokens.last() != Some(&Token::EndOfCommand) {
                        tokens.push(Token::EndOfCommand);
                    }
                }
                '#' => {
                    // Comment -- skip rest of line
                    while let Some(&c) = chars.peek() {
                        if c == '\n' {
                            break;
                        }
                        chars.next();
                    }
                }
                '{' => {
                    chars.next();
                    let content = collect_braces(&mut chars)?;
                    tokens.push(Token::Braces(content));
                }
                '[' => {
                    chars.next();
                    let content = collect_brackets(&mut chars)?;
                    tokens.push(Token::Bracket(content));
                }
                '"' => {
                    chars.next();
                    let content = collect_quoted(&mut chars)?;
                    tokens.push(Token::Quoted(content));
                }
                '\\' => {
                    chars.next();
                    if let Some(&'\n') = chars.peek() {
                        chars.next();
                        while let Some(&c) = chars.peek() {
                            if c == ' ' || c == '\t' {
                                chars.next();
                            } else {
                                break;
                            }
                        }
                    } else {
                        let mut word = String::new();
                        if let Some(c) = chars.next() {
                            word.push(c);
                        }
                        collect_bare_word(&mut chars, &mut word);
                        tokens.push(Token::Word(word));
                    }
                }
                _ => {
                    let mut word = String::new();
                    collect_bare_word(&mut chars, &mut word);
                    if !word.is_empty() {
                        tokens.push(Token::Word(word));
                    }
                }
            },
        }
    }

    Ok(tokens)
}

fn collect_braces(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Result<String, String> {
    let mut depth = 1u32;
    let mut content = String::new();
    while let Some(ch) = chars.next() {
        match ch {
            '{' => {
                depth += 1;
                content.push('{');
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Ok(content);
                }
                content.push('}');
            }
            '\\' => {
                content.push('\\');
                if let Some(c) = chars.next() {
                    content.push(c);
                }
            }
            _ => content.push(ch),
        }
    }
    Err("unterminated braces".into())
}

fn collect_brackets(
    chars: &mut std::iter::Peekable<std::str::Chars<'_>>,
) -> Result<String, String> {
    let mut depth = 1u32;
    let mut content = String::new();
    while let Some(ch) = chars.next() {
        match ch {
            '[' => {
                depth += 1;
                content.push('[');
            }
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Ok(content);
                }
                content.push(']');
            }
            _ => content.push(ch),
        }
    }
    Err("unterminated brackets".into())
}

fn collect_quoted(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Result<String, String> {
    let mut content = String::new();
    while let Some(ch) = chars.next() {
        match ch {
            '"' => return Ok(content),
            '\\' => {
                if let Some(c) = chars.next() {
                    match c {
                        'n' => content.push('\n'),
                        't' => content.push('\t'),
                        '\\' => content.push('\\'),
                        '"' => content.push('"'),
                        '$' => content.push('$'),
                        '[' => content.push('['),
                        _ => {
                            content.push('\\');
                            content.push(c);
                        }
                    }
                }
            }
            _ => content.push(ch),
        }
    }
    Err("unterminated quoted string".into())
}

fn collect_bare_word(chars: &mut std::iter::Peekable<std::str::Chars<'_>>, word: &mut String) {
    while let Some(&ch) = chars.peek() {
        match ch {
            ' ' | '\t' | '\n' | ';' | '{' | '}' | '[' | ']' | '"' => break,
            '\\' => {
                chars.next();
                if let Some(c) = chars.next() {
                    if c == '\n' {
                        break;
                    }
                    word.push(c);
                }
            }
            _ => {
                word.push(ch);
                chars.next();
            }
        }
    }
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_command() {
        let tokens = tokenize("set x 42").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Word("42".into()),
            ]
        );
    }

    #[test]
    fn braces() {
        let tokens = tokenize("set x {hello world}").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Braces("hello world".into()),
            ]
        );
    }

    #[test]
    fn nested_braces() {
        let tokens = tokenize("set x {a {b} c}").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Braces("a {b} c".into()),
            ]
        );
    }

    #[test]
    fn quoted_string() {
        let tokens = tokenize(r#"set x "hello world""#).unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Quoted("hello world".into()),
            ]
        );
    }

    #[test]
    fn bracket_substitution() {
        let tokens = tokenize("set x [expr 1+2]").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Bracket("expr 1+2".into()),
            ]
        );
    }

    #[test]
    fn multiple_commands() {
        let tokens = tokenize("set x 1\nset y 2").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Word("1".into()),
                Token::EndOfCommand,
                Token::Word("set".into()),
                Token::Word("y".into()),
                Token::Word("2".into()),
            ]
        );
    }

    #[test]
    fn semicolon_separator() {
        let tokens = tokenize("set x 1; set y 2").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Word("1".into()),
                Token::EndOfCommand,
                Token::Word("set".into()),
                Token::Word("y".into()),
                Token::Word("2".into()),
            ]
        );
    }

    #[test]
    fn comment_ignored() {
        let tokens = tokenize("# this is a comment\nset x 1").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::EndOfCommand,
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Word("1".into()),
            ]
        );
    }

    #[test]
    fn escaped_quote_in_string() {
        let tokens = tokenize(r#"set x "hello \"world\"""#).unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::Word("set".into()),
                Token::Word("x".into()),
                Token::Quoted("hello \"world\"".into()),
            ]
        );
    }
}
