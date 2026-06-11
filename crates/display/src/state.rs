//! GUI-side state: theme (single merged palette) and per-dialog scratch
//! buffers. The core handler owns document/tool/canvas state; everything
//! here is presentation-only and never serialized.

use eframe::egui::{self, Color32, Visuals};

use schemify_core::handler::ObjectRef;
use schemify_core::schemify::Color;
use schemify_marketplace::SearchResult;
use schemify_plugins::{ThemeTokens, ThemeValue};

// ════════════════════════════════════════════════════════════
// Theme — one struct for canvas + chrome colors
// ════════════════════════════════════════════════════════════

/// All colors the display crate needs, resolved once per dark/light switch.
/// (Old `CanvasPalette` + the live parts of `WidgetPalette`, merged; the
/// token-based theme system was killed with the old plugin theming.)
#[derive(Debug, Clone)]
pub struct Theme {
    pub dark: bool,

    // Canvas
    pub canvas_bg: Color32,
    pub grid_dot: Color32,
    pub wire: Color32,
    pub wire_selected: Color32,
    pub wire_endpoint: Color32,
    pub bus: Color32,
    pub inst_selected: Color32,
    pub inst_pin: Color32,
    pub symbol_line: Color32,
    pub wire_preview: Color32,
    pub origin: Color32,
    pub rubber_band: Color32,
    pub selection_rect: Color32,
    pub text_label: Color32,
    pub geometry_line: Color32,
    pub geometry_fill: Color32,
    pub inst_error: Color32,

    // Chrome
    pub accent: Color32,
    pub warn: Color32,
    pub error: Color32,
}

impl Theme {
    #[rustfmt::skip]
    fn build(dark: bool) -> Self {
        let c = |d: Color32, l: Color32| if dark { d } else { l };
        let rgb = |dr, dg, db, lr, lg, lb| {
            c(Color32::from_rgb(dr, dg, db), Color32::from_rgb(lr, lg, lb))
        };
        let rgba = |dr, dg, db, da, lr, lg, lb, la| {
            c(Color32::from_rgba_premultiplied(dr, dg, db, da),
              Color32::from_rgba_premultiplied(lr, lg, lb, la))
        };
        Self {
            dark,
            canvas_bg:      rgb(30, 30, 36,        245, 245, 248),
            grid_dot:       rgba(80, 80, 90, 120,  160, 160, 170, 120),
            wire:           rgb(100, 200, 100,     30, 140, 30),
            wire_selected:  rgb(255, 200, 50,      200, 140, 0),
            wire_endpoint:  rgb(130, 220, 130,     40, 160, 40),
            bus:            rgb(80, 140, 220,      40, 80, 180),
            inst_selected:  rgb(255, 200, 50,      200, 140, 0),
            inst_pin:       rgb(200, 80, 80,       180, 40, 40),
            symbol_line:    rgb(200, 200, 210,     50, 50, 60),
            wire_preview:   rgb(255, 140, 40,      220, 100, 20),
            origin:         rgba(100, 100, 120, 80, 140, 140, 160, 80),
            rubber_band:    rgba(80, 140, 255, 40,  40, 100, 220, 30),
            selection_rect: rgba(80, 140, 255, 60,  40, 100, 220, 60),
            text_label:     rgba(180, 180, 195, 200, 60, 60, 70, 200),
            geometry_line:  rgb(180, 180, 195,     60, 60, 70),
            geometry_fill:  rgba(60, 60, 80, 40,   200, 200, 220, 40),
            inst_error:     rgb(232, 100, 100,     200, 40, 40),
            accent:         rgb(88, 166, 255,      30, 100, 200),
            warn:           rgb(240, 200, 60,      180, 140, 20),
            error:          rgb(232, 100, 100,     200, 40, 40),
        }
    }

    pub fn dark() -> Self {
        Self::build(true)
    }

    pub fn light() -> Self {
        Self::build(false)
    }

    pub fn for_mode(dark: bool) -> Self {
        Self::build(dark)
    }

    /// Apply this theme to egui's visuals.
    pub fn apply(&self, ctx: &egui::Context) {
        let mut visuals = if self.dark {
            Visuals::dark()
        } else {
            Visuals::light()
        };
        visuals.hyperlink_color = self.accent;
        visuals.selection.bg_fill = self.accent.linear_multiply(0.3);
        visuals.selection.stroke.color = self.accent;
        visuals.error_fg_color = self.error;
        visuals.warn_fg_color = self.warn;
        ctx.set_visuals(visuals);
        // egui's default menu_width (400) makes menu-bar dropdowns
        // comically wide; menus size to their content above this floor.
        ctx.style_mut(|s| s.spacing.menu_width = 140.0);
    }
}

impl Default for Theme {
    fn default() -> Self {
        Self::dark()
    }
}

/// Single source of truth for the color-token list: generates both
/// directions of the token ↔ field mapping (plugin theme protocol).
/// Token names are the field names verbatim, plus `dark` as a Bool.
macro_rules! theme_color_tokens {
    ($($field:ident),* $(,)?) => {
        impl Theme {
            /// Apply one named token. Returns false for unknown
            /// names or mismatched value types (ignored by callers).
            pub fn set_token(&mut self, name: &str, value: &ThemeValue) -> bool {
                match (name, value) {
                    $((stringify!($field), ThemeValue::Color(c)) => {
                        self.$field =
                            Color32::from_rgba_unmultiplied(c[0], c[1], c[2], c[3]);
                        true
                    })*
                    ("dark", ThemeValue::Bool(b)) => {
                        self.dark = *b;
                        true
                    }
                    _ => false,
                }
            }

            /// Color of one named token (for plugin widget `ThemeColor::Token`).
            pub fn token_color(&self, name: &str) -> Option<Color32> {
                match name {
                    $(stringify!($field) => Some(self.$field),)*
                    _ => None,
                }
            }

            /// Snapshot all tokens (payload of `state/theme_changed` /
            /// `state/query_theme`).
            pub fn to_tokens(&self) -> ThemeTokens {
                let mut tokens = ThemeTokens::default();
                $(tokens.tokens.insert(
                    stringify!($field).to_owned(),
                    ThemeValue::Color(self.$field.to_srgba_unmultiplied()),
                );)*
                tokens
                    .tokens
                    .insert("dark".to_owned(), ThemeValue::Bool(self.dark));
                tokens
            }
        }
    };
}

