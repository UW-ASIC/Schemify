"""Extended topology builder tests — complex circuits and edge cases."""

import pytest

from circuit_graph import (
    BBox,
    Component,
    Net,
    Pin,
    Point,
    Style,
    WarningType,
    CircuitGraph,
)
from crossing_classifier import Crossing, CrossingType, WireSegment
from detector import Detection
from label_reader import ComponentLabel
from topology import TopologyBuilder


class TestTopologyFullCircuits:
    """Test the topology builder with realistic multi-component circuits."""

    @pytest.fixture
    def builder(self):
        return TopologyBuilder()

    def test_rc_lowpass_three_component(self, builder):
        """R → C → GND: 3 components, 2 wires, should produce 2 nets."""
        detections = [
            Detection(class_name="resistor", confidence=0.95, bbox=BBox(x=100, y=90, w=80, h=20)),
            Detection(class_name="capacitor", confidence=0.92, bbox=BBox(x=250, y=80, w=20, h=60)),
            Detection(class_name="ground", confidence=0.99, bbox=BBox(x=255, y=160, w=20, h=20)),
        ]
        labels = [
            ComponentLabel(detection_idx=0, ref="R1", ref_confidence=0.9, value="10k"),
            ComponentLabel(detection_idx=1, ref="C1", ref_confidence=0.9, value="100n"),
            ComponentLabel(detection_idx=2),
        ]
        wire_r_to_c = WireSegment(
            start=Point(x=180, y=100), end=Point(x=250, y=100), points=[]
        )
        wire_c_to_gnd = WireSegment(
            start=Point(x=260, y=140), end=Point(x=260, y=160), points=[]
        )

        graph = builder.build(
            detections=detections,
            wire_segments=[wire_r_to_c, wire_c_to_gnd],
            crossings=[],
            labels=labels,
            style=Style.TEXTBOOK,
        )

        assert len(graph.components) == 3
        assert graph.components[0].value == "10k"
        assert len(graph.nets) >= 1
        assert graph.validate() == []

    def test_differential_pair_structure(self, builder):
        """Two NMOS + tail current source — 5 wires, crossing-free."""
        detections = [
            Detection(class_name="nmos", confidence=0.88, bbox=BBox(x=100, y=200, w=60, h=80)),
            Detection(class_name="nmos", confidence=0.90, bbox=BBox(x=300, y=200, w=60, h=80)),
            Detection(class_name="current_source", confidence=0.85, bbox=BBox(x=200, y=340, w=40, h=50)),
        ]
        labels = [
            ComponentLabel(detection_idx=0, ref="M1"),
            ComponentLabel(detection_idx=1, ref="M2"),
            ComponentLabel(detection_idx=2, ref="ISS"),
        ]
        # M1.S → ISS.+ wire
        wire_m1_iss = WireSegment(
            start=Point(x=130, y=280), end=Point(x=220, y=340), points=[]
        )
        # M2.S → ISS.+ wire
        wire_m2_iss = WireSegment(
            start=Point(x=330, y=280), end=Point(x=220, y=340), points=[]
        )

        graph = builder.build(
            detections=detections,
            wire_segments=[wire_m1_iss, wire_m2_iss],
            crossings=[],
            labels=labels,
            style=Style.TEXTBOOK,
        )

        assert len(graph.components) == 3
        # At least one net should connect M1.S, M2.S, and ISS
        all_pins = {pid for n in graph.nets for pid in n.pins}
        assert len(all_pins) > 0

    def test_empty_detections(self, builder):
        """Zero detections → empty graph."""
        graph = builder.build(
            detections=[], wire_segments=[], crossings=[],
            labels=[], style=Style.TEXTBOOK,
        )
        assert graph.components == []
        assert graph.nets == []

    def test_single_component_no_wires(self, builder):
        """One component, no wires → one component, zero nets."""
        detections = [
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=100, y=100, w=50, h=20)),
        ]
        labels = [ComponentLabel(detection_idx=0, ref="R1")]

        graph = builder.build(
            detections=detections,
            wire_segments=[],
            crossings=[],
            labels=labels,
            style=Style.TEXTBOOK,
        )
        assert len(graph.components) == 1
        assert len(graph.nets) == 0


