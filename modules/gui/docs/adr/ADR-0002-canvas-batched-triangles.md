# ADR-0002: Canvas Rendering via LineBatch + renderTriangles

## Status: accepted

## Context

The schematic canvas must render thousands of line segments (wires, symbol outlines, pin markers, grid dots) every frame. dvui provides `dvui.Path.stroke()` for individual lines, but calling it per-segment causes one draw call per element — too slow for schematics with hundreds of instances.

## Decision

All canvas geometry is collected into a `LineBatch` struct that builds vertex/index arrays in memory, then emits a single `dvui.renderTriangles()` call per batch. Each line segment is expanded into a screen-space quad (4 vertices, 6 indices) on the CPU. Filled polygons use simple ear-clipping (fan triangulation from first vertex). Grid dots use the same `Triangles.Builder` path.

Text labels are deferred into a `LabelList` and drained after the batch flush, so text always renders on top of geometry.

## Consequences

- One or two draw calls per frame for all schematic geometry (wires batch + symbols batch), regardless of element count.
- All geometry is computed on the CPU every frame — no GPU-side vertex caching. Acceptable because schematic element counts are typically <10k.
- Line thickness is screen-space, not world-space. Zooming changes element density but not visual stroke width. This is intentional for readability.
- Circles and arcs cannot be batched — they use `dvui.Path.stroke()` with polyline approximation. These are rare (only in symbol geometry) so the per-call overhead is acceptable.
- The `LineBatch` allocates from dvui's LIFO (stack) allocator, so there is no per-frame heap allocation for normal rendering.
