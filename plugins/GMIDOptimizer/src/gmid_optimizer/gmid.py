"""Python wrapper for the GmIDVisualizer C++ library.

Uses ctypes FFI to call the C-linkage API:
- gmid_characterise() -> runs ngspice sweep, returns LUT data
- gmid_free_result()  -> frees heap-allocated result

The C++ library handles all netlist generation, simulation, and data extraction.
We wrap the LUT data into scipy interpolators for fast lookup during optimization.
"""

from __future__ import annotations

import ctypes
import ctypes.util
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np
from scipy.interpolate import interp1d

# ---------------------------------------------------------------------------
# C struct mirrors (must match dep/GmId/include/gmid/lib.hpp)
# ---------------------------------------------------------------------------


class GmidLutPoint(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_double),
        ("y", ctypes.c_double),
    ]


class GmidPlotResult(ctypes.Structure):
    _fields_ = [
        ("svg_path", ctypes.c_char * 1024),
        ("title", ctypes.c_char * 128),
        ("x_label", ctypes.c_char * 64),
        ("y_label", ctypes.c_char * 64),
        ("lut", ctypes.POINTER(GmidLutPoint)),
        ("lut_len", ctypes.c_int),
    ]


class GmidCharResult(ctypes.Structure):
    _fields_ = [
        ("plots", ctypes.POINTER(GmidPlotResult)),
        ("plot_count", ctypes.c_int),
        ("error", ctypes.c_char * 512),
    ]


# ---------------------------------------------------------------------------
# Library loader
# ---------------------------------------------------------------------------

_lib: Optional[ctypes.CDLL] = None
_LIB_NAME = "libGmIDVisualizer.so"

# Search paths for the shared library
_SEARCH_PATHS = [
    Path(__file__).parent.parent / "dep" / "GmId" / "build" / _LIB_NAME,
    Path(__file__).parent.parent / "build" / _LIB_NAME,
]


def _load_lib() -> ctypes.CDLL:
    global _lib
    if _lib is not None:
        return _lib

    for path in _SEARCH_PATHS:
        if path.exists():
            _lib = ctypes.CDLL(str(path))
            _setup_prototypes(_lib)
            return _lib

    # Try system library path
    found = ctypes.util.find_library("GmIDVisualizer")
    if found:
        _lib = ctypes.CDLL(found)
        _setup_prototypes(_lib)
        return _lib

    raise RuntimeError(
        f"Cannot find {_LIB_NAME}. Build it first:\n"
        f"  cd dep/GmId && cmake -B build && cmake --build build"
    )


def _setup_prototypes(lib: ctypes.CDLL) -> None:
    lib.gmid_characterise.argtypes = [
        ctypes.c_char_p,   # model_file
        ctypes.c_char_p,   # device_name (NULL = auto-detect)
        ctypes.c_char_p,   # kind ("mosfet" or "bjt")
        ctypes.c_char_p,   # out_dir
        ctypes.c_char_p,   # work_dir (NULL = out_dir/work)
        ctypes.c_double, ctypes.c_double, ctypes.c_int,    # vgs_start, vgs_stop, vgs_steps
        ctypes.c_double, ctypes.c_double, ctypes.c_int,    # vds_start, vds_stop, vds_steps
        ctypes.c_double, ctypes.c_double, ctypes.c_double, # width_um, length_um, temp_c
    ]
    lib.gmid_characterise.restype = ctypes.POINTER(GmidCharResult)

    lib.gmid_free_result.argtypes = [ctypes.POINTER(GmidCharResult)]
    lib.gmid_free_result.restype = None


# ---------------------------------------------------------------------------
# Plot data extracted from C++ result
# ---------------------------------------------------------------------------

@dataclass
class PlotData:
    title: str
    x_label: str
    y_label: str
    svg_path: str
    x: np.ndarray
    y: np.ndarray


# ---------------------------------------------------------------------------
# Core characterization function
# ---------------------------------------------------------------------------

