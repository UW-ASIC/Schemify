"""Per-style image preprocessors."""

from .handdrawn import HanddrawnPreprocessor
from .textbook import TextbookPreprocessor
from .datasheet import DatasheetPreprocessor

PREPROCESSORS = {
    "handdrawn": HanddrawnPreprocessor,
    "textbook": TextbookPreprocessor,
    "datasheet": DatasheetPreprocessor,
}

__all__ = [
    "HanddrawnPreprocessor",
    "TextbookPreprocessor",
    "DatasheetPreprocessor",
    "PREPROCESSORS",
]
