"""PDK definitions, registry, and built-in process kits."""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class PDK:
    """Process Design Kit descriptor.

    Holds device model names, electrical parameters, and model library paths
    for a single PDK. Users can create custom instances or extend built-ins.
    """

    name: str
    display: str
    volare_family: str | None  # None → not managed by volare
    vdd: float  # supply voltage (V)
    l_min: float  # minimum channel length (m)
    nfet: str  # default NMOS model name
    pfet: str  # default PMOS model name
    model_lib: str  # relative path from PDK root to model library
    corner: str = "tt"
    corners: list[str] = field(default_factory=lambda: ["tt"])
    discrete_lengths: list[float] = field(default_factory=list)
    max_finger_w: float = 5e-6
    device_map: dict[str, str] = field(default_factory=dict)
    device_prefix: str = "X"  # "X" for subcircuit-wrapped, "M" for raw MOSFET
    spice_preamble: str = ""  # extra .param lines needed before .lib
    root: Path | None = None

    def model_path(self) -> Path | None:
        """Absolute path to model library, or None if root unset."""
        if self.root:
            return self.root / self.model_lib
        return None

    def snap_length(self, length: float) -> float:
        """Snap a channel length to nearest discrete grid value."""
        if not self.discrete_lengths:
            return length
        return min(self.discrete_lengths, key=lambda x: abs(x - length))

    def device(self, generic: str) -> str:
        """Look up PDK-specific model name from generic key.

        Falls back to generic string if no mapping exists.
        """
        return self.device_map.get(generic, generic)

    def with_root(self, root: Path | str) -> PDK:
        """Return a copy with PDK root directory set."""
        new = copy.copy(self)
        new.root = Path(root)
        return new

    def ngspice_lib_directive(self) -> str:
        """Return .lib directive (with preamble) for ngspice simulation."""
        path = self.model_path()
        if path is None:
            raise RuntimeError(f"PDK root not set for {self.name}")
        parts = []
        if self.spice_preamble:
            parts.append(self.spice_preamble)
        parts.append(f'.lib "{path}" {self.corner}')
        return "\n".join(parts)


# ---------------------------------------------------------------------------
# Built-in PDK definitions
# ---------------------------------------------------------------------------

SKY130 = PDK(
    name="sky130A",
    display="SkyWater 130nm",
    volare_family="sky130",
    vdd=1.8,
    l_min=0.15e-6,
    nfet="sky130_fd_pr__nfet_01v8",
    pfet="sky130_fd_pr__pfet_01v8",
    model_lib="libs.tech/ngspice/sky130.lib.spice",
    corner="tt",
    corners=["tt", "ff", "ss", "sf", "fs"],
    discrete_lengths=[
        0.15e-6, 0.18e-6, 0.25e-6, 0.5e-6,
        1e-6, 2e-6, 4e-6, 8e-6,
    ],
    max_finger_w=5e-6,
    device_map={
        "nfet": "sky130_fd_pr__nfet_01v8",
        "pfet": "sky130_fd_pr__pfet_01v8",
        "nfet_lvt": "sky130_fd_pr__nfet_01v8_lvt",
        "pfet_lvt": "sky130_fd_pr__pfet_01v8_lvt",
        "nfet_hvt": "sky130_fd_pr__nfet_01v8_hvt",
        "pfet_hvt": "sky130_fd_pr__pfet_01v8_hvt",
    },
)

IHP_SG13G2 = PDK(
    name="ihp-sg13g2",
    display="IHP 130nm SiGe BiCMOS",
    volare_family=None,
    vdd=1.2,
    l_min=0.13e-6,
    nfet="sg13_lv_nmos",
    pfet="sg13_lv_pmos",
    model_lib="libs.tech/ngspice/sg13g2_moslv.lib",
    corner="typ",
    corners=["typ", "fast", "slow"],
    discrete_lengths=[
        0.13e-6, 0.15e-6, 0.18e-6, 0.25e-6,
        0.5e-6, 1e-6, 2e-6,
    ],
    max_finger_w=10e-6,
    device_map={
        "nfet": "sg13_lv_nmos",
        "pfet": "sg13_lv_pmos",
        "nfet_hv": "sg13_hv_nmos",
        "pfet_hv": "sg13_hv_pmos",
    },
)

GF180MCU = PDK(
    name="gf180mcuA",
    display="GlobalFoundries 180nm MCU",
    volare_family="gf180mcu",
    vdd=3.3,
    l_min=0.28e-6,
    nfet="nfet_03v3",
    pfet="pfet_03v3",
    model_lib="libs.tech/ngspice/sm141064.ngspice",
    corner="typical",
    corners=["typical", "fast", "slow"],
    spice_preamble=".param fnoicor=0\n.param sw_stat_mismatch=0",
    discrete_lengths=[
        0.28e-6, 0.30e-6, 0.35e-6, 0.5e-6,
        1e-6, 2e-6, 4e-6, 8e-6, 10e-6,
    ],
    max_finger_w=10e-6,
    device_map={
        "nfet": "nfet_03v3",
        "pfet": "pfet_03v3",
        "nfet_hv": "nfet_05v0",
        "pfet_hv": "pfet_05v0",
    },
)


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

_REGISTRY: dict[str, PDK] = {}


def register_pdk(pdk: PDK) -> None:
    """Register a PDK (built-in or user-defined)."""
    _REGISTRY[pdk.name] = pdk


def get_pdk(name: str) -> PDK:
    """Retrieve a registered PDK by name."""
    if name not in _REGISTRY:
        available = ", ".join(_REGISTRY) or "(none)"
        raise KeyError(f"Unknown PDK: {name!r}. Available: {available}")
    return copy.copy(_REGISTRY[name])


def list_pdks() -> list[str]:
    """List registered PDK names."""
    return list(_REGISTRY)


# Auto-register built-ins
for _pdk in (SKY130, IHP_SG13G2, GF180MCU):
    register_pdk(_pdk)
