"""Tests for the crossing classifier."""

import numpy as np
import pytest

from circuit_graph import Point, Style
from crossing_classifier import (
    CrossingClassifier,
    CrossingType,
    WireSegment,
)


class TestSegmentIntersection:
    @pytest.fixture
    def classifier(self):
        return CrossingClassifier()

    def test_perpendicular_segments_intersect(self, classifier):
        seg_a = WireSegment(
            start=Point(x=0, y=50), end=Point(x=100, y=50), points=[]
        )
        seg_b = WireSegment(
            start=Point(x=50, y=0), end=Point(x=50, y=100), points=[]
        )
        pt = classifier._segment_intersection(seg_a, seg_b)
        assert pt is not None
        assert abs(pt.x - 50) < 2
        assert abs(pt.y - 50) < 2

    def test_parallel_segments_no_intersection(self, classifier):
        seg_a = WireSegment(
            start=Point(x=0, y=50), end=Point(x=100, y=50), points=[]
        )
        seg_b = WireSegment(
            start=Point(x=0, y=60), end=Point(x=100, y=60), points=[]
        )
        pt = classifier._segment_intersection(seg_a, seg_b)
        assert pt is None

    def test_non_overlapping_segments(self, classifier):
        seg_a = WireSegment(
            start=Point(x=0, y=0), end=Point(x=10, y=0), points=[]
        )
        seg_b = WireSegment(
            start=Point(x=50, y=0), end=Point(x=50, y=10), points=[]
        )
        pt = classifier._segment_intersection(seg_a, seg_b)
        assert pt is None


class TestHeuristicClassification:
    @pytest.fixture
    def classifier(self):
        return CrossingClassifier()

    def test_dark_blob_means_connected(self, classifier):
        img = np.ones((100, 100, 3), dtype=np.uint8) * 255
        import cv2
        # Large filled dot — clearly a junction marker
        cv2.circle(img, (50, 50), 7, (0, 0, 0), -1)

        ctype, conf = classifier._classify_heuristic(img, Point(x=50, y=50), Style.TEXTBOOK)
        assert ctype in (CrossingType.CONNECTED, CrossingType.AMBIGUOUS)

    def test_clean_crossing_textbook_means_unconnected(self, classifier):
        img = np.ones((100, 100, 3), dtype=np.uint8) * 255
        import cv2
        cv2.line(img, (0, 50), (100, 50), (0, 0, 0), 1)
        cv2.line(img, (50, 0), (50, 100), (0, 0, 0), 1)

        ctype, conf = classifier._classify_heuristic(img, Point(x=50, y=50), Style.TEXTBOOK)
        assert ctype in (CrossingType.PLAIN_UNCONNECTED, CrossingType.AMBIGUOUS)

    def test_handdrawn_crossing_is_ambiguous(self, classifier):
        img = np.ones((100, 100, 3), dtype=np.uint8) * 255
        import cv2
        cv2.line(img, (0, 50), (100, 50), (0, 0, 0), 2)
        cv2.line(img, (50, 0), (50, 100), (0, 0, 0), 2)

        ctype, conf = classifier._classify_heuristic(img, Point(x=50, y=50), Style.HANDDRAWN)
        assert ctype in (CrossingType.AMBIGUOUS, CrossingType.PLAIN_UNCONNECTED)


class TestFindIntersections:
    @pytest.fixture
    def classifier(self):
        return CrossingClassifier()

    def test_two_crossing_wires(self, classifier):
        seg_h = WireSegment(
            start=Point(x=0, y=50), end=Point(x=100, y=50), points=[]
        )
        seg_v = WireSegment(
            start=Point(x=50, y=0), end=Point(x=50, y=100), points=[]
        )
        results = classifier._find_intersections([seg_h, seg_v])
        assert len(results) == 1
        loc, indices = results[0]
        assert 0 in indices and 1 in indices

    def test_no_intersections(self, classifier):
        seg_a = WireSegment(
            start=Point(x=0, y=0), end=Point(x=10, y=0), points=[]
        )
        seg_b = WireSegment(
            start=Point(x=50, y=50), end=Point(x=60, y=50), points=[]
        )
        results = classifier._find_intersections([seg_a, seg_b])
        assert len(results) == 0
