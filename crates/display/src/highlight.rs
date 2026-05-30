//! Syntax highlighting for SPICE code and Markdown editors.
//!
//! Produces `egui::text::LayoutJob` with colored spans for use with
//! `TextEdit::layouter()`.

use eframe::egui;
use egui::text::LayoutJob;
use egui::{Color32, FontId, TextFormat};

// ── Color Palettes ──────────────────────────────────────────────────────────

struct SpiceColors {
    comment: Color32,
    directive: Color32,
    component: Color32,
    number: Color32,
    string: Color32,
    keyword: Color32,
    default: Color32,
}

impl SpiceColors {
    fn dark() -> Self {
        Self {
            comment: Color32::from_rgb(106, 153, 85),    // green
            directive: Color32::from_rgb(197, 134, 192), // purple
            component: Color32::from_rgb(220, 160, 80),  // orange
            number: Color32::from_rgb(100, 200, 180),    // teal
            string: Color32::from_rgb(206, 145, 120),    // brown/gold
            keyword: Color32::from_rgb(86, 156, 214),    // blue
            default: Color32::from_rgb(212, 212, 212),   // light gray
        }
    }

    fn light() -> Self {
        Self {
            comment: Color32::from_rgb(0, 128, 0),
            directive: Color32::from_rgb(128, 0, 128),
            component: Color32::from_rgb(180, 100, 20),
            number: Color32::from_rgb(0, 128, 128),
            string: Color32::from_rgb(163, 21, 21),
            keyword: Color32::from_rgb(0, 0, 200),
            default: Color32::from_rgb(30, 30, 30),
        }
    }

    fn for_visuals(dark: bool) -> Self {
        if dark {
            Self::dark()
        } else {
            Self::light()
        }
    }
}

// ── SPICE Highlighting ──────────────────────────────────────────────────────

const SPICE_DIRECTIVES: &[&str] = &[
    ".tran", ".ac", ".dc", ".op", ".noise", ".tf", ".sens", ".pz", ".model", ".subckt", ".ends",
    ".end", ".param", ".func", ".include", ".lib", ".save", ".print", ".plot", ".probe", ".meas",
    ".measure", ".option", ".options", ".global", ".temp", ".ic", ".nodeset", ".step", ".alter",
    ".control", ".endc", ".four", ".monte", ".pss", ".hb",
];

const SPICE_KEYWORDS: &[&str] = &[
    "dc", "ac", "pulse", "sin", "pwl", "exp", "sffm", "am", "poly", "table", "vol", "cur",
];

fn is_spice_number_char(c: char) -> bool {
    c.is_ascii_digit() || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E'
}

fn is_si_suffix(s: &str) -> bool {
    matches!(
        s.to_lowercase().as_str(),
        "t" | "g"
            | "meg"
            | "k"
            | "m"
            | "u"
            | "n"
            | "p"
            | "f"
            | "a"
            | "mil"
            | "hz"
            | "khz"
            | "mhz"
            | "ghz"
    )
}

fn is_component_prefix(c: char) -> bool {
    matches!(
        c.to_ascii_uppercase(),
        'R' | 'C'
            | 'L'
            | 'V'
            | 'I'
            | 'M'
            | 'Q'
            | 'D'
            | 'J'
            | 'K'
            | 'X'
            | 'E'
            | 'F'
            | 'G'
            | 'H'
            | 'B'
            | 'S'
            | 'W'
            | 'T'
            | 'U'
            | 'O'
            | 'P'
            | 'N'
    )
}

/// Build a `LayoutJob` with SPICE syntax highlighting.
pub fn highlight_spice(text: &str, font: FontId, dark: bool) -> LayoutJob {
    let colors = SpiceColors::for_visuals(dark);
    let mut job = LayoutJob::default();
    job.wrap.max_width = f32::INFINITY;

    let fmt = |color: Color32| TextFormat {
        font_id: font.clone(),
        color,
        ..Default::default()
    };

    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_start();

        // Full-line comment: * at start or ; anywhere
        if trimmed.starts_with('*') || trimmed.starts_with(';') {
            job.append(line, 0.0, fmt(colors.comment));
            continue;
        }

        // Tokenize the line
        highlight_spice_line(line, &colors, &font, &mut job);
    }

    job
}

