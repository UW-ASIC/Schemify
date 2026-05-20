//! Minimal TCL script evaluator.
//!
//! Executes TCL commands in sequence, maintaining variable scope.
//! Supports variable substitution ($var, ${var}), command substitution ([cmd]),
//! and basic control flow (if, foreach).
//!
//! Designed for parsing xschemrc files -- not a full TCL interpreter.

use std::collections::HashMap;

use super::commands::{exec_builtin, substitute_vars, CmdResult};
use super::tokenizer::{tokenize, Token};

/// TCL interpreter state.
#[derive(Debug, Default)]
pub struct TclInterp {
    pub vars: HashMap<String, String>,
    pub lists: HashMap<String, Vec<String>>,
}

impl TclInterp {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set a variable before evaluation (e.g., seed env vars).
    pub fn set_var(&mut self, name: &str, value: &str) {
        self.vars.insert(name.into(), value.into());
    }

    /// Get a variable value after evaluation.
    pub fn get_var(&self, name: &str) -> Option<&str> {
        self.vars.get(name).map(|s| s.as_str())
    }

    /// Get a list variable.
    pub fn get_list(&self, name: &str) -> Option<&[String]> {
        self.lists.get(name).map(|v| v.as_slice())
    }

    /// Evaluate a TCL script string.
    pub fn eval(&mut self, script: &str) -> CmdResult {
        let mut source_fn = |_path: &str,
                              _vars: &mut HashMap<String, String>,
                              _lists: &mut HashMap<String, Vec<String>>,
                              _depth: u32|
         -> CmdResult {
            // Default: source is a no-op (no file access)
            Ok(String::new())
        };
        eval_script(script, &mut self.vars, &mut self.lists, 0, &mut source_fn)
    }

    /// Evaluate a TCL script with file access for `source` commands.
    pub fn eval_with_source(&mut self, script: &str) -> CmdResult {
        eval_script_with_file_source(script, &mut self.vars, &mut self.lists, 0)
    }
}

/// Evaluate a TCL script, given mutable access to variable and list state.
pub fn eval_script(
    script: &str,
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(
        &str,
        &mut HashMap<String, String>,
        &mut HashMap<String, Vec<String>>,
        u32,
    ) -> CmdResult,
) -> CmdResult {
    if depth > 100 {
        return Err("recursion depth exceeded (>100)".into());
    }

    let tokens = tokenize(script).map_err(|e| format!("tokenize error: {}", e))?;
    let mut last_result = String::new();
    let mut cmd_tokens: Vec<String> = Vec::new();

    for token in &tokens {
        match token {
            Token::EndOfCommand => {
                if !cmd_tokens.is_empty() {
                    last_result = execute_command(&cmd_tokens, vars, lists, depth, source_fn)?;
                    cmd_tokens.clear();
                }
            }
            Token::Word(w) => {
                // Perform variable and command substitution
                let expanded = expand_word(w, vars, lists, depth, source_fn)?;
                cmd_tokens.push(expanded);
            }
            Token::Braces(content) => {
                // No substitution inside braces
                cmd_tokens.push(content.clone());
            }
            Token::Quoted(content) => {
                // Perform substitution inside quotes
                let expanded = expand_word(content, vars, lists, depth, source_fn)?;
                cmd_tokens.push(expanded);
            }
            Token::Bracket(content) => {
                // Command substitution
                let result = eval_script(content, vars, lists, depth + 1, source_fn)?;
                cmd_tokens.push(result);
            }
        }
    }

    // Execute any remaining command
    if !cmd_tokens.is_empty() {
        last_result = execute_command(&cmd_tokens, vars, lists, depth, source_fn)?;
    }

    Ok(last_result)
}

fn execute_command(
    tokens: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(
        &str,
        &mut HashMap<String, String>,
        &mut HashMap<String, Vec<String>>,
        u32,
    ) -> CmdResult,
) -> CmdResult {
    if tokens.is_empty() {
        return Ok(String::new());
    }
    let cmd = &tokens[0];
    let args = &tokens[1..];
    exec_builtin(cmd, args, vars, lists, depth, source_fn)
}

