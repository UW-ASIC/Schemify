//! Plugin manifest parser — reads plugin.toml files to extract static
//! contributions (panels, commands, menus, config schema, activation events)
//! without loading the plugin binary.
//!
//! Supports a subset of TOML: [sections], [[arrays-of-tables]], key = "value",
//! key = true/false, key = 123, key = ["a", "b"].

const std = @import("std");
const Cap = @import("Capability.zig");

// ── Public types ─────────────────────────────────────────────────────────────

pub const Keybind = struct {
    key: []const u8 = "",
    mods: []const []const u8 = &.{},
};

pub const PanelDef = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    layout: []const u8 = "",
    icon: []const u8 = "",
    vim_command: []const u8 = "",
    keybind: Keybind = .{},
};

pub const CommandDef = struct {
    tag: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    keybind: Keybind = .{},
};

pub const MenuDef = struct {
    location: []const u8 = "",
    label: []const u8 = "",
    command: []const u8 = "",
    when: []const u8 = "",
};

pub const ConfigDef = struct {
    key: []const u8 = "",
    type: []const u8 = "",
    default: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    options: []const []const u8 = &.{},
    min: ?i32 = null,
    max: ?i32 = null,
};

pub const FileTypeDef = struct {
    id: []const u8 = "",
    extensions: []const []const u8 = &.{},
    icon: []const u8 = "",
};

pub const ExtensionPointDef = struct {
    id: []const u8 = "",
    description: []const u8 = "",
};

pub const MessagesDef = struct {
    publishes: []const []const u8 = &.{},
    subscribes: []const []const u8 = &.{},
};

pub const BuildDef = struct {
    binary: []const u8 = "",
    wasm: []const u8 = "",
};

pub const PluginRuntime = enum { native, subprocess, hybrid };

