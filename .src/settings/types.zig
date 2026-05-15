//! Settings config types — ThemeConfig, KeybindConfig, and SettingsState.
//! Pure data types with no dependencies beyond std.

const std = @import("std");

// ── Theme config ─────────────────────────────────────────────────────────────

/// JSON-serializable theme configuration.
/// Matches the schema of bundled theme JSON files and ~/.config/Schemify/theme.json.
pub const ThemeConfig = struct {
    // Identity
    name: []const u8 = "Default",
    dark: bool = true,

    // Canvas colors (RGB or RGBA)
    canvas_bg: ?[3]u8 = null,
    grid_dot: ?[4]u8 = null,
    wire: ?[3]u8 = null,
    wire_selected: ?[3]u8 = null,
    wire_endpoint: ?[3]u8 = null,
    instance_body: ?[3]u8 = null,
    instance_pin: ?[3]u8 = null,
    symbol_line: ?[3]u8 = null,
    symbol_pin: ?[3]u8 = null,
    wire_preview: ?[4]u8 = null,
    origin: ?[4]u8 = null,

    // Chrome colors
    sidebar_bg: ?[3]u8 = null,
    bottombar_bg: ?[3]u8 = null,
    toolbar_bg: ?[3]u8 = null,
    tabbar_bg: ?[3]u8 = null,
    tab_active_bg: ?[3]u8 = null,
    statusbar_bg: ?[3]u8 = null,
    text_primary: ?[3]u8 = null,
    text_secondary: ?[3]u8 = null,
    accent: ?[3]u8 = null,
    separator: ?[3]u8 = null,
    hover_bg: ?[3]u8 = null,

    // Shape / spacing
    corner_radius: ?f32 = null,
    border_width: ?f32 = null,
    button_padding_h: ?f32 = null,
    button_padding_v: ?f32 = null,
    wire_width: ?f32 = null,
    grid_dot_size: ?f32 = null,
    tab_shape: ?u8 = null,
    toolbar_height: ?f32 = null,
    tabbar_height: ?f32 = null,
    statusbar_height: ?f32 = null,
};

/// A named preset (loaded from bundled themes or user's themes/ directory).
pub const ThemePreset = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    config: ThemeConfig = .{},

    pub fn nameSlice(self: *const ThemePreset) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ── Keybind config ───────────────────────────────────────────────────────────

/// A single keybind override from user config.
pub const KeybindEntry = struct {
    /// Key combo string, e.g. "ctrl+s", "r", "shift+r"
    key_combo: [32]u8 = [_]u8{0} ** 32,
    key_combo_len: u8 = 0,
    /// Command name, e.g. "save", "rotate_cw", "zoom_in"
    command: [64]u8 = [_]u8{0} ** 64,
    command_len: u8 = 0,

    pub fn keySlice(self: *const KeybindEntry) []const u8 {
        return self.key_combo[0..self.key_combo_len];
    }

    pub fn cmdSlice(self: *const KeybindEntry) []const u8 {
        return self.command[0..self.command_len];
    }
};

pub const KeybindPreset = enum {
    vim,
    conventional,
    custom,

    pub fn label(self: KeybindPreset) []const u8 {
        return switch (self) {
            .vim => "Vim (default)",
            .conventional => "Conventional",
            .custom => "Custom",
        };
    }
};

pub const KeybindConfig = struct {
    preset: KeybindPreset = .vim,
    overrides: std.ArrayListUnmanaged(KeybindEntry) = .{},

    pub fn deinit(self: *KeybindConfig, a: std.mem.Allocator) void {
        self.overrides.deinit(a);
    }
};

// ── Settings state ───────────────────────────────────────────────────────────

pub const SettingsDialogTab = enum {
    theme,
    keybinds,
};

pub const SettingsDialogState = struct {
    is_open: bool = false,
    active_tab: SettingsDialogTab = .theme,
    selected_preset: i16 = -1,
    json_edit_buf: [4096]u8 = [_]u8{0} ** 4096,
    json_edit_len: usize = 0,
    status_msg: [128]u8 = [_]u8{0} ** 128,
    status_len: u8 = 0,
    dirty: bool = false,
};
