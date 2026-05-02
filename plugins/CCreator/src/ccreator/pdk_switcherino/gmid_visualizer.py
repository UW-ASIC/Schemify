"""Python wrapper for the GmIDVisualizer C++ library (dep/GmIDVisualizer).

Uses ctypes FFI to call gmid_characterise() for high-fidelity gm/Id sweeps.
Falls back to PySpice-based characterization if the C++ library is not built.

Build the library:
  cd dep/GmIDVisualizer && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
"""

from __future__ import annotations

import ctypes
import ctypes.util
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np

from .characterize import DeviceLUT
from .pdk import PDK

# ---------------------------------------------------------------------------
# C struct mirrors (match dep/GmIDVisualizer/include/gmid/lib.hpp)
# ---------------------------------------------------------------------------


class _GmidLutPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class _GmidPlotResult(ctypes.Structure):
    _fields_ = [
        ("svg_path", ctypes.c_char * 1024),
        ("title", ctypes.c_char * 128),
        ("x_label", ctypes.c_char * 64),
        ("y_label", ctypes.c_char * 64),
        ("lut", ctypes.POINTER(_GmidLutPoint)),
        ("lut_len", ctypes.c_int),
    ]


class _GmidCharResult(ctypes.Structure):
    _fields_ = [
        ("plots", ctypes.POINTER(_GmidPlotResult)),
        ("plot_count", ctypes.c_int),
        ("error", ctypes.c_char * 512),
    ]


# ---------------------------------------------------------------------------
# Library loader
# ---------------------------------------------------------------------------

_LIB_NAME = "libGmIDVisualizer.so"
_SEARCH_PATHS = [
    Path(__file__).parent.parent / "dep" / "GmIDVisualizer" / "build" / _LIB_NAME,
    Path(__file__).parent.parent / "build" / _LIB_NAME,
]

_lib: Optional[ctypes.CDLL] = None


def _load_lib() -> Optional[ctypes.CDLL]:
    global _lib
    if _lib is not None:
        return _lib

    for path in _SEARCH_PATHS:
        if path.exists():
            _lib = ctypes.CDLL(str(path))
            _setup_prototypes(_lib)
            return _lib

    found = ctypes.util.find_library("GmIDVisualizer")
    if found:
        _lib = ctypes.CDLL(found)
        _setup_prototypes(_lib)
        return _lib

    return None


def _setup_prototypes(lib: ctypes.CDLL) -> None:
    lib.gmid_characterise.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_double, ctypes.c_double, ctypes.c_int,
        ctypes.c_double, ctypes.c_double, ctypes.c_int,
        ctypes.c_double, ctypes.c_double, ctypes.c_double,
    ]
    lib.gmid_characterise.restype = ctypes.POINTER(_GmidCharResult)
    lib.gmid_free_result.argtypes = [ctypes.POINTER(_GmidCharResult)]
    lib.gmid_free_result.restype = None


def is_available() -> bool:
    """Check if the GmIDVisualizer C++ library is built and loadable."""
    return _load_lib() is not None


# ---------------------------------------------------------------------------
# Plot indices (from types.hpp mosfet_specs)
# ---------------------------------------------------------------------------
_GMID_VS_JD = 0
_GMID_VS_GM = 1
_GMID_VS_GDS = 2
_GMID_VS_AV = 3
_VGS_VS_GMID = 4
_VGS_VS_ID = 5


@dataclass
class PlotData:
    title: str
    x_label: str
    y_label: str
    svg_path: str
    x: np.ndarray
    y: np.ndarray


def characterise_ffi(
    pdk: PDK,
    device: str,
    kind: str = "mosfet",
    L_um: float = 0.15,
    W_um: float = 10.0,
    vgs_steps: int = 181,
    vds_steps: int = 18,
    temp_c: float = 27.0,
    out_dir: str = "/tmp/gmid_out",
) -> list[PlotData]:
    """Run characterization via GmIDVisualizer C++ FFI.

    Returns 6 PlotData objects for MOSFET characterization.
    Raises RuntimeError if library not available or simulation fails.
    """
    lib = _load_lib()
    if lib is None:
        raise RuntimeError(
            f"GmIDVisualizer not built. Run:\n"
            f"  cd dep/GmIDVisualizer && cmake -B build && cmake --build build"
        )

    model_path = pdk.model_path()
    if model_path is None:
        raise RuntimeError(f"PDK root not set for {pdk.name}")

    result_ptr = lib.gmid_characterise(
        str(model_path).encode(),
        device.encode(),
        kind.encode(),
        out_dir.encode(),
        None,  # work_dir
        0.0, pdk.vdd, vgs_steps,
        0.05, pdk.vdd, vds_steps,
        W_um, L_um, temp_c,
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


def characterise_to_lut(
    pdk: PDK,
    device: str,
    kind: str,
    L_um: float,
    W_um: float = 10.0,
) -> DeviceLUT:
    """Run GmIDVisualizer FFI and convert results to DeviceLUT.

    The C++ library returns 6 plots; we extract gm/Id, Jd, Vgs, Av, gm, gds.
    """
    plots = characterise_ffi(pdk, device, kind, L_um, W_um)

    # Plot 0: gm/Id vs Jd → x=gmid, y=jd
    p_jd = plots[_GMID_VS_JD]
    # Plot 1: gm/Id vs gm → x=gmid, y=gm
    p_gm = plots[_GMID_VS_GM]
    # Plot 2: gm/Id vs gds → x=gmid, y=gds
    p_gds = plots[_GMID_VS_GDS]
    # Plot 3: gm/Id vs Av → x=gmid, y=av
    p_av = plots[_GMID_VS_AV]
    # Plot 4: VGS vs gm/Id → x=vgs, y=gmid (need to invert)
    p_vgs = plots[_VGS_VS_GMID]

    # Use the Jd plot's gmid as reference axis
    gmid = p_jd.x

    # Build Vgs lookup from plot 4 (inverted: gmid → vgs)
    from scipy.interpolate import interp1d
    vgs_interp = interp1d(p_vgs.y, p_vgs.x, kind="cubic", fill_value="extrapolate")
    vgs = vgs_interp(gmid)

    return DeviceLUT(
        device=device,
        L_um=L_um,
        gmid=gmid,
        jd=p_jd.y,
        vgs=vgs,
        av=p_av.y,
        gm=p_gm.y,
        gds=p_gds.y,
    )