pub const Manifest = struct {
    // [plugin]
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    author: []const u8 = "",
    description: []const u8 = "",
    license: []const u8 = "",
    api: u32 = 0,
    abi: u32 = 0,
    engine: []const u8 = "",
    runtime: PluginRuntime = .native,
    subprocess_command: []const u8 = "",

    // [capabilities]
    capabilities: Cap.Capability = .{},

    // [[panels]]
    panels: []const PanelDef = &.{},

    // [[commands]]
    commands: []const CommandDef = &.{},

    // [[menus]]
    menus: []const MenuDef = &.{},

    // [activation]
    activation_events: []const []const u8 = &.{},

    // [build]
    build: BuildDef = .{},

    // [[config]]
    config: []const ConfigDef = &.{},

    // [messages]
    messages: MessagesDef = .{},

    // [[file_types]]
    file_types: []const FileTypeDef = &.{},

    // [[extension_points]]
    extension_points: []const ExtensionPointDef = &.{},

    pub fn isApiV1(self: *const Manifest) bool {
        return self.api >= 1;
    }

    pub fn deinit(self: *const Manifest, alloc: std.mem.Allocator) void {
        const freeStr = struct {
            fn f(a: std.mem.Allocator, s: []const u8) void {
                if (s.len > 0) a.free(s);
            }
        }.f;

        // Top-level strings
        freeStr(alloc, self.id);
        freeStr(alloc, self.name);
        freeStr(alloc, self.version);
        freeStr(alloc, self.author);
        freeStr(alloc, self.description);
        freeStr(alloc, self.license);
        freeStr(alloc, self.engine);
        freeStr(alloc, self.subprocess_command);

        // Build
        freeStr(alloc, self.build.binary);
        freeStr(alloc, self.build.wasm);

        // Activation events
        for (self.activation_events) |e| freeStr(alloc, e);
        if (self.activation_events.len > 0) alloc.free(self.activation_events);

        // Panels
        for (self.panels) |p| {
            freeStr(alloc, p.id);
            freeStr(alloc, p.title);
            freeStr(alloc, p.layout);
            freeStr(alloc, p.icon);
            freeStr(alloc, p.vim_command);
            freeStr(alloc, p.keybind.key);
            for (p.keybind.mods) |mod| freeStr(alloc, mod);
            if (p.keybind.mods.len > 0) alloc.free(p.keybind.mods);
        }
        if (self.panels.len > 0) alloc.free(self.panels);

        // Commands
        for (self.commands) |c| {
            freeStr(alloc, c.tag);
            freeStr(alloc, c.name);
            freeStr(alloc, c.description);
            freeStr(alloc, c.keybind.key);
            for (c.keybind.mods) |mod| freeStr(alloc, mod);
            if (c.keybind.mods.len > 0) alloc.free(c.keybind.mods);
        }
        if (self.commands.len > 0) alloc.free(self.commands);

        // Menus
        for (self.menus) |menu| {
            freeStr(alloc, menu.location);
            freeStr(alloc, menu.label);
            freeStr(alloc, menu.command);
            freeStr(alloc, menu.when);
        }
        if (self.menus.len > 0) alloc.free(self.menus);

        // Config
        for (self.config) |cfg| {
            freeStr(alloc, cfg.key);
            freeStr(alloc, cfg.type);
            freeStr(alloc, cfg.default);
            freeStr(alloc, cfg.title);
            freeStr(alloc, cfg.description);
            for (cfg.options) |o| freeStr(alloc, o);
            if (cfg.options.len > 0) alloc.free(cfg.options);
        }
        if (self.config.len > 0) alloc.free(self.config);

        // Messages
        for (self.messages.publishes) |p| freeStr(alloc, p);
        if (self.messages.publishes.len > 0) alloc.free(self.messages.publishes);
        for (self.messages.subscribes) |s| freeStr(alloc, s);
        if (self.messages.subscribes.len > 0) alloc.free(self.messages.subscribes);

        // File types
        for (self.file_types) |ft| {
            freeStr(alloc, ft.id);
            freeStr(alloc, ft.icon);
            for (ft.extensions) |e| freeStr(alloc, e);
            if (ft.extensions.len > 0) alloc.free(ft.extensions);
        }
        if (self.file_types.len > 0) alloc.free(self.file_types);

        // Extension points
        for (self.extension_points) |ep| {
            freeStr(alloc, ep.id);
            freeStr(alloc, ep.description);
        }
        if (self.extension_points.len > 0) alloc.free(self.extension_points);
    }
};

// ── Parser ───────────────────────────────────────────────────────────────────

const Section = enum {
    none,
    plugin,
    capabilities,
    activation,
    build,
    messages,
    // Array-of-table contexts
    panels,
    commands,
    menus,
    config,
    file_types,
    extension_points,
};

pub const ParseError = error{ InvalidFormat, OutOfMemory };

