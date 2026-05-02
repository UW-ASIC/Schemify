"""Schemify PDKSwitcherino plugin -- cross-PDK circuit remapping.

Provides an overlay panel for switching schematics between open-source PDKs
(sky130, ihp-sg13g2, gf180mcu) with gm/Id-preserving transistor resizing.

Core flow:
  1. Auto-detect source PDK from model names in the schematic
  2. Select target PDK
  3. Preview remap: model mapping table, before/after W/L/nf
  4. BLOCK apply if any model has no mapping (hard error)
  5. Apply: update instance properties via set_instance_prop()

Vim command: :pdkswitch [source] [target]
"""

from __future__ import annotations

import importlib.util as _ilu
import os
import re
import traceback
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# SDK bootstrap -- load tools/api/python/src/lib.py by path
# ---------------------------------------------------------------------------

_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_LIB = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "api", "python", "src", "lib.py")
)
_spec = _ilu.spec_from_file_location("schemify_plugin", _SDK_LIB)
schemify_plugin = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(schemify_plugin)  # type: ignore

Plugin = schemify_plugin.Plugin
Writer = schemify_plugin.Writer
Reader = schemify_plugin.Reader
Layout = schemify_plugin.Layout
_Tag = schemify_plugin._Tag

TAG = "PDKSwitcherino"

# ---------------------------------------------------------------------------
# Widget ID allocation
# ---------------------------------------------------------------------------

# Source PDK buttons: 100..109
WID_SRC_BASE = 100
# Target PDK buttons: 120..129
WID_TGT_BASE = 120
# Options
WID_CB_USE_LUT = 200
# Actions
WID_REMAP = 300
WID_APPLY = 301
WID_REFRESH = 302
WID_DETECT_VOLARE = 303
# Preview table rows: 400..599
WID_PREVIEW_BASE = 400
# Mapping table rows: 600..699
WID_MAP_BASE = 600
# Error rows: 700..799
WID_ERR_BASE = 700
# Misc labels
WID_STATUS = 900
WID_VOLARE_STATUS = 901

# ---------------------------------------------------------------------------
# PDK info (mirrors pdk.py built-ins, used for display before library loads)
# ---------------------------------------------------------------------------

BUILTIN_PDKS = [
    {"key": "sky130A", "display": "SkyWater 130nm", "vdd": 1.8, "lmin_um": 0.15},
    {"key": "ihp-sg13g2", "display": "IHP 130nm SiGe BiCMOS", "vdd": 1.2, "lmin_um": 0.13},
    {"key": "gf180mcuA", "display": "GlobalFoundries 180nm", "vdd": 3.3, "lmin_um": 0.28},
]

# All known model names -> (pdk_key, generic_name).
# Used for auto-detection of source PDK from schematic contents.
_MODEL_TO_PDK: dict[str, tuple[str, str]] = {
    # sky130
    "sky130_fd_pr__nfet_01v8": ("sky130A", "nfet"),
    "sky130_fd_pr__pfet_01v8": ("sky130A", "pfet"),
    "sky130_fd_pr__nfet_01v8_lvt": ("sky130A", "nfet_lvt"),
    "sky130_fd_pr__pfet_01v8_lvt": ("sky130A", "pfet_lvt"),
    "sky130_fd_pr__nfet_01v8_hvt": ("sky130A", "nfet_hvt"),
    "sky130_fd_pr__pfet_01v8_hvt": ("sky130A", "pfet_hvt"),
    # ihp-sg13g2
    "sg13_lv_nmos": ("ihp-sg13g2", "nfet"),
    "sg13_lv_pmos": ("ihp-sg13g2", "pfet"),
    "sg13_hv_nmos": ("ihp-sg13g2", "nfet_hv"),
    "sg13_hv_pmos": ("ihp-sg13g2", "pfet_hv"),
    # gf180mcu
    "nfet_03v3": ("gf180mcuA", "nfet"),
    "pfet_03v3": ("gf180mcuA", "pfet"),
    "nfet_05v0": ("gf180mcuA", "nfet_hv"),
    "pfet_05v0": ("gf180mcuA", "pfet_hv"),
}

# Schematic symbols that represent MOSFETs.
_MOSFET_SYMBOLS = frozenset({"nmos4", "pmos4", "nmos", "pmos"})


def _pdk_index(key: str) -> int | None:
    """Return BUILTIN_PDKS index for a given PDK key, or None."""
    for i, p in enumerate(BUILTIN_PDKS):
        if p["key"] == key:
            return i
    return None


# ---------------------------------------------------------------------------
# Data structures for remap state
# ---------------------------------------------------------------------------

@dataclass
class InstanceInfo:
    """Collected info about a single MOSFET instance in the schematic."""
    idx: int
    name: str
    symbol: str
    model: str = ""
    w: str = ""
    l: str = ""
    nf: str = ""
    # Filled after remap:
    new_model: str = ""
    new_w: str = ""
    new_l: str = ""
    new_nf: str = ""


