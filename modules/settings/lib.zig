const std = @import("std");
pub const theme = @import("theme.zig");
pub const keybinds = @import("keybinds.zig");
pub const types = @import("types.zig");

// Re-export key types.
pub const ThemeConfig = types.ThemeConfig;
pub const ThemePreset = types.ThemePreset;
pub const KeybindConfig = types.KeybindConfig;
pub const KeybindEntry = types.KeybindEntry;
pub const KeybindPreset = types.KeybindPreset;
pub const SettingsDialogTab = types.SettingsDialogTab;
pub const SettingsDialogState = types.SettingsDialogState;

// ── Config directory ─────────────────────────────────────────────────────────

var config_dir_buf: [512]u8 = undefined;
var config_dir_len: usize = 0;
var initialized: bool = false;

/// Get the resolved config directory path.
pub fn configDir() []const u8 {
    if (!initialized) return "";
    return config_dir_buf[0..config_dir_len];
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

/// Initialize the settings system. Call once at startup before first frame.
/// Creates config directory if missing, loads theme.json and keybinds.json.
pub fn load(a: std.mem.Allocator) void {
    // Resolve ~/.config/Schemify/
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const dir = std.fmt.bufPrint(&config_dir_buf, "{s}/.config/Schemify", .{home}) catch return;
    config_dir_len = dir.len;
    initialized = true;

    // Create config directory tree if missing.
    ensureDir(dir);
    var themes_dir_buf: [520]u8 = undefined;
    const themes_dir = std.fmt.bufPrint(&themes_dir_buf, "{s}/themes", .{dir}) catch return;
    ensureDir(themes_dir);

    // Load theme and keybind configs.
    theme.loadFromDisk(dir, a);
    keybinds.loadFromDisk(dir, a);
}

/// Reload settings from disk (e.g. after user edits files externally).
pub fn reload(a: std.mem.Allocator) void {
    const dir = configDir();
    if (dir.len == 0) return;
    theme.loadFromDisk(dir, a);
    keybinds.loadFromDisk(dir, a);
}

/// Cleanup.
pub fn deinit(a: std.mem.Allocator) void {
    keybinds.deinit(a);
}

/// Get a JSON string of the active theme config suitable for applying to the
/// GUI theme system via theme.applyJson(). Caller owns the returned memory.
pub fn getActiveThemeJson(a: std.mem.Allocator) ?[]const u8 {
    return theme.toOverridesJson(a);
}

/// Apply a theme preset by index and save.
pub fn applyThemePreset(idx: usize, a: std.mem.Allocator) bool {
    return theme.applyPreset(idx, configDir(), a);
}

/// Apply keybind preset and save.
pub fn applyKeybindPreset(preset: KeybindPreset, a: std.mem.Allocator) void {
    keybinds.applyPreset(preset, configDir(), a);
}

/// Create default config files if they don't exist.
pub fn ensureDefaults(a: std.mem.Allocator) void {
    const dir = configDir();
    if (dir.len == 0) return;

    // Create default theme.json if missing.
    var t_path_buf: [520]u8 = undefined;
    const t_path = std.fmt.bufPrint(&t_path_buf, "{s}/theme.json", .{dir}) catch return;
    if (std.fs.cwd().access(t_path, .{})) |_| {
        // File exists, do nothing.
    } else |_| {
        _ = theme.saveToDisk(dir, a);
    }

    // Create default keybinds.json if missing.
    var k_path_buf: [520]u8 = undefined;
    const k_path = std.fmt.bufPrint(&k_path_buf, "{s}/keybinds.json", .{dir}) catch return;
    if (std.fs.cwd().access(k_path, .{})) |_| {
        // File exists, do nothing.
    } else |_| {
        _ = keybinds.saveToDisk(dir, a);
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn ensureDir(path: []const u8) void {
    std.fs.cwd().makePath(path) catch {};
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "configDir is empty before init" {
    const dir = configDir();
    try std.testing.expectEqual(@as(usize, 0), dir.len);
}