pub fn parse(alloc: std.mem.Allocator, source: []const u8) ParseError!Manifest {
    var m = Manifest{};

    var panels_list = std.ArrayListUnmanaged(PanelDef){};
    var commands_list = std.ArrayListUnmanaged(CommandDef){};
    var menus_list = std.ArrayListUnmanaged(MenuDef){};
    var config_list = std.ArrayListUnmanaged(ConfigDef){};
    var file_types_list = std.ArrayListUnmanaged(FileTypeDef){};
    var ext_points_list = std.ArrayListUnmanaged(ExtensionPointDef){};

    var section: Section = .none;

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
        const trimmed = std.mem.trimLeft(u8, line, &[_]u8{ ' ', '\t' });

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Array-of-tables: [[name]]
        if (std.mem.startsWith(u8, trimmed, "[[") and std.mem.endsWith(u8, trimmed, "]]")) {
            const name = trimmed[2 .. trimmed.len - 2];
            if (std.mem.eql(u8, name, "panels")) {
                section = .panels;
                panels_list.append(alloc, .{}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, "commands")) {
                section = .commands;
                commands_list.append(alloc, .{}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, "menus")) {
                section = .menus;
                menus_list.append(alloc, .{}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, "config")) {
                section = .config;
                config_list.append(alloc, .{}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, "file_types")) {
                section = .file_types;
                file_types_list.append(alloc, .{}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, "extension_points")) {
                section = .extension_points;
                ext_points_list.append(alloc, .{}) catch return error.OutOfMemory;
            }
            continue;
        }

        // Table: [name]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = trimmed[1 .. trimmed.len - 1];
            if (std.mem.eql(u8, name, "plugin")) {
                section = .plugin;
            } else if (std.mem.eql(u8, name, "capabilities")) {
                section = .capabilities;
            } else if (std.mem.eql(u8, name, "activation")) {
                section = .activation;
            } else if (std.mem.eql(u8, name, "build")) {
                section = .build;
            } else if (std.mem.eql(u8, name, "messages")) {
                section = .messages;
            } else {
                section = .none;
            }
            continue;
        }

        // Key = Value
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trimRight(u8, trimmed[0..eq_pos], &[_]u8{ ' ', '\t' });
        const raw_val = std.mem.trimLeft(u8, trimmed[eq_pos + 1 ..], &[_]u8{ ' ', '\t' });

        switch (section) {
            .plugin => {
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "id")) {
                    m.id = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "name")) {
                    m.name = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "version")) {
                    m.version = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "author")) {
                    m.author = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "description")) {
                    m.description = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "license")) {
                    m.license = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "api")) {
                    m.api = std.fmt.parseInt(u32, raw_val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "abi")) {
                    m.abi = std.fmt.parseInt(u32, raw_val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "binary")) {
                    if (m.build.binary.len == 0)
                        m.build.binary = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "engine")) {
                    m.engine = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "runtime")) {
                    if (std.mem.eql(u8, val, "subprocess")) {
                        m.runtime = .subprocess;
                    } else if (std.mem.eql(u8, val, "hybrid")) {
                        m.runtime = .hybrid;
                    } else {
                        m.runtime = .native;
                    }
                } else if (std.mem.eql(u8, key, "entry")) {
                    if (m.build.binary.len == 0)
                        m.build.binary = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "command")) {
                    m.subprocess_command = alloc.dupe(u8, val) catch return error.OutOfMemory;
                }
            },
            .capabilities => {
                if (isBoolTrue(raw_val)) {
                    if (Cap.fromName(key)) |cap| {
                        m.capabilities = Cap.merge(m.capabilities, cap);
                    }
                }
            },
            .activation => {
                if (std.mem.eql(u8, key, "events")) {
                    m.activation_events = parseStrArray(alloc, raw_val) catch return error.OutOfMemory;
                }
            },
            .build => {
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "binary")) {
                    m.build.binary = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "wasm")) {
                    m.build.wasm = alloc.dupe(u8, val) catch return error.OutOfMemory;
                }
            },
            .messages => {
                if (std.mem.eql(u8, key, "publishes")) {
                    m.messages.publishes = parseStrArray(alloc, raw_val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "subscribes")) {
                    m.messages.subscribes = parseStrArray(alloc, raw_val) catch return error.OutOfMemory;
                }
            },
            .panels => {
                if (panels_list.items.len == 0) continue;
                var panel = &panels_list.items[panels_list.items.len - 1];
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "id")) {
                    panel.id = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "title")) {
                    panel.title = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "layout")) {
                    panel.layout = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "icon")) {
                    panel.icon = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "vim_command") or std.mem.eql(u8, key, "vim_cmd")) {
                    panel.vim_command = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "keybind")) {
                    panel.keybind = parseKeybind(alloc, raw_val) catch .{};
                }
            },
            .commands => {
                if (commands_list.items.len == 0) continue;
                var cmd = &commands_list.items[commands_list.items.len - 1];
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "tag")) {
                    cmd.tag = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "name")) {
                    cmd.name = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "description")) {
                    cmd.description = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "keybind")) {
                    cmd.keybind = parseKeybind(alloc, raw_val) catch .{};
                }
            },
            .menus => {
                if (menus_list.items.len == 0) continue;
                var menu = &menus_list.items[menus_list.items.len - 1];
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "location")) {
                    menu.location = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "label")) {
                    menu.label = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "command")) {
                    menu.command = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "when")) {
                    menu.when = alloc.dupe(u8, val) catch return error.OutOfMemory;
                }
            },
            .config => {
                if (config_list.items.len == 0) continue;
                var cfg = &config_list.items[config_list.items.len - 1];
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "key")) {
                    cfg.key = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "type")) {
                    cfg.type = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "default")) {
                    cfg.default = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "title")) {
                    cfg.title = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "description")) {
                    cfg.description = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "options")) {
                    cfg.options = parseStrArray(alloc, raw_val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "min")) {
                    cfg.min = std.fmt.parseInt(i32, raw_val, 10) catch null;
                } else if (std.mem.eql(u8, key, "max")) {
                    cfg.max = std.fmt.parseInt(i32, raw_val, 10) catch null;
                }
            },
            .file_types => {
                if (file_types_list.items.len == 0) continue;
                var ft = &file_types_list.items[file_types_list.items.len - 1];
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "id")) {
                    ft.id = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "extensions")) {
                    ft.extensions = parseStrArray(alloc, raw_val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "icon")) {
                    ft.icon = alloc.dupe(u8, val) catch return error.OutOfMemory;
                }
            },
            .extension_points => {
                if (ext_points_list.items.len == 0) continue;
                var ep = &ext_points_list.items[ext_points_list.items.len - 1];
                const val = unquote(raw_val);
                if (std.mem.eql(u8, key, "id")) {
                    ep.id = alloc.dupe(u8, val) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, key, "description")) {
                    ep.description = alloc.dupe(u8, val) catch return error.OutOfMemory;
                }
            },
            .none => {},
        }
    }

    // Convert array lists to owned slices
    m.panels = panels_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
    m.commands = commands_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
    m.menus = menus_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
    m.config = config_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
    m.file_types = file_types_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
    m.extension_points = ext_points_list.toOwnedSlice(alloc) catch return error.OutOfMemory;

    return m;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn isBoolTrue(s: []const u8) bool {
    return std.mem.eql(u8, s, "true");
}

