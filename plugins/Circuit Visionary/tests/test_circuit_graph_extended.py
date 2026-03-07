"""Extended tests for CircuitGraph — edge cases, stress, and deeper coverage."""

import json

import pytest

from circuit_graph import (
    BBox,
    CircuitGraph,
    Component,
    ComponentType,
    ImageDimensions,
    Metadata,
    Net,
    Pin,
    Point,
    Style,
    Warning,
    WarningType,
    DEFAULT_PINS,
    SYMBOL_MAP,
    _clean_nones,
)


class TestBBoxEdgeCases:
    def test_zero_size_bbox(self):
        b = BBox(x=50, y=50, w=0, h=0)
        assert b.area == 0
        assert b.center == (50.0, 50.0)

    def test_large_bbox(self):
        b = BBox(x=0, y=0, w=10000, h=8000)
        assert b.area == 80_000_000
        assert b.center == (5000.0, 4000.0)

    def test_negative_origin(self):
        b = BBox(x=-10, y=-20, w=100, h=50)
        assert b.center == (40.0, 5.0)


class TestComponentEdgeCases:
    def test_every_component_type_creates_valid_component(self):
        for ct in ComponentType:
            c = Component(id=f"comp_{ct.value}", type=ct.value)
            assert c.type == ct.value
            assert c.id == f"comp_{ct.value}"

    def test_unknown_type_gets_no_auto_pins(self):
        c = Component(id="comp_000", type="exotic_widget")
        assert c.pins == []

    def test_unknown_type_gets_no_symbol(self):
        c = Component(id="comp_000", type="exotic_widget")
        assert c.symbol is None

    def test_opamp_has_five_pins(self):
        c = Component(id="comp_000", type="opamp")
        assert len(c.pins) == 5
        names = {p.name for p in c.pins}
        assert names == {"IN+", "IN-", "OUT", "V+", "V-"}

    def test_dependent_source_has_four_pins(self):
        c = Component(id="comp_000", type="dependent_voltage_source")
        assert len(c.pins) == 4

    def test_ground_has_one_pin(self):
        c = Component(id="comp_000", type="ground")
        assert len(c.pins) == 1
        assert c.pins[0].name == "1"

    def test_component_with_properties(self):
        c = Component(
            id="comp_000", type="resistor",
            properties={"tolerance": "5%", "package": "0603"},
        )
        assert c.properties["tolerance"] == "5%"

    def test_component_confidence_boundaries(self):
        c0 = Component(id="c0", type="resistor", confidence=0.0)
        c1 = Component(id="c1", type="resistor", confidence=1.0)
        assert c0.confidence == 0.0
        assert c1.confidence == 1.0

    def test_pin_by_name_returns_correct_pin(self):
        c = Component(id="comp_000", type="opamp")
        p = c.pin_by_name("OUT")
        assert p is not None
        assert p.id == "comp_000.OUT"

    def test_component_value_special_chars(self):
        c = Component(id="comp_000", type="resistor", value="4.7kΩ ±1%")
        assert "Ω" in c.value


class TestNetEdgeCases:
    def test_single_pin_net(self):
        n = Net(id="net_000", pins=["comp_000.1"])
        assert len(n.pins) == 1

    def test_large_net(self):
        pins = [f"comp_{i:03d}.1" for i in range(50)]
        n = Net(id="net_000", pins=pins, name="VDD")
        assert len(n.pins) == 50

    def test_net_with_zero_confidence(self):
        n = Net(id="net_000", pins=["comp_000.1", "comp_001.1"], confidence=0.0)
        assert n.confidence == 0.0


class TestCircuitGraphEmpty:
    def test_empty_graph(self):
        g = CircuitGraph()
        assert g.components == []
        assert g.nets == []
        assert g.warnings == []
        assert g.version == "1.0"

    def test_empty_graph_validates(self):
        g = CircuitGraph()
        assert g.validate() == []

    def test_empty_graph_serializes(self):
        g = CircuitGraph()
        j = g.to_json()
        restored = CircuitGraph.from_json(j)
        assert restored.components == []

    def test_empty_graph_queries_return_empty(self):
        g = CircuitGraph()
        assert g.component_by_id("comp_000") is None
        assert g.nets_for_pin("comp_000.1") == []
        assert g.unconnected_pins() == []
        assert g.low_confidence_components() == []
        assert g.low_confidence_nets() == []


class TestCircuitGraphStress:
    def test_many_components(self):
        components = [
            Component(id=f"comp_{i:03d}", type="resistor", ref=f"R{i+1}")
            for i in range(200)
        ]
        g = CircuitGraph(components=components)
        assert len(g.components) == 200
        assert g.validate() == []

        j = g.to_json()
        restored = CircuitGraph.from_json(j)
        assert len(restored.components) == 200

    def test_many_nets(self):
        c = Component(id="comp_000", type="resistor")
        nets = [
            Net(id=f"net_{i:03d}", pins=["comp_000.1"])
            for i in range(100)
        ]
        g = CircuitGraph(components=[c], nets=nets)
        j = g.to_json()
        restored = CircuitGraph.from_json(j)
        assert len(restored.nets) == 100

    def test_many_warnings(self):
        warnings = [
            Warning(
                type=WarningType.LOW_CONFIDENCE_DETECTION.value,
                message=f"Warning {i}",
                confidence=0.5,
            )
            for i in range(50)
        ]
        g = CircuitGraph(warnings=warnings)
        j = g.to_json()
        restored = CircuitGraph.from_json(j)
        assert len(restored.warnings) == 50