@dataclass
class RemapPreview:
    """Full remap preview result."""
    devices: list[InstanceInfo] = field(default_factory=list)
    unmapped_models: list[str] = field(default_factory=list)
    mapping_table: list[tuple[str, str]] = field(default_factory=list)
    mode: str = "linear"  # "lut" or "linear"
    warnings: list[str] = field(default_factory=list)
    has_errors: bool = False


# ---------------------------------------------------------------------------
# State machine phases
# ---------------------------------------------------------------------------

class _Phase:
    IDLE = "idle"
    QUERYING = "querying"            # waiting for instance_data messages
    COLLECTING_PROPS = "collecting"  # waiting for instance_prop messages
    PREVIEW_READY = "preview"        # preview computed, waiting for user
    APPLYING = "applying"            # writing properties back


# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

class PDKSwitcherinoPlugin(Plugin):
    """Cross-PDK circuit remapping with gm/Id methodology."""

    def __init__(self) -> None:
        self._src_idx: int = 0
        self._tgt_idx: int = 1
        self._use_lut: bool = False
        self._luts_available: bool = False

        self._volare_available: bool = False
        self._installed_pdks: list[str] = []

        self._phase: str = _Phase.IDLE
        self._status: str = "Ready"

        # Instance collection during QUERYING / COLLECTING_PROPS
        self._instance_count: int = 0
        self._instances: dict[int, InstanceInfo] = {}
        self._pending_props: int = 0

        # Remap results
        self._preview: RemapPreview | None = None

    # ------------------------------------------------------------------
    # Override process() to handle tags the base class doesn't dispatch
    # ------------------------------------------------------------------

    def process(self, in_data: bytes) -> bytes:
        r = Reader(in_data)
        w = Writer()
        for msg in r:
            t = msg["tag"]
            if t == "load":
                self.on_load(w)
            elif t == "unload":
                self.on_unload(w)
            elif t == "tick":
                self.on_tick(msg["dt"], w)
            elif t == "draw_panel":
                self.on_draw_panel(msg["panel_id"], w)
            elif t == "button_clicked":
                self.on_button_clicked(msg["panel_id"], msg["widget_id"], w)
            elif t == "slider_changed":
                self.on_slider_changed(msg["panel_id"], msg["widget_id"], msg["val"], w)
            elif t == "checkbox_changed":
                self.on_checkbox_changed(msg["panel_id"], msg["widget_id"], msg["val"], w)
            elif t == "command":
                self.on_command(msg["cmd_tag"], msg["payload"], w)
            elif t == "state_response":
                self.on_state_response(msg["key"], msg["val"], w)
            elif t == "config_response":
                self._on_config_response(msg["key"], msg["val"], w)
            elif t == "selection_changed":
                self.on_selection_changed(msg["instance_idx"], w)
            elif t == "schematic_changed":
                self.on_schematic_changed(w)
            elif t == "schematic_snapshot":
                self._on_schematic_snapshot(
                    msg["instance_count"], msg["wire_count"], msg["net_count"], w
                )
            elif t == "instance_data":
                self.on_instance_data(msg["idx"], msg["name"], msg["symbol"], w)
            elif t == "instance_prop":
                self._on_instance_prop(msg["idx"], msg["key"], msg["val"], w)
            elif t == "hover":
                self.on_hover(
                    msg["world_x"], msg["world_y"], msg["element_type"],
                    msg["element_idx"], msg["element_name"], w
                )
            elif t == "key_event":
                self.on_key_event(msg["key"], msg["mods"], msg["action"], w)
        return w.get_bytes()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def on_load(self, w: Writer) -> None:
        w.register_panel(
            "pdk-switch", "PDK Switcher", "pdkswitch", Layout.OVERLAY, 0
        )
        w.set_status("PDKSwitcherino loaded")
        w.log(0, TAG, "PDKSwitcherino plugin loaded (ABI v7)")

        self._probe_volare(w)

    def on_unload(self, w: Writer) -> None:
        w.log(0, TAG, "PDKSwitcherino unloaded")

    # ------------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------------

    def on_draw_panel(self, panel_id: int, w: Writer) -> None:
        w.label("PDK Switcher", 1)
        w.separator(2)

        self._draw_source_section(w)
        w.separator(19)
        self._draw_target_section(w)
        w.separator(39)
        self._draw_comparison(w)
        w.separator(49)
        self._draw_options(w)
        w.separator(59)
        self._draw_mapping_table(w)
        w.separator(69)
        self._draw_actions(w)
        w.separator(79)
        self._draw_errors(w)
        self._draw_preview(w)
        w.separator(89)
        self._draw_volare_status(w)
        w.separator(99)

        w.label(f"Status: {self._status}", WID_STATUS)

    def _draw_source_section(self, w: Writer) -> None:
        w.label("Source PDK:", 10)
        w.tooltip("Auto-detected from schematic model names, or select manually.", 10)
        for i, pdk in enumerate(BUILTIN_PDKS):
            marker = "> " if i == self._src_idx else "  "
            installed = " [installed]" if pdk["key"] in self._installed_pdks else ""
            w.button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}",
                WID_SRC_BASE + i,
            )

    def _draw_target_section(self, w: Writer) -> None:
        w.label("Target PDK:", 20)
        for i, pdk in enumerate(BUILTIN_PDKS):
            if i == self._src_idx:
                continue
            marker = "> " if i == self._tgt_idx else "  "
            installed = " [installed]" if pdk["key"] in self._installed_pdks else ""
            w.button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}",
                WID_TGT_BASE + i,
            )

    def _draw_comparison(self, w: Writer) -> None:
        src = BUILTIN_PDKS[self._src_idx]
        tgt = BUILTIN_PDKS[self._tgt_idx]
        vdd_ratio = src["vdd"] / tgt["vdd"]
        lmin_ratio = tgt["lmin_um"] / src["lmin_um"]

        w.collapsible_start("PDK Comparison", True, 40)
        w.label(f"  VDD:     {src['vdd']}V  ->  {tgt['vdd']}V", 41)
        w.label(f"  L_min:   {src['lmin_um']}um  ->  {tgt['lmin_um']}um", 42)
        w.label(f"  VDD ratio:   {vdd_ratio:.2f}x", 43)
        w.label(f"  L_min ratio: {lmin_ratio:.2f}x", 44)
        w.collapsible_end(40)

    def _draw_options(self, w: Writer) -> None:
        lut_label = "Use gm/Id LUT (higher accuracy)"
        if self._use_lut and self._luts_available:
            lut_label += " -- LUTs loaded"
        elif self._use_lut:
            lut_label += " -- will use linear scaling if LUTs unavailable"
        w.checkbox(self._use_lut, lut_label, WID_CB_USE_LUT)

    def _draw_mapping_table(self, w: Writer) -> None:
        """Draw the model mapping table between source and target PDKs."""
        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]

        # Build mapping from known models
        src_generics = {}  # generic -> model_name for source PDK
        tgt_generics = {}  # generic -> model_name for target PDK
        for model, (pdk_key, generic) in _MODEL_TO_PDK.items():
            if pdk_key == src_key:
                src_generics[generic] = model
            elif pdk_key == tgt_key:
                tgt_generics[generic] = model

        if not src_generics:
            return

        w.collapsible_start("Model Mapping", True, WID_MAP_BASE)
        wid = WID_MAP_BASE + 1
        w.label(f"  {'Source (' + src_key + ')':<36s}  ->  Target ({tgt_key})", wid)
        wid += 1
        w.label("  " + "-" * 60, wid)
        wid += 1

        for generic in sorted(src_generics):
            src_model = src_generics[generic]
            if generic in tgt_generics:
                tgt_model = tgt_generics[generic]
                w.label(f"  {src_model:<36s}  ->  {tgt_model}", wid)
            else:
                w.label(f"  {src_model:<36s}  ->  ERROR: no mapping", wid)
            wid += 1

        w.collapsible_end(WID_MAP_BASE)

    def _draw_actions(self, w: Writer) -> None:
        w.begin_row(70)
        w.button("Remap Schematic", WID_REMAP)
        w.button("Refresh PDKs", WID_REFRESH)
        w.end_row(70)

    def _draw_errors(self, w: Writer) -> None:
        """Draw errors section if any models are unmapped -- blocks apply."""
        preview = self._preview
        if preview is None:
            return
        if not preview.unmapped_models:
            return

        w.separator(WID_ERR_BASE)
        w.label("ERRORS -- cannot apply remap:", WID_ERR_BASE + 1)
        wid = WID_ERR_BASE + 2
        for model in preview.unmapped_models:
            w.label(f"  [ERROR] No target mapping for: {model}", wid)
            wid += 1
        w.label(
            f"  {len(preview.unmapped_models)} unmapped model(s) -- resolve before applying.",
            wid,
        )

    def _draw_preview(self, w: Writer) -> None:
        """Draw the before/after preview table and apply button."""
        preview = self._preview
        if preview is None:
            return

        devices = preview.devices
        if not devices:
            w.label("No MOSFETs found in schematic.", WID_PREVIEW_BASE)
            return

        mode_str = "gm/Id LUT" if preview.mode == "lut" else "linear scaling"
        w.collapsible_start(
            f"Preview ({len(devices)} devices, {mode_str})", True, WID_PREVIEW_BASE
        )

        wid = WID_PREVIEW_BASE + 1
        # Header
        w.label(
            f"  {'Instance':<14s} {'Model (src)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}"
            f"  ->  {'Model (tgt)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}",
            wid,
        )
        wid += 1
        w.label("  " + "-" * 120, wid)
        wid += 1

        for dev in devices:
            # Format source side
            src_w = dev.w if dev.w else "?"
            src_l = dev.l if dev.l else "?"
            src_nf = dev.nf if dev.nf else "1"

            if dev.new_model:
                # Remap was computed
                tgt_model = dev.new_model
                tgt_w = dev.new_w if dev.new_w else "?"
                tgt_l = dev.new_l if dev.new_l else "?"
                tgt_nf = dev.new_nf if dev.new_nf else src_nf

                # Mark unmapped with ERROR
                if tgt_model == dev.model and dev.model not in _get_mapped_models(
                    BUILTIN_PDKS[self._src_idx]["key"],
                    BUILTIN_PDKS[self._tgt_idx]["key"],
                ):
                    tgt_model = f"ERROR: {dev.model}"
            else:
                tgt_model = "?"
                tgt_w = "?"
                tgt_l = "?"
                tgt_nf = "?"

            w.label(
                f"  {dev.name:<14s} {dev.model:<32s} {src_w:>8s} {src_l:>8s} {src_nf:>4s}"
                f"  ->  {tgt_model:<32s} {tgt_w:>8s} {tgt_l:>8s} {tgt_nf:>4s}",
                wid,
            )
            wid += 1

        w.collapsible_end(WID_PREVIEW_BASE)

        # Warnings
        for warn in preview.warnings:
            w.label(f"  [warn] {warn}", wid)
            wid += 1

        # Apply button -- only if no unmapped errors
        if preview.has_errors:
            w.label(
                "Apply blocked: fix unmapped model errors above.",
                WID_APPLY,
            )
        else:
            w.button(
                f"Apply Remap ({len(devices)} devices)", WID_APPLY
            )

    def _draw_volare_status(self, w: Writer) -> None:
        if self._volare_available:
            w.label(
                f"Volare: available ({len(self._installed_pdks)} PDK(s) installed)",
                WID_VOLARE_STATUS,
            )
        else:
            w.label("Volare: not found (pip install volare)", WID_VOLARE_STATUS)
            w.button("Detect Volare", WID_DETECT_VOLARE)

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_button_clicked(self, panel_id: int, widget_id: int, w: Writer) -> None:
        # Source PDK selection
        src_idx = widget_id - WID_SRC_BASE
        if 0 <= src_idx < len(BUILTIN_PDKS):
            self._src_idx = src_idx
            if self._tgt_idx == self._src_idx:
                self._tgt_idx = (self._src_idx + 1) % len(BUILTIN_PDKS)
            self._preview = None
            self._phase = _Phase.IDLE
            w.request_refresh()
            return

        # Target PDK selection
        tgt_idx = widget_id - WID_TGT_BASE
        if 0 <= tgt_idx < len(BUILTIN_PDKS):
            if tgt_idx != self._src_idx:
                self._tgt_idx = tgt_idx
                self._preview = None
                self._phase = _Phase.IDLE
            w.request_refresh()
            return

        if widget_id == WID_REMAP:
            self._start_remap(w)
            return

        if widget_id == WID_APPLY:
            self._apply_remap(w)
            return

        if widget_id == WID_REFRESH:
            self._refresh_pdks(w)
            w.request_refresh()
            return

        if widget_id == WID_DETECT_VOLARE:
            self._probe_volare(w)
            w.request_refresh()
            return

    def on_checkbox_changed(self, panel_id: int, widget_id: int, val: bool, w: Writer) -> None:
        if widget_id == WID_CB_USE_LUT:
            self._use_lut = val
            # Invalidate preview since remap mode changed
            if self._preview is not None:
                self._preview = None
                self._phase = _Phase.IDLE
            w.request_refresh()

    def on_command(self, cmd_tag: str, payload: str, w: Writer) -> None:
        """Handle :pdkswitch [source] [target] vim command."""
        if cmd_tag != "pdkswitch":
            return

        parts = payload.strip().split()

        # --- Subcommands ---
        if parts and parts[0] == "list-pdks":
            lines = []
            for i, pdk in enumerate(BUILTIN_PDKS):
                installed = "[installed]" if pdk["key"] in self._installed_pdks else ""
                marker = "*" if i == self._src_idx else " "
                lines.append(f"{marker} {pdk['key']}: {pdk['display']} VDD={pdk['vdd']}V Lmin={pdk['lmin_um']}um {installed}")
            self._status = " | ".join(lines)
            w.set_status(self._status)
            w.request_refresh()
            return

        if parts and parts[0] == "add-pdk":
            arg = " ".join(parts[1:])
            add_parts = arg.split()
            if len(add_parts) < 4:
                self._status = "Usage: :pdkswitch add-pdk <key> <display> <vdd> <lmin_um>"
                w.set_status(self._status)
                w.request_refresh()
                return
            key = add_parts[0]
            display = add_parts[1]
            try:
                vdd = float(add_parts[2])
                lmin = float(add_parts[3])
            except ValueError:
                self._status = "Error: vdd and lmin_um must be numbers"
                w.set_status(self._status)
                w.request_refresh()
                return
            # Check for duplicates
            if _pdk_index(key) is not None:
                self._status = f"PDK {key} already exists"
                w.set_status(self._status)
                w.request_refresh()
                return
            BUILTIN_PDKS.append({"key": key, "display": display, "vdd": vdd, "lmin_um": lmin})
            self._status = f"Added PDK: {key} ({display}) VDD={vdd}V Lmin={lmin}um"
            w.set_status(self._status)
            w.log(0, TAG, self._status)
            w.request_refresh()
            return

        if parts and parts[0] == "auto-switch":
            if len(parts) < 2:
                self._status = "Usage: :pdkswitch auto-switch <target_pdk>"
                w.set_status(self._status)
                w.request_refresh()
                return
            self._auto_switch_all(parts[1], w)
            return

        if len(parts) >= 2:
            src_name, tgt_name = parts[0], parts[1]
            src_i = _pdk_index(src_name)
            tgt_i = _pdk_index(tgt_name)
            if src_i is None:
                self._status = f"Unknown source PDK: {src_name}"
                w.set_status(self._status)
                w.request_refresh()
                return
            if tgt_i is None:
                self._status = f"Unknown target PDK: {tgt_name}"
                w.set_status(self._status)
                w.request_refresh()
                return
            if src_i == tgt_i:
                self._status = "Source and target PDK cannot be the same"
                w.set_status(self._status)
                w.request_refresh()
                return
            self._src_idx = src_i
            self._tgt_idx = tgt_i
            self._preview = None
            self._start_remap(w)
            return

        if len(parts) == 1:
            tgt_name = parts[0]
            tgt_i = _pdk_index(tgt_name)
            if tgt_i is None:
                self._status = f"Unknown target PDK: {tgt_name}"
                w.set_status(self._status)
                w.request_refresh()
                return
            if tgt_i == self._src_idx:
                self._status = "Target cannot be the same as source"
                w.set_status(self._status)
                w.request_refresh()
                return
            self._tgt_idx = tgt_i
            self._preview = None
            self._start_remap(w)
            return

        # No args: just open panel / start remap with current selections
        self._start_remap(w)

    def on_schematic_changed(self, w: Writer) -> None:
        """Schematic changed externally -- invalidate everything."""
        self._instances.clear()
        self._preview = None
        self._phase = _Phase.IDLE
        self._status = "Schematic changed -- re-remap needed"

    def on_instance_data(self, idx: int, name: str, symbol: str, w: Writer) -> None:
        """Receive instance data from query_instances(). Collect MOSFETs."""
        if self._phase not in (_Phase.QUERYING,):
            return

        if symbol in _MOSFET_SYMBOLS:
            self._instances[idx] = InstanceInfo(idx=idx, name=name, symbol=symbol)

    def _on_schematic_snapshot(self, instance_count: int, wire_count: int,
                               net_count: int, w: Writer) -> None:
        """Received after query_instances(), before instance_data messages."""
        if self._phase == _Phase.QUERYING:
            self._instance_count = instance_count

    def _on_instance_prop(self, idx: int, key: str, val: str, w: Writer) -> None:
        """Receive property for an instance we're tracking."""
        if self._phase != _Phase.COLLECTING_PROPS:
            return

        inst = self._instances.get(idx)
        if inst is None:
            return

        if key == "model":
            inst.model = val
        elif key in ("W", "w"):
            inst.w = val
        elif key in ("L", "l"):
            inst.l = val
        elif key in ("nf", "NF", "mult"):
            inst.nf = val

        self._pending_props -= 1

        # When all properties collected, compute remap preview
        if self._pending_props <= 0:
            self._compute_preview(w)

    def _on_config_response(self, key: str, val: str, w: Writer) -> None:
        """Handle config responses (unused for now, placeholder)."""
        pass

    # ------------------------------------------------------------------
    # Remap logic
    # ------------------------------------------------------------------

    def _start_remap(self, w: Writer) -> None:
        """Begin remap: query all instances from the schematic."""
        self._instances.clear()
        self._preview = None
        self._phase = _Phase.QUERYING
        self._status = "Querying schematic instances..."
        w.query_instances()
        w.set_status(self._status)
        w.request_refresh()

    def _compute_preview(self, w: Writer) -> None:
        """Compute the full remap preview after all instance data is collected."""
        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]

        preview = RemapPreview()

        # Auto-detect source PDK from model names if instances have models
        detected_pdks: dict[str, int] = {}
        for inst in self._instances.values():
            if inst.model and inst.model in _MODEL_TO_PDK:
                pdk_key = _MODEL_TO_PDK[inst.model][0]
                detected_pdks[pdk_key] = detected_pdks.get(pdk_key, 0) + 1

        if detected_pdks:
            # Pick the most common PDK
            best_pdk = max(detected_pdks, key=detected_pdks.get)
            best_idx = _pdk_index(best_pdk)
            if best_idx is not None and best_idx != self._src_idx:
                self._src_idx = best_idx
                if self._tgt_idx == self._src_idx:
                    self._tgt_idx = (self._src_idx + 1) % len(BUILTIN_PDKS)
                src_key = BUILTIN_PDKS[self._src_idx]["key"]
                tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]
                preview.warnings.append(
                    f"Auto-detected source PDK: {src_key} "
                    f"({detected_pdks[best_pdk]} device(s))"
                )

        # Try to load the pdk_switcherino library for real remapping
        switcher = None
        try:
            from pdk_switcherino import PDKSwitcher, get_pdk, auto_root

            src_pdk = auto_root(get_pdk(src_key))
            tgt_pdk = auto_root(get_pdk(tgt_key))
            switcher = PDKSwitcher(src_pdk, tgt_pdk)

            # Try loading LUTs if requested
            if self._use_lut:
                try:
                    from pdk_switcherino import get_lut

                    src_nfet_lut = get_lut(
                        src_pdk, src_pdk.nfet, "nmos", src_pdk.l_min * 1e6
                    )
                    src_pfet_lut = get_lut(
                        src_pdk, src_pdk.pfet, "pmos", src_pdk.l_min * 1e6
                    )
                    tgt_nfet_lut = get_lut(
                        tgt_pdk, tgt_pdk.nfet, "nmos", tgt_pdk.l_min * 1e6
                    )
                    tgt_pfet_lut = get_lut(
                        tgt_pdk, tgt_pdk.pfet, "pmos", tgt_pdk.l_min * 1e6
                    )
                    switcher.load_luts(
                        src_nfet_lut, src_pfet_lut, tgt_nfet_lut, tgt_pfet_lut
                    )
                    preview.mode = "lut"
                    self._luts_available = True
                    preview.warnings.append("LUT mode: gm/Id preserving remap")
                except Exception as e:
                    preview.mode = "linear"
                    self._luts_available = False
                    preview.warnings.append(f"LUT unavailable ({e}), using linear scaling")
            else:
                preview.mode = "linear"

        except ImportError as e:
            preview.warnings.append(f"pdk_switcherino not available: {e}")
            preview.warnings.append("Using built-in linear scaling fallback")
        except Exception as e:
            preview.warnings.append(f"Switcher init failed: {e}")
            w.log(2, TAG, traceback.format_exc())

        # Build the model mapping table
        mapped_src_to_tgt = _get_mapped_models(src_key, tgt_key)

        # Build generic-name mapping for display
        src_generics: dict[str, str] = {}
        tgt_generics: dict[str, str] = {}
        for model, (pdk_key, generic) in _MODEL_TO_PDK.items():
            if pdk_key == src_key:
                src_generics[generic] = model
            elif pdk_key == tgt_key:
                tgt_generics[generic] = model

        for generic in sorted(src_generics):
            src_model = src_generics[generic]
            tgt_model = tgt_generics.get(generic, "")
            preview.mapping_table.append((src_model, tgt_model))

        # Remap each device
        seen_unmapped: set[str] = set()

        for inst in sorted(self._instances.values(), key=lambda d: d.idx):
            model = inst.model
            if not model:
                # No model property -- skip with warning
                preview.warnings.append(f"{inst.name}: no model property, skipped")
                continue

            # Check if this model is mappable
            mapped_model = mapped_src_to_tgt.get(model)

            if mapped_model is None:
                # Model has no mapping to target PDK -- ERROR
                if model not in seen_unmapped:
                    preview.unmapped_models.append(model)
                    seen_unmapped.add(model)
                preview.has_errors = True
                inst.new_model = model  # keep original to show in preview
                inst.new_w = "?"
                inst.new_l = "?"
                inst.new_nf = inst.nf or "1"
                preview.devices.append(inst)
                continue

            # Parse numeric values
            w_val = _parse_spice_value(inst.w)
            l_val = _parse_spice_value(inst.l)
            nf_val = int(inst.nf) if inst.nf and inst.nf.isdigit() else 1

            if switcher and w_val is not None and l_val is not None:
                # Use the library's remap_device
                result = switcher.remap_device(model, w_val, l_val, nf_val)
                inst.new_model = result.model
                inst.new_w = _format_spice_value(result.w)
                inst.new_l = _format_spice_value(result.l)
                inst.new_nf = str(result.nf)
                for rw in result.warnings:
                    preview.warnings.append(f"{inst.name}: {rw}")
            else:
                # Fallback: simple ratio scaling
                inst.new_model = mapped_model
                if w_val is not None and l_val is not None:
                    src_info = BUILTIN_PDKS[self._src_idx]
                    tgt_info = BUILTIN_PDKS[self._tgt_idx]
                    vdd_ratio = src_info["vdd"] / tgt_info["vdd"]
                    lmin_ratio = tgt_info["lmin_um"] / src_info["lmin_um"]
                    new_w = w_val * vdd_ratio * lmin_ratio
                    new_l = l_val * lmin_ratio
                    inst.new_w = _format_spice_value(new_w)
                    inst.new_l = _format_spice_value(new_l)
                    inst.new_nf = str(nf_val)
                else:
                    inst.new_w = inst.w
                    inst.new_l = inst.l
                    inst.new_nf = inst.nf or "1"
                    preview.warnings.append(
                        f"{inst.name}: could not parse W/L, model remapped only"
                    )

            preview.devices.append(inst)

        self._preview = preview
        self._phase = _Phase.PREVIEW_READY

        n = len(preview.devices)
        n_err = len(preview.unmapped_models)
        if n_err > 0:
            self._status = (
                f"Preview ready: {n} device(s), "
                f"{n_err} UNMAPPED model(s) -- cannot apply"
            )
        else:
            self._status = f"Preview ready: {n} device(s), {preview.mode} mode"

        w.set_status(self._status)
        w.log(0, TAG, self._status)
        w.request_refresh()

    def _apply_remap(self, w: Writer) -> None:
        """Apply the computed remap to the schematic."""
        preview = self._preview
        if preview is None:
            self._status = "No remap preview -- run Remap first"
            w.set_status(self._status)
            w.request_refresh()
            return

        # BLOCK if any unmapped models
        if preview.has_errors:
            self._status = (
                f"BLOCKED: {len(preview.unmapped_models)} unmapped model(s). "
                "Cannot apply remap with unmapped devices."
            )
            w.set_status(self._status)
            w.log(2, TAG, self._status)
            w.request_refresh()
            return

        self._phase = _Phase.APPLYING
        applied = 0

        for dev in preview.devices:
            if not dev.new_model:
                continue

            idx = dev.idx

            # Set model
            if dev.new_model != dev.model:
                w.set_instance_prop(idx, "model", dev.new_model)

            # Set W
            if dev.new_w and dev.new_w != dev.w:
                w.set_instance_prop(idx, "W", dev.new_w)

            # Set L
            if dev.new_l and dev.new_l != dev.l:
                w.set_instance_prop(idx, "L", dev.new_l)

            # Set nf
            if dev.new_nf and dev.new_nf != dev.nf:
                w.set_instance_prop(idx, "nf", dev.new_nf)

            applied += 1

        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]
        self._status = (
            f"Applied: {applied} device(s) remapped from {src_key} to {tgt_key}"
        )
        w.set_status(self._status)
        w.log(0, TAG, self._status)

        # Clear preview after applying
        self._preview = None
        self._phase = _Phase.IDLE
        w.request_refresh()

    # ------------------------------------------------------------------
    # Volare helpers
    # ------------------------------------------------------------------

    def _probe_volare(self, w: Writer) -> None:
        """Detect volare and enumerate installed PDKs."""
        try:
            from pdk_switcherino import detect_volare, installed_pdks

            self._volare_available = detect_volare() is not None
            if self._volare_available:
                self._installed_pdks = installed_pdks()
                w.log(0, TAG, f"Volare found, {len(self._installed_pdks)} PDK(s) installed")
        except Exception:
            self._volare_available = False
            self._installed_pdks = []

    def _refresh_pdks(self, w: Writer) -> None:
        """Re-scan installed PDKs via volare."""
        try:
            from pdk_switcherino import installed_pdks

            self._installed_pdks = installed_pdks()
            self._status = f"Found {len(self._installed_pdks)} installed PDK(s)"
        except Exception as e:
            self._status = f"Refresh failed: {e}"
        w.set_status(self._status)

    def _auto_switch_all(self, target_key: str, w: Writer) -> None:
        """Auto-switch all .chn files in the project to target PDK."""
        tgt_idx = _pdk_index(target_key)
        if tgt_idx is None:
            self._status = f"Unknown target PDK: {target_key}"
            w.set_status(self._status)
            return

        # Find project directory from current file
        # We need to get_state("project_dir") but for now use cwd or parent of current file
        import glob as globmod

        # Search for .chn files (NOT .chn_tb or .chn_prim - just components)
        search_dirs = ["."]
        chn_files = []
        for d in search_dirs:
            chn_files.extend(globmod.glob(os.path.join(d, "**/*.chn"), recursive=True))

        if not chn_files:
            self._status = "No .chn files found in project"
            w.set_status(self._status)
            return

        tgt_key = BUILTIN_PDKS[tgt_idx]["key"]
        total_remapped = 0
        files_processed = 0

        for chn_path in chn_files:
            try:
                with open(chn_path, "r", encoding="utf-8") as f:
                    content = f.read()

                # Find all model names in the file
                models_found = set()
                for line in content.split("\n"):
                    for model_name in _MODEL_TO_PDK:
                        if model_name in line:
                            models_found.add(model_name)

                if not models_found:
                    continue  # No known models, skip

                # Detect source PDK
                pdk_counts: dict[str, int] = {}
                for m in models_found:
                    pdk_key = _MODEL_TO_PDK[m][0]
                    pdk_counts[pdk_key] = pdk_counts.get(pdk_key, 0) + 1
                src_key = max(pdk_counts, key=pdk_counts.get)

                if src_key == tgt_key:
                    continue  # Already on target PDK

                src_idx = _pdk_index(src_key)
                if src_idx is None:
                    continue

                # Get the model mapping
                mapped = _get_mapped_models(src_key, tgt_key)

                # Also compute W/L scaling
                src_info = BUILTIN_PDKS[src_idx]
                tgt_info = BUILTIN_PDKS[tgt_idx]
                vdd_ratio = src_info["vdd"] / tgt_info["vdd"]
                lmin_ratio = tgt_info["lmin_um"] / src_info["lmin_um"]

                # Replace model names in the file content
                modified = content
                file_remapped = 0
                for src_model, tgt_model in mapped.items():
                    if src_model in modified:
                        modified = modified.replace(src_model, tgt_model)
                        file_remapped += 1

                # Try to scale W/L values in MOSFET lines
                # This is a simplified text-based approach
                new_lines = []
                for line in modified.split("\n"):
                    # Look for lines with W= and L= patterns
                    if any(tgt_model in line for tgt_model in mapped.values()):
                        line = _scale_wl_in_line(line, vdd_ratio, lmin_ratio)
                    new_lines.append(line)
                modified = "\n".join(new_lines)

                if modified != content:
                    with open(chn_path, "w", encoding="utf-8") as f:
                        f.write(modified)
                    total_remapped += file_remapped
                    files_processed += 1
                    w.log(0, TAG, f"Remapped {chn_path}: {src_key} -> {tgt_key} ({file_remapped} models)")

            except Exception as e:
                w.log(2, TAG, f"Error processing {chn_path}: {e}")

        self._status = f"Auto-switch complete: {files_processed} files, {total_remapped} models remapped to {tgt_key}"
        w.set_status(self._status)
        w.log(0, TAG, self._status)
        w.request_refresh()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_mapped_models(src_key: str, tgt_key: str) -> dict[str, str]:
    """Build source_model -> target_model map for two PDKs via generic keys.

    Returns only models that have a valid mapping. Models absent from the
    returned dict have NO mapping and must be treated as errors.
    """
    src_rev: dict[str, str] = {}  # model -> generic
    tgt_map: dict[str, str] = {}  # generic -> model

    for model, (pdk_key, generic) in _MODEL_TO_PDK.items():
        if pdk_key == src_key:
            src_rev[model] = generic
        elif pdk_key == tgt_key:
            tgt_map[generic] = model

    result: dict[str, str] = {}
    for model, generic in src_rev.items():
        if generic in tgt_map:
            result[model] = tgt_map[generic]
    return result


