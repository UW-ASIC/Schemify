"""
Schemify Themes Plugin — built-in and user themes with live switching.

Ships with 22 built-in themes and allows users to add custom themes as
.json files in ~/.config/Schemify/themes/.

The active theme's full color config is sent to the host via SET_CONFIG
whenever a theme button is clicked.

Theme categories are based on corner_radius:
  Sharp    — corner_radius 0–2
  Balanced — corner_radius 3–6
  Rounded  — corner_radius 7–12
  Pill     — corner_radius 13+
"""

from __future__ import annotations

import json
import os
import sys

# ── SDK path resolution ───────────────────────────────────────────────────────
# When the host copies this script to the install location the relative path
# to the SDK bindings is three levels up from the plugin's src/ dir.
_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_PYTHON_DIR = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "sdk", "bindings", "python")
)
if _SDK_PYTHON_DIR not in sys.path:
    sys.path.insert(0, _SDK_PYTHON_DIR)

import schemify  # noqa: E402 (must follow sys.path setup)

# ── Constants ─────────────────────────────────────────────────────────────────

PANEL_ID    = "themes"
PANEL_TITLE = "Themes"
TAG         = "Themes"

# Widget ID ranges:
#   0–9      : header/labels
#   10–209   : theme buttons (up to 200 themes)
#   210–219  : Shape Preset buttons
#   220–229  : Wire Width buttons
#   230–239  : Tab Style buttons
WID_THEME_BASE        = 10
WID_SHAPE_PRESET_BASE = 210
WID_WIRE_WIDTH_BASE   = 220
WID_TAB_STYLE_BASE    = 230

# Shape preset definitions: (label, corner_radius)
SHAPE_PRESETS = [
    ("Sharp",    0.0),
    ("Balanced", 4.0),
    ("Rounded",  8.0),
    ("Pill",     16.0),
]

# Wire width preset definitions: (label, wire_width)
WIRE_WIDTHS = [
    ("Thin (1px)",    1.0),
    ("Normal (1.5px)", 1.0),   # multiplier 1.0 = default 1.5px base
    ("Thick (2.5px)", 1.4),
    ("Bold (3px)",    1.8),
]

# Tab style definitions: (label, tab_shape)
TAB_STYLES = [
    ("Rect [0]",      0),
    ("Rounded [1]",   1),
    ("Arrow [2]",     2),
    ("Angled [3]",    3),
    ("Underline [4]", 4),
]

# Bundled themes directory.
# When deployed via addPythonPlugin the build.zig copies themes/*.json to
# $SCRIPTS/Themes/themes/ (same directory as plugin.py) so we look there first,
# then fall back to the in-repo location (one level up from src/) for development.
_BUNDLED_THEMES_DIR_INSTALLED = os.path.join(_PLUGIN_SRC_DIR, "themes")
_BUNDLED_THEMES_DIR_DEV       = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "themes")
)
# Prefer the installed path; fall back to the dev (source tree) path.
_BUNDLED_THEMES_DIR = (
    _BUNDLED_THEMES_DIR_INSTALLED
    if os.path.isdir(_BUNDLED_THEMES_DIR_INSTALLED)
    else _BUNDLED_THEMES_DIR_DEV
)

# User themes directory
_USER_THEMES_DIR = os.path.join(
    os.environ.get("HOME", os.path.expanduser("~")),
    ".config", "Schemify", "themes"
)


# ── Theme loading ─────────────────────────────────────────────────────────────

