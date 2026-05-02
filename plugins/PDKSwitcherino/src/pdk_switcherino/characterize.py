"""PDK-generic gm/Id characterization via PySpice DC sweeps.

Runs Vgs sweeps at multiple Vds bias points for a MOSFET device and extracts:
  gm/Id, current density (Jd), Vgs, intrinsic gain (Av), gm, gds

Results cached as .npz files keyed by (device, L).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.interpolate import interp1d

from .pdk import PDK

CACHE_ROOT = Path.home() / ".cache" / "pdk_switcherino" / "lut"


@dataclass
class DeviceLUT:
    """Interpolation-based gm/Id lookup for a single (device, L) pair."""

    device: str
    L_um: float
    gmid: np.ndarray
    jd: np.ndarray
    vgs: np.ndarray
    av: np.ndarray
    gm: np.ndarray
    gds: np.ndarray

    _gmid_to_jd: interp1d | None = None
    _gmid_to_vgs: interp1d | None = None
    _gmid_to_av: interp1d | None = None
    _jd_to_gmid: interp1d | None = None

    def __post_init__(self):
        self._build_interp()

    def _build_interp(self):
        gmid_s, idx = _sort_unique(self.gmid)
        self._gmid_to_jd = interp1d(gmid_s, self.jd[idx], kind="cubic", fill_value="extrapolate")
        self._gmid_to_vgs = interp1d(gmid_s, self.vgs[idx], kind="cubic", fill_value="extrapolate")
        # Av can be noisy (gm/gds ratio) — use linear interp to avoid oscillations
        self._gmid_to_av = interp1d(gmid_s, np.maximum(self.av[idx], 0.01), kind="linear", fill_value="extrapolate")
        self._range = (float(gmid_s[0]), float(gmid_s[-1]))

        # Build inverse: Jd → gm/Id (for extracting operating point from current density)
        jd_s, jd_idx = _sort_unique(self.jd)
        self._jd_to_gmid = interp1d(jd_s, self.gmid[jd_idx], kind="cubic", fill_value="extrapolate")
        self._jd_range = (float(jd_s[0]), float(jd_s[-1]))

    @property
    def gmid_range(self) -> tuple[float, float]:
        return self._range

    def lookup_jd(self, gmid: float) -> float:
        return float(self._gmid_to_jd(np.clip(gmid, *self._range)))

    def lookup_vgs(self, gmid: float) -> float:
        return float(self._gmid_to_vgs(np.clip(gmid, *self._range)))

    def lookup_av(self, gmid: float) -> float:
        val = float(self._gmid_to_av(np.clip(gmid, *self._range)))
        return max(val, 0.01)  # Av is always positive; clamp interpolation artifacts

    def lookup_gmid(self, jd: float) -> float:
        """Inverse lookup: current density (A/um) → gm/Id."""
        jd_clamped = float(np.clip(jd, *self._jd_range))
        return float(self._jd_to_gmid(jd_clamped))

    def compute_w(self, gmid: float, id_target: float) -> float:
        """Compute W (um) for target drain current at given gm/Id."""
        jd = self.lookup_jd(gmid)
        if abs(jd) < 1e-30:
            return 1.0
        return abs(id_target / jd)

    def save(self, path: Path) -> None:
        np.savez(path, gmid=self.gmid, jd=self.jd, vgs=self.vgs,
                 av=self.av, gm=self.gm, gds=self.gds)

    @classmethod
    def load(cls, path: Path, device: str, L_um: float) -> DeviceLUT:
        data = np.load(path)
        return cls(device=device, L_um=L_um, **{k: data[k] for k in
                   ("gmid", "jd", "vgs", "av", "gm", "gds")})


@dataclass
class DeviceLUTFamily:
    """Collection of DeviceLUTs at multiple channel lengths for the same device.

    Enables Av-preserving L selection: instead of blindly scaling L by L_min ratio,
    find the target L that matches the source intrinsic gain at the operating gm/Id.

    For MOSFETs, Av = gm/gds increases monotonically with L (longer channel →
    lower gds → higher output resistance). So for any (gm/Id, Av_target) pair
    there is a unique L that matches.
    """

    device: str
    luts: dict[float, DeviceLUT]  # L_um → DeviceLUT

    @property
    def L_values(self) -> list[float]:
        """Sorted list of characterized L values (um)."""
        return sorted(self.luts.keys())

    def find_L_for_av(self, gmid: float, av_target: float) -> tuple[float, float]:
        """Find the characterized L (um) whose Av best matches av_target.

        Av(L) should be monotonically increasing (longer L → lower gds → higher gain).
        Non-monotonic points are filtered as likely bad characterization data.

        Returns (L_um, actual_av_at_that_L) from the characterized L values.
        """
        L_vals = self.L_values
        if not L_vals:
            raise ValueError("No LUTs in family")

        raw = [(L, self.luts[L].lookup_av(gmid)) for L in L_vals]

        # Filter: keep only monotonically increasing Av(L)
        # Non-monotonic points indicate bad characterization data
        filtered = [raw[0]]
        for i in range(1, len(raw)):
            if raw[i][1] >= filtered[-1][1]:
                filtered.append(raw[i])

        if not filtered:
            filtered = raw

        # Pick the discrete L with Av closest to target
        best_L, best_av = min(filtered, key=lambda x: abs(x[1] - av_target))
        return best_L, best_av

    def get_lut_nearest(self, L_um: float) -> DeviceLUT:
        """Get LUT at the nearest characterized L value."""
        if not self.luts:
            raise ValueError("No LUTs in family")
        nearest = min(self.luts, key=lambda x: abs(x - L_um))
        return self.luts[nearest]


def _sort_unique(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    idx = np.argsort(x)
    xs = x[idx]
    unique = np.diff(xs, prepend=-np.inf) > 1e-10
    return xs[unique], idx[unique]


# ---------------------------------------------------------------------------
# PDK-specific ngspice include generators
# ---------------------------------------------------------------------------

def _sky130_includes(pdk: PDK, device: str, kind: str) -> str:
    """Sky130 individual model includes (faster than .lib)."""
    ngspice_dir = pdk.root / "libs.tech" / "ngspice"
    model_dir = pdk.root / "libs.ref" / "sky130_fd_pr" / "spice"

    lines = [
        f'.param mc_mm_switch=0',
        f'.param mc_pr_switch=0',
        f'.include "{ngspice_dir}/parameters/lod.spice"',
        f'.include "{ngspice_dir}/parameters/invariant.spice"',
        f'.include "{ngspice_dir}/corners/tt/nonfet.spice"',
        f'.include "{model_dir}/{device}__mismatch.corner.spice"',
    ]
    if kind == "nmos":
        lines.append(f'.include "{model_dir}/{device}__tt.pm3.spice"')
    else:
        lines.append(f'.include "{model_dir}/{device}__tt.corner.spice"')
    return "\n".join(lines)


def _build_includes(pdk: PDK, device: str, kind: str) -> str:
    if pdk.volare_family == "sky130" and pdk.root:
        model_dir = pdk.root / "libs.ref" / "sky130_fd_pr" / "spice"
        if (model_dir / f"{device}__mismatch.corner.spice").exists():
            return _sky130_includes(pdk, device, kind)
    return pdk.ngspice_lib_directive()


# ---------------------------------------------------------------------------
# PySpice DC sweep characterization
# ---------------------------------------------------------------------------

def _sweep_at_vds(
    includes: str,
    prefix: str,
    device: str,
    W_um: float,
    L_um: float,
    vds_val: float,
    vdd: float,
    vgs_step: float = 0.01,
    is_pmos: bool = False,
) -> tuple[np.ndarray, np.ndarray]:
    """Run a single Vgs sweep at a fixed Vds using PySpice.

    Returns (vgs_array, id_array) with positive Id convention.
    """
    from PySpice.Spice.Netlist import Circuit

    c = Circuit("gmid_sweep")

    if is_pmos:
        c.raw_spice = (
            f"{includes}\n"
            f"{prefix}1 d g vdd vdd {device} W={W_um}u L={L_um}u\n"
            f"Vdd_supply vdd 0 {vdd}\n"
        )
        c.V("gs", "g", c.gnd, 0)
        c.V("ds", "d", c.gnd, vdd - vds_val)
        sim = c.simulator()
        analysis = sim.dc(Vgs=slice(vdd, 0, -vgs_step))
        vgs_raw = np.array(analysis["g"])
        ids_raw = np.array(analysis.branches["vds"])
        # Flip to ascending Vgs order
        vgs = vgs_raw[::-1]
        ids = np.abs(ids_raw[::-1])
    else:
        c.raw_spice = (
            f"{includes}\n"
            f"{prefix}1 d g 0 0 {device} W={W_um}u L={L_um}u\n"
        )
        c.V("gs", "g", c.gnd, 0)
        c.V("ds", "d", c.gnd, vds_val)
        sim = c.simulator()
        analysis = sim.dc(Vgs=slice(0, vdd, vgs_step))
        vgs = np.array(analysis["g"])
        ids = -np.array(analysis.branches["vds"])

    return vgs, ids


def sweep_device(
    pdk: PDK,
    device: str,
    kind: str,
    L_um: float,
    W_um: float = 10.0,
    vgs_step: float = 0.01,
) -> dict[str, np.ndarray]:
    """Run gm/Id characterization sweep using PySpice.

    Sweeps Vgs at three Vds points (mid ± delta) to extract gm and gds.
    Returns dict with: vgs, id, gm, gds, gmid, jd, av
    """
    if pdk.root is None:
        raise RuntimeError(f"PDK root not set for {pdk.name}. Call auto_root() first.")

    includes = _build_includes(pdk, device, kind)
    prefix = pdk.device_prefix
    vdd = pdk.vdd
    is_pmos = kind == "pmos"

    vds_mid = vdd / 2
    vds_delta = 0.05
    vds_lo = vds_mid - vds_delta
    vds_hi = vds_mid + vds_delta

    sweep_kw = dict(
        includes=includes, prefix=prefix, device=device,
        W_um=W_um, L_um=L_um, vdd=vdd, vgs_step=vgs_step,
        is_pmos=is_pmos,
    )

    vgs, id_lo = _sweep_at_vds(vds_val=vds_lo, **sweep_kw)
    _, id_mid = _sweep_at_vds(vds_val=vds_mid, **sweep_kw)
    _, id_hi = _sweep_at_vds(vds_val=vds_hi, **sweep_kw)

    gm = np.abs(np.gradient(id_mid, vgs))
    gds = np.abs((id_hi - id_lo) / (2 * vds_delta))

    # Filter: require meaningful current (not subthreshold noise)
    id_floor = max(id_mid.max() * 1e-5, 1e-9)
    valid = (id_mid > id_floor) & (gm > 1e-12) & (gds > 1e-12)

    ids_v = id_mid[valid]
    gm_v = gm[valid]
    gds_v = gds[valid]

    return {
        "vgs": vgs[valid],
        "id": ids_v,
        "gm": gm_v,
        "gds": gds_v,
        "gmid": gm_v / ids_v,
        "jd": ids_v / W_um,
        "av": gm_v / gds_v,
    }


# ---------------------------------------------------------------------------
# LUT cache management
# ---------------------------------------------------------------------------

def _cache_path(pdk: PDK, device: str, L_um: float) -> Path:
    return CACHE_ROOT / pdk.name / f"{device}_L{L_um:.2f}u.npz"


def get_lut(
    pdk: PDK,
    device: str,
    kind: str,
    L_um: float,
    force: bool = False,
    extra_cache_dirs: list[Path] | None = None,
) -> DeviceLUT:
    """Get or generate a gm/Id lookup table for a device.

    Checks cache first. If not cached, runs PySpice characterization.
    extra_cache_dirs: additional directories to search for cached LUTs
    (e.g. GMIDOptimizer's example cache).
    """
    cache = _cache_path(pdk, device, L_um)

    if not force and cache.exists():
        return DeviceLUT.load(cache, device, L_um)

    if extra_cache_dirs:
        for d in extra_cache_dirs:
            candidate = d / f"{device}_L{L_um:.2f}u.npz"
            if candidate.exists():
                return DeviceLUT.load(candidate, device, L_um)

    # Try GmIDVisualizer C++ FFI first (higher fidelity), fall back to PySpice
    try:
        from .gmid_visualizer import characterise_to_lut, is_available
        if is_available():
            lut = characterise_to_lut(pdk, device, kind, L_um)
            cache.parent.mkdir(parents=True, exist_ok=True)
            lut.save(cache)
            return lut
    except Exception:
        pass

    # PySpice fallback
    data = sweep_device(pdk, device, kind, L_um)
    lut = DeviceLUT(
        device=device, L_um=L_um,
        gmid=data["gmid"], jd=data["jd"], vgs=data["vgs"],
        av=data["av"], gm=data["gm"], gds=data["gds"],
    )

    cache.parent.mkdir(parents=True, exist_ok=True)
    lut.save(cache)

    return lut