fn highlight_spice_line(line: &str, colors: &SpiceColors, font: &FontId, job: &mut LayoutJob) {
    let fmt = |color: Color32| TextFormat {
        font_id: font.clone(),
        color,
        ..Default::default()
    };

    let chars: Vec<char> = line.chars().collect();
    let len = chars.len();
    let mut i = 0;
    let mut is_line_start = true;

    while i < len {
        let c = chars[i];

        // Inline comment
        if c == ';' {
            let rest: String = chars[i..].iter().collect();
            job.append(&rest, 0.0, fmt(colors.comment));
            return;
        }

        // Whitespace
        if c.is_ascii_whitespace() {
            let start = i;
            while i < len && chars[i].is_ascii_whitespace() {
                i += 1;
            }
            let ws: String = chars[start..i].iter().collect();
            job.append(&ws, 0.0, fmt(colors.default));
            if c == '\n' {
                is_line_start = true;
            }
            continue;
        }

        // Directive (starts with .)
        if c == '.' {
            let start = i;
            i += 1;
            while i < len && chars[i].is_ascii_alphanumeric() {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            let lower = word.to_lowercase();
            if SPICE_DIRECTIVES.contains(&lower.as_str()) {
                job.append(&word, 0.0, fmt(colors.directive));
            } else {
                job.append(&word, 0.0, fmt(colors.default));
            }
            is_line_start = false;
            continue;
        }

        // Number (possibly with SI suffix)
        if c.is_ascii_digit() || (c == '-' && i + 1 < len && chars[i + 1].is_ascii_digit()) {
            let start = i;
            while i < len && is_spice_number_char(chars[i]) {
                i += 1;
            }
            // Consume SI suffix
            let suffix_start = i;
            while i < len && chars[i].is_ascii_alphabetic() {
                i += 1;
            }
            if suffix_start < i {
                let suffix: String = chars[suffix_start..i].iter().collect();
                if !is_si_suffix(&suffix) {
                    // Not a valid suffix, rewind
                    i = suffix_start;
                }
            }
            let num: String = chars[start..i].iter().collect();
            job.append(&num, 0.0, fmt(colors.number));
            is_line_start = false;
            continue;
        }

        // Quoted string
        if c == '\'' || c == '"' {
            let start = i;
            let quote = c;
            i += 1;
            while i < len && chars[i] != quote {
                i += 1;
            }
            if i < len {
                i += 1; // closing quote
            }
            let s: String = chars[start..i].iter().collect();
            job.append(&s, 0.0, fmt(colors.string));
            is_line_start = false;
            continue;
        }

        // Word (identifier/keyword/component)
        if c.is_ascii_alphanumeric() || c == '_' {
            let start = i;
            while i < len && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            let lower = word.to_lowercase();

            if is_line_start && word.len() > 1 && is_component_prefix(chars[start]) {
                // Component instance name at line start (R1, C2, M1, etc.)
                job.append(&word, 0.0, fmt(colors.component));
            } else if SPICE_KEYWORDS.contains(&lower.as_str()) {
                job.append(&word, 0.0, fmt(colors.keyword));
            } else {
                job.append(&word, 0.0, fmt(colors.default));
            }
            is_line_start = false;
            continue;
        }

        // Operators and punctuation
        let start = i;
        i += 1;
        let ch: String = chars[start..i].iter().collect();
        job.append(&ch, 0.0, fmt(colors.default));
        is_line_start = false;
    }
}

// ── LaTeX Highlighting ──────────────────────────────────────────────────────

const LATEX_SECTION_CMDS: &[&str] = &[
    "section",
    "subsection",
    "subsubsection",
    "paragraph",
    "chapter",
    "part",
    "title",
    "author",
    "date",
    "abstract",
];

const LATEX_ENV_CMDS: &[&str] = &["begin", "end"];

const LATEX_MATH_CMDS: &[&str] = &[
    "frac",
    "dfrac",
    "tfrac",
    "sqrt",
    "sum",
    "prod",
    "int",
    "iint",
    "iiint",
    "oint",
    "lim",
    "inf",
    "sup",
    "max",
    "min",
    "sin",
    "cos",
    "tan",
    "cot",
    "sec",
    "csc",
    "arcsin",
    "arccos",
    "arctan",
    "sinh",
    "cosh",
    "tanh",
    "log",
    "ln",
    "exp",
    "det",
    "dim",
    "ker",
    "gcd",
    "left",
    "right",
    "big",
    "Big",
    "bigg",
    "Bigg",
    "text",
    "mathrm",
    "mathbf",
    "mathbb",
    "mathcal",
    "mathit",
    "boldsymbol",
    "overline",
    "underline",
    "hat",
    "bar",
    "vec",
    "dot",
    "ddot",
    "tilde",
    "overbrace",
    "underbrace",
];

const LATEX_GREEK: &[&str] = &[
    "alpha",
    "beta",
    "gamma",
    "delta",
    "epsilon",
    "varepsilon",
    "zeta",
    "eta",
    "theta",
    "vartheta",
    "iota",
    "kappa",
    "lambda",
    "mu",
    "nu",
    "xi",
    "pi",
    "varpi",
    "rho",
    "varrho",
    "sigma",
    "varsigma",
    "tau",
    "upsilon",
    "phi",
    "varphi",
    "chi",
    "psi",
    "omega",
    "Gamma",
    "Delta",
    "Theta",
    "Lambda",
    "Xi",
    "Pi",
    "Sigma",
    "Phi",
    "Psi",
    "Omega",
];

const LATEX_OPERATORS: &[&str] = &[
    "times",
    "div",
    "cdot",
    "pm",
    "mp",
    "leq",
    "geq",
    "neq",
    "approx",
    "equiv",
    "sim",
    "propto",
    "infty",
    "partial",
    "nabla",
    "forall",
    "exists",
    "nexists",
    "in",
    "notin",
    "subset",
    "supset",
    "subseteq",
    "supseteq",
    "cup",
    "cap",
    "emptyset",
    "land",
    "lor",
    "neg",
    "to",
    "rightarrow",
    "leftarrow",
    "Rightarrow",
    "Leftarrow",
    "iff",
    "mapsto",
    "uparrow",
    "downarrow",
    "ldots",
    "cdots",
    "vdots",
    "ddots",
    "quad",
    "qquad",
    "hbar",
    "ell",
    "Re",
    "Im",
    "aleph",
    "angle",
];

struct LatexColors {
    command: Color32,
    math_delim: Color32,
    math_body: Color32,
    group_brace: Color32,
    comment: Color32,
    environment: Color32,
    section: Color32,
    greek: Color32,
    operator: Color32,
    number: Color32,
    default: Color32,
}

impl LatexColors {
    fn dark() -> Self {
        Self {
            command: Color32::from_rgb(86, 156, 214),     // blue
            math_delim: Color32::from_rgb(220, 160, 80),  // orange
            math_body: Color32::from_rgb(197, 134, 192),  // purple
            group_brace: Color32::from_rgb(255, 215, 0),  // gold
            comment: Color32::from_rgb(106, 153, 85),     // green
            environment: Color32::from_rgb(78, 201, 176), // teal
            section: Color32::from_rgb(220, 220, 170),    // yellow
            greek: Color32::from_rgb(156, 220, 156),      // light green
            operator: Color32::from_rgb(206, 145, 120),   // brown
            number: Color32::from_rgb(100, 200, 180),     // cyan
            default: Color32::from_rgb(212, 212, 212),    // light gray
        }
    }

    fn light() -> Self {
        Self {
            command: Color32::from_rgb(0, 0, 200),
            math_delim: Color32::from_rgb(180, 100, 20),
            math_body: Color32::from_rgb(128, 0, 128),
            group_brace: Color32::from_rgb(160, 120, 0),
            comment: Color32::from_rgb(0, 128, 0),
            environment: Color32::from_rgb(0, 128, 128),
            section: Color32::from_rgb(100, 100, 0),
            greek: Color32::from_rgb(0, 100, 0),
            operator: Color32::from_rgb(163, 21, 21),
            number: Color32::from_rgb(0, 128, 128),
            default: Color32::from_rgb(30, 30, 30),
        }
    }

    fn for_visuals(dark: bool) -> Self {
        if dark {
            Self::dark()
        } else {
            Self::light()
        }
    }
}

/// Build a `LayoutJob` with LaTeX syntax highlighting.
pub fn highlight_latex(text: &str, font: FontId, dark: bool) -> LayoutJob {
    let colors = LatexColors::for_visuals(dark);
    let mut job = LayoutJob::default();
    job.wrap.max_width = f32::INFINITY;

    let bytes = text.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    let mut plain_start = 0;
    let in_math = false;

    let fmt = |color: Color32| TextFormat {
        font_id: font.clone(),
        color,
        ..Default::default()
    };

    while i < len {
        match bytes[i] {
            // LaTeX comment: % to end of line
            b'%' if !in_math => {
                flush_plain(text, plain_start, i, &fmt(colors.default), &mut job);
                let start = i;
                while i < len && bytes[i] != b'\n' {
                    i += 1;
                }
                job.append(&text[start..i], 0.0, fmt(colors.comment));
                plain_start = i;
            }

            // Display math: $$...$$
            b'$' if i + 1 < len && bytes[i + 1] == b'$' => {
                flush_plain(text, plain_start, i, &fmt(colors.default), &mut job);
                job.append("$$", 0.0, fmt(colors.math_delim));
                i += 2;
                let body_start = i;
                while i + 1 < len && !(bytes[i] == b'$' && bytes[i + 1] == b'$') {
                    i += 1;
                }
                if body_start < i {
                    highlight_latex_math(&text[body_start..i], &colors, &font, &mut job);
                }
                if i + 1 < len {
                    job.append("$$", 0.0, fmt(colors.math_delim));
                    i += 2;
                }
                plain_start = i;
            }

            // Inline math: $...$
            b'$' => {
                flush_plain(text, plain_start, i, &fmt(colors.default), &mut job);
                job.append("$", 0.0, fmt(colors.math_delim));
                i += 1;
                let body_start = i;
                while i < len && bytes[i] != b'$' {
                    i += 1;
                }
                if body_start < i {
                    highlight_latex_math(&text[body_start..i], &colors, &font, &mut job);
                }
                if i < len {
                    job.append("$", 0.0, fmt(colors.math_delim));
                    i += 1;
                }
                plain_start = i;
            }

            // LaTeX command: \commandname
            b'\\' => {
                flush_plain(text, plain_start, i, &fmt(colors.default), &mut job);
                let start = i;
                i += 1;
                // Read command name (alphabetic only)
                let cmd_start = i;
                while i < len && bytes[i].is_ascii_alphabetic() {
                    i += 1;
                }
                if cmd_start < i {
                    let cmd = &text[cmd_start..i];
                    let color = classify_latex_cmd(cmd, &colors);
                    job.append(&text[start..i], 0.0, fmt(color));
                } else if i < len {
                    // Single-char command like \\ or \{ or \}
                    i += 1;
                    job.append(&text[start..i], 0.0, fmt(colors.command));
                } else {
                    job.append(&text[start..i], 0.0, fmt(colors.command));
                }
                plain_start = i;
            }

            // Braces
            b'{' | b'}' => {
                flush_plain(text, plain_start, i, &fmt(colors.default), &mut job);
                job.append(&text[i..i + 1], 0.0, fmt(colors.group_brace));
                i += 1;
                plain_start = i;
            }

            // Numbers
            b'0'..=b'9' => {
                flush_plain(text, plain_start, i, &fmt(colors.default), &mut job);
                let start = i;
                while i < len && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
                    i += 1;
                }
                job.append(&text[start..i], 0.0, fmt(colors.number));
                plain_start = i;
            }

            _ => {
                i += 1;
            }
        }
    }

    flush_plain(text, plain_start, len, &fmt(colors.default), &mut job);
    job
}

