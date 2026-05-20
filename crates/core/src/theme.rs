use std::collections::HashMap;

/// A single theme value.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum ThemeValue {
    Color([u8; 4]),
    Float(f32),
    Bool(bool),
    Int(i32),
}

/// Flat map of named theme tokens.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ThemeTokens {
    pub tokens: HashMap<String, ThemeValue>,
}

impl ThemeTokens {
    pub fn dark() -> Self {
        let mut t = HashMap::with_capacity(48);

        // UI
        t.insert("bg_primary".into(), ThemeValue::Color([22, 22, 28, 255]));
        t.insert("bg_secondary".into(), ThemeValue::Color([32, 32, 40, 255]));
        t.insert("bg_panel".into(), ThemeValue::Color([28, 28, 36, 255]));
        t.insert("text_primary".into(), ThemeValue::Color([230, 230, 230, 255]));
        t.insert("text_dim".into(), ThemeValue::Color([140, 140, 150, 255]));
        t.insert("accent".into(), ThemeValue::Color([88, 166, 255, 255]));
        t.insert("border".into(), ThemeValue::Color([60, 60, 70, 255]));
        t.insert("error".into(), ThemeValue::Color([255, 80, 80, 255]));
        t.insert("warning".into(), ThemeValue::Color([255, 200, 60, 255]));
        t.insert("success".into(), ThemeValue::Color([80, 220, 100, 255]));

        // Canvas
        t.insert("canvas_bg".into(), ThemeValue::Color([22, 22, 28, 255]));
        t.insert("grid_color".into(), ThemeValue::Color([50, 50, 60, 120]));
        t.insert("grid_major_color".into(), ThemeValue::Color([70, 70, 80, 160]));
        t.insert("wire_default".into(), ThemeValue::Color([88, 210, 255, 255]));
        t.insert("wire_bus".into(), ThemeValue::Color([70, 180, 170, 255]));
        t.insert("wire_selected".into(), ThemeValue::Color([255, 165, 50, 255]));
        t.insert("selection_fill".into(), ThemeValue::Color([88, 166, 255, 40]));
        t.insert("selection_stroke".into(), ThemeValue::Color([88, 166, 255, 180]));
        t.insert("ghost_color".into(), ThemeValue::Color([80, 255, 120, 180]));
        t.insert("crosshair_color".into(), ThemeValue::Color([200, 200, 200, 100]));
        t.insert("pin_color".into(), ThemeValue::Color([255, 220, 60, 255]));
        t.insert("symbol_stroke".into(), ThemeValue::Color([220, 220, 220, 255]));
        t.insert("symbol_fill".into(), ThemeValue::Color([40, 40, 50, 255]));
        t.insert("label_color".into(), ThemeValue::Color([200, 200, 210, 255]));

        // Spacing
        t.insert("grid_spacing".into(), ThemeValue::Float(10.0));
        t.insert("snap_size".into(), ThemeValue::Float(10.0));
        t.insert("wire_thickness".into(), ThemeValue::Float(2.0));
        t.insert("symbol_stroke_width".into(), ThemeValue::Float(1.5));
        t.insert("selection_stroke_width".into(), ThemeValue::Float(1.0));
        t.insert("font_size_label".into(), ThemeValue::Float(14.0));
        t.insert("font_size_param".into(), ThemeValue::Float(12.0));

        // Bools
        t.insert("dark_mode".into(), ThemeValue::Bool(true));
        t.insert("show_grid".into(), ThemeValue::Bool(true));
        t.insert("show_crosshair".into(), ThemeValue::Bool(true));
        t.insert("fill_symbols".into(), ThemeValue::Bool(true));

        Self { tokens: t }
    }

