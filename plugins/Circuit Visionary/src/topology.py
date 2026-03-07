"""Topology Builder — constructs a CircuitGraph from pipeline stage outputs.

This is the final assembly stage. It takes detections, wire segments,
crossings, and labels, and produces a CircuitGraph with:
- Components (with pins, refs, values)
- Nets (groups of pins connected by wires)
- Warnings (ambiguities, low confidence, etc.)
"""

from __future__ import annotations

import logging
from collections import defaultdict
from typing import Optional

from circuit_graph import (
    CircuitGraph,
    Component,
    Net,
    Pin,
    Warning,
    WarningType,
    Style,
    DEFAULT_PINS,
    Point,
)
from crossing_classifier import Crossing, CrossingType, WireSegment
from detector import Detection
from label_reader import ComponentLabel

log = logging.getLogger(__name__)

PROXIMITY_THRESHOLD = 30  # pixels — max distance from wire endpoint to pin


class TopologyBuilder:
    def build(
        self,
        *,
        detections: list[Detection],
        wire_segments: list[WireSegment],
        crossings: list[Crossing],
        labels: list[ComponentLabel],
        style: Style,
    ) -> CircuitGraph:
        """Assemble a CircuitGraph from all pipeline stage outputs."""

        # 1. Create components from detections + labels
        components = self._build_components(detections, labels)

        # 2. Build pin position map (pin_id → approximate pixel location)
        pin_positions = self._estimate_pin_positions(components, detections)

        # 3. Build connectivity graph from wires
        #    Each wire endpoint is associated with the nearest pin
        net_groups = self._trace_connectivity(
            pin_positions, wire_segments, crossings
        )

        # 4. Create Net objects
        nets = self._build_nets(net_groups, labels, detections)

        # 5. Generate warnings
        warnings = self._generate_warnings(components, nets, crossings, labels)

        graph = CircuitGraph(
            components=components,
            nets=nets,
            warnings=warnings,
        )

        errors = graph.validate()
        for e in errors:
            log.warning("Validation: %s", e)

        return graph

    def _build_components(
        self,
        detections: list[Detection],
        labels: list[ComponentLabel],
    ) -> list[Component]:
        components: list[Component] = []

        for i, det in enumerate(detections):
            # Skip annotation-type detections
            if det.class_name in ("junction_dot", "crossing_bridge", "no_connect", "test_point"):
                continue

            comp_id = f"comp_{i:03d}"
            label = labels[i] if i < len(labels) else None

            pins = [
                Pin.for_component(comp_id, name)
                for name in DEFAULT_PINS.get(det.class_name, ["1", "2"])
            ]

            components.append(
                Component(
                    id=comp_id,
                    type=det.class_name,
                    ref=label.ref if label else None,
                    value=label.value if label else None,
                    confidence=det.confidence,
                    pins=pins,
                    source_bbox=det.bbox,
                )
            )

        return components

    def _estimate_pin_positions(
        self,
        components: list[Component],
        detections: list[Detection],
    ) -> dict[str, Point]:
        """Estimate pin positions based on component bbox and standard layouts.

        For 2-pin components: pins at midpoints of opposing edges.
        For transistors: gate on left, drain on top, source on bottom.
        """
        positions: dict[str, Point] = {}

        det_map = {}
        for i, det in enumerate(detections):
            comp_id = f"comp_{i:03d}"
            det_map[comp_id] = det

        for comp in components:
            det = det_map.get(comp.id)
            if not det:
                continue

            b = det.bbox
            cx = b.x + b.w // 2
            cy = b.y + b.h // 2

            pin_names = [p.name for p in comp.pins]

            if len(pin_names) == 2:
                if b.w >= b.h:
                    positions[comp.pins[0].id] = Point(x=b.x, y=cy)
                    positions[comp.pins[1].id] = Point(x=b.x + b.w, y=cy)
                else:
                    positions[comp.pins[0].id] = Point(x=cx, y=b.y)
                    positions[comp.pins[1].id] = Point(x=cx, y=b.y + b.h)

            elif comp.type in ("nmos", "pmos"):
                positions[f"{comp.id}.G"] = Point(x=b.x, y=cy)
                positions[f"{comp.id}.D"] = Point(x=cx, y=b.y)
                positions[f"{comp.id}.S"] = Point(x=cx, y=b.y + b.h)

            elif comp.type in ("nmos4", "pmos4"):
                positions[f"{comp.id}.G"] = Point(x=b.x, y=cy)
                positions[f"{comp.id}.D"] = Point(x=cx, y=b.y)
                positions[f"{comp.id}.S"] = Point(x=cx, y=b.y + b.h)
                positions[f"{comp.id}.B"] = Point(x=b.x + b.w, y=cy)

            elif comp.type in ("npn", "pnp"):
                positions[f"{comp.id}.B"] = Point(x=b.x, y=cy)
                positions[f"{comp.id}.C"] = Point(x=cx, y=b.y)
                positions[f"{comp.id}.E"] = Point(x=cx, y=b.y + b.h)

            elif comp.type in ("opamp", "comparator"):
                positions[f"{comp.id}.IN+"] = Point(x=b.x, y=b.y + b.h * 3 // 4)
                positions[f"{comp.id}.IN-"] = Point(x=b.x, y=b.y + b.h // 4)
                positions[f"{comp.id}.OUT"] = Point(x=b.x + b.w, y=cy)
                positions[f"{comp.id}.V+"] = Point(x=cx, y=b.y)
                positions[f"{comp.id}.V-"] = Point(x=cx, y=b.y + b.h)

            elif len(pin_names) == 1:
                positions[comp.pins[0].id] = Point(x=cx, y=cy)

        return positions

    def _trace_connectivity(
        self,
        pin_positions: dict[str, Point],
        wire_segments: list[WireSegment],
        crossings: list[Crossing],
    ) -> list[set[str]]:
        """Build net groups using union-find on wire connectivity.

        A wire endpoint near a pin connects that pin to the wire's net.
        Connected crossings merge the nets of the intersecting wires.
        """
        # Union-Find
        parent: dict[str, str] = {}

        def find(x: str) -> str:
            while parent.get(x, x) != x:
                parent[x] = parent.get(parent[x], parent[x])
                x = parent[x]
            return x

        def union(a: str, b: str) -> None:
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[ra] = rb

        # Initialize every pin as its own set
        for pid in pin_positions:
            parent[pid] = pid

        # Wire-id proxies for segments not yet connected to pins
        wire_proxies: dict[int, str] = {}
        for idx, seg in enumerate(wire_segments):
            proxy = f"__wire_{idx}"
            parent[proxy] = proxy
            wire_proxies[idx] = proxy

        # Connect wire endpoints to nearest pins
        for idx, seg in enumerate(wire_segments):
            proxy = wire_proxies[idx]
            for endpoint in (seg.start, seg.end):
                nearest_pin, dist = self._nearest_pin(endpoint, pin_positions)
                if nearest_pin and dist < PROXIMITY_THRESHOLD:
                    union(proxy, nearest_pin)

        # Process crossings: connected junctions merge wire nets
        for crossing in crossings:
            if crossing.type == CrossingType.CONNECTED:
                if len(crossing.segments) >= 2:
                    first = wire_proxies.get(crossing.segments[0])
                    for seg_idx in crossing.segments[1:]:
                        other = wire_proxies.get(seg_idx)
                        if first and other:
                            union(first, other)

        # Group pins by root
        groups: dict[str, set[str]] = defaultdict(set)
        for pid in pin_positions:
            root = find(pid)
            groups[root].add(pid)

        # Filter out singleton nets and proxy-only groups
        result = [
            pins for pins in groups.values()
            if len(pins) >= 2
        ]
        return result

    def _nearest_pin(
        self, point: Point, pin_positions: dict[str, Point]
    ) -> tuple[Optional[str], float]:
        best_id: Optional[str] = None
        best_dist = float("inf")
        for pid, pos in pin_positions.items():
            d = ((point.x - pos.x) ** 2 + (point.y - pos.y) ** 2) ** 0.5
            if d < best_dist:
                best_dist = d
                best_id = pid
        return best_id, best_dist

    def _build_nets(
        self,
        groups: list[set[str]],
        labels: list[ComponentLabel],
        detections: list[Detection],
    ) -> list[Net]:
        nets: list[Net] = []
        for i, pin_set in enumerate(groups):
            pins = sorted(pin_set)
            net = Net(id=f"net_{i:03d}", pins=pins)

            # Check if any connected component is a power/ground symbol
            for pid in pins:
                comp_id = pid.rsplit(".", 1)[0]
                idx_str = comp_id.split("_")[-1]
                try:
                    idx = int(idx_str)
                    if idx < len(detections):
                        dtype = detections[idx].class_name
                        if dtype in ("vdd", "vcc"):
                            net.name = dtype.upper()
                        elif dtype in ("vss", "ground"):
                            net.name = "GND" if dtype == "ground" else "VSS"
                except (ValueError, IndexError):
                    pass

            nets.append(net)

        return nets

    def _generate_warnings(
        self,
        components: list[Component],
        nets: list[Net],
        crossings: list[Crossing],
        labels: list[ComponentLabel],
    ) -> list[Warning]:
        warnings: list[Warning] = []

        # Low confidence detections
        for comp in components:
            if comp.confidence < 0.7:
                warnings.append(
                    Warning(
                        type=WarningType.LOW_CONFIDENCE_DETECTION.value,
                        message=f"{comp.ref or comp.id}: {comp.type} at {comp.confidence:.2f}",
                        component_id=comp.id,
                        confidence=comp.confidence,
                    )
                )

        # Ambiguous crossings
        for crossing in crossings:
            if crossing.type == CrossingType.AMBIGUOUS:
                warnings.append(
                    Warning(
                        type=WarningType.AMBIGUOUS_CROSSING.value,
                        message="Wire crossing without explicit junction marker",
                        location=crossing.location,
                        confidence=crossing.confidence,
                        assumed="unconnected",
                    )
                )

        # Auto-generated references (low OCR confidence)
        for label in labels:
            if label.ref and label.ref_confidence == 0.0:
                warnings.append(
                    Warning(
                        type=WarningType.OCR_UNCERTAIN.value,
                        message=f"Auto-generated ref {label.ref} — verify manually",
                        confidence=0.0,
                    )
                )

        # Unconnected pins
        connected_pins = {pid for net in nets for pid in net.pins}
        for comp in components:
            for pin in comp.pins:
                if pin.id not in connected_pins:
                    # Power/ground symbols with 1 pin are expected to have it in a net
                    if comp.type in ("ground", "vdd", "vss", "vcc"):
                        warnings.append(
                            Warning(
                                type=WarningType.UNCONNECTED_PIN.value,
                                message=f"Power symbol {comp.ref or comp.id} not connected",
                                component_id=comp.id,
                            )
                        )

        return warnings
