const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const platform = @import("utility").platform;
const AppState = st.AppState;
const keybinds_input = @import("Input/keybinds.zig");
const theme_config = @import("theme_config");

// ── Types ────────────────────────────────────────────────────────────────────

pub const ThemeConfig = struct {
    name: []const u8 = "Default",
    dark: bool = true,
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

pub const ThemePreset = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    config: ThemeConfig = .{},

    pub fn nameSlice(self: *const ThemePreset) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const KeybindEntry = struct {
    key_combo: [32]u8 = [_]u8{0} ** 32,
    key_combo_len: u8 = 0,
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

pub const LlmProvider = enum { claude, openai, ollama };

pub const LlmSettings = struct {
    default_provider: LlmProvider = .claude,
    api_key_claude: [128]u8 = [_]u8{0} ** 128,
    api_key_claude_len: u8 = 0,
    api_key_openai: [128]u8 = [_]u8{0} ** 128,
    api_key_openai_len: u8 = 0,
    ollama_url: [256]u8 = [_]u8{0} ** 256,
    ollama_url_len: u16 = 0,
    model_claude: [64]u8 = [_]u8{0} ** 64,
    model_claude_len: u8 = 0,
    model_openai: [64]u8 = [_]u8{0} ** 64,
    model_openai_len: u8 = 0,
    model_ollama: [64]u8 = [_]u8{0} ** 64,
    model_ollama_len: u8 = 0,

    pub fn claudeKeySlice(self: *const LlmSettings) []const u8 {
        return self.api_key_claude[0..self.api_key_claude_len];
    }

    pub fn openaiKeySlice(self: *const LlmSettings) []const u8 {
        return self.api_key_openai[0..self.api_key_openai_len];
    }

    pub fn ollamaUrlSlice(self: *const LlmSettings) []const u8 {
        if (self.ollama_url_len > 0) return self.ollama_url[0..self.ollama_url_len];
        return "http://localhost:11434";
    }
};

pub const SettingsDialogTab = st.SettingsDialogTab;
pub const SettingsDialogState = st.SettingsDialogState;

// ── Config directory ─────────────────────────────────────────────────────────

var config_dir_buf: [512]u8 = undefined;
var config_dir_len: usize = 0;
var initialized: bool = false;

pub fn configDir() []const u8 {
    if (!initialized) return "";
    return config_dir_buf[0..config_dir_len];
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

pub fn load(a: std.mem.Allocator) void {
    const home = platform.homeDir() orelse "/tmp";
    const dir = std.fmt.bufPrint(&config_dir_buf, "{s}/.config/Schemify", .{home}) catch return;
    config_dir_len = dir.len;
    initialized = true;

    ensureDir(dir);
    var themes_dir_buf: [520]u8 = undefined;
    const themes_dir = std.fmt.bufPrint(&themes_dir_buf, "{s}/themes", .{dir}) catch return;
    ensureDir(themes_dir);

    theme_persistence.loadFromDisk(dir, a);
    keybind_persistence.loadFromDisk(dir, a);
}

pub fn reload(a: std.mem.Allocator) void {
    const dir = configDir();
    if (dir.len == 0) return;
    theme_persistence.loadFromDisk(dir, a);
    keybind_persistence.loadFromDisk(dir, a);
}

pub fn deinit(a: std.mem.Allocator) void {
    keybind_persistence.deinit(a);
}

pub fn getActiveThemeJson(a: std.mem.Allocator) ?[]const u8 {
    return theme_persistence.toOverridesJson(a);
}

pub fn applyThemePreset(idx: usize, a: std.mem.Allocator) bool {
    return theme_persistence.applyPreset(idx, configDir(), a);
}

pub fn applyKeybindPreset(preset: KeybindPreset, a: std.mem.Allocator) void {
    keybind_persistence.applyPreset(preset, configDir(), a);
}

pub fn ensureDefaults(a: std.mem.Allocator) void {
    const dir = configDir();
    if (dir.len == 0) return;

    var t_path_buf: [520]u8 = undefined;
    const t_path = std.fmt.bufPrint(&t_path_buf, "{s}/theme.json", .{dir}) catch return;
    if (platform.fs.cwd().access(t_path, .{})) |_| {} else |_| {
        _ = theme_persistence.saveToDisk(dir, a);
    }

    var k_path_buf: [520]u8 = undefined;
    const k_path = std.fmt.bufPrint(&k_path_buf, "{s}/keybinds.json", .{dir}) catch return;
    if (platform.fs.cwd().access(k_path, .{})) |_| {} else |_| {
        _ = keybind_persistence.saveToDisk(dir, a);
    }
}

fn ensureDir(path: []const u8) void {
    platform.fs.cwd().makePath(path) catch {};
}

// ── Theme persistence (internal) ─────────────────────────────────────────────

pub const theme_persistence = struct {
    const MAX_PRESETS = 64;

    var presets_buf: [MAX_PRESETS]ThemePreset = [_]ThemePreset{.{}} ** MAX_PRESETS;
    var presets_count: usize = 0;
    var active_config: ThemeConfig = .{};
    var active_name_buf: [64]u8 = [_]u8{0} ** 64;
    var active_name_len: u8 = 0;

    fn setActiveConfig(config: ThemeConfig) void {
        active_config = config;
        const name = config.name;
        active_name_len = @intCast(@min(name.len, 63));
        @memcpy(active_name_buf[0..active_name_len], name[0..active_name_len]);
        active_name_buf[active_name_len] = 0;
        active_config.name = active_name_buf[0..active_name_len];
    }

    pub fn getActiveConfig() *const ThemeConfig {
        return &active_config;
    }

    pub fn getActiveConfigMut() *ThemeConfig {
        return &active_config;
    }

    pub fn getPresets() []const ThemePreset {
        return presets_buf[0..presets_count];
    }

    pub fn loadFromDisk(cfg_dir: []const u8, a: std.mem.Allocator) void {
        loadPresets(cfg_dir, a);
        loadActiveTheme(cfg_dir, a);
    }

    pub fn saveToDisk(cfg_dir: []const u8, a: std.mem.Allocator) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/theme.json", .{cfg_dir}) catch return false;
        const json = serializeConfig(&active_config, a) orelse return false;
        defer a.free(json);
        const file = platform.fs.cwd().createFile(path, .{}) catch return false;
        defer file.close();
        file.writeAll(json) catch return false;
        return true;
    }

    pub fn applyPreset(idx: usize, cfg_dir: []const u8, a: std.mem.Allocator) bool {
        if (idx >= presets_count) return false;
        setActiveConfig(presets_buf[idx].config);
        return saveToDisk(cfg_dir, a);
    }

    pub fn applyJson(json_str: []const u8, a: std.mem.Allocator) bool {
        const config = parseThemeJson(json_str, a) orelse return false;
        setActiveConfig(config);
        return true;
    }

    pub fn toOverridesJson(a: std.mem.Allocator) ?[]const u8 {
        return serializeConfig(&active_config, a);
    }

    fn loadPresets(cfg_dir: []const u8, a: std.mem.Allocator) void {
        presets_count = 0;
        loadPresetsFromDir("plugins/Themes/themes", a);
        var user_dir_buf: [512]u8 = undefined;
        const user_dir = std.fmt.bufPrint(&user_dir_buf, "{s}/themes", .{cfg_dir}) catch return;
        loadPresetsFromDir(user_dir, a);
    }

    fn loadPresetsFromDir(dir_path: []const u8, a: std.mem.Allocator) void {
        var dir = platform.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
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
            const name = config.name;
            const len = @min(name.len, 63);
            @memcpy(preset.name[0..len], name[0..len]);
            preset.name[len] = 0;
            preset.name_len = @intCast(len);
            preset.config.name = preset.name[0..len];
            presets_count += 1;
        }
        if (presets_count > 1) {
            const LessThan = struct {
                fn lt(_: void, ap: ThemePreset, bp: ThemePreset) bool {
                    return std.mem.order(u8, ap.name[0..ap.name_len], bp.name[0..bp.name_len]) == .lt;
                }
            };
            std.sort.insertion(ThemePreset, presets_buf[0..presets_count], {}, LessThan.lt);
        }
    }

    fn loadActiveTheme(cfg_dir: []const u8, a: std.mem.Allocator) void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/theme.json", .{cfg_dir}) catch return;
        const data = platform.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch {
            if (presets_count > 0) {
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

    // ── Theme JSON parsing ───────────────────────────────────────────────────

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

        inline for (.{
            .{ "grid_dot", "grid_dot" },
            .{ "wire_preview", "wire_preview" },
            .{ "origin", "origin" },
        }) |pair| {
            if (@field(v, pair[0])) |arr| {
                @field(config, pair[1]) = .{ clamp8(arr[0]), clamp8(arr[1]), clamp8(arr[2]), clamp8(arr[3]) };
            }
        }

        inline for (.{
            "corner_radius", "border_width", "button_padding_h", "button_padding_v",
            "wire_width",    "grid_dot_size", "toolbar_height",  "tabbar_height",
            "statusbar_height",
        }) |name| {
            if (@field(v, name)) |fval| {
                @field(config, name) = @floatCast(fval);
            }
        }

        if (v.tab_shape) |n| config.tab_shape = @intCast(std.math.clamp(n, 0, 4));
        return config;
    }

    fn clamp8(x: i64) u8 {
        return @intCast(std.math.clamp(x, 0, 255));
    }

    // ── Theme JSON serialization ─────────────────────────────────────────────

    fn serializeConfig(config: *const ThemeConfig, a: std.mem.Allocator) ?[]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(a);
        var writer = buf.writer(a);

        writer.writeAll("{\n") catch return null;
        writer.print("  \"name\": \"{s}\",\n", .{config.name}) catch return null;
        writer.print("  \"dark\": {s},\n", .{if (config.dark) "true" else "false"}) catch return null;

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

        if (config.tab_shape) |v| {
            writer.print("  \"tab_shape\": {d},\n", .{v}) catch return null;
        }

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

        inline for (.{
            .{ "grid_dot", "grid_dot" },
            .{ "wire_preview", "wire_preview" },
            .{ "origin", "origin" },
        }) |pair| {
            if (@field(config, pair[1])) |rgba| {
                writer.print("  \"{s}\": [{d}, {d}, {d}, {d}],\n", .{ pair[0], rgba[0], rgba[1], rgba[2], rgba[3] }) catch return null;
            }
        }

        inline for (.{
            .{ "toolbar_height", "toolbar_height" },
            .{ "tabbar_height", "tabbar_height" },
            .{ "statusbar_height", "statusbar_height" },
        }) |pair| {
            if (@field(config, pair[1])) |v| {
                writer.print("  \"{s}\": {d:.0},\n", .{ pair[0], v }) catch return null;
            }
        }

        if (buf.items.len >= 2 and buf.items[buf.items.len - 2] == ',') {
            buf.items.len -= 2;
            writer.writeAll("\n") catch return null;
        }
        writer.writeAll("}\n") catch return null;
        return buf.toOwnedSlice(a) catch return null;
    }
};

// ── Keybind persistence (internal) ───────────────────────────────────────────

pub const keybind_persistence = struct {
    var active_config: KeybindConfig = .{};

    pub fn getPreset() KeybindPreset {
        return active_config.preset;
    }

    pub fn getOverrides() []const KeybindEntry {
        return active_config.overrides.items;
    }

    pub fn loadFromDisk(cfg_dir: []const u8, a: std.mem.Allocator) void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/keybinds.json", .{cfg_dir}) catch return;
        const data = platform.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch {
            active_config = .{ .preset = .vim };
            return;
        };
        defer a.free(data);
        parseKeybindsJson(data, a);
    }

    pub fn saveToDisk(cfg_dir: []const u8, a: std.mem.Allocator) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/keybinds.json", .{cfg_dir}) catch return false;
        const json = serializeConfig(a) orelse return false;
        defer a.free(json);
        const file = platform.fs.cwd().createFile(path, .{}) catch return false;
        defer file.close();
        file.writeAll(json) catch return false;
        return true;
    }

    pub fn applyPreset(preset: KeybindPreset, cfg_dir: []const u8, a: std.mem.Allocator) void {
        active_config.overrides.clearRetainingCapacity();
        active_config.preset = preset;

        if (preset == .conventional) {
            const conv = [_]struct { []const u8, []const u8 }{
                .{ "ctrl+n", "file_new" },
                .{ "ctrl+o", "file_open" },
                .{ "ctrl+s", "file_save" },
                .{ "ctrl+z", "undo" },
                .{ "ctrl+y", "redo" },
                .{ "ctrl+c", "clipboard_copy" },
                .{ "ctrl+x", "clipboard_cut" },
                .{ "ctrl+v", "clipboard_paste" },
                .{ "ctrl+a", "select_all" },
                .{ "ctrl+f", "find_select_dialog" },
                .{ "delete", "delete_selected" },
                .{ "ctrl+d", "duplicate_selected" },
                .{ "ctrl+r", "rotate_cw" },
                .{ "ctrl+shift+r", "rotate_ccw" },
            };
            for (conv) |c| {
                var entry = KeybindEntry{};
                const klen = @min(c[0].len, 31);
                @memcpy(entry.key_combo[0..klen], c[0][0..klen]);
                entry.key_combo_len = @intCast(klen);
                const clen = @min(c[1].len, 63);
                @memcpy(entry.command[0..clen], c[1][0..clen]);
                entry.command_len = @intCast(clen);
                active_config.overrides.append(a, entry) catch {};
            }
        }

        _ = saveToDisk(cfg_dir, a);
    }

    pub fn deinit(a: std.mem.Allocator) void {
        active_config.deinit(a);
    }

    fn parseKeybindsJson(json_str: []const u8, a: std.mem.Allocator) void {
        const parsed = std.json.parseFromSlice(std.json.Value, a, json_str, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;

        if (root.object.get("preset")) |pval| {
            if (pval == .string) {
                const ps = pval.string;
                if (std.mem.eql(u8, ps, "vim")) {
                    active_config.preset = .vim;
                } else if (std.mem.eql(u8, ps, "conventional")) {
                    active_config.preset = .conventional;
                } else {
                    active_config.preset = .custom;
                }
            }
        }

        active_config.overrides.clearRetainingCapacity();
        if (root.object.get("bindings")) |bval| {
            if (bval == .object) {
                var it = bval.object.iterator();
                while (it.next()) |kv| {
                    const key_str = kv.key_ptr.*;
                    const cmd_val = kv.value_ptr.*;
                    if (cmd_val != .string) continue;
                    const cmd_str = cmd_val.string;
                    var entry = KeybindEntry{};
                    const klen = @min(key_str.len, 31);
                    @memcpy(entry.key_combo[0..klen], key_str[0..klen]);
                    entry.key_combo_len = @intCast(klen);
                    const clen = @min(cmd_str.len, 63);
                    @memcpy(entry.command[0..clen], cmd_str[0..clen]);
                    entry.command_len = @intCast(clen);
                    active_config.overrides.append(a, entry) catch {};
                }
            }
        }
    }

    fn serializeConfig(a: std.mem.Allocator) ?[]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(a);
        var writer = buf.writer(a);
        writer.writeAll("{\n") catch return null;
        writer.print("  \"preset\": \"{s}\"", .{@tagName(active_config.preset)}) catch return null;

        if (active_config.overrides.items.len > 0) {
            writer.writeAll(",\n  \"bindings\": {\n") catch return null;
            for (active_config.overrides.items, 0..) |entry, i| {
                writer.print("    \"{s}\": \"{s}\"", .{
                    entry.keySlice(), entry.cmdSlice(),
                }) catch return null;
                if (i < active_config.overrides.items.len - 1) {
                    writer.writeAll(",\n") catch return null;
                } else {
                    writer.writeAll("\n") catch return null;
                }
            }
            writer.writeAll("  }\n") catch return null;
        } else {
            writer.writeAll("\n") catch return null;
        }

        writer.writeAll("}\n") catch return null;
        return buf.toOwnedSlice(a) catch return null;
    }
};

