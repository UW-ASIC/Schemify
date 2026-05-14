const std = @import("std");
const types = @import("types.zig");
const ThemeConfig = types.ThemeConfig;
const ThemePreset = types.ThemePreset;

// ── Bundled theme presets ────────────────────────────────────────────────────
// Embedded at comptime from plugins/Themes/themes/*.json.
// Each preset is a ThemeConfig with a name.

/// Maximum number of presets (bundled + user).
pub const MAX_PRESETS = 64;

/// Loaded presets (populated at runtime from disk).
var presets_buf: [MAX_PRESETS]ThemePreset = [_]ThemePreset{.{}} ** MAX_PRESETS;
var presets_count: usize = 0;

/// Active theme config (loaded from theme.json or selected preset).
var active_config: ThemeConfig = .{};

/// Name buffer for the active config's name (avoids dangling pointer from JSON parse).
var active_name_buf: [64]u8 = [_]u8{0} ** 64;
var active_name_len: u8 = 0;

fn setActiveConfig(config: ThemeConfig) void {
    active_config = config;
    // Copy name into owned buffer so it doesn't dangle.
    const name = config.name;
    active_name_len = @intCast(@min(name.len, 63));
    @memcpy(active_name_buf[0..active_name_len], name[0..active_name_len]);
    active_name_buf[active_name_len] = 0;
    active_config.name = active_name_buf[0..active_name_len];
}

// ── Public API ───────────────────────────────────────────────────────────────

pub fn getActiveConfig() *const ThemeConfig {
    return &active_config;
}

pub fn getActiveConfigMut() *ThemeConfig {
    return &active_config;
}

pub fn getPresets() []const ThemePreset {
    return presets_buf[0..presets_count];
}

/// Load theme.json from config dir. Falls back to defaults if missing.
pub fn loadFromDisk(config_dir: []const u8, a: std.mem.Allocator) void {
    loadPresets(config_dir, a);
    loadActiveTheme(config_dir, a);
}

/// Save current theme config to theme.json.
pub fn saveToDisk(config_dir: []const u8, a: std.mem.Allocator) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/theme.json", .{config_dir}) catch return false;
    const json = serializeConfig(&active_config, a) orelse return false;
    defer a.free(json);

    const file = std.fs.cwd().createFile(path, .{}) catch return false;
    defer file.close();
    file.writeAll(json) catch return false;
    return true;
}

/// Apply a preset by index. Copies preset config to active and saves.
pub fn applyPreset(idx: usize, config_dir: []const u8, a: std.mem.Allocator) bool {
    if (idx >= presets_count) return false;
    setActiveConfig(presets_buf[idx].config);
    return saveToDisk(config_dir, a);
}

/// Apply raw JSON string. Returns true on success.
pub fn applyJson(json_str: []const u8, a: std.mem.Allocator) bool {
    const config = parseThemeJson(json_str, a) orelse return false;
    setActiveConfig(config);
    return true;
}

/// Convert current active config to ThemeOverrides-compatible JSON string
/// for passing to theme.applyJson() in the GUI module.
pub fn toOverridesJson(a: std.mem.Allocator) ?[]const u8 {
    return serializeConfig(&active_config, a);
}

// ── Preset loading ───────────────────────────────────────────────────────────

fn loadPresets(config_dir: []const u8, a: std.mem.Allocator) void {
    presets_count = 0;

    // Load bundled presets from the Themes plugin directory.
    // At build time these are at plugins/Themes/themes/. At runtime we search
    // relative to the executable or a known path.
    loadPresetsFromDir("plugins/Themes/themes", a);

    // Load user presets from ~/.config/Schemify/themes/
    var user_dir_buf: [512]u8 = undefined;
    const user_dir = std.fmt.bufPrint(&user_dir_buf, "{s}/themes", .{config_dir}) catch return;
    loadPresetsFromDir(user_dir, a);
}

fn loadPresetsFromDir(dir_path: []const u8, a: std.mem.Allocator) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (presets_count >= MAX_PRESETS) break;

        const data = dir.readFileAlloc(a, entry.name, 64 * 1024) catch continue;
        defer a.free(data);

        const config = parseThemeJson(data, a) orelse continue;

        var preset = &presets_buf[presets_count];
        preset.config = config;

        // Copy name into owned buffer so it doesn't dangle after JSON parse.
        const name = config.name;
        const len = @min(name.len, 63);
        @memcpy(preset.name[0..len], name[0..len]);
        preset.name[len] = 0;
        preset.name_len = @intCast(len);
        // Point the config's name at the owned buffer.
        preset.config.name = preset.name[0..len];

        presets_count += 1;
    }

    // Sort presets by name for stable UI ordering.
    if (presets_count > 1) {
        const LessThan = struct {
            fn lt(_: void, ap: ThemePreset, bp: ThemePreset) bool {
                return std.mem.order(u8, ap.name[0..ap.name_len], bp.name[0..bp.name_len]) == .lt;
            }
        };
        std.sort.insertion(ThemePreset, presets_buf[0..presets_count], {}, LessThan.lt);
    }
}

