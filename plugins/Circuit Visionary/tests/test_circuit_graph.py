"""Tests for the CircuitGraph data model — serialization, validation, queries."""

import json
from pathlib import Path

import pytest

from circuit_graph import (
    BBox,
    CircuitGraph,
    Component,
    ImageDimensions,
    Metadata,
    Net,
    Pin,
    Point,
    Warning,
    WarningType,
    DEFAULT_PINS,
    SYMBOL_MAP,
)


FIXTURES = Path(__file__).resolve().parent / "fixtures"


class TestBBox:
    def test_center(self):
        b = BBox(x=100, y=200, w=50, h=30)
        assert b.center == (125.0, 215.0)

    def test_area(self):
        b = BBox(x=0, y=0, w=10, h=20)
        assert b.area == 200


class TestPin:
    def test_for_component(self):
        p = Pin.for_component("comp_001", "G")
        assert p.id == "comp_001.G"
        assert p.name == "G"


class TestComponent:
    def test_auto_pins_resistor(self):
        c = Component(id="comp_000", type="resistor")
        assert len(c.pins) == 2
        assert c.pins[0].id == "comp_000.1"
        assert c.pins[1].id == "comp_000.2"

    def test_auto_pins_nmos4(self):
        c = Component(id="comp_000", type="nmos4")
        assert len(c.pins) == 4
        pin_names = {p.name for p in c.pins}
        assert pin_names == {"G", "D", "S", "B"}

    def test_auto_symbol(self):
        c = Component(id="comp_000", type="opamp")
        assert c.symbol == "devices/opamp"

    def test_explicit_pins_not_overridden(self):
        pins = [Pin(id="comp_000.A", name="A")]
        c = Component(id="comp_000", type="resistor", pins=pins)
        assert len(c.pins) == 1
        assert c.pins[0].name == "A"

    def test_pin_by_name(self):
        c = Component(id="comp_000", type="nmos")
        assert c.pin_by_name("G") is not None
        assert c.pin_by_name("X") is None

    def test_all_default_pin_types_have_symbols(self):
        for comp_type in DEFAULT_PINS:
            if comp_type in ("junction_dot", "crossing_bridge", "off_page_connector",
                             "test_point", "no_connect"):
                continue
            assert comp_type in SYMBOL_MAP, f"No symbol for {comp_type}"


class TestCircuitGraphSerialization:
    def test_round_trip_json(self, simple_rc_graph):
        json_str = simple_rc_graph.to_json()
        restored = CircuitGraph.from_json(json_str)

        assert len(restored.components) == 3
        assert len(restored.nets) == 3
        assert restored.metadata.detected_style == "textbook"
        assert restored.components[0].ref == "R1"
        assert restored.components[1].value == "100nF"

    def test_round_trip_preserves_pins(self, simple_rc_graph):
        json_str = simple_rc_graph.to_json()
        restored = CircuitGraph.from_json(json_str)

        r1 = restored.components[0]
        assert len(r1.pins) == 2
        assert r1.pins[0].id == "comp_000.1"

    def test_round_trip_preserves_bbox(self, simple_rc_graph):
        json_str = simple_rc_graph.to_json()
        restored = CircuitGraph.from_json(json_str)

        assert restored.components[0].source_bbox.x == 100
        assert restored.components[0].source_bbox.w == 80

    def test_round_trip_preserves_warnings(self):
        g = CircuitGraph(
            warnings=[
                Warning(
                    type="ambiguous_crossing",
                    message="test",
                    location=Point(x=10, y=20),
                    assumed="unconnected",
                )
            ]
        )
        restored = CircuitGraph.from_json(g.to_json())
        assert len(restored.warnings) == 1
        assert restored.warnings[0].location.x == 10
        assert restored.warnings[0].assumed == "unconnected"

    def test_nones_cleaned_from_json(self, simple_rc_graph):
        json_str = simple_rc_graph.to_json()
        data = json.loads(json_str)
        # Ground component has ref=None — should not appear in JSON
        gnd = data["components"][2]
        assert "ref" not in gnd

    def test_to_dict_is_json_serializable(self, nmos_diff_pair_graph):
        d = nmos_diff_pair_graph.to_dict()
        json.dumps(d)  # should not raise

    def test_read_write_file(self, simple_rc_graph, tmp_path):
        path = tmp_path / "test.json"
        simple_rc_graph.write(path)
        restored = CircuitGraph.read(path)
        assert len(restored.components) == len(simple_rc_graph.components)


class TestCircuitGraphValidation:
    def test_valid_graph_no_errors(self, simple_rc_graph):
        errors = simple_rc_graph.validate()
        assert errors == []

    def test_duplicate_component_ids(self):
        g = CircuitGraph(
            components=[
                Component(id="comp_000", type="resistor"),
                Component(id="comp_000", type="capacitor"),
            ]
        )
        errors = g.validate()
        assert any("Duplicate component" in e for e in errors)

    def test_duplicate_net_ids(self):
        c = Component(id="comp_000", type="resistor")
        g = CircuitGraph(
            components=[c],
            nets=[
                Net(id="net_000", pins=["comp_000.1", "comp_000.2"]),
                Net(id="net_000", pins=["comp_000.1", "comp_000.2"]),
            ],
        )
        errors = g.validate()
        assert any("Duplicate net" in e for e in errors)

    def test_net_references_unknown_pin(self):
        c = Component(id="comp_000", type="resistor")
        g = CircuitGraph(
            components=[c],
            nets=[Net(id="net_000", pins=["comp_000.1", "comp_999.X"])],
        )
        errors = g.validate()
        assert any("unknown pin" in e for e in errors)

    def test_duplicate_refs(self):
        g = CircuitGraph(
            components=[
                Component(id="comp_000", type="resistor", ref="R1"),
                Component(id="comp_001", type="resistor", ref="R1"),
            ]
        )
        errors = g.validate()
        assert any("Duplicate reference" in e for e in errors)


class TestCircuitGraphQueries:
    def test_component_by_id(self, simple_rc_graph):
        c = simple_rc_graph.component_by_id("comp_001")
        assert c is not None
        assert c.type == "capacitor"
        assert simple_rc_graph.component_by_id("comp_999") is None

    def test_nets_for_pin(self, simple_rc_graph):
        nets = simple_rc_graph.nets_for_pin("comp_000.2")
        assert len(nets) == 1
        assert nets[0].id == "net_001"

    def test_unconnected_pins(self):
        c = Component(id="comp_000", type="resistor")
        g = CircuitGraph(
            components=[c],
            nets=[Net(id="net_000", pins=["comp_000.1"])],
        )
        unconnected = g.unconnected_pins()
        assert "comp_000.2" in unconnected

    def test_low_confidence_components(self, nmos_diff_pair_graph):
        low = nmos_diff_pair_graph.low_confidence_components(threshold=0.9)
        ids = [c.id for c in low]
        assert "comp_000" in ids  # M1 confidence = 0.88
        assert "comp_002" in ids  # ISS confidence = 0.85


class TestFixtureFiles:
    """Validate that the JSON fixtures in tests/fixtures/ are well-formed."""

    @pytest.mark.parametrize(
        "fixture_name",
        ["simple_rc.json", "nmos_diff_pair.json", "inverting_opamp.json", "datasheet_lm358.json"],
    )
    def test_fixture_loads_and_validates(self, fixture_name):
        path = FIXTURES / fixture_name
        if not path.exists():
            pytest.skip(f"Fixture {fixture_name} not yet created")
        g = CircuitGraph.read(path)
        errors = g.validate()
        assert errors == [], f"Validation errors in {fixture_name}: {errors}"
