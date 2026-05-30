use std::collections::HashMap;

use thiserror::Error;

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

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
// Tokenizer
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

/// Tokenize an expression string into a sequence of tokens.
fn tokenize(input: &str) -> Result<Vec<Token>, ExprError> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = input.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        let ch = chars[i];

        // Skip whitespace.
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
                // Parse number, then optional engineering suffix.
                let start = i;
                while i < len
                    && (chars[i].is_ascii_digit()
                        || chars[i] == '.'
                        || chars[i] == 'e'
                        || chars[i] == 'E')
                {
                    // Handle scientific notation: 1e-3, 1E+6.
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

                // Check for engineering suffix.
                let (suffix_mult, suffix_len) = parse_eng_suffix(&chars, i);
                i += suffix_len;

                let base_val: f64 = num_str
                    .parse()
                    .map_err(|_| ExprError::InvalidNumber(num_str.clone()))?;
                tokens.push(Token::Number(base_val * suffix_mult));
            }
            _ if ch.is_ascii_alphabetic() || ch == '_' => {
                // Identifier (variable or function name).
                let start = i;
                while i < len && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
                let ident: String = chars[start..i].iter().collect();
                tokens.push(Token::Ident(ident));
            }
            _ => {
                return Err(ExprError::UnexpectedChar(ch));
            }
        }
    }

    Ok(tokens)
}

