//! Built-in TCL command implementations.
//!
//! Only the minimal set needed for xschemrc parsing:
//! `set`, `puts`, `lappend`, `file`, `source`, `if`, `foreach`, `expr`,
//! `info`, `catch`, `string`, `append`.

use std::collections::HashMap;

use super::expr::eval_expr;

/// Result of executing a TCL command.
pub type CmdResult = Result<String, String>;

/// Execute a built-in command. Returns the result string.
pub fn exec_builtin(
    cmd: &str,
    args: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(&str, &mut HashMap<String, String>, &mut HashMap<String, Vec<String>>, u32) -> CmdResult,
) -> CmdResult {
    if depth > 100 {
        return Err("recursion depth exceeded (>100)".into());
    }

    match cmd {
        "set" => cmd_set(args, vars),
        "puts" => cmd_puts(args),
        "lappend" => cmd_lappend(args, vars, lists),
        "append" => cmd_append(args, vars),
        "file" => cmd_file(args),
        "source" => cmd_source(args, vars, lists, depth, source_fn),
        "if" => cmd_if(args, vars, lists, depth, source_fn),
        "foreach" => cmd_foreach(args, vars, lists, depth, source_fn),
        "expr" => cmd_expr(args, vars),
        "info" => cmd_info(args, vars),
        "catch" => cmd_catch(args, vars, lists, depth, source_fn),
        "string" => cmd_string(args),
        "proc" => Ok(String::new()), // Ignore proc definitions
        "package" => Ok(String::new()), // Ignore package require
        "namespace" => Ok(String::new()), // Ignore namespace
        "return" => {
            if args.is_empty() {
                Ok(String::new())
            } else {
                Ok(args[0].clone())
            }
        }
        "list" => Ok(args.join(" ")),
        "llength" => {
            if args.is_empty() {
                Ok("0".into())
            } else {
                Ok(args[0].split_whitespace().count().to_string())
            }
        }
        "lindex" => {
            if args.len() < 2 {
                return Ok(String::new());
            }
            let items: Vec<&str> = args[0].split_whitespace().collect();
            let idx: usize = args[1].parse().unwrap_or(0);
            Ok(items.get(idx).unwrap_or(&"").to_string())
        }
        _ => {
            // Unknown command -- silently return empty (forward compat)
            Ok(String::new())
        }
    }
}

fn cmd_set(args: &[String], vars: &mut HashMap<String, String>) -> CmdResult {
    match args.len() {
        0 => Err("set: wrong # args".into()),
        1 => {
            // Read variable
            vars.get(&args[0])
                .cloned()
                .ok_or_else(|| format!("can't read \"{}\": no such variable", args[0]))
        }
        _ => {
            // Set variable
            vars.insert(args[0].clone(), args[1].clone());
            Ok(args[1].clone())
        }
    }
}

fn cmd_puts(args: &[String]) -> CmdResult {
    // Just consume -- we don't print during import
    let _ = args;
    Ok(String::new())
}

fn cmd_lappend(
    args: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
) -> CmdResult {
    if args.is_empty() {
        return Err("lappend: wrong # args".into());
    }
    let var_name = &args[0];
    let list = lists.entry(var_name.clone()).or_default();
    for val in &args[1..] {
        list.push(val.clone());
    }
    // Also update the string representation in vars
    let joined = list.join(" ");
    vars.insert(var_name.clone(), joined.clone());
    Ok(joined)
}

fn cmd_append(args: &[String], vars: &mut HashMap<String, String>) -> CmdResult {
    if args.is_empty() {
        return Err("append: wrong # args".into());
    }
    let var_name = &args[0];
    let entry = vars.entry(var_name.clone()).or_default();
    for val in &args[1..] {
        entry.push_str(val);
    }
    Ok(entry.clone())
}

fn cmd_file(args: &[String]) -> CmdResult {
    if args.is_empty() {
        return Err("file: wrong # args".into());
    }
    match args[0].as_str() {
        "dirname" => {
            if args.len() < 2 {
                return Err("file dirname: wrong # args".into());
            }
            let path = std::path::Path::new(&args[1]);
            Ok(path
                .parent()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|| ".".into()))
        }
        "join" => {
            if args.len() < 2 {
                return Ok(String::new());
            }
            let mut path = std::path::PathBuf::from(&args[1]);
            for part in &args[2..] {
                if part.starts_with('/') {
                    // Absolute path replaces everything
                    path = std::path::PathBuf::from(part);
                } else {
                    path.push(part);
                }
            }
            Ok(path.to_string_lossy().to_string())
        }
        "exists" => {
            if args.len() < 2 {
                return Ok("0".into());
            }
            Ok(if std::path::Path::new(&args[1]).exists() {
                "1".into()
            } else {
                "0".into()
            })
        }
        "tail" => {
            if args.len() < 2 {
                return Err("file tail: wrong # args".into());
            }
            let path = std::path::Path::new(&args[1]);
            Ok(path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default())
        }
        "extension" => {
            if args.len() < 2 {
                return Err("file extension: wrong # args".into());
            }
            let path = std::path::Path::new(&args[1]);
            Ok(path
                .extension()
                .map(|e| format!(".{}", e.to_string_lossy()))
                .unwrap_or_default())
        }
        sub => Err(format!("file {}: not implemented", sub)),
    }
}

