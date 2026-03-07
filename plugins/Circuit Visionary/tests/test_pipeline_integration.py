"""Integration tests — end-to-end pipeline with synthetic inputs.

These tests validate that the pipeline stages compose correctly.
They use synthetic images and mock detections to run without model weights.
"""

import json
from pathlib import Path

import numpy as np
import pytest

from circuit_graph import CircuitGraph, Style

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class TestCircuitGraphSchemaValidation:
    """Validate CircuitGraph output against the JSON schema."""

    def _validate_schema(self, graph: CircuitGraph):
        try:
            import jsonschema

            schema_path = (
                Path(__file__).resolve().parent.parent
                / "schemas"
                / "circuit_graph.schema.json"
            )
            if not schema_path.exists():
                pytest.skip("Schema file not found")

            schema = json.loads(schema_path.read_text())
            jsonschema.validate(graph.to_dict(), schema)
        except ImportError:
            pytest.skip("jsonschema not installed")

    def test_simple_rc_validates(self, simple_rc_graph):
        self._validate_schema(simple_rc_graph)

    def test_diff_pair_validates(self, nmos_diff_pair_graph):
        self._validate_schema(nmos_diff_pair_graph)

    def test_opamp_validates(self, opamp_inverting_graph):
        self._validate_schema(opamp_inverting_graph)


class TestFixtureRoundTrips:
    """Ensure fixture JSON files survive read → write → read."""

    @pytest.mark.parametrize(
        "name",
        ["simple_rc.json", "nmos_diff_pair.json", "inverting_opamp.json", "datasheet_lm358.json"],
    )
    def test_fixture_round_trip(self, name, tmp_path):
        path = FIXTURES / name
        if not path.exists():
            pytest.skip(f"{name} not created yet")

        g1 = CircuitGraph.read(path)
        out = tmp_path / name
        g1.write(out)
        g2 = CircuitGraph.read(out)

        assert len(g1.components) == len(g2.components)
        assert len(g1.nets) == len(g2.nets)
        for c1, c2 in zip(g1.components, g2.components):
            assert c1.id == c2.id
            assert c1.type == c2.type
            assert c1.ref == c2.ref


class TestEndToEndWithSynthetics:
    """Run the full pipeline on synthetic images (no model weights needed).

    Without YOLO weights the detector returns empty results, so these tests
    verify that the pipeline handles zero-detection gracefully and that all
    stages compose without errors.
    """

    def test_pipeline_blank_image(self, blank_image, tmp_path):
        from circuit_extract import Pipeline

        p = Pipeline(style_override="textbook")
        path = tmp_path / "blank.png"

        import cv2
        cv2.imwrite(str(path), blank_image)

        graph = p.run(path)
        assert isinstance(graph, CircuitGraph)
        assert graph.metadata.detected_style == "textbook"
        # No models → no detections → empty graph
        assert len(graph.components) == 0
        assert len(graph.nets) == 0

    def test_pipeline_with_lines(self, clean_image, tmp_path):
        from circuit_extract import Pipeline

        p = Pipeline(style_override="textbook")
        path = tmp_path / "clean.png"

        import cv2
        cv2.imwrite(str(path), clean_image)

        graph = p.run(path)
        assert isinstance(graph, CircuitGraph)
        assert graph.version == "1.0"

    def test_pipeline_respects_style_override(self, clean_image, tmp_path):
        from circuit_extract import Pipeline

        path = tmp_path / "test.png"
        import cv2
        cv2.imwrite(str(path), clean_image)

        for style in ("handdrawn", "textbook", "datasheet"):
            p = Pipeline(style_override=style)
            graph = p.run(path)
            assert graph.metadata.detected_style == style

    def test_pipeline_output_is_serializable(self, clean_image, tmp_path):
        from circuit_extract import Pipeline

        p = Pipeline(style_override="textbook")
        path = tmp_path / "test.png"
        import cv2
        cv2.imwrite(str(path), clean_image)

        graph = p.run(path)
        json_str = graph.to_json()
        restored = CircuitGraph.from_json(json_str)
        assert restored.version == graph.version

    def test_pipeline_nonexistent_file_raises(self):
        from circuit_extract import Pipeline

        p = Pipeline()
        with pytest.raises(FileNotFoundError):
            p.run("/nonexistent/image.png")