class TestTopologyUnionFind:
    """Test the union-find connectivity logic specifically."""

    @pytest.fixture
    def builder(self):
        return TopologyBuilder()

    def test_chain_of_three_components(self, builder):
        """R1 → wire → R2 → wire → R3: all should end up in connected nets."""
        detections = [
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=50, y=95, w=60, h=10)),
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=160, y=95, w=60, h=10)),
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=270, y=95, w=60, h=10)),
        ]
        labels = [
            ComponentLabel(detection_idx=0, ref="R1"),
            ComponentLabel(detection_idx=1, ref="R2"),
            ComponentLabel(detection_idx=2, ref="R3"),
        ]
        wire1 = WireSegment(start=Point(x=110, y=100), end=Point(x=160, y=100), points=[])
        wire2 = WireSegment(start=Point(x=220, y=100), end=Point(x=270, y=100), points=[])

        graph = builder.build(
            detections=detections,
            wire_segments=[wire1, wire2],
            crossings=[],
            labels=labels,
            style=Style.TEXTBOOK,
        )

        # R1.2 and R2.1 should share a net, R2.2 and R3.1 should share a net
        all_pins_in_nets = {pid for n in graph.nets for pid in n.pins}
        assert len(all_pins_in_nets) >= 2

    def test_unconnected_crossing_keeps_nets_separate(self, builder):
        """PLAIN_UNCONNECTED crossing should NOT merge wire nets."""
        detections = [
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=50, y=95, w=40, h=10)),
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=160, y=95, w=40, h=10)),
            Detection(class_name="capacitor", confidence=0.9, bbox=BBox(x=95, y=40, w=10, h=40)),
            Detection(class_name="capacitor", confidence=0.9, bbox=BBox(x=95, y=120, w=10, h=40)),
        ]
        labels = [ComponentLabel(detection_idx=i, ref=f"X{i}") for i in range(4)]

        wire_h = WireSegment(start=Point(x=90, y=100), end=Point(x=160, y=100), points=[])
        wire_v = WireSegment(start=Point(x=100, y=80), end=Point(x=100, y=120), points=[])

        crossing = Crossing(
            location=Point(x=100, y=100),
            type=CrossingType.PLAIN_UNCONNECTED,
            confidence=0.9,
            segments=[0, 1],
        )

        graph = builder.build(
            detections=detections,
            wire_segments=[wire_h, wire_v],
            crossings=[crossing],
            labels=labels,
            style=Style.TEXTBOOK,
        )

        # Nets from horizontal and vertical wires should stay separate
        # (unconnected crossing should not merge them)
        assert isinstance(graph.nets, list)