fn expand_word(
    word: &str,
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(
        &str,
        &mut HashMap<String, String>,
        &mut HashMap<String, Vec<String>>,
        u32,
    ) -> CmdResult,
) -> CmdResult {
    let mut result = String::with_capacity(word.len());
    let mut chars = word.chars().peekable();

    while let Some(ch) = chars.next() {
        match ch {
            '$' => {
                // Variable substitution
                if chars.peek() == Some(&'{') {
                    chars.next();
                    let mut var_name = String::new();
                    while let Some(&c) = chars.peek() {
                        if c == '}' {
                            chars.next();
                            break;
                        }
                        var_name.push(c);
                        chars.next();
                    }
                    if let Some(val) = vars.get(&var_name) {
                        result.push_str(val);
                    }
                } else {
                    let mut var_name = String::new();
                    while let Some(&c) = chars.peek() {
                        if c.is_alphanumeric() || c == '_' || c == ':' {
                            var_name.push(c);
                            chars.next();
                        } else {
                            break;
                        }
                    }
                    if let Some(val) = vars.get(&var_name) {
                        result.push_str(val);
                    } else {
                        result.push('$');
                        result.push_str(&var_name);
                    }
                }
            }
            '[' => {
                // Inline command substitution
                let mut bracket_depth = 1u32;
                let mut cmd_str = String::new();
                while let Some(c) = chars.next() {
                    match c {
                        '[' => {
                            bracket_depth += 1;
                            cmd_str.push('[');
                        }
                        ']' => {
                            bracket_depth -= 1;
                            if bracket_depth == 0 {
                                break;
                            }
                            cmd_str.push(']');
                        }
                        _ => cmd_str.push(c),
                    }
                }
                let sub_result = eval_script(&cmd_str, vars, lists, depth + 1, source_fn)?;
                result.push_str(&sub_result);
            }
            '\\' => {
                if let Some(esc) = chars.next() {
                    match esc {
                        'n' => result.push('\n'),
                        't' => result.push('\t'),
                        '$' => result.push('$'),
                        '[' => result.push('['),
                        '\\' => result.push('\\'),
                        _ => {
                            result.push('\\');
                            result.push(esc);
                        }
                    }
                }
            }
            _ => result.push(ch),
        }
    }

    Ok(result)
}

/// Evaluate a script with file-based `source` support.
fn eval_script_with_file_source(
    script: &str,
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
) -> CmdResult {
    if depth > 100 {
        return Err("recursion depth exceeded (>100)".into());
    }

    let mut source_fn = |path: &str,
                          v: &mut HashMap<String, String>,
                          l: &mut HashMap<String, Vec<String>>,
                          d: u32|
     -> CmdResult {
        // Perform variable substitution on the path
        let expanded_path = substitute_vars(path, v);
        match std::fs::read_to_string(&expanded_path) {
            Ok(content) => eval_script_with_file_source(&content, v, l, d),
            Err(e) => {
                // Non-fatal: source files may not exist
                eprintln!("warning: could not source '{}': {}", expanded_path, e);
                Ok(String::new())
            }
        }
    };

    eval_script(script, vars, lists, depth, &mut source_fn)
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eval_set() {
        let mut interp = TclInterp::new();
        interp.eval("set x 42").unwrap();
        assert_eq!(interp.get_var("x"), Some("42"));
    }

    #[test]
    fn eval_variable_expansion() {
        let mut interp = TclInterp::new();
        interp.eval("set HOME /home/user").unwrap();
        interp.eval("set path $HOME/projects").unwrap();
        assert_eq!(interp.get_var("path"), Some("/home/user/projects"));
    }

    #[test]
    fn eval_command_substitution() {
        let mut interp = TclInterp::new();
        interp.eval("set x [expr 1 + 2]").unwrap();
        assert_eq!(interp.get_var("x"), Some("3"));
    }

    #[test]
    fn eval_lappend() {
        let mut interp = TclInterp::new();
        interp.eval("lappend mylist /path/a").unwrap();
        interp.eval("lappend mylist /path/b").unwrap();
        assert_eq!(interp.get_var("mylist"), Some("/path/a /path/b"));
    }

    #[test]
    fn eval_multiple_commands() {
        let mut interp = TclInterp::new();
        interp.eval("set x 10\nset y 20").unwrap();
        assert_eq!(interp.get_var("x"), Some("10"));
        assert_eq!(interp.get_var("y"), Some("20"));
    }

    #[test]
    fn eval_if_true() {
        let mut interp = TclInterp::new();
        interp.eval("set x 1\nif {$x == 1} {set result yes} else {set result no}").unwrap();
        assert_eq!(interp.get_var("result"), Some("yes"));
    }

    #[test]
    fn eval_if_false() {
        let mut interp = TclInterp::new();
        interp.eval("set x 0\nif {$x == 1} {set result yes} else {set result no}").unwrap();
        assert_eq!(interp.get_var("result"), Some("no"));
    }

    #[test]
    fn eval_foreach() {
        let mut interp = TclInterp::new();
        interp.eval("set result 0\nforeach i {1 2 3} {set result [expr $result + $i]}").unwrap();
        assert_eq!(interp.get_var("result"), Some("6"));
    }

    #[test]
    fn eval_file_dirname() {
        let mut interp = TclInterp::new();
        interp
            .eval("set dir [file dirname /home/user/test.sch]")
            .unwrap();
        assert_eq!(interp.get_var("dir"), Some("/home/user"));
    }

    #[test]
    fn eval_file_join() {
        let mut interp = TclInterp::new();
        interp
            .eval("set path [file join /home user test.sch]")
            .unwrap();
        assert_eq!(interp.get_var("path"), Some("/home/user/test.sch"));
    }

    #[test]
    fn eval_braces_no_substitution() {
        let mut interp = TclInterp::new();
        interp.eval("set x hello").unwrap();
        interp.eval("set y {$x world}").unwrap();
        assert_eq!(interp.get_var("y"), Some("$x world"));
    }

    #[test]
    fn eval_recursion_limit() {
        // Should not panic, should return error
        let mut interp = TclInterp::new();
        let result = eval_script(
            "set x 1",
            &mut interp.vars,
            &mut interp.lists,
            101,
            &mut |_, _, _, _| Ok(String::new()),
        );
        assert!(result.is_err());
    }
}