def _parse_spice_value(s: str) -> float | None:
    """Parse a SPICE value string like '2u', '0.15e-6', '280n' to float (SI)."""
    if not s:
        return None
    s = s.strip()
    multipliers = {
        "T": 1e12, "G": 1e9, "M": 1e6, "MEG": 1e6, "k": 1e3, "K": 1e3,
        "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15, "a": 1e-18,
    }
    # Try direct float first
    try:
        return float(s)
    except ValueError:
        pass

    # Try suffix-based
    for suffix, mult in sorted(multipliers.items(), key=lambda x: -len(x[0])):
        if s.lower().endswith(suffix.lower()):
            num_part = s[: -len(suffix)]
            try:
                return float(num_part) * mult
            except ValueError:
                continue

    # Try with trailing 'm' for meters
    if s.endswith("m"):
        try:
            return float(s[:-1]) * 1e-3
        except ValueError:
            pass

    return None


def _format_spice_value(val: float) -> str:
    """Format a float to a human-readable SPICE string with SI suffix."""
    if val == 0:
        return "0"
    abs_val = abs(val)
    if abs_val >= 1e-3:
        return f"{val:.4g}"
    elif abs_val >= 1e-6:
        return f"{val * 1e6:.3g}u"
    elif abs_val >= 1e-9:
        return f"{val * 1e9:.3g}n"
    elif abs_val >= 1e-12:
        return f"{val * 1e12:.3g}p"
    else:
        return f"{val:.4g}"


def _scale_wl_in_line(line: str, vdd_ratio: float, lmin_ratio: float) -> str:
    """Scale W= and L= values in a line using VDD and Lmin ratios."""

    def scale_match(match, scale):
        val_str = match.group(1)
        parsed = _parse_spice_value(val_str)
        if parsed is not None:
            new_val = parsed * scale
            return match.group(0).replace(val_str, _format_spice_value(new_val))
        return match.group(0)

    # Scale W values: W *= vdd_ratio * lmin_ratio
    line = re.sub(r'\bW\s*=\s*([^\s,]+)', lambda m: scale_match(m, vdd_ratio * lmin_ratio), line, flags=re.IGNORECASE)
    # Scale L values: L *= lmin_ratio
    line = re.sub(r'\bL\s*=\s*([^\s,]+)', lambda m: scale_match(m, lmin_ratio), line, flags=re.IGNORECASE)

    return line


# ---------------------------------------------------------------------------
# Module-level plugin instance + ABI entry point
# ---------------------------------------------------------------------------

_plugin = PDKSwitcherinoPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return _plugin.process(in_bytes)