// ── Settings panel drawing ───────────────────────────────────────────────────

var settings_win_rect: st.WinRect = .{ .x = 80, .y = 60, .w = 640, .h = 520 };

pub fn draw(app: *AppState) void {
    const sd = &app.gui.cold.settings_dialog;
    if (!sd.is_open) return;

    const win = dvui.windowRect();
    settings_win_rect.w = win.w * 0.80;
    settings_win_rect.h = win.h * 0.80;
    settings_win_rect.x = (win.w - settings_win_rect.w) / 2.0;
    settings_win_rect.y = (win.h - settings_win_rect.h) / 2.0;

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &sd.is_open,
        .rect = winRectPtr(&settings_win_rect),
        .resize = .none,
    }, .{
        .min_size_content = .{ .w = 600, .h = 460 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Settings", "", &sd.is_open));

    // Tab bar
    {
        var tab_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 2 },
            .id_extra = 10000,
        });
        defer tab_bar.deinit();

        if (dvui.button(@src(), "Theme", .{}, .{
            .id_extra = 10001,
            .style = if (sd.active_tab == .theme) .highlight else .control,
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) sd.active_tab = .theme;

        if (dvui.button(@src(), "Keybinds", .{}, .{
            .id_extra = 10002,
            .style = if (sd.active_tab == .keybinds) .highlight else .control,
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) sd.active_tab = .keybinds;
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 10003 });

    switch (sd.active_tab) {
        .theme => drawThemeTab(app),
        .keybinds => drawKeybindsTab(app),
    }

    if (sd.status_len > 0) {
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 10099 });
        dvui.labelNoFmt(@src(), sd.status_msg[0..sd.status_len], .{}, .{
            .id_extra = 10100,
            .color_text = theme_config.chromeAccent(),
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        });
    }
}

