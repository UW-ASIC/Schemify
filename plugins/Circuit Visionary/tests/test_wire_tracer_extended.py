"""Extended wire tracer tests — complex geometries and edge cases."""

import cv2
import numpy as np
import pytest

from circuit_graph import BBox, Point
from detector import Detection
from wire_tracer import WireTracer


class TestWireTracerComplex:
    @pytest.fixture
    def tracer(self):
        return WireTracer(min_wire_length=10)

    def test_l_shaped_wire(self, tracer):
        """An L-shaped wire should produce at least one segment."""
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 150), (150, 150), (0, 0, 0), 2)
        cv2.line(img, (150, 150), (150, 50), (0, 0, 0), 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1
        total_points = sum(len(s.points) for s in segments)
        assert total_points > 10

    def test_t_junction(self, tracer):
        """A T-junction wire pattern."""
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 150), (250, 150), (0, 0, 0), 2)  # horizontal
        cv2.line(img, (150, 150), (150, 50), (0, 0, 0), 2)   # vertical up

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1

    def test_parallel_wires(self, tracer):
        """Two parallel horizontal wires should yield two segments."""
        img = np.ones((300, 400, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 100), (350, 100), (0, 0, 0), 2)
        cv2.line(img, (50, 200), (350, 200), (0, 0, 0), 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 2

    def test_diagonal_wire(self, tracer):
        """A diagonal wire should still be traced."""
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 50), (250, 250), (0, 0, 0), 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1

    def test_crossing_wires(self, tracer):
        """Two crossing wires should produce segments."""
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 150), (250, 150), (0, 0, 0), 2)
        cv2.line(img, (150, 50), (150, 250), (0, 0, 0), 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1

    def test_thick_wire(self, tracer):
        """A thick wire (4px) should still skeletonize to a single path."""
        img = np.ones((200, 400, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 100), (350, 100), (0, 0, 0), 4)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1

    def test_multiple_masked_components(self, tracer):
        """Masking multiple components should leave wire gaps."""
        img = np.ones((200, 600, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 100), (550, 100), (0, 0, 0), 2)

        dets = [
            Detection(class_name="resistor", confidence=0.9, bbox=BBox(x=150, y=85, w=80, h=30)),
            Detection(class_name="capacitor", confidence=0.9, bbox=BBox(x=350, y=85, w=30, h=30)),
        ]
        segments = tracer.trace(img, detections=dets)
        assert isinstance(segments, list)

    def test_grayscale_input(self, tracer):
        """Single-channel grayscale input should work."""
        img = np.ones((200, 400), dtype=np.uint8) * 255
        cv2.line(img, (50, 100), (350, 100), 0, 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1

    def test_noisy_image_still_traces(self, tracer):
        """Noisy image should still find major wire paths."""
        rng = np.random.default_rng(42)
        img = np.ones((300, 400, 3), dtype=np.uint8) * 240
        noise = rng.integers(-15, 15, img.shape, dtype=np.int16)
        img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
        # Draw a strong line through the noise
        cv2.line(img, (50, 150), (350, 150), (0, 0, 0), 3)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1


class TestFitSegmentsExtended:
    @pytest.fixture
    def tracer(self):
        return WireTracer(min_wire_length=5)

    def test_vertical_points(self, tracer):
        points = [Point(x=100, y=y) for y in range(0, 200)]
        segments = tracer._fit_segments(points)
        assert len(segments) == 1
        assert segments[0].start.x == 100
        assert segments[0].end.x == 100

    def test_diagonal_points(self, tracer):
        points = [Point(x=i, y=i) for i in range(0, 200)]
        segments = tracer._fit_segments(points)
        assert len(segments) == 1

    def test_empty_points(self, tracer):
        segments = tracer._fit_segments([])
        assert segments == []

    def test_two_points(self, tracer):
        points = [Point(x=0, y=0), Point(x=100, y=0)]
        segments = tracer._fit_segments(points)
        assert len(segments) == 1