fn parseStrArray(alloc: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    // Parse ["a", "b", "c"] or single "value"
    const trimmed = std.mem.trim(u8, raw, &[_]u8{ ' ', '\t' });
    if (trimmed.len == 0) return &.{};

    if (trimmed[0] != '[') {
        // Single value
        const v = unquote(trimmed);
        const duped = try alloc.dupe(u8, v);
        const slice = try alloc.alloc([]const u8, 1);
        slice[0] = duped;
        return slice;
    }

    // Strip brackets
    const inner = if (trimmed.len >= 2 and trimmed[trimmed.len - 1] == ']')
        std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &[_]u8{ ' ', '\t', '\n', '\r' })
    else
        trimmed[1..];

    var list = std.ArrayListUnmanaged([]const u8){};
    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |item| {
        const entry = std.mem.trim(u8, item, &[_]u8{ ' ', '\t', '\n', '\r' });
        if (entry.len == 0) continue;
        const val = unquote(entry);
        if (val.len == 0) continue;
        try list.append(alloc, try alloc.dupe(u8, val));
    }
    return list.toOwnedSlice(alloc);
}

fn parseKeybind(alloc: std.mem.Allocator, raw: []const u8) !Keybind {
    // Parse { key = "c", mods = ["ctrl", "shift"] }  (old format)
    // or just "c"  (API v1 simple string format)
    const trimmed = std.mem.trim(u8, raw, &[_]u8{ ' ', '\t' });
    if (trimmed.len < 2) return .{};

    // API v1: simple quoted string like "c" → key only, no mods
    if (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return .{ .key = try alloc.dupe(u8, trimmed[1 .. trimmed.len - 1]) };
    }

    if (trimmed[0] != '{') return .{};

    var kb = Keybind{};
    const inner = if (trimmed[trimmed.len - 1] == '}')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed[1..];

    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |pair| {
        const t = std.mem.trim(u8, pair, &[_]u8{ ' ', '\t' });
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const k = std.mem.trim(u8, t[0..eq], &[_]u8{ ' ', '\t' });
        const v = std.mem.trim(u8, t[eq + 1 ..], &[_]u8{ ' ', '\t' });

        if (std.mem.eql(u8, k, "key")) {
            kb.key = try alloc.dupe(u8, unquote(v));
        } else if (std.mem.eql(u8, k, "mods")) {
            kb.mods = try parseStrArray(alloc, v);
        }
    }
    return kb;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parse minimal manifest" {
    const src =
        \\[plugin]
        \\id = "test"
        \\name = "Test Plugin"
        \\version = "1.0.0"
        \\abi = 9
        \\
        \\[capabilities]
        \\file_read_project = true
        \\canvas_draw = true
        \\network = false
        \\
        \\[[panels]]
        \\id = "test-main"
        \\title = "Test Panel"
        \\layout = "right_sidebar"
        \\vim_command = "test"
        \\
        \\[[commands]]
        \\tag = "test_run"
        \\name = "Test: Run"
        \\description = "Run the test"
        \\
        \\[activation]
        \\events = ["onCommand:test_*", "onPanel:test-*"]
        \\
        \\[build]
        \\binary = "libtest.so"
    ;

    const m = try parse(std.testing.allocator, src);

    defer m.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test", m.id);
    try std.testing.expectEqualStrings("Test Plugin", m.name);
    try std.testing.expectEqual(@as(u32, 0), m.api);
    try std.testing.expectEqual(@as(u32, 9), m.abi);
    try std.testing.expect(!m.isApiV1());
    try std.testing.expect(m.capabilities.file_read_project);
    try std.testing.expect(m.capabilities.canvas_draw);
    try std.testing.expect(!m.capabilities.network);
    try std.testing.expectEqual(@as(usize, 1), m.panels.len);
    try std.testing.expectEqualStrings("test-main", m.panels[0].id);
    try std.testing.expectEqual(@as(usize, 1), m.commands.len);
    try std.testing.expectEqualStrings("test_run", m.commands[0].tag);
    try std.testing.expectEqual(@as(usize, 2), m.activation_events.len);
    try std.testing.expectEqualStrings("libtest.so", m.build.binary);
}