fn flush_plain(text: &str, start: usize, end: usize, fmt: &TextFormat, job: &mut LayoutJob) {
    if start < end {
        job.append(&text[start..end], 0.0, fmt.clone());
    }
}

fn classify_latex_cmd(cmd: &str, colors: &LatexColors) -> Color32 {
    if LATEX_ENV_CMDS.contains(&cmd) {
        colors.environment
    } else if LATEX_SECTION_CMDS.contains(&cmd) {
        colors.section
    } else if LATEX_GREEK.contains(&cmd) {
        colors.greek
    } else if LATEX_MATH_CMDS.contains(&cmd) {
        colors.math_body
    } else if LATEX_OPERATORS.contains(&cmd) {
        colors.operator
    } else {
        colors.command
    }
}

/// Highlight the body of a math block (between $ delimiters).
fn highlight_latex_math(text: &str, colors: &LatexColors, font: &FontId, job: &mut LayoutJob) {
    let bytes = text.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    let mut plain_start = 0;

    let fmt = |color: Color32| TextFormat {
        font_id: font.clone(),
        color,
        ..Default::default()
    };

    while i < len {
        match bytes[i] {
            b'\\' => {
                // Flush preceding math text
                if plain_start < i {
                    job.append(&text[plain_start..i], 0.0, fmt(colors.math_body));
                }
                let start = i;
                i += 1;
                let cmd_start = i;
                while i < len && bytes[i].is_ascii_alphabetic() {
                    i += 1;
                }
                if cmd_start < i {
                    let cmd = &text[cmd_start..i];
                    let color = classify_latex_cmd(cmd, colors);
                    job.append(&text[start..i], 0.0, fmt(color));
                } else if i < len {
                    i += 1;
                    job.append(&text[start..i], 0.0, fmt(colors.command));
                } else {
                    job.append(&text[start..i], 0.0, fmt(colors.command));
                }
                plain_start = i;
            }
            b'{' | b'}' => {
                if plain_start < i {
                    job.append(&text[plain_start..i], 0.0, fmt(colors.math_body));
                }
                job.append(&text[i..i + 1], 0.0, fmt(colors.group_brace));
                i += 1;
                plain_start = i;
            }
            b'^' | b'_' => {
                if plain_start < i {
                    job.append(&text[plain_start..i], 0.0, fmt(colors.math_body));
                }
                job.append(&text[i..i + 1], 0.0, fmt(colors.math_delim));
                i += 1;
                plain_start = i;
            }
            b'0'..=b'9' | b'.' => {
                if plain_start < i {
                    job.append(&text[plain_start..i], 0.0, fmt(colors.math_body));
                }
                let start = i;
                while i < len && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
                    i += 1;
                }
                job.append(&text[start..i], 0.0, fmt(colors.number));
                plain_start = i;
            }
            _ => {
                i += 1;
            }
        }
    }

    if plain_start < len {
        job.append(&text[plain_start..], 0.0, fmt(colors.math_body));
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── is_spice_number_char ────────────────────────────────────────────────

    #[test]
    fn spice_number_chars() {
        assert!(is_spice_number_char('0'));
        assert!(is_spice_number_char('9'));
        assert!(is_spice_number_char('.'));
        assert!(is_spice_number_char('-'));
        assert!(is_spice_number_char('+'));
        assert!(is_spice_number_char('e'));
        assert!(is_spice_number_char('E'));
    }

    #[test]
    fn non_spice_number_chars() {
        assert!(!is_spice_number_char('a'));
        assert!(!is_spice_number_char('R'));
        assert!(!is_spice_number_char(' '));
        assert!(!is_spice_number_char('_'));
    }

    // ── is_si_suffix ────────────────────────────────────────────────────────

    #[test]
    fn valid_si_suffixes() {
        assert!(is_si_suffix("k"));
        assert!(is_si_suffix("K"));
        assert!(is_si_suffix("meg"));
        assert!(is_si_suffix("MEG"));
        assert!(is_si_suffix("u"));
        assert!(is_si_suffix("n"));
        assert!(is_si_suffix("p"));
        assert!(is_si_suffix("f"));
        assert!(is_si_suffix("GHz"));
        assert!(is_si_suffix("MHz"));
    }

    #[test]
    fn invalid_si_suffixes() {
        assert!(!is_si_suffix("xyz"));
        assert!(!is_si_suffix("ohm"));
        assert!(!is_si_suffix(""));
        assert!(!is_si_suffix("volts"));
    }

    // ── is_component_prefix ─────────────────────────────────────────────────

    #[test]
    fn valid_component_prefixes() {
        for c in ['R', 'C', 'L', 'V', 'I', 'M', 'Q', 'D', 'J', 'X'] {
            assert!(
                is_component_prefix(c),
                "Expected '{c}' to be a component prefix"
            );
        }
        // Lowercase variants.
        assert!(is_component_prefix('r'));
        assert!(is_component_prefix('c'));
        assert!(is_component_prefix('m'));
    }

    #[test]
    fn invalid_component_prefixes() {
        assert!(!is_component_prefix('Z'));
        assert!(!is_component_prefix('0'));
        assert!(!is_component_prefix('.'));
        assert!(!is_component_prefix('Y'));
    }

    // ── highlight_spice (integration-level) ─────────────────────────────────

    #[test]
    fn highlight_spice_comment_line() {
        let font = FontId::proportional(14.0);
        let job = highlight_spice("* this is a comment\n", font, true);
        // The entire line should be a single section (the comment).
        assert!(!job.sections.is_empty());
    }

    #[test]
    fn highlight_spice_directive_recognized() {
        let font = FontId::proportional(14.0);
        let job = highlight_spice(".tran 1n 100n\n", font, true);
        assert!(!job.sections.is_empty());
        // The text should be present in the job.
        assert_eq!(job.text, ".tran 1n 100n\n");
    }

    #[test]
    fn highlight_spice_empty_string() {
        let font = FontId::proportional(14.0);
        let job = highlight_spice("", font, true);
        assert!(job.sections.is_empty());
    }

    #[test]
    fn highlight_spice_preserves_text() {
        let input = "R1 in out 10k\n.dc V1 0 5 0.1\n";
        let font = FontId::proportional(14.0);
        let job = highlight_spice(input, font, false);
        assert_eq!(job.text, input);
    }

    // ── highlight_latex ─────────────────────────────────────────────────────

    #[test]
    fn highlight_latex_preserves_text() {
        let input = "Hello $x^2$ world";
        let font = FontId::proportional(14.0);
        let job = highlight_latex(input, font, true);
        assert_eq!(job.text, input);
    }

    #[test]
    fn highlight_latex_empty_string() {
        let font = FontId::proportional(14.0);
        let job = highlight_latex("", font, true);
        assert!(job.sections.is_empty());
    }

    #[test]
    fn highlight_latex_comment() {
        let font = FontId::proportional(14.0);
        let job = highlight_latex("text % comment\n", font, true);
        assert_eq!(job.text, "text % comment\n");
        // Should have at least 2 sections (text before %, comment).
        assert!(job.sections.len() >= 2);
    }

    // ── classify_latex_cmd ───────────────────────────────────────────────────

    #[test]
    fn classify_latex_cmd_section() {
        let colors = LatexColors::dark();
        assert_eq!(classify_latex_cmd("section", &colors), colors.section);
        assert_eq!(classify_latex_cmd("title", &colors), colors.section);
    }

    #[test]
    fn classify_latex_cmd_environment() {
        let colors = LatexColors::dark();
        assert_eq!(classify_latex_cmd("begin", &colors), colors.environment);
        assert_eq!(classify_latex_cmd("end", &colors), colors.environment);
    }

    #[test]
    fn classify_latex_cmd_greek() {
        let colors = LatexColors::dark();
        assert_eq!(classify_latex_cmd("alpha", &colors), colors.greek);
        assert_eq!(classify_latex_cmd("Omega", &colors), colors.greek);
    }

    #[test]
    fn classify_latex_cmd_math() {
        let colors = LatexColors::dark();
        assert_eq!(classify_latex_cmd("frac", &colors), colors.math_body);
        assert_eq!(classify_latex_cmd("sqrt", &colors), colors.math_body);
    }

    #[test]
    fn classify_latex_cmd_operator() {
        let colors = LatexColors::dark();
        assert_eq!(classify_latex_cmd("times", &colors), colors.operator);
        assert_eq!(classify_latex_cmd("infty", &colors), colors.operator);
    }

    #[test]
    fn classify_latex_cmd_unknown_falls_back_to_command() {
        let colors = LatexColors::dark();
        assert_eq!(classify_latex_cmd("unknowncmd", &colors), colors.command);
    }
}
