//! Plugin input dispatch -- key events and hover.  Uses PluginHost interface only.
//!
//! Callers (in gui/) are responsible for mapping dvui keys to u8 chars and
//! packing modifier flags before calling these functions.  This avoids a
//! circular build-module dependency (plugins -> gui).

const plugins = @import("plugins");
const PluginHost = plugins.PluginHost.PluginHost;

/// Forward a pre-mapped key event to subscribed plugins.  Returns true if consumed.
/// `key_char` is the ASCII char from key_mapping.keyToChar, `mods` from packMods,
/// `action`: 0=down, 1=up, 2=repeat.
pub fn dispatchKeyEvent(host: PluginHost, key_char: u8, mods: u8, action: u8) bool {
    if (key_char == 0) return false;
    return host.dispatchKeyEvent(key_char, mods, action);
}

/// Hit-test cursor and dispatch hover event to subscribed plugins.
pub fn dispatchHover(host: PluginHost, cursor_world: [2]i32, element_type: u8, element_idx: i32, element_name: []const u8) void {
    host.dispatchHover(cursor_world[0], cursor_world[1], element_type, element_idx, element_name);
}

/// Get tooltip text from plugins.
pub fn getTooltip(host: PluginHost) []const u8 {
    return host.tooltipText();
}