def characterise(
    model_file: str,
    device_name: Optional[str] = None,
    kind: str = "mosfet",
    out_dir: str = "/tmp/gmid_out",
    work_dir: Optional[str] = None,
    vgs_start: float = 0.0,
    vgs_stop: float = 1.8,
    vgs_steps: int = 181,
    vds_start: float = 0.05,
    vds_stop: float = 1.8,
    vds_steps: int = 18,
    width_um: float = 10.0,
    length_um: float = 0.18,
    temp_c: float = 27.0,
) -> list[PlotData]:
    """Run GmIDVisualizer characterization sweep via FFI.

    Returns list of 6 PlotData (mosfet) or 6 PlotData (bjt) with LUT arrays.
    """
    lib = _load_lib()

    result_ptr = lib.gmid_characterise(
        model_file.encode(),
        device_name.encode() if device_name else None,
        kind.encode(),
        out_dir.encode(),
        work_dir.encode() if work_dir else None,
        vgs_start, vgs_stop, vgs_steps,
        vds_start, vds_stop, vds_steps,
        width_um, length_um, temp_c,
    )

    if not result_ptr:
        raise RuntimeError("gmid_characterise returned NULL")

    result = result_ptr.contents
    error = result.error.decode().strip("\x00")
    if error:
        lib.gmid_free_result(result_ptr)
        raise RuntimeError(f"Characterization failed: {error}")

    plots = []
    for i in range(result.plot_count):
        p = result.plots[i]
        n = p.lut_len
        x = np.array([p.lut[j].x for j in range(n)])
        y = np.array([p.lut[j].y for j in range(n)])
        plots.append(PlotData(
            title=p.title.decode().strip("\x00"),
            x_label=p.x_label.decode().strip("\x00"),
            y_label=p.y_label.decode().strip("\x00"),
            svg_path=p.svg_path.decode().strip("\x00"),
            x=x, y=y,
        ))

    lib.gmid_free_result(result_ptr)
    return plots


# ---------------------------------------------------------------------------
# GmIdLookup: interpolation wrapper over characterization data
# ---------------------------------------------------------------------------

# Plot indices from mosfet_specs in types.hpp:
# 0: gm/Id vs current density (Jd)
# 1: gm/Id vs gm
# 2: gm/Id vs gds
# 3: gm/Id vs intrinsic gain (gm/gds)
# 4: VGS vs gm/Id
# 5: VGS vs Id

_PLOT_GMID_VS_JD = 0
_PLOT_GMID_VS_GM = 1
_PLOT_GMID_VS_GDS = 2
_PLOT_GMID_VS_AV = 3
_PLOT_VGS_VS_GMID = 4
_PLOT_VGS_VS_ID = 5


