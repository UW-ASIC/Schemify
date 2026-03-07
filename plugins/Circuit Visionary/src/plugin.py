"""CircuitVision Schemify plugin — JSON-RPC entry point.

Integrates the CircuitVision pipeline with the Schemify editor via the
JSON-RPC protocol defined in scripts/schemify.py.

The editor calls init → tick → deinit over stdin/stdout.
On init, we preload models. On tick, we check for pending extraction requests
(submitted via a request file). Results are written to a response file that
the Zig ImportPlugin reads.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def _load_schemify_sdk() -> None:
    here = Path(__file__).resolve().parent
    root = here.parent.parent.parent
    scripts = root / "scripts"
    sys.path.insert(0, str(scripts))
    sys.path.insert(0, str(here))


_load_schemify_sdk()
import schemify  # noqa: E402

_pipeline = None
_work_dir: Path = Path(".")


def init() -> None:
    global _pipeline, _work_dir

    schemify.log("CircuitVision: loading pipeline")

    _work_dir = Path(os.environ.get("SCHEMIFY_PROJECT_DIR", "."))
    queue_dir = _work_dir / ".circuitvision"
    queue_dir.mkdir(exist_ok=True)

    # Defer heavy imports until init to keep startup fast.
    # If dependencies aren't installed, log the error but don't crash —
    # the plugin will report "not ready" on extraction requests.
    try:
        from circuit_extract import Pipeline

        model_dir = os.environ.get("CIRCUITVISION_MODEL_DIR")
        _pipeline = Pipeline(model_dir=model_dir)
        schemify.log("CircuitVision: pipeline ready")
    except ImportError as e:
        schemify.log(f"CircuitVision: missing dependency — {e}")
        schemify.log("CircuitVision: run `pip install -r requirements.txt`")
    except Exception as e:
        schemify.log(f"CircuitVision: init error — {e}")


def tick(dt: float) -> None:
    """Check for pending extraction requests."""
    _ = dt
    if _pipeline is None:
        return

    request_file = _work_dir / ".circuitvision" / "request.json"
    if not request_file.exists():
        return

    try:
        req = json.loads(request_file.read_text(encoding="utf-8"))
        request_file.unlink()

        image_path = req.get("image_path", "")
        style = req.get("style")
        schemify.log(f"CircuitVision: extracting {image_path}")

        graph = _pipeline.run(
            image_path,
        )

        response_file = _work_dir / ".circuitvision" / "response.json"
        response_file.write_text(graph.to_json(), encoding="utf-8")
        schemify.log(
            f"CircuitVision: done — {len(graph.components)} components, "
            f"{len(graph.nets)} nets"
        )
    except Exception as e:
        schemify.log(f"CircuitVision: extraction failed — {e}")
        error_response = _work_dir / ".circuitvision" / "response.json"
        error_response.write_text(
            json.dumps({"error": str(e)}), encoding="utf-8"
        )


def deinit() -> None:
    schemify.log("CircuitVision: unloaded")


if __name__ == "__main__":
    schemify.run(
        name="CircuitVision",
        init=init,
        tick=tick,
        deinit=deinit,
    )