test "parse API v1 manifest" {
    const src =
        \\[plugin]
        \\name = "TestPlugin"
        \\version = "1.0.0"
        \\api = 1
        \\binary = "test.so"
        \\
        \\[activation]
        \\events = ["on_startup"]
        \\
        \\[[panels]]
        \\id = "test_main"
        \\title = "Test"
        \\layout = "right_sidebar"
        \\keybind = "t"
        \\vim_cmd = "test"
    ;
    const m = try parse(std.testing.allocator, src);
    defer m.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), m.api);
    try std.testing.expectEqual(@as(u32, 0), m.abi);
    try std.testing.expect(m.isApiV1());
    try std.testing.expectEqualStrings("TestPlugin", m.name);
    try std.testing.expectEqualStrings("test.so", m.build.binary);
    try std.testing.expectEqual(@as(usize, 1), m.activation_events.len);
    try std.testing.expectEqualStrings("on_startup", m.activation_events[0]);
    try std.testing.expectEqual(@as(usize, 1), m.panels.len);
    try std.testing.expectEqualStrings("test_main", m.panels[0].id);
    try std.testing.expectEqualStrings("Test", m.panels[0].title);
    try std.testing.expectEqualStrings("right_sidebar", m.panels[0].layout);
    try std.testing.expectEqualStrings("t", m.panels[0].keybind.key);
    try std.testing.expectEqualStrings("test", m.panels[0].vim_command);
}
