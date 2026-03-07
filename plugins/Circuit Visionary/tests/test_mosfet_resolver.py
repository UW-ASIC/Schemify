"""Tests for the MOSFET terminal resolver."""

import cv2
import numpy as np
import pytest

from circuit_graph import BBox
from detector import Detection
from mosfet_resolver import MOSFETResolver, TerminalAssignment


class TestMOSFETResolver:
    @pytest.fixture
    def resolver(self):
        return MOSFETResolver()

    def test_passthrough_non_mosfet(self, resolver, sample_detections, clean_image):
        result = resolver.resolve(sample_detections, clean_image)
        assert len(result) == len(sample_detections)
        assert result[0].class_name == "resistor"

    def test_resolves_mosfet(self, resolver, mosfet_detections, clean_image):
        result = resolver.resolve(mosfet_detections, clean_image)
        assert len(result) == 3
        # MOSFETs should still be nmos or pmos type
        assert result[0].class_name in ("nmos", "pmos")

    def test_resolve_returns_terminal_assignment(self, resolver):
        det = Detection(
            class_name="nmos",
            confidence=0.9,
            bbox=BBox(x=100, y=100, w=60, h=80),
        )
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        # Draw a simple MOSFET-like symbol
        cv2.line(img, (100, 140), (130, 140), (0, 0, 0), 2)  # gate line
        cv2.line(img, (130, 100), (130, 180), (0, 0, 0), 2)  # channel

        assignment = resolver._resolve_terminals(det, img)
        assert isinstance(assignment, TerminalAssignment)
        assert assignment.gate is not None
        assert assignment.drain is not None
        assert assignment.source is not None

    def test_4pin_mosfet_has_body(self, resolver):
        det = Detection(
            class_name="nmos4",
            confidence=0.9,
            bbox=BBox(x=100, y=100, w=60, h=80),
        )
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        assignment = resolver._resolve_terminals(det, img)
        assert assignment.body is not None

    def test_3pin_mosfet_no_body(self, resolver):
        det = Detection(
            class_name="nmos",
            confidence=0.9,
            bbox=BBox(x=100, y=100, w=60, h=80),
        )
        img = np.ones((300, 300, 3), dtype=np.uint8) * 255
        assignment = resolver._resolve_terminals(det, img)
        assert assignment.body is None

    def test_empty_bbox_handled(self, resolver):
        det = Detection(
            class_name="nmos",
            confidence=0.9,
            bbox=BBox(x=0, y=0, w=0, h=0),
        )
        img = np.ones((10, 10, 3), dtype=np.uint8) * 255
        assignment = resolver._resolve_terminals(det, img)
        assert isinstance(assignment, TerminalAssignment)
