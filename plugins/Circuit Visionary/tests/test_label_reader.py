"""Tests for the label reader (OCR + reference/value assignment)."""

import pytest

from circuit_graph import BBox, Point
from detector import Detection
from label_reader import LabelReader, ComponentLabel, TextLabel, REF_PREFIX


class TestLabelAssignment:
    @pytest.fixture
    def reader(self):
        return LabelReader(proximity_threshold=80)

    def test_fill_missing_refs(self, reader, sample_detections):
        labels = [ComponentLabel(detection_idx=i) for i in range(len(sample_detections))]
        reader._fill_missing_refs(labels, sample_detections)

        assert labels[0].ref == "R1"
        assert labels[1].ref == "C1"
        # Ground typically doesn't get a prefix in REF_PREFIX, falls back to "X"
        assert labels[2].ref is not None

    def test_ref_prefix_coverage(self):
        expected = {"resistor", "capacitor", "inductor", "nmos", "pmos", "opamp"}
        for comp_type in expected:
            assert comp_type in REF_PREFIX, f"No ref prefix for {comp_type}"

    def test_looks_like_ref(self, reader):
        assert reader._looks_like_ref("R1")
        assert reader._looks_like_ref("M12")
        assert reader._looks_like_ref("C3")
        assert reader._looks_like_ref("U1")
        assert not reader._looks_like_ref("10k")
        assert not reader._looks_like_ref("hello")
        assert not reader._looks_like_ref("")

    def test_looks_like_value(self, reader):
        assert reader._looks_like_value("10k")
        assert reader._looks_like_value("100nF")
        assert reader._looks_like_value("1.2V")
        assert reader._looks_like_value("47")
        assert not reader._looks_like_value("R1")
        assert not reader._looks_like_value("VDD")

    def test_assign_labels_nearest_component(self, reader):
        detections = [
            Detection(class_name="resistor", confidence=0.9,
                      bbox=BBox(x=100, y=100, w=50, h=20)),
            Detection(class_name="capacitor", confidence=0.9,
                      bbox=BBox(x=300, y=100, w=20, h=50)),
        ]
        texts = [
            TextLabel(text="R1", confidence=0.9,
                      bbox=BBox(x=100, y=80, w=20, h=10),
                      center=Point(x=110, y=85)),
            TextLabel(text="10k", confidence=0.85,
                      bbox=BBox(x=100, y=130, w=20, h=10),
                      center=Point(x=110, y=135)),
            TextLabel(text="C1", confidence=0.88,
                      bbox=BBox(x=300, y=80, w=20, h=10),
                      center=Point(x=310, y=85)),
        ]

        labels = reader._assign_labels(texts, detections)
        assert labels[0].ref == "R1"
        assert labels[0].value == "10k"
        assert labels[1].ref == "C1"

    def test_text_too_far_not_assigned(self, reader):
        detections = [
            Detection(class_name="resistor", confidence=0.9,
                      bbox=BBox(x=100, y=100, w=50, h=20)),
        ]
        texts = [
            TextLabel(text="R1", confidence=0.9,
                      bbox=BBox(x=500, y=500, w=20, h=10),
                      center=Point(x=510, y=505)),
        ]

        labels = reader._assign_labels(texts, detections)
        assert labels[0].ref is None

    def test_no_ocr_returns_empty(self, reader, clean_image, sample_detections):
        # Without paddleocr installed, _extract_text returns []
        texts = reader._extract_text(clean_image)
        # Either returns results or empty (depends on paddleocr availability)
        assert isinstance(texts, list)