fn cmd_source(
    args: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(&str, &mut HashMap<String, String>, &mut HashMap<String, Vec<String>>, u32) -> CmdResult,
) -> CmdResult {
    if args.is_empty() {
        return Err("source: wrong # args".into());
    }
    source_fn(&args[0], vars, lists, depth + 1)
}

fn cmd_if(
    args: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(&str, &mut HashMap<String, String>, &mut HashMap<String, Vec<String>>, u32) -> CmdResult,
) -> CmdResult {
    // Simplified: if {condition} {body} ?elseif {condition} {body}? ?else {body}?
    if args.len() < 2 {
        return Err("if: wrong # args".into());
    }

    let mut idx = 0;
    loop {
        if idx >= args.len() {
            break;
        }

        let condition = &args[idx];
        idx += 1;

        // Skip optional "then" keyword
        if idx < args.len() && args[idx] == "then" {
            idx += 1;
        }

        if idx >= args.len() {
            return Err("if: missing body".into());
        }

        let body = &args[idx];
        idx += 1;

        // Evaluate condition
        let cond_result = eval_expr_with_vars(condition, vars)?;
        if cond_result != "0" && !cond_result.is_empty() {
            // Execute body
            return super::evaluator::eval_script(body, vars, lists, depth + 1, source_fn);
        }

        // Check for elseif or else
        if idx < args.len() {
            if args[idx] == "elseif" {
                idx += 1;
                continue;
            } else if args[idx] == "else" {
                idx += 1;
                if idx < args.len() {
                    return super::evaluator::eval_script(
                        &args[idx],
                        vars,
                        lists,
                        depth + 1,
                        source_fn,
                    );
                }
                break;
            }
        }
        break;
    }

    Ok(String::new())
}

fn cmd_foreach(
    args: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(&str, &mut HashMap<String, String>, &mut HashMap<String, Vec<String>>, u32) -> CmdResult,
) -> CmdResult {
    // foreach var list body
    if args.len() < 3 {
        return Err("foreach: wrong # args".into());
    }

    let var_name = &args[0];
    let list_items: Vec<String> = args[1].split_whitespace().map(String::from).collect();
    let body = &args[2];

    let mut last_result = String::new();
    for item in &list_items {
        vars.insert(var_name.clone(), item.clone());
        last_result = super::evaluator::eval_script(body, vars, lists, depth + 1, source_fn)?;
    }

    Ok(last_result)
}

fn cmd_expr(args: &[String], vars: &HashMap<String, String>) -> CmdResult {
    let expr_str = args.join(" ");
    eval_expr_with_vars(&expr_str, vars)
}

fn cmd_info(args: &[String], vars: &HashMap<String, String>) -> CmdResult {
    if args.is_empty() {
        return Err("info: wrong # args".into());
    }
    match args[0].as_str() {
        "exists" => {
            if args.len() < 2 {
                return Ok("0".into());
            }
            Ok(if vars.contains_key(&args[1]) {
                "1"
            } else {
                "0"
            }
            .into())
        }
        _ => Ok(String::new()),
    }
}

fn cmd_catch(
    args: &[String],
    vars: &mut HashMap<String, String>,
    lists: &mut HashMap<String, Vec<String>>,
    depth: u32,
    source_fn: &mut dyn FnMut(&str, &mut HashMap<String, String>, &mut HashMap<String, Vec<String>>, u32) -> CmdResult,
) -> CmdResult {
    if args.is_empty() {
        return Err("catch: wrong # args".into());
    }
    let result = super::evaluator::eval_script(&args[0], vars, lists, depth + 1, source_fn);
    match result {
        Ok(val) => {
            if args.len() >= 2 {
                vars.insert(args[1].clone(), val);
            }
            Ok("0".into()) // TCL_OK
        }
        Err(msg) => {
            if args.len() >= 2 {
                vars.insert(args[1].clone(), msg);
            }
            Ok("1".into()) // TCL_ERROR
        }
    }
}

fn cmd_string(args: &[String]) -> CmdResult {
    if args.is_empty() {
        return Err("string: wrong # args".into());
    }
    match args[0].as_str() {
        "length" => {
            if args.len() < 2 {
                return Ok("0".into());
            }
            Ok(args[1].len().to_string())
        }
        "equal" | "compare" => {
            if args.len() < 3 {
                return Err("string equal: wrong # args".into());
            }
            Ok(if args[1] == args[2] {
                if args[0] == "equal" {
                    "1"
                } else {
                    "0"
                }
            } else if args[0] == "equal" {
                "0"
            } else {
                "1"
            }
            .into())
        }
        "match" => {
            if args.len() < 3 {
                return Err("string match: wrong # args".into());
            }
            // Simple glob matching: only support * and ?
            let matches = simple_glob_match(&args[1], &args[2]);
            Ok(if matches { "1" } else { "0" }.into())
        }
        "trim" => {
            if args.len() < 2 {
                return Ok(String::new());
            }
            Ok(args[1].trim().to_string())
        }
        "first" => {
            if args.len() < 3 {
                return Err("string first: wrong # args".into());
            }
            Ok(args[2]
                .find(&args[1])
                .map(|i| i as i64)
                .unwrap_or(-1)
                .to_string())
        }
        _ => Ok(String::new()),
    }
}

