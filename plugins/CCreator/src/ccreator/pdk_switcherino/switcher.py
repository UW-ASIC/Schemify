"""PDK switcher — remap device models and sizes between PDKs.

Uses gm/Id design methodology to preserve transistor operating points:
1. Av-preserving (multi-L families): picks target L that matches source
   intrinsic gain (Av = gm/gds), then sizes W to preserve drain current.
2. Single-L gm/Id: scales L by L_min ratio, sizes W via gm/Id LUT.

Both modes require characterization LUTs and explicit bias currents.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from .pdk import PDK

if TYPE_CHECKING:
    from .characterize import DeviceLUT, DeviceLUTFamily


@dataclass
class RemapResult:
    """Result of remapping a single device."""

    model: str
    w: float
    l: float
    nf: int = 1
    gmid: float | None = None
    av_src: float | None = None
    av_tgt: float | None = None
    warnings: list[str] = field(default_factory=list)


class PDKSwitcher:
    """Remap device parameters from a source PDK to a target PDK.

    Builds a bidirectional model-name map from device_map entries.
    Requires gm/Id characterization LUTs for both source and target PDKs.
    """

    def __init__(self, source: PDK, target: PDK) -> None:
        self.source = source
        self.target = target
        self._model_map = self._build_model_map()
        self._src_luts: dict[str, DeviceLUT] = {}
        self._tgt_luts: dict[str, DeviceLUT] = {}
        self._tgt_families: dict[str, DeviceLUTFamily] = {}

    def load_luts(
        self,
        src_nfet: DeviceLUT,
        src_pfet: DeviceLUT,
        tgt_nfet: DeviceLUT,
        tgt_pfet: DeviceLUT,
    ) -> None:
        """Load gm/Id lookup tables for LUT-based remapping."""
        self._src_luts[self.source.nfet] = src_nfet
        self._src_luts[self.source.pfet] = src_pfet
        self._tgt_luts[self.target.nfet] = tgt_nfet
        self._tgt_luts[self.target.pfet] = tgt_pfet

    def load_lut_families(
        self,
        src_nfet: DeviceLUT,
        src_pfet: DeviceLUT,
        tgt_nfet_family: DeviceLUTFamily,
        tgt_pfet_family: DeviceLUTFamily,
    ) -> None:
        """Load source LUTs + target multi-L families for Av-preserving remap.

        Source LUTs are at the design's L (to extract operating point).
        Target families contain LUTs at multiple L values so we can pick the L
        that preserves intrinsic gain.
        """
        self._src_luts[self.source.nfet] = src_nfet
        self._src_luts[self.source.pfet] = src_pfet
        self._tgt_families[self.target.nfet] = tgt_nfet_family
        self._tgt_families[self.target.pfet] = tgt_pfet_family

    @property
    def has_luts(self) -> bool:
        return bool(self._src_luts and (self._tgt_luts or self._tgt_families))

    @property
    def has_families(self) -> bool:
        return bool(self._src_luts and self._tgt_families)

    def _build_model_map(self) -> dict[str, str]:
        """Map source model names → target model names via generic keys."""
        src_rev: dict[str, str] = {}
        for generic, model in self.source.device_map.items():
            src_rev[model] = generic

        mapping: dict[str, str] = {}
        for model, generic in src_rev.items():
            if generic in self.target.device_map:
                mapping[model] = self.target.device_map[generic]

        mapping.setdefault(self.source.nfet, self.target.nfet)
        mapping.setdefault(self.source.pfet, self.target.pfet)
        return mapping

    def map_model(self, model: str) -> str:
        """Map a source model name to target PDK. Returns original if unknown."""
        return self._model_map.get(model, model)

    def remap_device(
        self,
        model: str,
        w: float,
        l: float,
        nf: int = 1,
        bias_current: float = 0.0,
    ) -> RemapResult:
        """Remap a MOSFET's model, W, and L from source to target PDK.

        Two modes (in priority order):
          1. Av-preserving (multi-L families): picks target L that matches source
             intrinsic gain, then sizes W to preserve drain current at same gm/Id.
          2. Single-L gm/Id: scales L by L_min ratio, sizes W via gm/Id LUT.

        Requires characterization LUTs to be loaded. Raises if not available.

        Args:
            model: source PDK model name
            w: channel width in meters
            l: channel length in meters
            nf: number of fingers
            bias_current: drain current in Amps (required for accurate remap)
        """
        warnings: list[str] = []

        new_model = self.map_model(model)
        if new_model == model and model not in self._model_map:
            warnings.append(f"no model mapping for {model!r}, kept as-is")

        l_ratio = self.target.l_min / self.source.l_min
        src_lut = self._src_luts.get(model)
        tgt_family = self._tgt_families.get(new_model)
        tgt_lut = self._tgt_luts.get(new_model)

        if not src_lut:
            raise ValueError(
                f"No source LUT for model {model!r}. "
                f"Load characterization data with load_luts() or load_lut_families()."
            )
        if not (tgt_family or tgt_lut):
            raise ValueError(
                f"No target LUT/family for model {new_model!r}. "
                f"Load characterization data with load_luts() or load_lut_families()."
            )

        # --- Extract operating point from source LUT ---
        W_um = w * 1e6  # m → um
        jd_src = abs(bias_current) / (W_um * nf)  # A/um
        gmid_val = src_lut.lookup_gmid(jd_src)
        id_target = abs(bias_current)
        av_src = src_lut.lookup_av(gmid_val)

        av_tgt = None
        new_l = None
        new_w = None

        # --- Mode 1: Av-preserving L selection (multi-L families) ---
        if tgt_family and av_src > 0:
            best_L_um, _ = tgt_family.find_L_for_av(gmid_val, av_src)
            new_l = self.target.snap_length(best_L_um * 1e-6)

            selected_lut = tgt_family.get_lut_nearest(new_l * 1e6)
            new_W_um = selected_lut.compute_w(gmid_val, id_target)
            new_w = new_W_um * 1e-6
            av_tgt = selected_lut.lookup_av(gmid_val)

            av_err = abs(av_tgt / av_src - 1)
            if av_err > 0.3:
                warnings.append(
                    f"residual Av mismatch: {av_src:.1f} → {av_tgt:.1f} "
                    f"({av_err*100:.0f}% — best available L)"
                )

        # --- Mode 2: Single-L gm/Id remap ---
        elif tgt_lut:
            new_l = self.target.snap_length(l * l_ratio)
            new_W_um = tgt_lut.compute_w(gmid_val, id_target)
            new_w = new_W_um * 1e-6
            av_tgt = tgt_lut.lookup_av(gmid_val)

            if av_src > 0 and abs(av_tgt / av_src - 1) > 0.3:
                warnings.append(
                    f"intrinsic gain mismatch: {av_src:.1f} → {av_tgt:.1f} "
                    f"({abs(av_tgt/av_src - 1)*100:.0f}% deviation)"
                )

        # L change warnings (informational, not for Av-preserving mode)
        if not tgt_family:
            actual_l_ratio = new_l / l
            snap_err = abs(new_l - l * l_ratio) / (l * l_ratio) if l > 0 else 0
            if snap_err > 0.15:
                warnings.append(
                    f"L snap error: ideal {l*l_ratio*1e6:.3f}um → snapped {new_l*1e6:.3f}um "
                    f"({snap_err*100:.0f}% off)"
                )
            if actual_l_ratio > 1.5:
                warnings.append(
                    f"L scaled {actual_l_ratio:.1f}x ({l*1e6:.2f}um → {new_l*1e6:.2f}um) — "
                    f"expect ~{20*math.log10(actual_l_ratio):.0f}dB higher gain (lower gds)"
                )
            elif actual_l_ratio < 0.67:
                warnings.append(
                    f"L scaled {actual_l_ratio:.2f}x ({l*1e6:.2f}um → {new_l*1e6:.2f}um) — "
                    f"expect ~{-20*math.log10(actual_l_ratio):.0f}dB lower gain (higher gds)"
                )

        # Finger optimization
        new_nf = nf
        if new_w > self.target.max_finger_w:
            new_nf = math.ceil(new_w / self.target.max_finger_w)
            new_w = new_w / new_nf
            warnings.append(f"nf increased to {new_nf} (finger width limit)")

        return RemapResult(
            model=new_model,
            w=new_w,
            l=new_l,
            nf=new_nf,
            gmid=gmid_val,
            av_src=av_src,
            av_tgt=av_tgt,
            warnings=warnings,
        )

    def remap_spice_line(
        self, line: str, bias_current: float | None = None,
    ) -> str:
        """Remap a raw SPICE MOSFET instance line."""
        pattern = (
            r"^(M\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+"
            r"(\S+)"
            r"(.*)"
        )
        m = re.match(pattern, line)
        if not m:
            return line

        prefix, model, params = m.group(1), m.group(2), m.group(3)

        w_match = re.search(r"W=([0-9eE.+\-]+)", params, re.IGNORECASE)
        l_match = re.search(r"L=([0-9eE.+\-]+)", params, re.IGNORECASE)
        if not (w_match and l_match):
            return line

        w = float(w_match.group(1))
        l = float(l_match.group(1))

        result = self.remap_device(model, w, l, bias_current=bias_current)

        new_params = re.sub(
            r"W=[0-9eE.+\-]+", f"W={result.w:.4g}", params, flags=re.IGNORECASE,
        )
        new_params = re.sub(
            r"L=[0-9eE.+\-]+", f"L={result.l:.4g}", new_params, flags=re.IGNORECASE,
        )
        if result.nf > 1 and not re.search(r"nf=", new_params, re.IGNORECASE):
            new_params += f" nf={result.nf}"

        return f"{prefix} {result.model}{new_params}"

    def remap_netlist(
        self, spice: str, bias_currents: dict[str, float] | None = None,
    ) -> str:
        """Remap all MOSFET lines in a SPICE netlist string.

        bias_currents: optional dict mapping instance names (e.g. "M1") to
        drain current in Amps. Enables gm/Id-preserving remap per device.
        """
        lines = []
        for line in spice.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("M"):
                inst = stripped.split()[0]
                ic = bias_currents.get(inst) if bias_currents else None
                lines.append(self.remap_spice_line(line, bias_current=ic))
            else:
                lines.append(line)
        return "\n".join(lines)

    def summary(self) -> str:
        """Human-readable summary of the mapping."""
        if self.has_families:
            mode = "gm/Id multi-L Av-preserving"
        else:
            mode = "gm/Id single-L"
        parts = [
            f"PDK Switch: {self.source.display} → {self.target.display} ({mode})",
            f"  VDD: {self.source.vdd}V → {self.target.vdd}V",
            f"  L_min: {self.source.l_min*1e6:.2f}um → {self.target.l_min*1e6:.2f}um",
            "  Model mappings:",
        ]
        for src, tgt in self._model_map.items():
            parts.append(f"    {src} → {tgt}")
        return "\n".join(parts)
