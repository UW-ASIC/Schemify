"""Tests for the style classifier — heuristic and CNN-based."""

import numpy as np
import pytest

from circuit_graph import Style
from style_classifier import StyleClassifier


class TestHeuristicClassifier:
    """Tests using the heuristic fallback (no model weights needed)."""

    @pytest.fixture
    def classifier(self):
        return StyleClassifier()

    def test_noisy_image_classified_as_handdrawn(self, classifier, noisy_image):
        style, conf = classifier.classify(noisy_image)
        # Noisy image should lean toward hand-drawn
        assert style in (Style.HANDDRAWN, Style.UNKNOWN)
        assert 0.0 <= conf <= 1.0

    def test_clean_image_returns_valid(self, classifier, clean_image):
        style, conf = classifier.classify(clean_image)
        assert isinstance(style, Style)
        assert 0.0 <= conf <= 1.0

    def test_dense_image_returns_valid(self, classifier, dense_image):
        style, conf = classifier.classify(dense_image)
        assert isinstance(style, Style)
        assert 0.0 <= conf <= 1.0

    def test_blank_image_returns_valid_style(self, classifier, blank_image):
        style, conf = classifier.classify(blank_image)
        assert isinstance(style, Style)
        assert 0.0 <= conf <= 1.0

    def test_grayscale_input(self, classifier):
        gray = np.ones((600, 800), dtype=np.uint8) * 200
        style, conf = classifier.classify(gray)
        assert isinstance(style, Style)

    def test_confidence_is_normalized(self, classifier, clean_image):
        _, conf = classifier.classify(clean_image)
        assert 0.0 <= conf <= 1.0

    def test_small_image(self, classifier):
        small = np.ones((50, 50, 3), dtype=np.uint8) * 200
        style, _ = classifier.classify(small)
        assert isinstance(style, Style)