fn drawThemeTab(app: *AppState) void {
    const sd = &app.gui.cold.settings_dialog;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .id_extra = 11000,
    });
    defer body.deinit();

    {
        const active = theme_persistence.getActiveConfig();
        var name_buf: [80]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&name_buf, "Active: {s}", .{active.name}) catch "Active: (unknown)", .{}, .{
            .id_extra = 11001,
            .style = .control,
        });
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 11002 });
    dvui.labelNoFmt(@src(), "Presets:", .{}, .{ .id_extra = 11003, .style = .control });

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .min_size_content = .{ .h = 120 },
            .max_size_content = .{ .w = 0, .h = 200 },
            .id_extra = 11004,
        });
        defer scroll.deinit();

        const presets = theme_persistence.getPresets();
        for (presets, 0..) |preset, i| {
            const name = preset.nameSlice();
            const is_selected = sd.selected_preset >= 0 and @as(usize, @intCast(sd.selected_preset)) == i;
            if (dvui.button(@src(), name, .{}, .{
                .id_extra = 11100 + i,
                .expand = .horizontal,
                .style = if (is_selected) .highlight else .control,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            })) {
                sd.selected_preset = @intCast(i);
            }
        }

        if (presets.len == 0) {
            dvui.labelNoFmt(@src(), "(no presets found)", .{}, .{ .id_extra = 11099, .style = .control });
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 11500 });

    dvui.labelNoFmt(@src(), "Shape:", .{}, .{ .id_extra = 11501, .style = .control });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 11502,
        });
        defer row.deinit();
        const shapes = [_]struct { []const u8, f32 }{
            .{ "Sharp", 0.0 },
            .{ "Balanced", 4.0 },
            .{ "Rounded", 8.0 },
            .{ "Pill", 16.0 },
        };
        inline for (shapes, 0..) |shape, si| {
            if (dvui.button(@src(), shape[0], .{}, .{
                .id_extra = 11510 + si,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            })) {
                applyShapePreset(app, shape[1]);
            }
        }
    }

    dvui.labelNoFmt(@src(), "Tab Style:", .{}, .{ .id_extra = 11520, .style = .control });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 11521,
        });
        defer row.deinit();
        const tabs = [_]struct { []const u8, u8 }{
            .{ "Rect", 0 },
            .{ "Rounded", 1 },
            .{ "Arrow", 2 },
            .{ "Angled", 3 },
            .{ "Underline", 4 },
        };
        inline for (tabs, 0..) |tab, ti| {
            if (dvui.button(@src(), tab[0], .{}, .{
                .id_extra = 11530 + ti,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            })) {
                applyTabStyle(app, tab[1]);
            }
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 11599 });

    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 11600,
        });
        defer btns.deinit();

        if (dvui.button(@src(), "Apply Preset", .{}, .{ .id_extra = 11601 })) {
            applySelectedPreset(app);
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = 11602 });

        if (dvui.button(@src(), "Save", .{}, .{ .id_extra = 11603 })) {
            const a = app.allocator();
            if (theme_persistence.saveToDisk(configDir(), a)) {
                setStatus(sd, "Theme saved");
            } else {
                setStatus(sd, "Failed to save theme");
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = 11604 });

        if (dvui.button(@src(), "Reload from Disk", .{}, .{ .id_extra = 11605 })) {
            const a = app.allocator();
            reload(a);
            applyThemeToGui(app);
            setStatus(sd, "Settings reloaded from disk");
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 11606 });

        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 11607 })) {
            sd.is_open = false;
        }
    }
}

