"""Schemify Themes plugin with built-in and user theme switching."""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Iterable
from typing import Any

# SDK path resolution
_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_PYTHON_DIR = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "sdk", "bindings", "python")
)
if _SDK_PYTHON_DIR not in sys.path:
    sys.path.insert(0, _SDK_PYTHON_DIR)

import schemify  # noqa: E402

PANEL_ID = "themes"
PANEL_TITLE = "Themes"
TAG = "Themes"

# Widget ID ranges:
#   0-9      : header/labels
#   10-209   : theme buttons (up to 200 themes)
#   210-219  : Shape Preset buttons
#   220-229  : Wire Width buttons
#   230-239  : Tab Style buttons
WID_THEME_BASE = 10
WID_SHAPE_PRESET_BASE = 210
WID_WIRE_WIDTH_BASE = 220
WID_TAB_STYLE_BASE = 230

THEME_CONFIG_PLUGIN_ID = "themes"
THEME_CONFIG_KEY = "active_theme"
USER_THEME_HINT = "~/.config/Schemify/themes/"
EMPTY_THEME_NAME = "-"

CATEGORY_ORDER = ("Sharp", "Balanced", "Rounded", "Pill")

# Shape preset definitions: (label, corner_radius)
SHAPE_PRESETS = [
    ("Sharp", 0.0),
    ("Balanced", 4.0),
    ("Rounded", 8.0),
    ("Pill", 16.0),
]

# Wire width preset definitions: (label, wire_width)
WIRE_WIDTHS = [
    ("Thin (1px)", 1.0),
    ("Normal (1.5px)", 1.0),  # multiplier 1.0 = default 1.5px base
    ("Thick (2.5px)", 1.4),
    ("Bold (3px)", 1.8),
]

# Tab style definitions: (label, tab_shape)
TAB_STYLES = [
    ("Rect [0]", 0),
    ("Rounded [1]", 1),
    ("Arrow [2]", 2),
    ("Angled [3]", 3),
    ("Underline [4]", 4),
]

# Bundled themes directory.
_BUNDLED_THEMES_DIR_INSTALLED = os.path.join(_PLUGIN_SRC_DIR, "themes")
_BUNDLED_THEMES_DIR_DEV = os.path.normpath(os.path.join(_PLUGIN_SRC_DIR, "..", "themes"))
_BUNDLED_THEMES_DIR = (
    _BUNDLED_THEMES_DIR_INSTALLED
    if os.path.isdir(_BUNDLED_THEMES_DIR_INSTALLED)
    else _BUNDLED_THEMES_DIR_DEV
)

# User themes directory
_USER_THEMES_DIR = os.path.join(
    os.environ.get("HOME", os.path.expanduser("~")),
    ".config",
    "Schemify",
    "themes",
)


def _iter_theme_paths(directory: str) -> Iterable[str]:
    """Yield theme file paths in deterministic filename order."""
    try:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except OSError:
        return ()
    return (
        entry.path
        for entry in entries
        if entry.is_file() and entry.name.endswith(".json")
    )


def _read_theme_file(path: str) -> tuple[str, dict[str, Any]] | None:
    """Return (theme_name, theme_json) or None when invalid."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    name = data.get("name")
    if not isinstance(name, str) or not name:
        return None
    return name, data


def _load_all_themes() -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Load bundled themes then user themes. User themes override bundled ones."""
    themes: dict[str, dict[str, Any]] = {}
    for directory in (_BUNDLED_THEMES_DIR, _USER_THEMES_DIR):
        for path in _iter_theme_paths(directory):
            parsed = _read_theme_file(path)
            if parsed is None:
                continue
            name, theme = parsed
            themes[name] = theme
    return themes, list(themes)


def _corner_category(theme: dict[str, Any]) -> str:
    """Return the display category string for a theme based on corner_radius."""
    corner_radius = theme.get("corner_radius", 4.0)
    if corner_radius <= 2:
        return "Sharp"
    if corner_radius <= 6:
        return "Balanced"
    if corner_radius <= 12:
        return "Rounded"
    return "Pill"


def _button_index(widget_id: int, base: int, size: int) -> int | None:
    """Return button index when widget_id is inside [base, base + size)."""
    idx = widget_id - base
    return idx if 0 <= idx < size else None


