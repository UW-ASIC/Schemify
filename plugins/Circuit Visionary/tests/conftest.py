"""Shared test fixtures for CircuitVision.

Provides synthetic images, pre-built CircuitGraph objects, and mock
detections so tests run without model weights or external dependencies.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

# Ensure src/ is importable
SRC = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SRC))

from circuit_graph import (
    BBox,
    CircuitGraph,
    Component,
    CrossingConvention,
    ImageDimensions,
    Metadata,
    Net,
    Pin,
    Point,
    Style,
    Warning,
    WarningType,
)
from crossing_classifier import Crossing, CrossingType, WireSegment
from detector import Detection


FIXTURES = Path(__file__).resolve().parent / "fixtures"


# ── Synthetic images ──────────────────────────────────────────────────────── #


@pytest.fixture
def blank_image() -> np.ndarray:
    """800x600 white BGR image."""
    return np.ones((600, 800, 3), dtype=np.uint8) * 255


@pytest.fixture
def noisy_image() -> np.ndarray:
    """800x600 image with Gaussian noise (simulates hand-drawn photo)."""
    rng = np.random.default_rng(42)
    img = np.ones((600, 800, 3), dtype=np.uint8) * 230
    noise = rng.normal(0, 25, img.shape).astype(np.int16)
    img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    return img


@pytest.fixture
def clean_image() -> np.ndarray:
    """800x600 white image with some clean black lines (simulates textbook)."""
    import cv2

    img = np.ones((600, 800, 3), dtype=np.uint8) * 255
    # Horizontal wire
    cv2.line(img, (100, 300), (700, 300), (0, 0, 0), 2)
    # Vertical wire
    cv2.line(img, (400, 100), (400, 500), (0, 0, 0), 2)
    # Resistor-like zigzag
    pts = np.array(
        [[200, 298], [220, 280], [240, 320], [260, 280], [280, 320], [300, 298]],
        dtype=np.int32,
    )
    cv2.polylines(img, [pts], False, (0, 0, 0), 2)
    return img


@pytest.fixture
def dense_image() -> np.ndarray:
    """800x600 image with many lines and text blocks (simulates datasheet)."""
    import cv2

    img = np.ones((600, 800, 3), dtype=np.uint8) * 255
    for y in range(50, 550, 40):
        cv2.line(img, (50, y), (750, y), (0, 0, 0), 1)
    for x in range(50, 750, 40):
        cv2.line(img, (x, 50), (x, 550), (0, 0, 0), 1)
    # Dense text-like blobs
    for y in range(60, 200, 15):
        cv2.rectangle(img, (60, y), (350, y + 8), (0, 0, 0), -1)
    return img


# ── Pre-built circuit graphs ─────────────────────────────────────────────── #


@pytest.fixture
def simple_rc_graph() -> CircuitGraph:
    """Simple RC low-pass filter: R1 + C1, 2 nets."""
    r1 = Component(
        id="comp_000",
        type="resistor",
        ref="R1",
        value="10k",
        confidence=0.95,
        pins=[
            Pin(id="comp_000.1", name="1"),
            Pin(id="comp_000.2", name="2"),
        ],
        source_bbox=BBox(x=100, y=290, w=80, h=20),
    )
    c1 = Component(
        id="comp_001",
        type="capacitor",
        ref="C1",
        value="100nF",
        confidence=0.92,
        pins=[
            Pin(id="comp_001.1", name="1"),
            Pin(id="comp_001.2", name="2"),
        ],
        source_bbox=BBox(x=250, y=280, w=20, h=60),
    )
    gnd = Component(
        id="comp_002",
        type="ground",
        ref=None,
        confidence=0.99,
        pins=[Pin(id="comp_002.1", name="1")],
        source_bbox=BBox(x=255, y=360, w=20, h=20),
    )

    net_in = Net(id="net_000", name="IN", pins=["comp_000.1"], confidence=0.9)
    net_mid = Net(
        id="net_001", name=None, pins=["comp_000.2", "comp_001.1"], confidence=0.93
    )
    net_gnd = Net(
        id="net_002", name="GND", pins=["comp_001.2", "comp_002.1"], confidence=0.97
    )

    return CircuitGraph(
        metadata=Metadata(
            detected_style="textbook",
            overall_confidence=0.93,
            image_dimensions=ImageDimensions(width=800, height=600),
            crossing_convention="dot_means_connected",
        ),
        components=[r1, c1, gnd],
        nets=[net_in, net_mid, net_gnd],
    )


@pytest.fixture
def nmos_diff_pair_graph() -> CircuitGraph:
    """NMOS differential pair: M1 + M2 + tail current source ISS, 5 nets."""
    m1 = Component(
        id="comp_000",
        type="nmos",
        ref="M1",
        confidence=0.88,
        pins=[
            Pin(id="comp_000.G", name="G"),
            Pin(id="comp_000.D", name="D"),
            Pin(id="comp_000.S", name="S"),
        ],
        source_bbox=BBox(x=200, y=200, w=60, h=80),
    )
    m2 = Component(
        id="comp_001",
        type="nmos",
        ref="M2",
        confidence=0.90,
        pins=[
            Pin(id="comp_001.G", name="G"),
            Pin(id="comp_001.D", name="D"),
            Pin(id="comp_001.S", name="S"),
        ],
        source_bbox=BBox(x=500, y=200, w=60, h=80),
    )
    iss = Component(
        id="comp_002",
        type="current_source",
        ref="ISS",
        value="100uA",
        confidence=0.85,
        pins=[
            Pin(id="comp_002.+", name="+"),
            Pin(id="comp_002.-", name="-"),
        ],
        source_bbox=BBox(x=350, y=350, w=40, h=50),
    )
    vdd = Component(
        id="comp_003", type="vdd", confidence=0.99,
        pins=[Pin(id="comp_003.1", name="1")],
        source_bbox=BBox(x=380, y=50, w=20, h=20),
    )
    gnd = Component(
        id="comp_004", type="ground", confidence=0.99,
        pins=[Pin(id="comp_004.1", name="1")],
        source_bbox=BBox(x=380, y=430, w=20, h=20),
    )

    return CircuitGraph(
        metadata=Metadata(
            detected_style="textbook",
            overall_confidence=0.88,
            image_dimensions=ImageDimensions(width=800, height=600),
        ),
        components=[m1, m2, iss, vdd, gnd],
        nets=[
            Net(id="net_000", name="VIN+", pins=["comp_000.G"]),
            Net(id="net_001", name="VIN-", pins=["comp_001.G"]),
            Net(id="net_002", name=None, pins=["comp_000.S", "comp_001.S", "comp_002.+"]),
            Net(id="net_003", name="GND", pins=["comp_002.-", "comp_004.1"]),
            Net(id="net_004", name="VDD", pins=["comp_003.1"]),
        ],
    )


@pytest.fixture
def opamp_inverting_graph() -> CircuitGraph:
    """Inverting opamp: R1 (input), R2 (feedback), U1 (opamp), GND."""
    r1 = Component(
        id="comp_000", type="resistor", ref="R1", value="10k",
        confidence=0.94,
        pins=[Pin(id="comp_000.1", name="1"), Pin(id="comp_000.2", name="2")],
        source_bbox=BBox(x=100, y=290, w=80, h=20),
    )
    r2 = Component(
        id="comp_001", type="resistor", ref="R2", value="100k",
        confidence=0.91,
        pins=[Pin(id="comp_001.1", name="1"), Pin(id="comp_001.2", name="2")],
        source_bbox=BBox(x=300, y=200, w=80, h=20),
    )
    u1 = Component(
        id="comp_002", type="opamp", ref="U1",
        confidence=0.96,
        pins=[
            Pin(id="comp_002.IN+", name="IN+"),
            Pin(id="comp_002.IN-", name="IN-"),
            Pin(id="comp_002.OUT", name="OUT"),
            Pin(id="comp_002.V+", name="V+"),
            Pin(id="comp_002.V-", name="V-"),
        ],
        source_bbox=BBox(x=400, y=250, w=100, h=80),
    )
    gnd = Component(
        id="comp_003", type="ground", confidence=0.99,
        pins=[Pin(id="comp_003.1", name="1")],
        source_bbox=BBox(x=395, y=380, w=20, h=20),
    )

    return CircuitGraph(
        metadata=Metadata(
            detected_style="textbook",
            overall_confidence=0.93,
            image_dimensions=ImageDimensions(width=800, height=600),
        ),
        components=[r1, r2, u1, gnd],
        nets=[
            Net(id="net_000", name="VIN", pins=["comp_000.1"]),
            Net(id="net_001", pins=["comp_000.2", "comp_001.1", "comp_002.IN-"]),
            Net(id="net_002", name="VOUT", pins=["comp_001.2", "comp_002.OUT"]),
            Net(id="net_003", name="GND", pins=["comp_002.IN+", "comp_003.1"]),
        ],
    )


# ── Mock detections ───────────────────────────────────────────────────────── #


@pytest.fixture
def sample_detections() -> list[Detection]:
    return [
        Detection(class_name="resistor", confidence=0.95, bbox=BBox(x=100, y=290, w=80, h=20), class_id=0),
        Detection(class_name="capacitor", confidence=0.92, bbox=BBox(x=250, y=280, w=20, h=60), class_id=1),
        Detection(class_name="ground", confidence=0.99, bbox=BBox(x=255, y=360, w=20, h=20), class_id=15),
    ]


@pytest.fixture
def mosfet_detections() -> list[Detection]:
    return [
        Detection(class_name="nmos", confidence=0.88, bbox=BBox(x=200, y=200, w=60, h=80), class_id=8),
        Detection(class_name="nmos", confidence=0.90, bbox=BBox(x=500, y=200, w=60, h=80), class_id=8),
        Detection(class_name="current_source", confidence=0.85, bbox=BBox(x=350, y=350, w=40, h=50), class_id=14),
    ]


# ── Wire segments ─────────────────────────────────────────────────────────── #


@pytest.fixture
def sample_wire_segments() -> list[WireSegment]:
    return [
        WireSegment(
            start=Point(x=180, y=300),
            end=Point(x=250, y=300),
            points=[Point(x=x, y=300) for x in range(180, 251)],
        ),
        WireSegment(
            start=Point(x=260, y=340),
            end=Point(x=260, y=360),
            points=[Point(x=260, y=y) for y in range(340, 361)],
        ),
    ]
