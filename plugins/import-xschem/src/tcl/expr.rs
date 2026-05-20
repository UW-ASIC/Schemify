//! Minimal TCL `expr` arithmetic evaluator.
//!
//! Supports: +, -, *, /, %, parentheses, integer and float literals,
//! comparison operators (==, !=, <, >, <=, >=), logical (&& ||), string eq/ne.

/// Evaluate a TCL expression string and return the result as a string.
pub fn eval_expr(input: &str) -> Result<String, String> {
    let tokens = tokenize_expr(input)?;
    let mut pos = 0;
    let result = parse_or(&tokens, &mut pos)?;
    Ok(format_value(&result))
}

#[derive(Debug, Clone)]
enum Value {
    Int(i64),
    Float(f64),
    Str(String),
}

fn format_value(v: &Value) -> String {
    match v {
        Value::Int(i) => i.to_string(),
        Value::Float(f) => {
            if f.fract() == 0.0 && f.abs() < (i64::MAX as f64) {
                format!("{}", *f as i64)
            } else {
                format!("{}", f)
            }
        }
        Value::Str(s) => s.clone(),
    }
}

fn to_float(v: &Value) -> f64 {
    match v {
        Value::Int(i) => *i as f64,
        Value::Float(f) => *f,
        Value::Str(s) => s.parse::<f64>().unwrap_or(0.0),
    }
}

fn to_int(v: &Value) -> i64 {
    match v {
        Value::Int(i) => *i,
        Value::Float(f) => *f as i64,
        Value::Str(s) => s.parse::<i64>().unwrap_or(0),
    }
}

fn to_bool(v: &Value) -> bool {
    match v {
        Value::Int(i) => *i != 0,
        Value::Float(f) => *f != 0.0,
        Value::Str(s) => !s.is_empty() && s != "0" && s != "false",
    }
}

// -- Expression tokenizer --

#[derive(Debug, Clone, PartialEq)]
enum ExprToken {
    /// Number literal. `is_float` is true if the literal contained a dot or exponent.
    Number(f64, bool),
    Op(String),
    LParen,
    RParen,
    Str(String),
}

fn tokenize_expr(input: &str) -> Result<Vec<ExprToken>, String> {
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();

    while let Some(&ch) = chars.peek() {
        match ch {
            ' ' | '\t' | '\n' | '\r' => {
                chars.next();
            }
            '(' => {
                chars.next();
                tokens.push(ExprToken::LParen);
            }
            ')' => {
                chars.next();
                tokens.push(ExprToken::RParen);
            }
            '+' | '-' => {
                chars.next();
                let is_unary = tokens.is_empty()
                    || matches!(
                        tokens.last(),
                        Some(ExprToken::Op(_)) | Some(ExprToken::LParen)
                    );
                if is_unary && chars.peek().map_or(false, |c| c.is_ascii_digit() || *c == '.') {
                    let mut num_str = String::new();
                    num_str.push(ch);
                    let is_float = collect_number(&mut chars, &mut num_str);
                    let val: f64 = num_str
                        .parse()
                        .map_err(|_| format!("invalid number: {}", num_str))?;
                    tokens.push(ExprToken::Number(val, is_float));
                } else {
                    tokens.push(ExprToken::Op(ch.to_string()));
                }
            }
            '*' | '/' | '%' => {
                chars.next();
                tokens.push(ExprToken::Op(ch.to_string()));
            }
            '=' => {
                chars.next();
                if chars.peek() == Some(&'=') {
                    chars.next();
                    tokens.push(ExprToken::Op("==".into()));
                } else {
                    return Err("unexpected '=' (did you mean '=='?)".into());
                }
            }
            '!' => {
                chars.next();
                if chars.peek() == Some(&'=') {
                    chars.next();
                    tokens.push(ExprToken::Op("!=".into()));
                } else {
                    tokens.push(ExprToken::Op("!".into()));
                }
            }
            '<' => {
                chars.next();
                if chars.peek() == Some(&'=') {
                    chars.next();
                    tokens.push(ExprToken::Op("<=".into()));
                } else {
                    tokens.push(ExprToken::Op("<".into()));
                }
            }
            '>' => {
                chars.next();
                if chars.peek() == Some(&'=') {
                    chars.next();
                    tokens.push(ExprToken::Op(">=".into()));
                } else {
                    tokens.push(ExprToken::Op(">".into()));
                }
            }
            '&' => {
                chars.next();
                if chars.peek() == Some(&'&') {
                    chars.next();
                    tokens.push(ExprToken::Op("&&".into()));
                } else {
                    return Err("unexpected '&' (did you mean '&&'?)".into());
                }
            }
            '|' => {
                chars.next();
                if chars.peek() == Some(&'|') {
                    chars.next();
                    tokens.push(ExprToken::Op("||".into()));
                } else {
                    return Err("unexpected '|' (did you mean '||'?)".into());
                }
            }
            '"' => {
                chars.next();
                let mut s = String::new();
                while let Some(&c) = chars.peek() {
                    if c == '"' {
                        chars.next();
                        break;
                    }
                    if c == '\\' {
                        chars.next();
                        if let Some(&esc) = chars.peek() {
                            chars.next();
                            s.push(esc);
                            continue;
                        }
                    }
                    s.push(c);
                    chars.next();
                }
                tokens.push(ExprToken::Str(s));
            }
            _ if ch.is_ascii_digit() || ch == '.' => {
                let mut num_str = String::new();
                let is_float = collect_number(&mut chars, &mut num_str);
                let val: f64 = num_str
                    .parse()
                    .map_err(|_| format!("invalid number: {}", num_str))?;
                tokens.push(ExprToken::Number(val, is_float));
            }
            _ if ch.is_alphabetic() || ch == '_' => {
                let mut word = String::new();
                while let Some(&c) = chars.peek() {
                    if c.is_alphanumeric() || c == '_' {
                        word.push(c);
                        chars.next();
                    } else {
                        break;
                    }
                }
                match word.as_str() {
                    "eq" | "ne" => tokens.push(ExprToken::Op(word)),
                    "true" => tokens.push(ExprToken::Number(1.0, false)),
                    "false" => tokens.push(ExprToken::Number(0.0, false)),
                    _ => tokens.push(ExprToken::Str(word)),
                }
            }
            _ => {
                chars.next();
            }
        }
    }
    Ok(tokens)
}