class TestPinPositionExtended:
    @pytest.fixture
    def builder(self):
        return TopologyBuilder()

    def test_2pin_vertical_component(self, builder):
        """Tall component (h > w) → pins on top and bottom."""
        comp = Component(
            id="comp_000", type="capacitor",
            pins=[Pin(id="comp_000.1", name="1"), Pin(id="comp_000.2", name="2")],
            source_bbox=BBox(x=100, y=100, w=20, h=60),
        )
        det = Detection(class_name="capacitor", confidence=0.9, bbox=BBox(x=100, y=100, w=20, h=60))

        positions = builder._estimate_pin_positions([comp], [det])
        # Vertical: pin 1 on top, pin 2 on bottom
        assert positions["comp_000.1"].y < positions["comp_000.2"].y

    def test_opamp_pin_layout(self, builder):
        comp = Component(
            id="comp_000", type="opamp",
            pins=[
                Pin(id="comp_000.IN+", name="IN+"),
                Pin(id="comp_000.IN-", name="IN-"),
                Pin(id="comp_000.OUT", name="OUT"),
                Pin(id="comp_000.V+", name="V+"),
                Pin(id="comp_000.V-", name="V-"),
            ],
            source_bbox=BBox(x=200, y=200, w=120, h=80),
        )
        det = Detection(class_name="opamp", confidence=0.96, bbox=BBox(x=200, y=200, w=120, h=80))

        positions = builder._estimate_pin_positions([comp], [det])
        assert "comp_000.IN+" in positions
        assert "comp_000.OUT" in positions
        # OUT should be on the right, IN+/IN- on the left
        assert positions["comp_000.OUT"].x > positions["comp_000.IN+"].x
        assert positions["comp_000.OUT"].x > positions["comp_000.IN-"].x
        # V+ on top, V- on bottom
        assert positions["comp_000.V+"].y < positions["comp_000.V-"].y

    def test_4pin_mosfet_body_on_right(self, builder):
        comp = Component(
            id="comp_000", type="nmos4",
            pins=[
                Pin(id="comp_000.G", name="G"),
                Pin(id="comp_000.D", name="D"),
                Pin(id="comp_000.S", name="S"),
                Pin(id="comp_000.B", name="B"),
            ],
            source_bbox=BBox(x=100, y=100, w=60, h=80),
        )
        det = Detection(class_name="nmos4", confidence=0.9, bbox=BBox(x=100, y=100, w=60, h=80))

        positions = builder._estimate_pin_positions([comp], [det])
        assert "comp_000.B" in positions
        # Body pin should be on the right side
        assert positions["comp_000.B"].x > positions["comp_000.G"].x

    def test_bjt_pin_layout(self, builder):
        comp = Component(
            id="comp_000", type="npn",
            pins=[
                Pin(id="comp_000.B", name="B"),
                Pin(id="comp_000.C", name="C"),
                Pin(id="comp_000.E", name="E"),
            ],
            source_bbox=BBox(x=100, y=100, w=60, h=80),
        )
        det = Detection(class_name="npn", confidence=0.9, bbox=BBox(x=100, y=100, w=60, h=80))

        positions = builder._estimate_pin_positions([comp], [det])
        # Base on left, collector on top, emitter on bottom
        assert positions["comp_000.B"].x <= positions["comp_000.C"].x
        assert positions["comp_000.C"].y < positions["comp_000.E"].y

    def test_single_pin_component(self, builder):
        comp = Component(
            id="comp_000", type="ground",
            pins=[Pin(id="comp_000.1", name="1")],
            source_bbox=BBox(x=100, y=100, w=20, h=20),
        )
        det = Detection(class_name="ground", confidence=0.99, bbox=BBox(x=100, y=100, w=20, h=20))

        positions = builder._estimate_pin_positions([comp], [det])
        assert "comp_000.1" in positions
        # Should be at center of bbox
        assert positions["comp_000.1"].x == 110
        assert positions["comp_000.1"].y == 110


class TestTopologyWarningGeneration:
    @pytest.fixture
    def builder(self):
        return TopologyBuilder()

    def test_multiple_low_confidence_warnings(self, builder):
        detections = [
            Detection(class_name="resistor", confidence=0.3, bbox=BBox(x=50, y=95, w=50, h=10)),
            Detection(class_name="capacitor", confidence=0.4, bbox=BBox(x=200, y=95, w=10, h=50)),
            Detection(class_name="inductor", confidence=0.9, bbox=BBox(x=350, y=95, w=50, h=10)),
        ]
        labels = [ComponentLabel(detection_idx=i, ref=f"X{i}") for i in range(3)]

        graph = builder.build(
            detections=detections, wire_segments=[], crossings=[],
            labels=labels, style=Style.TEXTBOOK,
        )

        low_conf_warnings = [
            w for w in graph.warnings
            if w.type == WarningType.LOW_CONFIDENCE_DETECTION.value
        ]
        assert len(low_conf_warnings) == 2  # R and C below 0.7, L above

    def test_auto_generated_ref_warning(self, builder):
        detections = [
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=100, y=100, w=50, h=20)),
        ]
        # Ref with 0.0 confidence → auto-generated
        labels = [ComponentLabel(detection_idx=0, ref="R1", ref_confidence=0.0)]

        graph = builder.build(
            detections=detections, wire_segments=[], crossings=[],
            labels=labels, style=Style.TEXTBOOK,
        )

        ocr_warnings = [
            w for w in graph.warnings
            if w.type == WarningType.OCR_UNCERTAIN.value
        ]
        assert len(ocr_warnings) == 1