class ThemesPlugin(schemify.Plugin):
    """Built-in and user-defined theme switcher."""

    def __init__(self) -> None:
        self._themes: dict[str, dict[str, Any]] = {}
        self._theme_names: list[str] = []
        self._current_idx = 0

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

    def _set_active_theme(self, payload: dict[str, Any], status: str, w: schemify.Writer) -> None:
        w.set_config(THEME_CONFIG_PLUGIN_ID, THEME_CONFIG_KEY, json.dumps(payload))
        w.set_status(status)
        w.request_refresh()

    def _theme_entries_by_category(self) -> dict[str, list[tuple[int, str]]]:
        grouped: dict[str, list[tuple[int, str]]] = {name: [] for name in CATEGORY_ORDER}
        for idx, name in enumerate(self._theme_names):
            category = _corner_category(self._themes[name])
            grouped.setdefault(category, []).append((idx, name))
        return grouped

    def on_draw(self, panel_id: int, w: schemify.Writer) -> None:
        w.label("Themes", id=0)
        w.separator(id=1)

        if not self._theme_names:
            w.label("No themes found.", id=2)
            w.label("Add .json files to:", id=3)
            w.label(_USER_THEMES_DIR, id=4)
        else:
            current_name = self._theme_names[self._current_idx] if self._theme_names else EMPTY_THEME_NAME
            w.label(f"Active: {current_name}", id=5)
            w.separator(id=6)

            widget_id = WID_THEME_BASE
            for category_name, entries in self._theme_entries_by_category().items():
                if not entries:
                    continue
                w.label(f"-- {category_name} --", id=widget_id)
                widget_id += 1
                for idx, name in entries:
                    theme = self._themes[name]
                    dark_tag = " (dark)" if theme.get("dark", True) else " (light)"
                    marker = "> " if idx == self._current_idx else "  "
                    w.button(f"{marker}{name}{dark_tag}", id=WID_THEME_BASE + idx)

        w.separator(id=207)
        w.label(f"User themes: {USER_THEME_HINT}", id=208)
        w.label("Add .json files and reload plugin.", id=209)

        w.separator(id=210)
        w.label("Shape Presets", id=211)
        for idx, (label, _corner_radius) in enumerate(SHAPE_PRESETS):
            w.button(label, id=WID_SHAPE_PRESET_BASE + idx)

        w.separator(id=220)
        w.label("Wire Width", id=221)
        for idx, (label, _wire_width) in enumerate(WIRE_WIDTHS):
            w.button(label, id=WID_WIRE_WIDTH_BASE + idx)

        w.separator(id=230)
        w.label("Tab Style", id=231)
        for idx, (label, _tab_shape) in enumerate(TAB_STYLES):
            w.button(label, id=WID_TAB_STYLE_BASE + idx)

    def on_event(self, msg: dict, w: schemify.Writer) -> None:
        if msg.get("tag") != schemify.TAG_BUTTON_CLICKED:
            return

        widget_id = msg.get("widget_id")
        if not isinstance(widget_id, int):
            return

        theme_idx = _button_index(widget_id, WID_THEME_BASE, len(self._theme_names))
        if theme_idx is not None:
            self._apply_theme(theme_idx, w)
            return

        shape_idx = _button_index(widget_id, WID_SHAPE_PRESET_BASE, len(SHAPE_PRESETS))
        if shape_idx is not None:
            label, corner_radius = SHAPE_PRESETS[shape_idx]
            self._set_active_theme({"corner_radius": corner_radius}, f"Shape: {label}", w)
            return

        wire_idx = _button_index(widget_id, WID_WIRE_WIDTH_BASE, len(WIRE_WIDTHS))
        if wire_idx is not None:
            label, wire_width = WIRE_WIDTHS[wire_idx]
            self._set_active_theme({"wire_width": wire_width}, f"Wire: {label}", w)
            return

        tab_idx = _button_index(widget_id, WID_TAB_STYLE_BASE, len(TAB_STYLES))
        if tab_idx is not None:
            label, tab_shape = TAB_STYLES[tab_idx]
            self._set_active_theme({"tab_shape": tab_shape}, f"Tab style: {label}", w)

    def _apply_theme(self, idx: int, w: schemify.Writer) -> None:
        self._current_idx = idx
        name = self._theme_names[idx]
        self._set_active_theme(self._themes[name], f"Theme: {name}", w)
        w.log_info(TAG, f"Applied theme: {name}")


_plugin = ThemesPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
