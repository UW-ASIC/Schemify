"""Tests for the component detector."""

import pytest

from circuit_graph import BBox
from detector import ComponentDetector, Detection, YOLO_CLASS_MAP


class TestDetection:
    def test_center(self):
        d = Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=100, y=200, w=50, h=30))
        cx, cy = d.center
        assert cx == 125.0
        assert cy == 215.0


class TestComponentDetector:
    def test_no_model_returns_empty(self, clean_image):
        det = ComponentDetector()
        results = det.detect(clean_image)
        assert results == []

    def test_class_map_contiguous(self):
        indices = sorted(YOLO_CLASS_MAP.keys())
        assert indices == list(range(len(indices)))

    def test_class_map_covers_common_types(self):
        names = set(YOLO_CLASS_MAP.values())
        for required in ["resistor", "capacitor", "nmos", "pmos", "opamp", "ground"]:
            assert required in names, f"Missing {required} in YOLO class map"

    def test_confidence_threshold(self):
        det = ComponentDetector(confidence_threshold=0.8)
        assert det.conf_thresh == 0.8

    def test_iou_threshold(self):
        det = ComponentDetector(iou_threshold=0.3)
        assert det.iou_thresh == 0.3
