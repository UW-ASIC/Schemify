"""Manhattan wire router for ngspice -> schematic conversion.

Pin offsets (relative to instance x,y):
  res/capa/ind/diode/vsource/isource:  p=(0,-30)  n=(0,+30)
  nmos4:  d=(+20,-30)  g=(-20,0)  s=(+20,+30)  b=(+20,0)
  pmos4:  d=(+20,+30)  g=(-20,0)  s=(+20,-30)  b=(+20,0)
  npn:    c=(+20,-30)  b=(-20,0)  e=(+20,+30)
  pnp:    c=(+20,+30)  b=(-20,0)  e=(+20,-30)
  njfet:  d=(+20,-30)  g=(-20,0)  s=(+20,+30)
  pjfet:  d=(+20,+30)  g=(-20,0)  s=(+20,-30)
  vdd:    vdd=(0,+10)
  gnd:    gnd=(0,-10)
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from enum import Enum
from typing import Optional

from .layout import PlacedElement, is_gnd_net, is_vdd_net
from .parser import Element


@dataclass
class RouteWire:
    x0: int
    y0: int
    x1: int
    y1: int
    net_name: Optional[str] = None


class PowerKind(Enum):
    VDD = "vdd"
    GND = "gnd"


@dataclass
class PowerSym:
    kind: PowerKind
    x: int
    y: int


@dataclass
class RouteResult:
    wires: list[RouteWire]
    power: list[PowerSym]


@dataclass
class ConnEntry:
    pin: str
    net: str


# Pin offset tables
@dataclass
class PinOff:
    name: str
    dx: int
    dy: int


TWO_TERM = [PinOff("p", 0, -30), PinOff("n", 0, 30)]

NMOS_PINS = [
    PinOff("d", 20, -30),
    PinOff("g", -20, 0),
    PinOff("s", 20, 30),
    PinOff("b", 20, 0),
]

PMOS_PINS = [
    PinOff("d", 20, 30),
    PinOff("g", -20, 0),
    PinOff("s", 20, -30),
    PinOff("b", 20, 0),
]

NPN_PINS = [PinOff("c", 20, -30), PinOff("b", -20, 0), PinOff("e", 20, 30)]

PNP_PINS = [PinOff("c", 20, 30), PinOff("b", -20, 0), PinOff("e", 20, -30)]

JFET_N_PINS = [PinOff("d", 20, -30), PinOff("g", -20, 0), PinOff("s", 20, 30)]

JFET_P_PINS = [PinOff("d", 20, 30), PinOff("g", -20, 0), PinOff("s", 20, -30)]


def _pin_offsets(sym_name: str) -> list[PinOff]:
    table = {
        "nmos4": NMOS_PINS,
        "pmos4": PMOS_PINS,
        "npn": NPN_PINS,
        "pnp": PNP_PINS,
        "njfet": JFET_N_PINS,
        "pjfet": JFET_P_PINS,
    }
    return table.get(sym_name, TWO_TERM)


def pin_pos(p: PlacedElement, node_idx: int) -> Optional[tuple[int, int]]:
    """Absolute pin position from placed element + node index."""
    offs = _pin_offsets(p.sym.sym)
    if node_idx >= len(offs):
        return None
    return (p.x + offs[node_idx].dx, p.y + offs[node_idx].dy)


def build_conns(elem: Element, sym_name: str) -> list[ConnEntry]:
    """Build conn list mapping symbol pin names to net names."""
    offs = _pin_offsets(sym_name)
    count = min(len(elem.nodes), len(offs))
    return [ConnEntry(pin=offs[i].name, net=elem.nodes[i]) for i in range(count)]


def route(
    elements: list[Element], placed: list[PlacedElement]
) -> RouteResult:
    """Route all nets from placed element list."""
    # Build net -> [(elem_idx, node_idx)] map
    net_pins: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for ei, elem in enumerate(elements):
        for ni, node in enumerate(elem.nodes):
            net_pins[node].append((ei, ni))

    wires: list[RouteWire] = []
    power: list[PowerSym] = []

    for net, pins in net_pins.items():
        if is_gnd_net(net):
            for ei, ni in pins:
                pos = pin_pos(placed[ei], ni)
                if pos:
                    power.append(PowerSym(kind=PowerKind.GND, x=pos[0], y=pos[1] + 10))
            continue

        if is_vdd_net(net):
            for ei, ni in pins:
                pos = pin_pos(placed[ei], ni)
                if pos:
                    power.append(PowerSym(kind=PowerKind.VDD, x=pos[0], y=pos[1] - 10))
            continue

        # Collect pin positions for this net
        pts: list[tuple[int, int]] = []
        for ei, ni in pins:
            pos = pin_pos(placed[ei], ni)
            if pos:
                pts.append(pos)

        if len(pts) < 2:
            continue

        for i in range(1, len(pts)):
            _route_segment(wires, pts[i - 1], pts[i], net)

    return RouteResult(wires=wires, power=power)


def _route_segment(
    wires: list[RouteWire],
    p1: tuple[int, int],
    p2: tuple[int, int],
    net: str,
) -> None:
    """Emit one L-shaped wire from p1 to p2 (horizontal first, then vertical)."""
    if p1 == p2:
        return

    if p1[0] == p2[0] or p1[1] == p2[1]:
        wires.append(RouteWire(x0=p1[0], y0=p1[1], x1=p2[0], y1=p2[1], net_name=net))
        return

    # L-shape: horizontal then vertical
    elbow = (p2[0], p1[1])
    wires.append(RouteWire(x0=p1[0], y0=p1[1], x1=elbow[0], y1=elbow[1], net_name=net))
    wires.append(RouteWire(x0=elbow[0], y0=elbow[1], x1=p2[0], y1=p2[1], net_name=net))