theme_color_tokens!(
    canvas_bg,
    grid_dot,
    wire,
    wire_selected,
    wire_endpoint,
    bus,
    inst_selected,
    inst_pin,
    symbol_line,
    wire_preview,
    origin,
    rubber_band,
    selection_rect,
    text_label,
    geometry_line,
    geometry_fill,
    inst_error,
    accent,
    warn,
    error,
);

/// Convert a schematic [`Color`] to egui, falling back to a theme default.
#[inline]
pub fn color_or(c: Color, default: Color32) -> Color32 {
    if c.is_none() {
        default
    } else {
        Color32::from_rgba_premultiplied(c.r, c.g, c.b, c.a)
    }
}

// ════════════════════════════════════════════════════════════
// Dialog / chrome scratch state
// ════════════════════════════════════════════════════════════

/// What the right-click context menu landed on.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CtxHit {
    #[default]
    None,
    Obj(ObjectRef),
    BusRipper(usize),
}

#[derive(Debug, Clone, Default)]
pub struct CtxMenuState {
    pub open: bool,
    pub pixel_pos: [f32; 2],
    pub world_pos: [i32; 2],
    pub hit: CtxHit,
    // Inline bus editors
    pub bus_rename: String,
    pub bus_width: u16,
}

#[derive(Debug, Clone, Default)]
pub struct PropsDialogState {
    pub inst_idx: usize,
    pub name_buf: String,
    pub prop_values: Vec<String>,
    pub initialized: bool,
}

#[derive(Debug, Clone)]
pub struct FindResult {
    pub label: String,
    pub index: usize,
}

#[derive(Debug, Clone, Default)]
pub struct FindDialogState {
    pub query: String,
    pub results: Vec<FindResult>,
    pub selected: Option<usize>,
}

/// Library browser sections (rows index into the section's source list).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibrarySection {
    Builtin,
    Pdk,
    ProjectPrims,
    ProjectSymbols,
}

#[derive(Debug, Clone, Default)]
pub struct NewPrimDialogState {
    pub name_buf: String,
    pub pins_buf: String,
    pub status_msg: String,
}

#[derive(Debug, Clone, Default)]
pub struct ImportDialogState {
    pub path_buf: String,
    pub pdk_name: String,
}

/// Waveform viewer window scratch (presentation-only).
#[derive(Debug, Clone, Default)]
pub struct WaveViewState {
    /// Signal browser live filter.
    pub filter: String,
    /// Expression bar buffer.
    pub expr: String,
    /// Cursor being dragged (0 = A, 1 = B).
    pub drag_cursor: Option<u8>,
    /// PNG export destination; set when a viewport screenshot is pending.
    pub pending_png: Option<std::path::PathBuf>,
}

/// Per-instance optimizer window scratch (presentation-only), keyed by
/// instance id in [`GuiState::optimizer`]. Entries are pruned each frame
/// for instances dropped by `OptimizerClose`.
#[derive(Debug, Clone, Default)]
pub struct OptimizerViewState {
    // Add-param row buffers (parsed on commit).
    pub param_name: String,
    pub param_min: String,
    pub param_max: String,
    pub param_init: String,
    // Add-objective row buffers (target: "min" | "max" | number).
    pub obj_name: String,
    pub obj_target: String,
    pub obj_weight: String,
    /// Measured-value buffers, one per objective (resized each frame).
    pub measured: Vec<String>,
}

// ════════════════════════════════════════════════════════════
// Top-level GUI state
// ════════════════════════════════════════════════════════════

/// All display-crate state that survives across frames.
#[derive(Debug, Clone, Default)]
pub struct GuiState {
    pub theme: Theme,

    // Vim command line (status bar)
    pub command_mode: bool,
    pub command_buf: String,
    /// Set while the command line has focus (suppresses keybinds).
    pub text_entry_focused: bool,

    // View toggles that are GUI-only (core ViewState has grid/dark/fullscreen)
    pub crosshair: bool,
    pub fill_rects: bool,

    // Dialog scratch
    pub props: PropsDialogState,
    pub find: FindDialogState,
    pub new_prim: NewPrimDialogState,
    pub import: ImportDialogState,
    pub ctx_menu: CtxMenuState,
    pub settings_filter: String,
    pub library_selected: Option<(LibrarySection, usize)>,

    // Doc view
    pub doc_buf: String,
    pub doc_loaded: bool,
    /// LaTeX → PNG render cache, keyed by hash(expr, style, color, dpr).
    pub doc_math_cache: std::collections::HashMap<u64, Result<std::sync::Arc<[u8]>, String>>,

    // Waveform viewer window
    pub wave: WaveViewState,

    // Optimizer windows — scratch per instance id
    pub optimizer: std::collections::HashMap<u32, OptimizerViewState>,

    // Marketplace dialog scratch
    pub marketplace: MarketplaceDialogState,
}

// ════════════════════════════════════════════════════════════
// Marketplace dialog state
// ════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Default)]
pub struct MarketplaceDialogState {
    pub search_query: String,
    pub results: Vec<SearchResult>,
    pub selected: Option<usize>,
    pub status: String,
    pub fetched: bool,
}