fn simple_glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    glob_match_impl(&p, 0, &t, 0)
}

fn glob_match_impl(p: &[char], pi: usize, t: &[char], ti: usize) -> bool {
    if pi == p.len() {
        return ti == t.len();
    }
    match p[pi] {
        '*' => {
            // Try matching zero or more characters
            for i in ti..=t.len() {
                if glob_match_impl(p, pi + 1, t, i) {
                    return true;
                }
            }
            false
        }
        '?' => {
            if ti < t.len() {
                glob_match_impl(p, pi + 1, t, ti + 1)
            } else {
                false
            }
        }
        c => {
            if ti < t.len() && t[ti] == c {
                glob_match_impl(p, pi + 1, t, ti + 1)
            } else {
                false
            }
        }
    }
}

/// Evaluate an expression with variable substitution.
fn eval_expr_with_vars(expr: &str, vars: &HashMap<String, String>) -> CmdResult {
    // Simple variable substitution: replace $var with its value
    let substituted = substitute_vars(expr, vars);
    eval_expr(&substituted)
}

/// Perform variable substitution on a string.
pub fn substitute_vars(input: &str, vars: &HashMap<String, String>) -> String {
    let mut result = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '$' {
            // Variable reference
            if chars.peek() == Some(&'{') {
                chars.next(); // skip {
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
                    // Leave unresolved variables as-is for passthrough
                    result.push('$');
                    result.push_str(&var_name);
                }
            }
        } else {
            result.push(ch);
        }
    }

    result
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_and_read() {
        let mut vars = HashMap::new();
        let mut lists = HashMap::new();
        let mut sf = |_: &str, _: &mut HashMap<String, String>, _: &mut HashMap<String, Vec<String>>, _: u32| -> CmdResult {
            Ok(String::new())
        };
        let r = exec_builtin("set", &["x".into(), "42".into()], &mut vars, &mut lists, 0, &mut sf).unwrap();
        assert_eq!(r, "42");
        assert_eq!(vars.get("x").unwrap(), "42");
    }

    #[test]
    fn lappend_builds_list() {
        let mut vars = HashMap::new();
        let mut lists = HashMap::new();
        let mut sf = |_: &str, _: &mut HashMap<String, String>, _: &mut HashMap<String, Vec<String>>, _: u32| -> CmdResult {
            Ok(String::new())
        };
        exec_builtin("lappend", &["mylist".into(), "a".into()], &mut vars, &mut lists, 0, &mut sf).unwrap();
        exec_builtin("lappend", &["mylist".into(), "b".into(), "c".into()], &mut vars, &mut lists, 0, &mut sf).unwrap();
        assert_eq!(vars.get("mylist").unwrap(), "a b c");
        assert_eq!(lists.get("mylist").unwrap(), &vec!["a", "b", "c"]);
    }

    #[test]
    fn file_dirname() {
        let mut vars = HashMap::new();
        let mut lists = HashMap::new();
        let mut sf = |_: &str, _: &mut HashMap<String, String>, _: &mut HashMap<String, Vec<String>>, _: u32| -> CmdResult {
            Ok(String::new())
        };
        let r = exec_builtin("file", &["dirname".into(), "/home/user/test.sch".into()], &mut vars, &mut lists, 0, &mut sf).unwrap();
        assert_eq!(r, "/home/user");
    }

    #[test]
    fn file_join() {
        let mut vars = HashMap::new();
        let mut lists = HashMap::new();
        let mut sf = |_: &str, _: &mut HashMap<String, String>, _: &mut HashMap<String, Vec<String>>, _: u32| -> CmdResult {
            Ok(String::new())
        };
        let r = exec_builtin("file", &["join".into(), "/home".into(), "user".into(), "file.txt".into()], &mut vars, &mut lists, 0, &mut sf).unwrap();
        assert_eq!(r, "/home/user/file.txt");
    }

    #[test]
    fn variable_substitution() {
        let mut vars = HashMap::new();
        vars.insert("HOME".into(), "/home/user".into());
        vars.insert("NAME".into(), "test".into());

        assert_eq!(
            substitute_vars("$HOME/projects/$NAME", &vars),
            "/home/user/projects/test"
        );
    }

    #[test]
    fn braced_variable_substitution() {
        let mut vars = HashMap::new();
        vars.insert("HOME".into(), "/home/user".into());

        assert_eq!(
            substitute_vars("${HOME}/projects", &vars),
            "/home/user/projects"
        );
    }

    #[test]
    fn string_match_glob() {
        assert!(simple_glob_match("*.sch", "test.sch"));
        assert!(!simple_glob_match("*.sch", "test.sym"));
        assert!(simple_glob_match("test*", "test123"));
        assert!(simple_glob_match("t?st", "test"));
    }
}