fn loadActiveTheme(config_dir: []const u8, a: std.mem.Allocator) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/theme.json", .{config_dir}) catch return;

    const data = std.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch {
        // No theme.json — use first preset if available, else defaults.
        if (presets_count > 0) {
            // Find "Schemify Dark" or use first preset.
            for (presets_buf[0..presets_count]) |p| {
                if (std.mem.eql(u8, p.nameSlice(), "Schemify Dark")) {
                    setActiveConfig(p.config);
                    return;
                }
            }
            setActiveConfig(presets_buf[0].config);
        }
        return;
    };
    defer a.free(data);

    if (parseThemeJson(data, a)) |config| {
        setActiveConfig(config);
    }
}

// ── JSON parsing ─────────────────────────────────────────────────────────────

const JsonSchema = struct {
    name: ?[]const u8 = null,
    dark: ?bool = null,
    canvas_bg: ?[3]i64 = null,
    grid_dot: ?[4]i64 = null,
    wire: ?[3]i64 = null,
    wire_selected: ?[3]i64 = null,
    wire_endpoint: ?[3]i64 = null,
    instance_body: ?[3]i64 = null,
    instance_pin: ?[3]i64 = null,
    symbol_line: ?[3]i64 = null,
    symbol_pin: ?[3]i64 = null,
    wire_preview: ?[4]i64 = null,
    origin: ?[4]i64 = null,
    sidebar_bg: ?[3]i64 = null,
    bottombar_bg: ?[3]i64 = null,
    toolbar_bg: ?[3]i64 = null,
    tabbar_bg: ?[3]i64 = null,
    tab_active_bg: ?[3]i64 = null,
    statusbar_bg: ?[3]i64 = null,
    text_primary: ?[3]i64 = null,
    text_secondary: ?[3]i64 = null,
    accent: ?[3]i64 = null,
    separator: ?[3]i64 = null,
    hover_bg: ?[3]i64 = null,
    corner_radius: ?f64 = null,
    border_width: ?f64 = null,
    button_padding_h: ?f64 = null,
    button_padding_v: ?f64 = null,
    wire_width: ?f64 = null,
    grid_dot_size: ?f64 = null,
    tab_shape: ?i64 = null,
    toolbar_height: ?f64 = null,
    tabbar_height: ?f64 = null,
    statusbar_height: ?f64 = null,
};

fn parseThemeJson(json_str: []const u8, a: std.mem.Allocator) ?ThemeConfig {
    const parsed = std.json.parseFromSlice(JsonSchema, a, json_str, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const v = &parsed.value;

    var config = ThemeConfig{};

    if (v.name) |n| config.name = n;
    if (v.dark) |d| config.dark = d;

    // RGB3 fields
    inline for (.{
        .{ "canvas_bg", "canvas_bg" },
        .{ "wire", "wire" },
        .{ "wire_selected", "wire_selected" },
        .{ "wire_endpoint", "wire_endpoint" },
        .{ "instance_body", "instance_body" },
        .{ "instance_pin", "instance_pin" },
        .{ "symbol_line", "symbol_line" },
        .{ "symbol_pin", "symbol_pin" },
        .{ "sidebar_bg", "sidebar_bg" },
        .{ "bottombar_bg", "bottombar_bg" },
        .{ "toolbar_bg", "toolbar_bg" },
        .{ "tabbar_bg", "tabbar_bg" },
        .{ "tab_active_bg", "tab_active_bg" },
        .{ "statusbar_bg", "statusbar_bg" },
        .{ "text_primary", "text_primary" },
        .{ "text_secondary", "text_secondary" },
        .{ "accent", "accent" },
        .{ "separator", "separator" },
        .{ "hover_bg", "hover_bg" },
    }) |pair| {
        if (@field(v, pair[0])) |arr| {
            @field(config, pair[1]) = .{ clamp8(arr[0]), clamp8(arr[1]), clamp8(arr[2]) };
        }
    }

    // RGBA4 fields
    inline for (.{
        .{ "grid_dot", "grid_dot" },
        .{ "wire_preview", "wire_preview" },
        .{ "origin", "origin" },
    }) |pair| {
        if (@field(v, pair[0])) |arr| {
            @field(config, pair[1]) = .{ clamp8(arr[0]), clamp8(arr[1]), clamp8(arr[2]), clamp8(arr[3]) };
        }
    }

    // Float fields
    inline for (.{
        "corner_radius", "border_width", "button_padding_h", "button_padding_v",
        "wire_width", "grid_dot_size", "toolbar_height", "tabbar_height", "statusbar_height",
    }) |name| {
        if (@field(v, name)) |fval| {
            @field(config, name) = @floatCast(fval);
        }
    }

    // Tab shape
    if (v.tab_shape) |n| config.tab_shape = @intCast(std.math.clamp(n, 0, 4));

    return config;
}

fn clamp8(x: i64) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}