    pub fn light() -> Self {
        let mut t = HashMap::with_capacity(48);

        // UI
        t.insert("bg_primary".into(), ThemeValue::Color([245, 245, 248, 255]));
        t.insert("bg_secondary".into(), ThemeValue::Color([235, 235, 240, 255]));
        t.insert("bg_panel".into(), ThemeValue::Color([240, 240, 244, 255]));
        t.insert("text_primary".into(), ThemeValue::Color([30, 30, 30, 255]));
        t.insert("text_dim".into(), ThemeValue::Color([120, 120, 130, 255]));
        t.insert("accent".into(), ThemeValue::Color([30, 100, 200, 255]));
        t.insert("border".into(), ThemeValue::Color([200, 200, 210, 255]));
        t.insert("error".into(), ThemeValue::Color([200, 40, 40, 255]));
        t.insert("warning".into(), ThemeValue::Color([180, 140, 20, 255]));
        t.insert("success".into(), ThemeValue::Color([30, 160, 60, 255]));

        // Canvas
        t.insert("canvas_bg".into(), ThemeValue::Color([250, 250, 252, 255]));
        t.insert("grid_color".into(), ThemeValue::Color([200, 200, 210, 160]));
        t.insert("grid_major_color".into(), ThemeValue::Color([170, 170, 180, 200]));
        t.insert("wire_default".into(), ThemeValue::Color([0, 40, 120, 255]));
        t.insert("wire_bus".into(), ThemeValue::Color([30, 120, 115, 255]));
        t.insert("wire_selected".into(), ThemeValue::Color([200, 90, 0, 255]));
        t.insert("selection_fill".into(), ThemeValue::Color([30, 100, 200, 40]));
        t.insert("selection_stroke".into(), ThemeValue::Color([30, 100, 200, 180]));
        t.insert("ghost_color".into(), ThemeValue::Color([40, 180, 80, 180]));
        t.insert("crosshair_color".into(), ThemeValue::Color([100, 100, 100, 100]));
        t.insert("pin_color".into(), ThemeValue::Color([180, 150, 20, 255]));
        t.insert("symbol_stroke".into(), ThemeValue::Color([40, 40, 40, 255]));
        t.insert("symbol_fill".into(), ThemeValue::Color([230, 230, 235, 255]));
        t.insert("label_color".into(), ThemeValue::Color([50, 50, 60, 255]));

        // Spacing (same as dark)
        t.insert("grid_spacing".into(), ThemeValue::Float(10.0));
        t.insert("snap_size".into(), ThemeValue::Float(10.0));
        t.insert("wire_thickness".into(), ThemeValue::Float(2.0));
        t.insert("symbol_stroke_width".into(), ThemeValue::Float(1.5));
        t.insert("selection_stroke_width".into(), ThemeValue::Float(1.0));
        t.insert("font_size_label".into(), ThemeValue::Float(14.0));
        t.insert("font_size_param".into(), ThemeValue::Float(12.0));

        // Bools
        t.insert("dark_mode".into(), ThemeValue::Bool(false));
        t.insert("show_grid".into(), ThemeValue::Bool(true));
        t.insert("show_crosshair".into(), ThemeValue::Bool(true));
        t.insert("fill_symbols".into(), ThemeValue::Bool(true));

        Self { tokens: t }
    }

    /// Apply overrides sorted by priority (higher wins).
    pub fn with_overrides(&self, overrides: &[ThemeOverride]) -> ThemeTokens {
        let mut result = self.clone();
        let mut sorted: Vec<&ThemeOverride> = overrides.iter().collect();
        sorted.sort_by_key(|o| o.priority);
        for ov in sorted {
            for (k, v) in &ov.overrides {
                result.tokens.insert(k.clone(), v.clone());
            }
        }
        result
    }
}

/// Plugin's theme modifications.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ThemeOverride {
    pub plugin_id: String,
    pub priority: i32,
    pub overrides: HashMap<String, ThemeValue>,
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXPECTED_TOKENS: &[&str] = &[
        "bg_primary", "bg_secondary", "bg_panel", "text_primary", "text_dim",
        "accent", "border", "error", "warning", "success",
        "canvas_bg", "grid_color", "grid_major_color", "wire_default", "wire_bus",
        "wire_selected", "selection_fill", "selection_stroke", "ghost_color",
        "crosshair_color", "pin_color", "symbol_stroke", "symbol_fill", "label_color",
        "grid_spacing", "snap_size", "wire_thickness", "symbol_stroke_width",
        "selection_stroke_width", "font_size_label", "font_size_param",
        "dark_mode", "show_grid", "show_crosshair", "fill_symbols",
    ];

    #[test]
    fn dark_has_all_tokens() {
        let dark = ThemeTokens::dark();
        for key in EXPECTED_TOKENS {
            assert!(dark.tokens.contains_key(*key), "missing token: {key}");
        }
    }

    #[test]
    fn light_has_all_tokens() {
        let light = ThemeTokens::light();
        for key in EXPECTED_TOKENS {
            assert!(light.tokens.contains_key(*key), "missing token: {key}");
        }
    }

    #[test]
    fn dark_mode_flag() {
        assert_eq!(ThemeTokens::dark().tokens["dark_mode"], ThemeValue::Bool(true));
        assert_eq!(ThemeTokens::light().tokens["dark_mode"], ThemeValue::Bool(false));
    }

    #[test]
    fn override_replaces_token() {
        let base = ThemeTokens::dark();
        let ov = ThemeOverride {
            plugin_id: "test".into(),
            priority: 0,
            overrides: HashMap::from([
                ("accent".into(), ThemeValue::Color([255, 0, 0, 255])),
            ]),
        };
        let result = base.with_overrides(&[ov]);
        assert_eq!(result.tokens["accent"], ThemeValue::Color([255, 0, 0, 255]));
        // untouched token preserved
        assert_eq!(result.tokens["border"], base.tokens["border"]);
    }

    #[test]
    fn priority_ordering_on_conflict() {
        let base = ThemeTokens::dark();
        let low = ThemeOverride {
            plugin_id: "low".into(),
            priority: 1,
            overrides: HashMap::from([
                ("accent".into(), ThemeValue::Color([1, 1, 1, 255])),
            ]),
        };
        let high = ThemeOverride {
            plugin_id: "high".into(),
            priority: 10,
            overrides: HashMap::from([
                ("accent".into(), ThemeValue::Color([2, 2, 2, 255])),
            ]),
        };
        // regardless of input order, higher priority wins
        let result = base.with_overrides(&[high.clone(), low]);
        assert_eq!(result.tokens["accent"], ThemeValue::Color([2, 2, 2, 255]));
    }
}