fn drawKeybindsTab(app: *AppState) void {
    const sd = &app.gui.cold.settings_dialog;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .id_extra = 12000,
    });
    defer body.deinit();

    dvui.labelNoFmt(@src(), "Keybind Preset:", .{}, .{ .id_extra = 12001, .style = .control });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 12002,
        });
        defer row.deinit();

        const current = keybind_persistence.getPreset();

        if (dvui.button(@src(), "Vim (default)", .{}, .{
            .id_extra = 12010,
            .style = if (current == .vim) .highlight else .control,
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            applyKeybindPreset(.vim, app.allocator());
            setStatus(sd, "Vim keybinds applied");
        }

        if (dvui.button(@src(), "Conventional", .{}, .{
            .id_extra = 12011,
            .style = if (current == .conventional) .highlight else .control,
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            applyKeybindPreset(.conventional, app.allocator());
            setStatus(sd, "Conventional keybinds applied");
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 12020 });
    dvui.labelNoFmt(@src(), "Active Keybinds:", .{}, .{ .id_extra = 12021, .style = .control });

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .id_extra = 12022,
        });
        defer scroll.deinit();

        for (keybinds_input.static_keybinds, 0..) |kb, i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .id_extra = 12100 + i,
            });
            defer row.deinit();

            var buf: [32]u8 = undefined;
            const cs: []const u8 = if (kb.ctrl) "Ctrl+" else "";
            const ss: []const u8 = if (kb.shift) "Shift+" else "";
            const as: []const u8 = if (kb.alt) "Alt+" else "";
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{
                cs, ss, as, @tagName(kb.key),
            }) catch "?", .{}, .{
                .min_size_content = .{ .w = 160 },
                .id_extra = 12200 + i,
            });

            const astr: []const u8 = switch (kb.action) {
                .queue => |q| q.msg,
                .gui => |gg| @tagName(gg),
            };
            dvui.labelNoFmt(@src(), astr, .{}, .{
                .expand = .horizontal,
                .id_extra = 12300 + i,
            });
        }

        const overrides = keybind_persistence.getOverrides();
        if (overrides.len > 0) {
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 12400 });
            dvui.labelNoFmt(@src(), "Custom Overrides:", .{}, .{ .id_extra = 12401, .style = .control });

            for (overrides, 0..) |entry, i| {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .id_extra = 12500 + i,
                });
                defer row.deinit();

                dvui.labelNoFmt(@src(), entry.keySlice(), .{}, .{
                    .min_size_content = .{ .w = 160 },
                    .id_extra = 12600 + i,
                });
                dvui.labelNoFmt(@src(), entry.cmdSlice(), .{}, .{
                    .expand = .horizontal,
                    .id_extra = 12700 + i,
                });
            }
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 12800 });

    {
        var hint_buf: [128]u8 = undefined;
        const dir = configDir();
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&hint_buf, "Config: {s}/keybinds.json", .{dir}) catch "~/.config/Schemify/keybinds.json", .{}, .{
            .id_extra = 12801,
            .color_text = theme_config.chromeTextSecondary(),
        });
    }

    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 12900,
        });
        defer btns.deinit();

        if (dvui.button(@src(), "Save", .{}, .{ .id_extra = 12901 })) {
            const a = app.allocator();
            if (keybind_persistence.saveToDisk(configDir(), a)) {
                setStatus(sd, "Keybinds saved");
            } else {
                setStatus(sd, "Failed to save keybinds");
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = 12902 });

        if (dvui.button(@src(), "Reload", .{}, .{ .id_extra = 12903 })) {
            const a = app.allocator();
            keybind_persistence.loadFromDisk(configDir(), a);
            setStatus(sd, "Keybinds reloaded");
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 12904 });

        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 12905 })) {
            sd.is_open = false;
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

inline fn winRectPtr(wr: *st.WinRect) *dvui.Rect {
    return @ptrCast(wr);
}

fn setStatus(sd: *SettingsDialogState, msg: []const u8) void {
    const len = @min(msg.len, sd.status_msg.len);
    @memcpy(sd.status_msg[0..len], msg[0..len]);
    sd.status_len = @intCast(len);
}

fn applySelectedPreset(app: *AppState) void {
    const sd = &app.gui.cold.settings_dialog;
    if (sd.selected_preset < 0) {
        setStatus(sd, "No preset selected");
        return;
    }
    const idx: usize = @intCast(sd.selected_preset);
    const a = app.allocator();
    if (applyThemePreset(idx, a)) {
        applyThemeToGui(app);
        const presets = theme_persistence.getPresets();
        if (idx < presets.len) {
            var msg_buf: [80]u8 = undefined;
            setStatus(sd, std.fmt.bufPrint(&msg_buf, "Applied: {s}", .{presets[idx].nameSlice()}) catch "Applied");
        }
        app.status_msg = "Theme applied";
    } else {
        setStatus(sd, "Failed to apply preset");
    }
}

fn applyShapePreset(app: *AppState, corner_radius: f32) void {
    theme_config.current_overrides.corner_radius = corner_radius;
    const a = app.allocator();
    theme_persistence.getActiveConfigMut().corner_radius = corner_radius;
    _ = theme_persistence.saveToDisk(configDir(), a);
    var msg_buf: [64]u8 = undefined;
    app.setStatusBuf(std.fmt.bufPrint(&msg_buf, "Corner radius: {d:.0}", .{corner_radius}) catch "Shape applied");
}

fn applyTabStyle(app: *AppState, tab_shape: u8) void {
    theme_config.current_overrides.tab_shape = tab_shape;
    const a = app.allocator();
    theme_persistence.getActiveConfigMut().tab_shape = tab_shape;
    _ = theme_persistence.saveToDisk(configDir(), a);
    var msg_buf: [64]u8 = undefined;
    app.setStatusBuf(std.fmt.bufPrint(&msg_buf, "Tab style: {d}", .{tab_shape}) catch "Tab style applied");
}

fn applyThemeToGui(app: *AppState) void {
    const a = app.allocator();
    const json = getActiveThemeJson(a) orelse return;
    defer a.free(json);
    theme_config.applyJson(a, json);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "configDir is empty before init" {
    const dir = configDir();
    try std.testing.expectEqual(@as(usize, 0), dir.len);
}