def _load_themes_from_dir(directory: str) -> dict:
    """Load all .json theme files from a directory. Returns name -> data dict."""
    result = {}
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return result
    for filename in entries:
        if not filename.endswith(".json"):
            continue
        filepath = os.path.join(directory, filename)
        try:
            with open(filepath, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            name = data.get("name")
            if name:
                result[name] = data
        except Exception:
            pass
    return result


def _load_all_themes() -> tuple[dict, list]:
    """Load bundled themes then user themes. User themes override bundled ones."""
    themes: dict = {}
    # Bundled themes first (deterministic order from sorted filenames)
    themes.update(_load_themes_from_dir(_BUNDLED_THEMES_DIR))
    # User themes can override or extend
    themes.update(_load_themes_from_dir(_USER_THEMES_DIR))
    names = list(themes.keys())
    return themes, names


def _corner_category(theme: dict) -> str:
    """Return the display category string for a theme based on corner_radius."""
    cr = theme.get("corner_radius", 4.0)
    if cr <= 2:
        return "Sharp"
    elif cr <= 6:
        return "Balanced"
    elif cr <= 12:
        return "Rounded"
    else:
        return "Pill"


# ── Plugin ────────────────────────────────────────────────────────────────────

class ThemesPlugin(schemify.Plugin):
    """Built-in and user-defined theme switcher."""

    def __init__(self) -> None:
        self._themes: dict = {}
        self._theme_names: list = []
        self._current_idx: int = 0

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def on_load(self, w: schemify.Writer) -> None:
        self._themes, self._theme_names = _load_all_themes()
        w.log_info(TAG, f"Loaded {len(self._theme_names)} themes")

        w.register_panel(
            id=PANEL_ID,
            title=PANEL_TITLE,
            vim_cmd="themes",
            layout=schemify.LAYOUT_OVERLAY,
            keybind=0,
        )
        w.set_status(f"Themes plugin ready ({len(self._theme_names)} themes)")

    def on_unload(self, w: schemify.Writer) -> None:
        w.log_info(TAG, "on_unload")

    def on_tick(self, dt: float, w: schemify.Writer) -> None:
        pass

    # ── Draw ───────────────────────────────────────────────────────────────────

    def on_draw(self, panel_id: int, w: schemify.Writer) -> None:
        # ── Header ────────────────────────────────────────────────────────── #
        w.label("Themes", id=0)
        w.separator(id=1)

        if not self._theme_names:
            w.label("No themes found.", id=2)
            w.label(f"Add .json files to:", id=3)
            w.label(_USER_THEMES_DIR, id=4)
        else:
            # Show current theme name
            current_name = self._theme_names[self._current_idx] if self._theme_names else "—"
            w.label(f"Active: {current_name}", id=5)
            w.separator(id=6)

            # Group themes by category
            categories: dict[str, list[tuple[int, str]]] = {
                "Sharp": [], "Balanced": [], "Rounded": [], "Pill": []
            }
            for i, name in enumerate(self._theme_names):
                theme = self._themes[name]
                cat = _corner_category(theme)
                if cat not in categories:
                    categories[cat] = []
                categories[cat].append((i, name))

            widget_id = WID_THEME_BASE
            for cat_name, entries in categories.items():
                if not entries:
                    continue
                w.label(f"── {cat_name} ──", id=widget_id)
                widget_id += 1
                for orig_idx, name in entries:
                    theme = self._themes[name]
                    dark_tag = " (dark)" if theme.get("dark", True) else " (light)"
                    marker = "> " if orig_idx == self._current_idx else "  "
                    w.button(f"{marker}{name}{dark_tag}", id=WID_THEME_BASE + orig_idx)

        w.separator(id=207)
        w.label("User themes: ~/.config/Schemify/themes/", id=208)
        w.label("Add .json files and reload plugin.", id=209)

        # ── Shape Presets ─────────────────────────────────────────────────── #
        w.separator(id=210)
        w.label("Shape Presets", id=211)
        for i, (label, _cr) in enumerate(SHAPE_PRESETS):
            w.button(label, id=WID_SHAPE_PRESET_BASE + i)

        # ── Wire Width ────────────────────────────────────────────────────── #
        w.separator(id=220)
        w.label("Wire Width", id=221)
        for i, (label, _ww) in enumerate(WIRE_WIDTHS):
            w.button(label, id=WID_WIRE_WIDTH_BASE + i)

        # ── Tab Style ─────────────────────────────────────────────────────── #
        w.separator(id=230)
        w.label("Tab Style", id=231)
        for i, (label, _ts) in enumerate(TAB_STYLES):
            w.button(label, id=WID_TAB_STYLE_BASE + i)

    # ── Events ─────────────────────────────────────────────────────────────────

    def on_event(self, msg: dict, w: schemify.Writer) -> None:
        if msg["tag"] != schemify.TAG_BUTTON_CLICKED:
            return
        widget_id: int = msg["widget_id"]

        # Theme button
        idx = widget_id - WID_THEME_BASE
        if 0 <= idx < len(self._theme_names):
            self._apply_theme(idx, w)
            return

        # Shape preset button
        sp_idx = widget_id - WID_SHAPE_PRESET_BASE
        if 0 <= sp_idx < len(SHAPE_PRESETS):
            _label, cr = SHAPE_PRESETS[sp_idx]
            partial = {"corner_radius": cr}
            w.set_config("themes", "active_theme", json.dumps(partial))
            w.set_status(f"Shape: {_label}")
            w.request_refresh()
            return

        # Wire width button
        ww_idx = widget_id - WID_WIRE_WIDTH_BASE
        if 0 <= ww_idx < len(WIRE_WIDTHS):
            _label, ww = WIRE_WIDTHS[ww_idx]
            partial = {"wire_width": ww}
            w.set_config("themes", "active_theme", json.dumps(partial))
            w.set_status(f"Wire: {_label}")
            w.request_refresh()
            return

        # Tab style button
        ts_idx = widget_id - WID_TAB_STYLE_BASE
        if 0 <= ts_idx < len(TAB_STYLES):
            _label, ts = TAB_STYLES[ts_idx]
            partial = {"tab_shape": ts}
            w.set_config("themes", "active_theme", json.dumps(partial))
            w.set_status(f"Tab style: {_label}")
            w.request_refresh()
            return

    def _apply_theme(self, idx: int, w: schemify.Writer) -> None:
        self._current_idx = idx
        name = self._theme_names[idx]
        theme = self._themes[name]
        # Serialize the full theme object and send it to the host as config.
        # set_config(plugin_id, key, val) — plugin_id identifies which plugin
        # owns this config key so the host can namespace it.
        w.set_config("themes", "active_theme", json.dumps(theme))
        w.set_status(f"Theme: {name}")
        w.request_refresh()
        w.log_info(TAG, f"Applied theme: {name}")


# ── Plugin entry point ────────────────────────────────────────────────────────

_plugin = ThemesPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
