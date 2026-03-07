"""VLM Verifier — optional visual language model cross-check.

Uses Claude or GPT-4o to verify extracted circuit topology against the
original image. The VLM sees the labeled image and the extracted component
list, then flags misidentifications or missing connections.

This is based on SINA's and Masala-CHAI's approach of using GPT-4o for
designator assignment and verification. We make it optional because it adds
latency and API cost.
"""

from __future__ import annotations

import base64
import json
import logging
from pathlib import Path
from typing import Optional

from circuit_graph import CircuitGraph, Warning, WarningType

log = logging.getLogger(__name__)

VERIFICATION_PROMPT = """\
You are a circuit analysis expert. I have extracted components from a schematic image using computer vision. Please verify the extraction.

## Extracted Components
{component_list}

## Extracted Nets
{net_list}

## Instructions
1. Look at the schematic image carefully
2. For each extracted component, verify: correct type, correct reference designator, correct value
3. Check if any components were missed
4. Check if any connections (nets) appear wrong
5. Pay special attention to MOSFET terminal assignments (G, D, S, B)

Respond with a JSON array of issues found. Each issue should have:
- "type": one of "wrong_type", "wrong_ref", "wrong_value", "missing_component", "wrong_connection", "wrong_terminal"
- "component_id": the affected component (if applicable)
- "message": brief description
- "confidence": your confidence in this finding (0.0-1.0)

If everything looks correct, return an empty array: []
"""


class VLMVerifier:
    def __init__(self, *, backend: str = "claude"):
        self.backend = backend

    def verify(
        self,
        image_path: Path | str,
        graph: CircuitGraph,
    ) -> list[Warning]:
        """Send the image + extracted data to a VLM for verification."""
        image_path = Path(image_path)

        component_list = self._format_components(graph)
        net_list = self._format_nets(graph)

        prompt = VERIFICATION_PROMPT.format(
            component_list=component_list,
            net_list=net_list,
        )

        try:
            if self.backend == "claude":
                response = self._call_claude(image_path, prompt)
            elif self.backend == "openai":
                response = self._call_openai(image_path, prompt)
            else:
                log.warning("Unknown VLM backend: %s", self.backend)
                return []

            return self._parse_response(response)

        except ImportError as e:
            log.warning("VLM backend not available: %s", e)
            return []
        except Exception as e:
            log.warning("VLM verification failed: %s", e)
            return []

    def _format_components(self, graph: CircuitGraph) -> str:
        lines = []
        for c in graph.components:
            pins = ", ".join(p.name for p in c.pins)
            lines.append(
                f"- {c.id}: {c.type} ref={c.ref} value={c.value} "
                f"conf={c.confidence:.2f} pins=[{pins}]"
            )
        return "\n".join(lines)

    def _format_nets(self, graph: CircuitGraph) -> str:
        lines = []
        for n in graph.nets:
            name = f" ({n.name})" if n.name else ""
            lines.append(f"- {n.id}{name}: {', '.join(n.pins)}")
        return "\n".join(lines)

    def _call_claude(self, image_path: Path, prompt: str) -> str:
        import anthropic

        client = anthropic.Anthropic()
        image_data = base64.standard_b64encode(image_path.read_bytes()).decode("utf-8")
        suffix = image_path.suffix.lower().lstrip(".")
        media_type = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}.get(
            suffix, "image/png"
        )

        message = client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=4096,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": image_data,
                            },
                        },
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
        )
        return message.content[0].text

    def _call_openai(self, image_path: Path, prompt: str) -> str:
        import openai

        client = openai.OpenAI()
        image_data = base64.standard_b64encode(image_path.read_bytes()).decode("utf-8")
        suffix = image_path.suffix.lower().lstrip(".")
        media_type = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}.get(
            suffix, "image/png"
        )

        response = client.chat.completions.create(
            model="gpt-4o",
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:{media_type};base64,{image_data}",
                            },
                        },
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
            max_tokens=4096,
        )
        return response.choices[0].message.content

    def _parse_response(self, response: str) -> list[Warning]:
        # Extract JSON array from response (may be wrapped in markdown code fences)
        text = response.strip()
        if "```" in text:
            parts = text.split("```")
            for part in parts:
                part = part.strip()
                if part.startswith("json"):
                    part = part[4:].strip()
                if part.startswith("["):
                    text = part
                    break

        try:
            issues = json.loads(text)
        except json.JSONDecodeError:
            log.warning("Could not parse VLM response as JSON")
            return []

        warnings: list[Warning] = []
        for issue in issues:
            warnings.append(
                Warning(
                    type=WarningType.LOW_CONFIDENCE_DETECTION.value,
                    message=f"[VLM] {issue.get('message', 'unknown issue')}",
                    component_id=issue.get("component_id"),
                    confidence=issue.get("confidence", 0.5),
                )
            )

        log.info("VLM verification: %d issues found", len(warnings))
        return warnings
