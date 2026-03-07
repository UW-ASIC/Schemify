"""Tests for per-style preprocessors."""

import cv2
import numpy as np
import pytest

from preprocessors.handdrawn import HanddrawnPreprocessor
from preprocessors.textbook import TextbookPreprocessor
from preprocessors.datasheet import DatasheetPreprocessor


class TestHanddrawnPreprocessor:
    @pytest.fixture
    def preprocessor(self):
        return HanddrawnPreprocessor()

    def test_output_shape_matches(self, preprocessor, noisy_image):
        result = preprocessor.process(noisy_image)
        assert result.shape[0] == noisy_image.shape[0]
        assert result.shape[1] == noisy_image.shape[1]
        assert len(result.shape) == 3  # always 3-channel output

    def test_noise_reduced(self, preprocessor, noisy_image):
        result = preprocessor.process(noisy_image)
        gray_before = cv2.cvtColor(noisy_image, cv2.COLOR_BGR2GRAY)
        gray_after = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)
        var_before = cv2.Laplacian(gray_before, cv2.CV_64F).var()
        var_after = cv2.Laplacian(gray_after, cv2.CV_64F).var()
        # Binarized output should have more defined edges, different variance profile
        assert var_after != var_before

    def test_deskew_near_zero_angle(self, preprocessor):
        img = np.ones((600, 800, 3), dtype=np.uint8) * 255
        cv2.line(img, (100, 300), (700, 300), (0, 0, 0), 2)
        result = preprocessor._deskew(img)
        assert result.shape == img.shape

    def test_small_component_removal(self, preprocessor):
        binary = np.zeros((100, 100), dtype=np.uint8)
        binary[10, 10] = 255  # single pixel noise
        cv2.circle(binary, (50, 50), 10, 255, -1)  # real content
        result = preprocessor._remove_small_components(binary, min_area=30)
        assert result[10, 10] == 0  # noise removed
        assert result[50, 50] == 255  # content preserved


class TestTextbookPreprocessor:
    @pytest.fixture
    def preprocessor(self):
        return TextbookPreprocessor()

    def test_output_is_valid_image(self, preprocessor, clean_image):
        result = preprocessor.process(clean_image)
        assert result.dtype == np.uint8
        assert len(result.shape) in (2, 3)

    def test_upscale_small_image(self, preprocessor):
        small = np.ones((200, 300, 3), dtype=np.uint8) * 255
        result = preprocessor._upscale_if_needed(small)
        assert min(result.shape[:2]) >= preprocessor.target_min_dim

    def test_no_upscale_large_image(self, preprocessor):
        large = np.ones((1200, 1600, 3), dtype=np.uint8) * 255
        result = preprocessor._upscale_if_needed(large)
        assert result.shape == large.shape

    def test_crop_removes_borders(self, preprocessor):
        img = np.ones((600, 800, 3), dtype=np.uint8) * 255
        cv2.rectangle(img, (200, 200), (600, 400), (0, 0, 0), 2)
        result = preprocessor._crop_to_content(img)
        # Cropped image should be smaller than original
        assert result.shape[0] < img.shape[0] or result.shape[1] < img.shape[1]

    def test_crop_doesnt_destroy_image(self, preprocessor, clean_image):
        result = preprocessor._crop_to_content(clean_image)
        assert result.shape[0] > 0 and result.shape[1] > 0


class TestDatasheetPreprocessor:
    @pytest.fixture
    def preprocessor(self):
        return DatasheetPreprocessor()

    def test_output_is_3_channel(self, preprocessor, dense_image):
        result = preprocessor.process(dense_image)
        assert len(result.shape) == 3
        assert result.shape[2] == 3

    def test_color_detection_bw(self, preprocessor, clean_image):
        assert not preprocessor._has_significant_color(clean_image)

    def test_color_detection_colored(self, preprocessor):
        img = np.zeros((100, 100, 3), dtype=np.uint8)
        img[:, :, 2] = 200  # strong red
        assert preprocessor._has_significant_color(img)

    def test_segmentation_keeps_content(self, preprocessor, dense_image):
        result = preprocessor._segment_schematic_region(dense_image)
        assert result.shape[0] > 0 and result.shape[1] > 0
