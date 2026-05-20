# A1: Connectivity Engine

## Goal
Union-find connectivity resolver. Pure fn: `(&Schematic, &Rodeo) -> Connectivity`. Pre-computes everything once, cached in `Document`.

## Branch
`feat/connectivity`

## Decisions (resolved)
- `Connectivity` struct → lives in `core/src/types.rs` (cross-boundary type, ADR-001)
- `resolve()` logic → lives in `handler/src/connectivity.rs`
- Fat result: pre-compute nets, point-to-net map, per-instance connections, net names
- `InstanceFlags::transform_point(x, y) -> (i32, i32)` → add to core (trivial, ADR-001 ok)
- Sim receives `&Connectivity` as arg from handler — sim never computes connectivity
- Invalidation flag already wired in dispatch (`doc.connectivity = None` on mutation)

## Zig Reference Files
- `../Schemify/src/schematic/connectivity.zig` — union-find, net resolution
- `../Schemify/src/schematic/helpers.zig` — rotation/flip transform math
- `../Schemify/src/schematic/types.zig` — Conn, Net, NetConn, NetMap

## Crate/File Map

### core (`crates/core/src/`)
- `types.rs` — add `Connectivity` struct, `Net`, `PinConnection`, `NetConnKind`
- `types.rs` — add `InstanceFlags::transform_point(&self, x: i32, y: i32) -> (i32, i32)`

### handler (`crates/handler/src/`)
- NEW `connectivity.rs` — `pub fn resolve(sch: &Schematic, interner: &Rodeo) -> Connectivity`
- `lib.rs` — add `mod connectivity;`, expose via `App` accessor
- `state.rs` — `Document.connectivity` already exists, ensure type matches new core struct

## Connectivity Struct (in core)

```rust
pub struct Connectivity {
    /// All resolved nets
    pub nets: Vec<Net>,
    /// Point (x,y) → net index
    pub point_to_net: HashMap<(i32, i32), usize>,
    /// Per-instance: vec of pin connections (instance_idx → connections)
    pub instance_connections: Vec<Vec<PinConnection>>,
    /// Net index → resolved name
    pub net_names: Vec<String>,
}

pub struct Net {
    pub name: String,
    pub connections: Vec<NetEndpoint>,
}

pub struct NetEndpoint {
    pub x: i32,
    pub y: i32,
    pub kind: NetConnKind,
}

pub enum NetConnKind {
    WireEndpoint { wire_idx: usize },
    InstancePin { instance_idx: usize, pin_name: String },
    Label { name: String },
}

pub struct PinConnection {
    pub pin_name: String,
    pub net_idx: usize,
    pub x: i32,
    pub y: i32,
}
```

## Algorithm (from Zig ref)
1. Init union-find: each wire endpoint = node keyed by `(x, y)`
2. Merge wire endpoints: same `(x,y)` → same set
3. T-junction detection: wire interior point touching another wire endpoint → merge
4. Instance pins: for each instance, get pin positions from `PrimEntry`, apply `transform_point` with instance rotation/flip, translate to instance `(x,y)` → merge pin position with existing nodes
5. Label assignment: explicit `wire.net_name` wins, else auto `n0, n1, ...`
6. Build output: walk union-find roots, collect per-net connections, build per-instance connection list

## transform_point logic
```
rotation 0:              ( x,  y)
rotation 1 (90 CW):      ( y, -x)
rotation 2 (180):         (-x, -y)
rotation 3 (270 CW):     (-y,  x)
flip (after rotation):    (-x,  y)
```

## Checklist
- [ ] Add `Connectivity` + related types to `core/src/types.rs`
- [ ] Add `InstanceFlags::transform_point()` to `core/src/types.rs`
- [ ] Create `handler/src/connectivity.rs` with `resolve()` fn
- [ ] Union-find with path compression + union by rank
- [ ] Wire endpoint merging
- [ ] T-junction detection (point on wire interior)
- [ ] Instance pin resolution (PrimEntry lookup + transform)
- [ ] Net naming (explicit label priority > auto)
- [ ] Wire `handler/src/lib.rs` accessor: `pub fn connectivity(&mut self) -> &Connectivity`
- [ ] Update `Document.connectivity` type in state.rs
- [ ] Tests: simple 2-wire net
- [ ] Tests: T-junction merge
- [ ] Tests: labeled net overrides auto name
- [ ] Tests: rotated instance pin positions
- [ ] Tests: flipped instance pin positions
- [ ] Commit after each meaningful change

## Do NOT Touch
- `dispatch.rs` — invalidation already wired
- `display/` — not your crate
- `sim/` — not your crate
- Don't add logic beyond `transform_point` to core