/// Try to parse an engineering suffix starting at position `i` in `chars`.
/// Returns (multiplier, number_of_chars_consumed).
fn parse_eng_suffix(chars: &[char], i: usize) -> (f64, usize) {
    let remaining: String = chars[i..].iter().collect();
    let lower = remaining.to_ascii_lowercase();

    // Try multi-character suffixes first (longest match).
    if lower.starts_with("meg") {
        // Make sure "meg" is not part of a longer identifier.
        let after = 3;
        if i + after >= chars.len() || !chars[i + after].is_ascii_alphabetic() {
            return (1e6, 3);
        }
    }

    if i < chars.len() {
        let ch = chars[i].to_ascii_lowercase();
        // Single-char suffixes — but only if not followed by alphanumeric
        // (to avoid eating part of a longer identifier).
        let is_standalone = i + 1 >= chars.len() || !chars[i + 1].is_ascii_alphanumeric();
        if is_standalone {
            match ch {
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

// ---------------------------------------------------------------------------
// Recursive-descent parser
// ---------------------------------------------------------------------------

/// Recursive-descent expression evaluator.
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
        if self.pos < self.tokens.len() {
            let tok = self.tokens[self.pos].clone();
            self.pos += 1;
            Some(tok)
        } else {
            None
        }
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

    // Grammar:
    //   expr     -> term (('+' | '-') term)*
    //   term     -> power (('*' | '/') power)*
    //   power    -> unary ('**' power)?       (right-associative)
    //   unary    -> '-' unary | primary
    //   primary  -> NUMBER | IDENT | IDENT '(' args ')' | '(' expr ')'

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
            // Right-associative: parse_power recursively.
            let exp = self.parse_power()?;
            Ok(base.powf(exp))
        } else {
            Ok(base)
        }
    }

    fn parse_unary(&mut self) -> Result<f64, ExprError> {
        if let Some(Token::Minus) = self.peek() {
            self.advance();
            let val = self.parse_unary()?;
            Ok(-val)
        } else if let Some(Token::Plus) = self.peek() {
            self.advance();
            self.parse_unary()
        } else {
            self.parse_primary()
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
                // Check if followed by '(' — function call.
                if let Some(Token::LParen) = self.peek() {
                    self.advance(); // consume '('
                    self.call_function(&name)
                } else {
                    // Variable lookup.
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
        let lower = name.to_ascii_lowercase();
        match lower.as_str() {
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

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Evaluate a SPICE parameter expression string.
///
/// Supports:
/// - Arithmetic: `+`, `-`, `*`, `/`, `**` (power), unary `-`
/// - Parenthesised sub-expressions
/// - Functions: `min(a,b)`, `max(a,b)`, `abs(a)`, `sqrt(a)`, `log(a)`, `exp(a)`
/// - Engineering suffixes: `T`, `G`, `meg`, `k`, `m`, `u`, `n`, `p`, `f`
/// - Variable references resolved from `ctx`
/// - Surrounding single quotes are stripped (SPICE `'expr'` syntax)
pub fn eval_expr(input: &str, ctx: &HashMap<String, f64>) -> Result<f64, ExprError> {
    // Strip surrounding quotes (SPICE uses 'expr' for parameter expressions).
    let trimmed = input.trim();
    let stripped = if (trimmed.starts_with('\'') && trimmed.ends_with('\''))
        || (trimmed.starts_with('"') && trimmed.ends_with('"'))
    {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };

    if stripped.is_empty() {
        return Err(ExprError::UnexpectedEnd);
    }

    let tokens = tokenize(stripped)?;
    if tokens.is_empty() {
        return Err(ExprError::UnexpectedEnd);
    }

    let mut parser = ExprParser::new(tokens, ctx);
    let result = parser.parse_expr()?;

    // Ensure all tokens were consumed.
    if parser.pos < parser.tokens.len() {
        return Err(ExprError::Expected("end of expression".to_string()));
    }

    Ok(result)
}

/// Try to parse a SPICE value string as a plain number with optional
/// engineering suffix.  Returns `None` if the string is not a simple number.
pub fn parse_spice_number(input: &str) -> Option<f64> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Strip surrounding quotes.
    let stripped = if (trimmed.starts_with('\'') && trimmed.ends_with('\''))
        || (trimmed.starts_with('"') && trimmed.ends_with('"'))
    {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };

    let chars: Vec<char> = stripped.chars().collect();
    let len = chars.len();

    // Find where the numeric part ends.
    let mut i = 0;
    if i < len && (chars[i] == '+' || chars[i] == '-') {
        i += 1;
    }
    while i < len && (chars[i].is_ascii_digit() || chars[i] == '.') {
        i += 1;
    }
    // Scientific notation.
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
    let consumed = i + suffix_len;

    if consumed != len {
        return None; // Trailing characters — not a simple number.
    }

    Some(base_val * suffix_mult)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_ctx() -> HashMap<String, f64> {
        HashMap::new()
    }

    // 1. Basic arithmetic
    #[test]
    fn basic_addition() {
        let ctx = empty_ctx();
        assert!((eval_expr("1+2", &ctx).unwrap() - 3.0).abs() < 1e-12);
    }

    #[test]
    fn basic_multiplication() {
        let ctx = empty_ctx();
        assert!((eval_expr("3*4", &ctx).unwrap() - 12.0).abs() < 1e-12);
    }

    #[test]
    fn basic_division() {
        let ctx = empty_ctx();
        assert!((eval_expr("10/2", &ctx).unwrap() - 5.0).abs() < 1e-12);
    }

    // 2. Operator precedence
    #[test]
    fn operator_precedence() {
        let ctx = empty_ctx();
        // 2 + 3*4 = 2 + 12 = 14
        assert!((eval_expr("2+3*4", &ctx).unwrap() - 14.0).abs() < 1e-12);
    }

    // 3. Power
    #[test]
    fn power_operator() {
        let ctx = empty_ctx();
        assert!((eval_expr("2**3", &ctx).unwrap() - 8.0).abs() < 1e-12);
    }

    // 4. Unary minus
    #[test]
    fn unary_minus() {
        let ctx = empty_ctx();
        assert!((eval_expr("-5", &ctx).unwrap() - (-5.0)).abs() < 1e-12);
    }

    #[test]
    fn unary_minus_in_expression() {
        let ctx = empty_ctx();
        assert!((eval_expr("3 + -2", &ctx).unwrap() - 1.0).abs() < 1e-12);
    }

    // 5. Parentheses
    #[test]
    fn parentheses() {
        let ctx = empty_ctx();
        assert!((eval_expr("(2+3)*4", &ctx).unwrap() - 20.0).abs() < 1e-12);
    }

    // 6. Functions
    #[test]
    fn function_min() {
        let ctx = empty_ctx();
        assert!((eval_expr("min(3,5)", &ctx).unwrap() - 3.0).abs() < 1e-12);
    }

    #[test]
    fn function_max() {
        let ctx = empty_ctx();
        assert!((eval_expr("max(3,5)", &ctx).unwrap() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn function_abs() {
        let ctx = empty_ctx();
        assert!((eval_expr("abs(-3)", &ctx).unwrap() - 3.0).abs() < 1e-12);
    }

    #[test]
    fn function_sqrt() {
        let ctx = empty_ctx();
        assert!((eval_expr("sqrt(4)", &ctx).unwrap() - 2.0).abs() < 1e-12);
    }

    #[test]
    fn function_log_exp() {
        let ctx = empty_ctx();
        // log(exp(1)) = 1
        assert!((eval_expr("log(exp(1))", &ctx).unwrap() - 1.0).abs() < 1e-12);
    }

    // 7. Engineering suffixes
    #[test]
    fn suffix_k() {
        let ctx = empty_ctx();
        assert!((eval_expr("1k", &ctx).unwrap() - 1000.0).abs() < 1e-12);
    }

    #[test]
    fn suffix_u() {
        let ctx = empty_ctx();
        assert!((eval_expr("1u", &ctx).unwrap() - 1e-6).abs() < 1e-20);
    }

    #[test]
    fn suffix_meg() {
        let ctx = empty_ctx();
        assert!((eval_expr("1meg", &ctx).unwrap() - 1e6).abs() < 1e-6);
    }

    #[test]
    fn suffix_m() {
        let ctx = empty_ctx();
        assert!((eval_expr("1m", &ctx).unwrap() - 1e-3).abs() < 1e-15);
    }

    #[test]
    fn suffix_n() {
        let ctx = empty_ctx();
        assert!((eval_expr("100n", &ctx).unwrap() - 100e-9).abs() < 1e-20);
    }

    #[test]
    fn suffix_p() {
        let ctx = empty_ctx();
        assert!((eval_expr("1p", &ctx).unwrap() - 1e-12).abs() < 1e-24);
    }

    #[test]
    fn suffix_f() {
        let ctx = empty_ctx();
        assert!((eval_expr("1f", &ctx).unwrap() - 1e-15).abs() < 1e-27);
    }

    #[test]
    fn suffix_t() {
        let ctx = empty_ctx();
        assert!((eval_expr("2T", &ctx).unwrap() - 2e12).abs() < 1.0);
    }

    #[test]
    fn suffix_g() {
        let ctx = empty_ctx();
        assert!((eval_expr("3G", &ctx).unwrap() - 3e9).abs() < 1.0);
    }

    // 8. Variable resolution
    #[test]
    fn variable_resolution() {
        let mut ctx = HashMap::new();
        ctx.insert("w_n".to_string(), 10e-6);
        assert!((eval_expr("w_n*2", &ctx).unwrap() - 20e-6).abs() < 1e-18);
    }

    // 9. Quoted expressions
    #[test]
    fn quoted_expression_single() {
        let ctx = empty_ctx();
        assert!((eval_expr("'1+2'", &ctx).unwrap() - 3.0).abs() < 1e-12);
    }

    #[test]
    fn quoted_expression_double() {
        let ctx = empty_ctx();
        assert!((eval_expr("\"3*4\"", &ctx).unwrap() - 12.0).abs() < 1e-12);
    }

    // 10. Error on undefined variable
    #[test]
    fn undefined_variable_error() {
        let ctx = empty_ctx();
        let result = eval_expr("undefined_var", &ctx);
        assert!(result.is_err());
        match result.unwrap_err() {
            ExprError::UndefinedVariable(name) => assert_eq!(name, "undefined_var"),
            other => panic!("expected UndefinedVariable, got {:?}", other),
        }
    }

    // Extra: division by zero
    #[test]
    fn division_by_zero_error() {
        let ctx = empty_ctx();
        let result = eval_expr("1/0", &ctx);
        assert!(result.is_err());
    }

    // Extra: parse_spice_number
    #[test]
    fn parse_spice_number_basic() {
        assert!((parse_spice_number("1k").unwrap() - 1000.0).abs() < 1e-12);
        assert!((parse_spice_number("100n").unwrap() - 100e-9).abs() < 1e-20);
        assert!((parse_spice_number("1.8").unwrap() - 1.8).abs() < 1e-12);
        assert!((parse_spice_number("1meg").unwrap() - 1e6).abs() < 1e-6);
        assert!(parse_spice_number("abc").is_none());
    }

    // Extra: complex expression
    #[test]
    fn complex_expression() {
        let mut ctx = HashMap::new();
        ctx.insert("x".to_string(), 3.0);
        // (x + 1) ** 2 = 16
        assert!((eval_expr("(x+1)**2", &ctx).unwrap() - 16.0).abs() < 1e-12);
    }

    // Extra: nested functions
    #[test]
    fn nested_functions() {
        let ctx = empty_ctx();
        // max(min(5, 10), 3) = 5
        assert!((eval_expr("max(min(5,10),3)", &ctx).unwrap() - 5.0).abs() < 1e-12);
    }
}
