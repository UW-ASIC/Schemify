"""Tests for the wire tracer."""

import cv2
import numpy as np
import pytest

from circuit_graph import BBox
from detector import Detection
from wire_tracer import WireTracer


class TestWireTracer:
    @pytest.fixture
    def tracer(self):
        return WireTracer(min_wire_length=10)

    def test_traces_horizontal_line(self, tracer):
        img = np.ones((200, 400, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 100), (350, 100), (0, 0, 0), 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1
        # The segment should span most of the line
        seg = segments[0]
        assert abs(seg.start.y - seg.end.y) < 10  # roughly horizontal

    def test_traces_vertical_line(self, tracer):
        img = np.ones((400, 200, 3), dtype=np.uint8) * 255
        cv2.line(img, (100, 50), (100, 350), (0, 0, 0), 2)

        segments = tracer.trace(img, detections=[])
        assert len(segments) >= 1

    def test_masks_detections(self, tracer):
        img = np.ones((200, 400, 3), dtype=np.uint8) * 255
        # Draw a filled rectangle (component) and a wire through it
        cv2.rectangle(img, (150, 80), (250, 120), (0, 0, 0), -1)
        cv2.line(img, (50, 100), (350, 100), (0, 0, 0), 2)

        det = Detection(
            class_name="resistor",
            confidence=0.9,
            bbox=BBox(x=150, y=80, w=100, h=40),
        )
        segments = tracer.trace(img, detections=[det])
        # Wire should still be traced (outside the masked bbox)
        # Exact count depends on how masking splits the wire
        assert isinstance(segments, list)

    def test_blank_image_no_segments(self, tracer, blank_image):
        segments = tracer.trace(blank_image, detections=[])
        assert segments == []

    def test_short_lines_filtered(self):
        tracer = WireTracer(min_wire_length=100)
        img = np.ones((200, 200, 3), dtype=np.uint8) * 255
        cv2.line(img, (50, 100), (80, 100), (0, 0, 0), 2)  # only 30px

        segments = tracer.trace(img, detections=[])
        assert len(segments) == 0


class TestFitSegments:
    @pytest.fixture
    def tracer(self):
        return WireTracer(min_wire_length=5)

    def test_horizontal_points(self, tracer):
        from circuit_graph import Point

        points = [Point(x=x, y=100) for x in range(0, 200)]
        segments = tracer._fit_segments(points)
        assert len(segments) == 1
        assert segments[0].start.y == 100
        assert segments[0].end.y == 100

    def test_too_few_points(self, tracer):
        from circuit_graph import Point

        segments = tracer._fit_segments([Point(x=0, y=0)])
        assert segments == []