@dataclass
class GmIdLookup:
    """Interpolation-based Gm/Id lookup built from GmIDVisualizer output.

    Given a gm/Id target, look up:
    - Vgs: gate voltage needed
    - Id/W: current density (A/um)
    - gm/gds: intrinsic gain
    """
    model: str
    L: float  # meters

    _plots: list[PlotData] = field(default_factory=list, repr=False)
    _gmid_to_jd: Optional[interp1d] = field(default=None, repr=False)
    _gmid_to_vgs: Optional[interp1d] = field(default=None, repr=False)
    _gmid_to_av: Optional[interp1d] = field(default=None, repr=False)
    _gmid_to_gm: Optional[interp1d] = field(default=None, repr=False)
    _gmid_to_gds: Optional[interp1d] = field(default=None, repr=False)
    _gmid_range: tuple[float, float] = field(default=(3.0, 25.0), repr=False)

    def build_from_plots(self, plots: list[PlotData]) -> None:
        """Build interpolation tables from characterization PlotData."""
        self._plots = plots

        # gm/Id vs Jd (plot 0): x=gmid, y=jd
        p0 = plots[_PLOT_GMID_VS_JD]
        gmid, jd = _clean_for_interp(p0.x, p0.y)
        self._gmid_to_jd = interp1d(gmid, jd, kind="cubic", fill_value="extrapolate")

        # gm/Id vs gm (plot 1)
        p1 = plots[_PLOT_GMID_VS_GM]
        gmid_gm, gm = _clean_for_interp(p1.x, p1.y)
        self._gmid_to_gm = interp1d(gmid_gm, gm, kind="cubic", fill_value="extrapolate")

        # gm/Id vs gds (plot 2)
        p2 = plots[_PLOT_GMID_VS_GDS]
        gmid_gds, gds = _clean_for_interp(p2.x, p2.y)
        self._gmid_to_gds = interp1d(gmid_gds, gds, kind="cubic", fill_value="extrapolate")

        # gm/Id vs intrinsic gain (plot 3)
        p3 = plots[_PLOT_GMID_VS_AV]
        gmid_av, av = _clean_for_interp(p3.x, p3.y)
        self._gmid_to_av = interp1d(gmid_av, av, kind="cubic", fill_value="extrapolate")

        # VGS vs gm/Id (plot 4): x=vgs, y=gmid -> invert to gmid->vgs
        p4 = plots[_PLOT_VGS_VS_GMID]
        gmid_vgs, vgs = _clean_for_interp(p4.y, p4.x)  # swap x/y to get gmid->vgs
        self._gmid_to_vgs = interp1d(gmid_vgs, vgs, kind="cubic", fill_value="extrapolate")

        # Range from the Jd plot (most reliable)
        self._gmid_range = (float(gmid[0]), float(gmid[-1]))

    def lookup_vgs(self, gmid: float) -> float:
        if self._gmid_to_vgs is None:
            raise RuntimeError("Lookup not built. Call build_from_plots() first.")
        return float(self._gmid_to_vgs(np.clip(gmid, *self._gmid_range)))

    def lookup_jd(self, gmid: float) -> float:
        """Return current density Jd (A/um) for given gm/Id."""
        if self._gmid_to_jd is None:
            raise RuntimeError("Lookup not built. Call build_from_plots() first.")
        return float(self._gmid_to_jd(np.clip(gmid, *self._gmid_range)))

    def lookup_id_w(self, gmid: float) -> float:
        """Return Id per unit width (A/um) for given gm/Id. Same as lookup_jd."""
        return self.lookup_jd(gmid)

    def lookup_intrinsic_gain(self, gmid: float) -> float:
        """Return gm/gds (intrinsic gain) for given gm/Id."""
        if self._gmid_to_av is None:
            raise RuntimeError("Lookup not built. Call build_from_plots() first.")
        return float(self._gmid_to_av(np.clip(gmid, *self._gmid_range)))

    def compute_w(self, gmid: float, id_target: float) -> float:
        """Compute W (um) given gm/Id ratio and target drain current.

        W = Id_target / Jd(gmid)   where Jd is in A/um
        """
        jd = self.lookup_jd(gmid)
        if abs(jd) < 1e-30:
            return 1.0  # fallback 1um
        return abs(id_target / jd)

    @property
    def gmid_range(self) -> tuple[float, float]:
        return self._gmid_range

    def save(self, path: Path) -> None:
        """Save plot LUT data to .npz for fast reload without re-simulation."""
        save_dict = {}
        for i, p in enumerate(self._plots):
            save_dict[f"p{i}_x"] = p.x
            save_dict[f"p{i}_y"] = p.y
            save_dict[f"p{i}_title"] = np.array([p.title], dtype=object)
            save_dict[f"p{i}_x_label"] = np.array([p.x_label], dtype=object)
            save_dict[f"p{i}_y_label"] = np.array([p.y_label], dtype=object)
        save_dict["n_plots"] = np.array([len(self._plots)])
        np.savez(path, **save_dict)

    def load(self, path: Path) -> None:
        """Load plot LUT data from .npz and rebuild interpolators."""
        data = np.load(path, allow_pickle=True)
        n = int(data["n_plots"][0])
        plots = []
        for i in range(n):
            plots.append(PlotData(
                title=str(data[f"p{i}_title"][0]),
                x_label=str(data[f"p{i}_x_label"][0]),
                y_label=str(data[f"p{i}_y_label"][0]),
                svg_path="",
                x=data[f"p{i}_x"],
                y=data[f"p{i}_y"],
            ))
        self.build_from_plots(plots)


def _clean_for_interp(
    x: np.ndarray, y: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """Sort by x, remove duplicates, ensure monotonic for interpolation."""
    sort_idx = np.argsort(x)
    x_sorted = x[sort_idx]
    y_sorted = y[sort_idx]

    # Remove duplicate x values
    unique_mask = np.diff(x_sorted, prepend=-np.inf) > 0
    return x_sorted[unique_mask], y_sorted[unique_mask]