// ── JSON serialization ──────────────────────────────────────────────────────

fn serializeConfig(config: *const ThemeConfig, a: std.mem.Allocator) ?[]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(a);
    var writer = buf.writer(a);

    writer.writeAll("{\n") catch return null;

    // Name and dark
    writer.print("  \"name\": \"{s}\",\n", .{config.name}) catch return null;
    writer.print("  \"dark\": {s},\n", .{if (config.dark) "true" else "false"}) catch return null;

    // Float fields
    inline for (.{
        .{ "corner_radius", "corner_radius" },
        .{ "border_width", "border_width" },
        .{ "wire_width", "wire_width" },
        .{ "grid_dot_size", "grid_dot_size" },
    }) |pair| {
        if (@field(config, pair[1])) |v| {
            writer.print("  \"{s}\": {d:.1},\n", .{ pair[0], v }) catch return null;
        }
    }

    // Tab shape
    if (config.tab_shape) |v| {
        writer.print("  \"tab_shape\": {d},\n", .{v}) catch return null;
    }

    // RGB3 colors
    inline for (.{
        .{ "canvas_bg", "canvas_bg" },
        .{ "wire", "wire" },
        .{ "wire_selected", "wire_selected" },
        .{ "wire_endpoint", "wire_endpoint" },
        .{ "instance_body", "instance_body" },
        .{ "instance_pin", "instance_pin" },
        .{ "symbol_line", "symbol_line" },
        .{ "symbol_pin", "symbol_pin" },
        .{ "sidebar_bg", "sidebar_bg" },
        .{ "bottombar_bg", "bottombar_bg" },
        .{ "toolbar_bg", "toolbar_bg" },
        .{ "tabbar_bg", "tabbar_bg" },
        .{ "tab_active_bg", "tab_active_bg" },
        .{ "statusbar_bg", "statusbar_bg" },
        .{ "text_primary", "text_primary" },
        .{ "text_secondary", "text_secondary" },
        .{ "accent", "accent" },
        .{ "separator", "separator" },
        .{ "hover_bg", "hover_bg" },
    }) |pair| {
        if (@field(config, pair[1])) |rgb| {
            writer.print("  \"{s}\": [{d}, {d}, {d}],\n", .{ pair[0], rgb[0], rgb[1], rgb[2] }) catch return null;
        }
    }

    // RGBA4 colors
    inline for (.{
        .{ "grid_dot", "grid_dot" },
        .{ "wire_preview", "wire_preview" },
        .{ "origin", "origin" },
    }) |pair| {
        if (@field(config, pair[1])) |rgba| {
            writer.print("  \"{s}\": [{d}, {d}, {d}, {d}],\n", .{ pair[0], rgba[0], rgba[1], rgba[2], rgba[3] }) catch return null;
        }
    }

    // Height fields
    inline for (.{
        .{ "toolbar_height", "toolbar_height" },
        .{ "tabbar_height", "tabbar_height" },
        .{ "statusbar_height", "statusbar_height" },
    }) |pair| {
        if (@field(config, pair[1])) |v| {
            writer.print("  \"{s}\": {d:.0},\n", .{ pair[0], v }) catch return null;
        }
    }

    // Remove trailing comma+newline, close brace
    if (buf.items.len >= 2 and buf.items[buf.items.len - 2] == ',') {
        buf.items.len -= 2; // remove ",\n"
        writer.writeAll("\n") catch return null;
    }
    writer.writeAll("}\n") catch return null;

    return buf.toOwnedSlice(a) catch return null;
}