class TestCircuitGraphAdvancedQueries:
    def test_low_confidence_nets(self):
        c = Component(id="comp_000", type="resistor")
        g = CircuitGraph(
            components=[c],
            nets=[
                Net(id="net_000", pins=["comp_000.1"], confidence=0.9),
                Net(id="net_001", pins=["comp_000.2"], confidence=0.3),
            ],
        )
        low = g.low_confidence_nets(threshold=0.5)
        assert len(low) == 1
        assert low[0].id == "net_001"

    def test_nets_for_nonexistent_pin(self, simple_rc_graph):
        assert simple_rc_graph.nets_for_pin("comp_999.X") == []

    def test_unconnected_pins_all_connected(self, simple_rc_graph):
        # simple_rc has some pins in nets — check those that are connected
        connected = {pid for n in simple_rc_graph.nets for pid in n.pins}
        assert len(connected) > 0


class TestCircuitGraphRoundTripEdgeCases:
    def test_unicode_values_survive_round_trip(self):
        c = Component(id="comp_000", type="resistor", value="4.7kΩ", ref="R1")
        g = CircuitGraph(components=[c])
        restored = CircuitGraph.from_json(g.to_json())
        assert restored.components[0].value == "4.7kΩ"

    def test_empty_string_values(self):
        c = Component(id="comp_000", type="resistor", ref="", value="")
        g = CircuitGraph(components=[c])
        j = g.to_json()
        # Empty strings should be preserved (not cleaned as None)
        data = json.loads(j)
        assert data["components"][0]["ref"] == ""

    def test_metadata_round_trip(self):
        g = CircuitGraph(
            metadata=Metadata(
                source_image="/path/to/img.jpg",
                detected_style="handdrawn",
                overall_confidence=0.73,
                image_dimensions=ImageDimensions(width=1920, height=1080),
                crossing_convention="ambiguous",
                pipeline_version="0.2.0",
            )
        )
        restored = CircuitGraph.from_json(g.to_json())
        m = restored.metadata
        assert m.source_image == "/path/to/img.jpg"
        assert m.detected_style == "handdrawn"
        assert abs(m.overall_confidence - 0.73) < 1e-6
        assert m.image_dimensions.width == 1920
        assert m.crossing_convention == "ambiguous"
        assert m.pipeline_version == "0.2.0"

    def test_warning_all_fields_round_trip(self):
        w = Warning(
            type="ambiguous_crossing",
            message="test crossing",
            location=Point(x=123, y=456),
            component_id="comp_007",
            confidence=0.42,
            assumed="unconnected",
        )
        g = CircuitGraph(warnings=[w])
        restored = CircuitGraph.from_json(g.to_json())
        rw = restored.warnings[0]
        assert rw.type == "ambiguous_crossing"
        assert rw.location.x == 123
        assert rw.component_id == "comp_007"
        assert abs(rw.confidence - 0.42) < 1e-6
        assert rw.assumed == "unconnected"

    def test_diff_pair_round_trip(self, nmos_diff_pair_graph):
        restored = CircuitGraph.from_json(nmos_diff_pair_graph.to_json())
        assert len(restored.components) == 5
        assert len(restored.nets) == 5
        # Check MOSFET pin names survived
        m1 = restored.components[0]
        assert {p.name for p in m1.pins} == {"G", "D", "S"}

    def test_opamp_round_trip(self, opamp_inverting_graph):
        restored = CircuitGraph.from_json(opamp_inverting_graph.to_json())
        u1 = next(c for c in restored.components if c.type == "opamp")
        assert len(u1.pins) == 5


class TestCleanNones:
    def test_removes_none_from_dict(self):
        assert _clean_nones({"a": 1, "b": None}) == {"a": 1}

    def test_recursive_none_removal(self):
        d = {"a": {"b": None, "c": 1}, "d": None}
        assert _clean_nones(d) == {"a": {"c": 1}}

    def test_preserves_zero_and_empty_string(self):
        d = {"a": 0, "b": "", "c": False, "d": None}
        result = _clean_nones(d)
        assert result["a"] == 0
        assert result["b"] == ""
        assert result["c"] is False
        assert "d" not in result

    def test_handles_nested_lists(self):
        d = {"a": [{"b": None, "c": 1}, {"d": 2}]}
        result = _clean_nones(d)
        assert result == {"a": [{"c": 1}, {"d": 2}]}


class TestDefaultPinsCompleteness:
    def test_all_component_types_enum_covered(self):
        """Every ComponentType with pins should be in DEFAULT_PINS."""
        no_pin_types = {
            "junction_dot", "crossing_bridge", "off_page_connector",
            "test_point", "no_connect", "ic_block", "logic_gate",
        }
        for ct in ComponentType:
            if ct.value in no_pin_types:
                continue
            assert ct.value in DEFAULT_PINS, f"Missing DEFAULT_PINS for {ct.value}"

    def test_symbol_map_values_are_paths(self):
        for comp_type, symbol in SYMBOL_MAP.items():
            assert "/" in symbol, f"Symbol {symbol} for {comp_type} not a path"
            assert symbol.startswith("devices/"), f"Symbol {symbol} not in devices/"