/// Collect digits into `buf`. Returns `true` if a dot or exponent was seen.
fn collect_number(chars: &mut std::iter::Peekable<std::str::Chars<'_>>, buf: &mut String) -> bool {
    let mut has_dot = false;
    let mut has_exp = false;
    while let Some(&ch) = chars.peek() {
        if ch.is_ascii_digit() {
            buf.push(ch);
            chars.next();
        } else if ch == '.' && !has_dot {
            has_dot = true;
            buf.push(ch);
            chars.next();
        } else if (ch == 'e' || ch == 'E') && !has_exp {
            has_exp = true;
            buf.push(ch);
            chars.next();
            if let Some(&sign) = chars.peek() {
                if sign == '+' || sign == '-' {
                    buf.push(sign);
                    chars.next();
                }
            }
        } else {
            break;
        }
    }
    has_dot || has_exp
}

// -- Recursive descent parser --

fn parse_or(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    let mut left = parse_and(tokens, pos)?;
    while *pos < tokens.len() {
        if tokens[*pos] == ExprToken::Op("||".into()) {
            *pos += 1;
            let right = parse_and(tokens, pos)?;
            left = Value::Int(if to_bool(&left) || to_bool(&right) { 1 } else { 0 });
        } else {
            break;
        }
    }
    Ok(left)
}

fn parse_and(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    let mut left = parse_comparison(tokens, pos)?;
    while *pos < tokens.len() {
        if tokens[*pos] == ExprToken::Op("&&".into()) {
            *pos += 1;
            let right = parse_comparison(tokens, pos)?;
            left = Value::Int(if to_bool(&left) && to_bool(&right) { 1 } else { 0 });
        } else {
            break;
        }
    }
    Ok(left)
}

fn parse_comparison(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    let mut left = parse_addition(tokens, pos)?;
    while *pos < tokens.len() {
        let op = match &tokens[*pos] {
            ExprToken::Op(s)
                if s == "==" || s == "!=" || s == "<" || s == ">" || s == "<=" || s == ">="
                    || s == "eq" || s == "ne" =>
            {
                s.clone()
            }
            _ => break,
        };
        *pos += 1;
        let right = parse_addition(tokens, pos)?;

        left = match op.as_str() {
            "==" => Value::Int(if to_float(&left) == to_float(&right) { 1 } else { 0 }),
            "!=" => Value::Int(if to_float(&left) != to_float(&right) { 1 } else { 0 }),
            "<" => Value::Int(if to_float(&left) < to_float(&right) { 1 } else { 0 }),
            ">" => Value::Int(if to_float(&left) > to_float(&right) { 1 } else { 0 }),
            "<=" => Value::Int(if to_float(&left) <= to_float(&right) { 1 } else { 0 }),
            ">=" => Value::Int(if to_float(&left) >= to_float(&right) { 1 } else { 0 }),
            "eq" => Value::Int(if format_value(&left) == format_value(&right) { 1 } else { 0 }),
            "ne" => Value::Int(if format_value(&left) != format_value(&right) { 1 } else { 0 }),
            _ => unreachable!(),
        };
    }
    Ok(left)
}

fn parse_addition(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    let mut left = parse_multiplication(tokens, pos)?;
    while *pos < tokens.len() {
        let op = match &tokens[*pos] {
            ExprToken::Op(s) if s == "+" || s == "-" => s.clone(),
            _ => break,
        };
        *pos += 1;
        let right = parse_multiplication(tokens, pos)?;
        left = match op.as_str() {
            "+" => match (&left, &right) {
                (Value::Int(a), Value::Int(b)) => Value::Int(a + b),
                _ => Value::Float(to_float(&left) + to_float(&right)),
            },
            "-" => match (&left, &right) {
                (Value::Int(a), Value::Int(b)) => Value::Int(a - b),
                _ => Value::Float(to_float(&left) - to_float(&right)),
            },
            _ => unreachable!(),
        };
    }
    Ok(left)
}

