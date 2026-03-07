"""CircuitGraph — the bridge data model between the AI pipeline and Schemify.

Every pipeline run produces a CircuitGraph, serializable to/from JSON.
The Zig editor reads this JSON to create unplaced components with enforced
connectivity constraints.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Optional


# ── Enumerations ──────────────────────────────────────────────────────────── #


class Style(str, Enum):
    HANDDRAWN = "handdrawn"
    TEXTBOOK = "textbook"
    DATASHEET = "datasheet"
    UNKNOWN = "unknown"


class CrossingConvention(str, Enum):
    DOT_MEANS_CONNECTED = "dot_means_connected"
    ALWAYS_BRIDGED = "always_bridged"
    AMBIGUOUS = "ambiguous"


class WarningType(str, Enum):
    AMBIGUOUS_CROSSING = "ambiguous_crossing"
    LOW_CONFIDENCE_DETECTION = "low_confidence_detection"
    OCR_UNCERTAIN = "ocr_uncertain"
    UNCONNECTED_PIN = "unconnected_pin"
    DUPLICATE_REF = "duplicate_ref"
    MOSFET_TERMINAL_AMBIGUOUS = "mosfet_terminal_ambiguous"


class ComponentType(str, Enum):
    # Passive
    RESISTOR = "resistor"
    CAPACITOR = "capacitor"
    INDUCTOR = "inductor"
    POTENTIOMETER = "potentiometer"
    FUSE = "fuse"

    # Semiconductor
    DIODE = "diode"
    LED = "led"
    ZENER = "zener"
    SCHOTTKY = "schottky"
    NPN = "npn"
    PNP = "pnp"

    # MOSFET
    NMOS = "nmos"
    NMOS4 = "nmos4"
    PMOS = "pmos"
    PMOS4 = "pmos4"

    # Sources
    VOLTAGE_SOURCE = "voltage_source"
    CURRENT_SOURCE = "current_source"
    DEPENDENT_VOLTAGE_SOURCE = "dependent_voltage_source"
    DEPENDENT_CURRENT_SOURCE = "dependent_current_source"

    # Power / Ground
    GROUND = "ground"
    VDD = "vdd"
    VSS = "vss"
    VCC = "vcc"

    # IC-level
    OPAMP = "opamp"
    COMPARATOR = "comparator"
    IC_BLOCK = "ic_block"
    LOGIC_GATE = "logic_gate"

    # Connections / Annotations
    JUNCTION_DOT = "junction_dot"
    CROSSING_BRIDGE = "crossing_bridge"
    OFF_PAGE_CONNECTOR = "off_page_connector"
    TEST_POINT = "test_point"
    NO_CONNECT = "no_connect"


# Canonical pin lists per component type
DEFAULT_PINS: dict[str, list[str]] = {
    "resistor": ["1", "2"],
    "capacitor": ["1", "2"],
    "inductor": ["1", "2"],
    "potentiometer": ["1", "2", "W"],
    "fuse": ["1", "2"],
    "diode": ["A", "K"],
    "led": ["A", "K"],
    "zener": ["A", "K"],
    "schottky": ["A", "K"],
    "npn": ["B", "C", "E"],
    "pnp": ["B", "C", "E"],
    "nmos": ["G", "D", "S"],
    "nmos4": ["G", "D", "S", "B"],
    "pmos": ["G", "D", "S"],
    "pmos4": ["G", "D", "S", "B"],
    "voltage_source": ["+", "-"],
    "current_source": ["+", "-"],
    "dependent_voltage_source": ["+", "-", "ctrl+", "ctrl-"],
    "dependent_current_source": ["+", "-", "ctrl+", "ctrl-"],
    "ground": ["1"],
    "vdd": ["1"],
    "vss": ["1"],
    "vcc": ["1"],
    "opamp": ["IN+", "IN-", "OUT", "V+", "V-"],
    "comparator": ["IN+", "IN-", "OUT", "V+", "V-"],
}


# ── Data classes ──────────────────────────────────────────────────────────── #


@dataclass
class BBox:
    x: int
    y: int
    w: int
    h: int

    @property
    def center(self) -> tuple[float, float]:
        return (self.x + self.w / 2, self.y + self.h / 2)

    @property
    def area(self) -> int:
        return self.w * self.h


@dataclass
class Pin:
    id: str
    name: str

    @classmethod
    def for_component(cls, comp_id: str, name: str) -> Pin:
        return cls(id=f"{comp_id}.{name}", name=name)


@dataclass
class Component:
    id: str
    type: str
    ref: Optional[str] = None
    value: Optional[str] = None
    symbol: Optional[str] = None
    confidence: float = 1.0
    pins: list[Pin] = field(default_factory=list)
    source_bbox: Optional[BBox] = None
    properties: dict[str, str] = field(default_factory=dict)

    def __post_init__(self):
        if not self.pins and self.type in DEFAULT_PINS:
            self.pins = [
                Pin.for_component(self.id, name)
                for name in DEFAULT_PINS[self.type]
            ]
        if not self.symbol:
            self.symbol = SYMBOL_MAP.get(self.type)

    def pin_by_name(self, name: str) -> Optional[Pin]:
        for p in self.pins:
            if p.name == name:
                return p
        return None


@dataclass
class Net:
    id: str
    pins: list[str]
    name: Optional[str] = None
    confidence: float = 1.0


@dataclass
class Point:
    x: int
    y: int


@dataclass
class Warning:
    type: str
    message: str
    location: Optional[Point] = None
    component_id: Optional[str] = None
    confidence: Optional[float] = None
    assumed: Optional[str] = None


@dataclass
class ImageDimensions:
    width: int
    height: int


@dataclass
class Metadata:
    source_image: Optional[str] = None
    detected_style: str = "unknown"
    overall_confidence: float = 0.0
    image_dimensions: Optional[ImageDimensions] = None
    crossing_convention: str = "dot_means_connected"
    pipeline_version: str = "0.1.0"


@dataclass
class CircuitGraph:
    """Top-level container for an extracted circuit.

    Serializes to the CircuitGraph JSON bridge format consumed by the Zig
    editor's ImportPlugin.
    """

    version: str = "1.0"
    metadata: Metadata = field(default_factory=Metadata)
    components: list[Component] = field(default_factory=list)
    nets: list[Net] = field(default_factory=list)
    warnings: list[Warning] = field(default_factory=list)

    # ── Queries ────────────────────────────────────────────────────────── #

    def component_by_id(self, comp_id: str) -> Optional[Component]:
        for c in self.components:
            if c.id == comp_id:
                return c
        return None

    def nets_for_pin(self, pin_id: str) -> list[Net]:
        return [n for n in self.nets if pin_id in n.pins]

    def unconnected_pins(self) -> list[str]:
        connected = {pid for net in self.nets for pid in net.pins}
        all_pins = {p.id for c in self.components for p in c.pins}
        return sorted(all_pins - connected)

    def low_confidence_components(self, threshold: float = 0.7) -> list[Component]:
        return [c for c in self.components if c.confidence < threshold]

    def low_confidence_nets(self, threshold: float = 0.7) -> list[Net]:
        return [n for n in self.nets if n.confidence < threshold]

    # ── Validation ─────────────────────────────────────────────────────── #

    def validate(self) -> list[str]:
        """Return a list of validation error strings. Empty = valid."""
        errors: list[str] = []
        comp_ids = {c.id for c in self.components}
        all_pin_ids = {p.id for c in self.components for p in c.pins}

        if len(comp_ids) != len(self.components):
            errors.append("Duplicate component IDs")

        net_ids = [n.id for n in self.nets]
        if len(set(net_ids)) != len(net_ids):
            errors.append("Duplicate net IDs")

        for net in self.nets:
            for pid in net.pins:
                if pid not in all_pin_ids:
                    errors.append(f"Net {net.id} references unknown pin {pid}")

        refs = [c.ref for c in self.components if c.ref]
        if len(set(refs)) != len(refs):
            dupes = [r for r in refs if refs.count(r) > 1]
            errors.append(f"Duplicate reference designators: {set(dupes)}")

        return errors

    # ── Serialization ──────────────────────────────────────────────────── #

    def to_dict(self) -> dict:
        return _clean_nones(asdict(self))

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)

    def write(self, path: str | Path) -> None:
        Path(path).write_text(self.to_json(), encoding="utf-8")

    @classmethod
    def from_dict(cls, data: dict) -> CircuitGraph:
        meta_raw = data.get("metadata", {})
        dims = meta_raw.get("image_dimensions")
        metadata = Metadata(
            source_image=meta_raw.get("source_image"),
            detected_style=meta_raw.get("detected_style", "unknown"),
            overall_confidence=meta_raw.get("overall_confidence", 0.0),
            image_dimensions=ImageDimensions(**dims) if dims else None,
            crossing_convention=meta_raw.get(
                "crossing_convention", "dot_means_connected"
            ),
            pipeline_version=meta_raw.get("pipeline_version", "0.1.0"),
        )

        components = []
        for c in data.get("components", []):
            pins = [Pin(**p) for p in c.get("pins", [])]
            bbox = c.get("source_bbox")
            components.append(
                Component(
                    id=c["id"],
                    type=c["type"],
                    ref=c.get("ref"),
                    value=c.get("value"),
                    symbol=c.get("symbol"),
                    confidence=c.get("confidence", 1.0),
                    pins=pins,
                    source_bbox=BBox(**bbox) if bbox else None,
                    properties=c.get("properties", {}),
                )
            )

        nets = [
            Net(
                id=n["id"],
                pins=n["pins"],
                name=n.get("name"),
                confidence=n.get("confidence", 1.0),
            )
            for n in data.get("nets", [])
        ]

        warnings = [
            Warning(
                type=w["type"],
                message=w["message"],
                location=Point(**w["location"]) if w.get("location") else None,
                component_id=w.get("component_id"),
                confidence=w.get("confidence"),
                assumed=w.get("assumed"),
            )
            for w in data.get("warnings", [])
        ]

        return cls(
            version=data.get("version", "1.0"),
            metadata=metadata,
            components=components,
            nets=nets,
            warnings=warnings,
        )

    @classmethod
    def from_json(cls, text: str) -> CircuitGraph:
        return cls.from_dict(json.loads(text))

    @classmethod
    def read(cls, path: str | Path) -> CircuitGraph:
        return cls.from_json(Path(path).read_text(encoding="utf-8"))


# ── Schemify symbol mapping ──────────────────────────────────────────────── #

SYMBOL_MAP: dict[str, str] = {
    "resistor": "devices/res",
    "capacitor": "devices/capa",
    "inductor": "devices/ind",
    "potentiometer": "devices/pot",
    "fuse": "devices/fuse",
    "diode": "devices/diode",
    "led": "devices/led",
    "zener": "devices/zener",
    "schottky": "devices/schottky",
    "npn": "devices/npn",
    "pnp": "devices/pnp",
    "nmos": "devices/nmos",
    "nmos4": "devices/nmos4",
    "pmos": "devices/pmos",
    "pmos4": "devices/pmos4",
    "voltage_source": "devices/vsource",
    "current_source": "devices/isource",
    "dependent_voltage_source": "devices/vcvs",
    "dependent_current_source": "devices/cccs",
    "ground": "devices/gnd",
    "vdd": "devices/vdd",
    "vss": "devices/vss",
    "vcc": "devices/vcc",
    "opamp": "devices/opamp",
    "comparator": "devices/comparator",
    "ic_block": "devices/generic_ic",
    "logic_gate": "devices/logic_gate",
}


# ── Helpers ───────────────────────────────────────────────────────────────── #


def _clean_nones(d):
    """Recursively remove None values from dicts for cleaner JSON output."""
    if isinstance(d, dict):
        return {k: _clean_nones(v) for k, v in d.items() if v is not None}
    if isinstance(d, list):
        return [_clean_nones(v) for v in d]
    return d
