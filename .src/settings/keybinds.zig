//! Keybind settings — loading, saving, and providing keybind overrides.
//! Reads from ~/.config/Schemify/keybinds.json.

const std = @import("std");
const types = @import("types.zig");
const KeybindEntry = types.KeybindEntry;
const KeybindConfig = types.KeybindConfig;
const KeybindPreset = types.KeybindPreset;

// ── State ────────────────────────────────────────────────────────────────────

var active_config: KeybindConfig = .{};

// ── Public API ───────────────────────────────────────────────────────────────

pub fn getActiveConfig() *const KeybindConfig {
    return &active_config;
}

pub fn getPreset() KeybindPreset {
    return active_config.preset;
}

pub fn getOverrides() []const KeybindEntry {
    return active_config.overrides.items;
}

/// Load keybinds.json from config dir. Falls back to vim defaults if missing.
pub fn loadFromDisk(config_dir: []const u8, a: std.mem.Allocator) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/keybinds.json", .{config_dir}) catch return;

    const data = std.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch {
        // No keybinds.json — use vim defaults (no overrides).
        active_config = .{ .preset = .vim };
        return;
    };
    defer a.free(data);

    parseKeybindsJson(data, a);
}

/// Save current keybind config to keybinds.json.
pub fn saveToDisk(config_dir: []const u8, a: std.mem.Allocator) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/keybinds.json", .{config_dir}) catch return false;
    const json = serializeConfig(a) orelse return false;
    defer a.free(json);

    const file = std.fs.cwd().createFile(path, .{}) catch return false;
    defer file.close();
    file.writeAll(json) catch return false;
    return true;
}

/// Apply keybind preset. Clears overrides and sets new preset.
pub fn applyPreset(preset: KeybindPreset, config_dir: []const u8, a: std.mem.Allocator) void {
    active_config.overrides.clearRetainingCapacity();
    active_config.preset = preset;

    if (preset == .conventional) {
        // Load conventional overrides — standard shortcuts for non-vim users.
        // These remap single-key vim binds to ctrl+ combos.
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

    _ = saveToDisk(config_dir, a);
}

/// Apply raw JSON string for keybinds. Returns true on success.
pub fn applyJson(json_str: []const u8, a: std.mem.Allocator) bool {
    const old_config = active_config;
    parseKeybindsJson(json_str, a);
    if (active_config.preset == old_config.preset and
        active_config.overrides.items.len == 0 and old_config.overrides.items.len == 0)
    {
        // Nothing changed — likely a parse failure. Restore.
        active_config = old_config;
        return false;
    }
    return true;
}

pub fn deinit(a: std.mem.Allocator) void {
    active_config.deinit(a);
}

// ── JSON parsing ─────────────────────────────────────────────────────────────

const JsonSchema = struct {
    preset: ?[]const u8 = null,
    bindings: ?std.json.ObjectMap = null,
};

fn parseKeybindsJson(json_str: []const u8, a: std.mem.Allocator) void {
    // Parse as a generic JSON value to handle the bindings object map.
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_str, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    // Preset
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

    // Bindings
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

// ── JSON serialization ──────────────────────────────────────────────────────

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

/// Generate a human-readable summary of current keybinds for the settings dialog.
pub fn generateSummary(a: std.mem.Allocator) ?[]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(a);
    var writer = buf.writer(a);

    writer.print("Preset: {s}\n\n", .{active_config.preset.label()}) catch return null;

    if (active_config.overrides.items.len > 0) {
        writer.writeAll("Custom overrides:\n") catch return null;
        for (active_config.overrides.items) |entry| {
            writer.print("  {s} -> {s}\n", .{ entry.keySlice(), entry.cmdSlice() }) catch return null;
        }
    } else {
        writer.writeAll("No custom overrides.\nUsing default keybinds for preset.\n") catch return null;
    }

    return buf.toOwnedSlice(a) catch return null;
}