fn parse_multiplication(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    let mut left = parse_unary(tokens, pos)?;
    while *pos < tokens.len() {
        let op = match &tokens[*pos] {
            ExprToken::Op(s) if s == "*" || s == "/" || s == "%" => s.clone(),
            _ => break,
        };
        *pos += 1;
        let right = parse_unary(tokens, pos)?;
        left = match op.as_str() {
            "*" => match (&left, &right) {
                (Value::Int(a), Value::Int(b)) => Value::Int(a * b),
                _ => Value::Float(to_float(&left) * to_float(&right)),
            },
            "/" => {
                let r = to_float(&right);
                if r == 0.0 {
                    return Err("division by zero".into());
                }
                match (&left, &right) {
                    (Value::Int(a), Value::Int(b)) => Value::Int(a / b),
                    _ => Value::Float(to_float(&left) / r),
                }
            }
            "%" => {
                let r = to_int(&right);
                if r == 0 {
                    return Err("modulo by zero".into());
                }
                Value::Int(to_int(&left) % r)
            }
            _ => unreachable!(),
        };
    }
    Ok(left)
}

fn parse_unary(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    if *pos < tokens.len() {
        if let ExprToken::Op(ref op) = tokens[*pos] {
            if op == "!" {
                *pos += 1;
                let val = parse_primary(tokens, pos)?;
                return Ok(Value::Int(if to_bool(&val) { 0 } else { 1 }));
            }
        }
    }
    parse_primary(tokens, pos)
}

fn parse_primary(tokens: &[ExprToken], pos: &mut usize) -> Result<Value, String> {
    if *pos >= tokens.len() {
        return Err("unexpected end of expression".into());
    }
    match &tokens[*pos] {
        ExprToken::Number(n, is_float) => {
            let val = *n;
            let is_float = *is_float;
            *pos += 1;
            if !is_float && val.fract() == 0.0 && val.abs() < (i64::MAX as f64) {
                Ok(Value::Int(val as i64))
            } else {
                Ok(Value::Float(val))
            }
        }
        ExprToken::Str(s) => {
            let s = s.clone();
            *pos += 1;
            if let Ok(i) = s.parse::<i64>() {
                Ok(Value::Int(i))
            } else if let Ok(f) = s.parse::<f64>() {
                Ok(Value::Float(f))
            } else {
                Ok(Value::Str(s))
            }
        }
        ExprToken::LParen => {
            *pos += 1;
            let val = parse_or(tokens, pos)?;
            if *pos < tokens.len() && tokens[*pos] == ExprToken::RParen {
                *pos += 1;
            } else {
                return Err("missing closing parenthesis".into());
            }
            Ok(val)
        }
        other => Err(format!("unexpected token in expression: {:?}", other)),
    }
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_addition() {
        assert_eq!(eval_expr("1 + 2").unwrap(), "3");
    }

    #[test]
    fn multiplication() {
        assert_eq!(eval_expr("3 * 4").unwrap(), "12");
    }

    #[test]
    fn precedence() {
        assert_eq!(eval_expr("2 + 3 * 4").unwrap(), "14");
    }

    #[test]
    fn parentheses() {
        assert_eq!(eval_expr("(2 + 3) * 4").unwrap(), "20");
    }

    #[test]
    fn division() {
        assert_eq!(eval_expr("10 / 3").unwrap(), "3");
    }

    #[test]
    fn float_division() {
        assert_eq!(eval_expr("10.0 / 3.0").unwrap(), "3.3333333333333335");
    }

    #[test]
    fn modulo() {
        assert_eq!(eval_expr("10 % 3").unwrap(), "1");
    }

    #[test]
    fn comparison() {
        assert_eq!(eval_expr("3 > 2").unwrap(), "1");
        assert_eq!(eval_expr("2 > 3").unwrap(), "0");
        assert_eq!(eval_expr("3 == 3").unwrap(), "1");
        assert_eq!(eval_expr("3 != 4").unwrap(), "1");
    }

    #[test]
    fn logical_and_or() {
        assert_eq!(eval_expr("1 && 1").unwrap(), "1");
        assert_eq!(eval_expr("1 && 0").unwrap(), "0");
        assert_eq!(eval_expr("0 || 1").unwrap(), "1");
        assert_eq!(eval_expr("0 || 0").unwrap(), "0");
    }

    #[test]
    fn negation() {
        assert_eq!(eval_expr("!0").unwrap(), "1");
        assert_eq!(eval_expr("!1").unwrap(), "0");
    }

    #[test]
    fn negative_number() {
        assert_eq!(eval_expr("-5 + 3").unwrap(), "-2");
    }

    #[test]
    fn string_eq() {
        assert_eq!(eval_expr(r#""hello" eq "hello""#).unwrap(), "1");
        assert_eq!(eval_expr(r#""hello" ne "world""#).unwrap(), "1");
    }
}
