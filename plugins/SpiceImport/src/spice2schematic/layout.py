"""Topological signal-flow placer for ngspice netlists.

Algorithm:
  1. Build net-element adjacency
  2. BFS layer assignment seeded from V/I source elements
  3. Within each layer: row = visit order
  4. Convert (layer, row) to grid coordinates, snap to SNAP units
  5. Overlap nudge: shift conflicting elements down one row slot
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from spice2schematic.parser import Element, Model

# Grid constants
H_STEP = 200  # horizontal spacing between columns
V_STEP = 120  # vertical spacing between rows
SNAP = 10  # coordinate snap granularity
ORIGIN_X = 100
ORIGIN_Y = -100


@dataclass
class SymInfo:
    sym: str  # CHN sym= name (e.g. "nmos4")
    kind_str: str  # CHN kind field (e.g. "nmos")


@dataclass
class PlacedElement:
    elem: Element
    x: int
    y: int
    sym: SymInfo


def sym_info_for(elem: Element, models: list[Model]) -> SymInfo:
    """Map SPICE element to symbol + kind string."""
    p = elem.prefix

    if p == "r":
        return SymInfo("res", "resistor")
    if p == "c":
        return SymInfo("capa", "capacitor")
    if p == "l":
        return SymInfo("ind", "inductor")
    if p == "d":
        if _is_zener(elem.model, models):
            return SymInfo("zener", "zener")
        return SymInfo("diode", "diode")
    if p == "m":
        if _is_pmos(elem.model, models):
            return SymInfo("pmos4", "pmos")
        return SymInfo("nmos4", "nmos")
    if p == "q":
        if _is_pnp(elem.model, models):
            return SymInfo("pnp", "pnp")
        return SymInfo("npn", "npn")
    if p == "j":
        if _is_pjfet(elem.model, models):
            return SymInfo("pjfet", "pjfet")
        return SymInfo("njfet", "njfet")
    if p == "v":
        return SymInfo("vsource", "vsource")
    if p == "i":
        return SymInfo("isource", "isource")
    if p == "e":
        return SymInfo("vcvs", "vcvs")
    if p == "g":
        return SymInfo("vccs", "vccs")
    if p == "f":
        return SymInfo("cccs", "cccs")
    if p == "h":
        return SymInfo("ccvs", "ccvs")
    if p == "b":
        return SymInfo("vsource", "behavioral")
    if p == "x":
        return SymInfo(elem.model or "unknown", "subcircuit")

    return SymInfo("vsource", "vsource")


def is_power_net(name: str) -> bool:
    if not name:
        return False
    lo = name.lower()
    if lo == "0":
        return True
    if lo in ("gnd", "ground", "vss"):
        return True
    if lo.startswith(("vdd", "vcc", "vref")):
        return True
    return False


def is_gnd_net(name: str) -> bool:
    lo = name.lower()
    return lo in ("0", "gnd", "ground", "vss")


def is_vdd_net(name: str) -> bool:
    if len(name) < 3:
        return False
    lo = name.lower()
    return lo.startswith(("vdd", "vcc")) or lo == "vref"


def place(
    elements: list[Element], models: list[Model]
) -> list[PlacedElement]:
    """Place elements on a grid using BFS topological layout."""
    if not elements:
        return []

    # Build net -> [element index] map (skip power/ground nets)
    net_map: dict[str, list[int]] = defaultdict(list)
    for i, elem in enumerate(elements):
        for node in elem.nodes:
            if not is_power_net(node):
                net_map[node].append(i)

    # BFS layer assignment
    layers = [-1] * len(elements)
    queue: list[int] = []

    # Seed: V/I sources at layer 0
    for i, elem in enumerate(elements):
        if elem.prefix in ("v", "i"):
            layers[i] = 0
            queue.append(i)

    # Fallback: no sources -> put everything at layer 0
    if not queue:
        for i in range(len(elements)):
            layers[i] = 0
            queue.append(i)

    qi = 0
    while qi < len(queue):
        idx = queue[qi]
        qi += 1
        for node in elements[idx].nodes:
            if is_power_net(node):
                continue
            for ni in net_map.get(node, []):
                if layers[ni] < 0:
                    layers[ni] = layers[idx] + 1
                    queue.append(ni)

    # Unvisited -> assign to max_layer + 1
    max_layer = max(layers) if layers else 0
    layers = [l if l >= 0 else max_layer + 1 for l in layers]

    # Row assignment within each layer (BFS order)
    row_counters: dict[int, int] = defaultdict(int)
    rows = [0] * len(elements)
    for idx in queue:
        l = layers[idx]
        rows[idx] = row_counters[l]
        row_counters[l] += 1

    # Overlap tracking and placement
    occupied: set[tuple[int, int]] = set()
    placed: list[PlacedElement] = []

    for i, elem in enumerate(elements):
        col = layers[i]
        row = rows[i]

        while (col, row) in occupied:
            row += 1
        occupied.add((col, row))

        x = _snap(ORIGIN_X + col * H_STEP)
        y = _snap(ORIGIN_Y - row * V_STEP)

        placed.append(
            PlacedElement(
                elem=elem,
                x=x,
                y=y,
                sym=sym_info_for(elem, models),
            )
        )

    return placed


def _snap(v: int) -> int:
    return ((v + SNAP // 2) // SNAP) * SNAP


def _find_model_kind(model_name: str | None, models: list[Model]) -> str | None:
    if not model_name:
        return None
    for mod in models:
        if mod.name.lower() == model_name.lower():
            return mod.kind.lower()
    return None


def _model_name_suggests_p(model: str | None, patterns: tuple[str, ...]) -> bool:
    """Check if a PDK model name contains any of the given substrings."""
    if not model:
        return False
    lo = model.lower()
    return any(p in lo for p in patterns)


def _is_zener(model: str | None, models: list[Model]) -> bool:
    kind = _find_model_kind(model, models)
    if kind:
        return "z" in kind
    return _model_name_suggests_p(model, ("zener",))


def _is_pmos(model: str | None, models: list[Model]) -> bool:
    kind = _find_model_kind(model, models)
    if kind:
        return kind.startswith("p")
    return _model_name_suggests_p(model, ("pmos", "pfet", "pch"))


def _is_pnp(model: str | None, models: list[Model]) -> bool:
    kind = _find_model_kind(model, models)
    if kind:
        return kind == "pnp" or kind.startswith("p")
    return _model_name_suggests_p(model, ("pnp",))


def _is_pjfet(model: str | None, models: list[Model]) -> bool:
    kind = _find_model_kind(model, models)
    if kind:
        return kind.startswith("p")
    return _model_name_suggests_p(model, ("pjfet", "pjf"))
