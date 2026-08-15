# Citadel Interior NavMesh Publication Plan

## Purpose

Repair generated-building interior navigation without changing the mature NPC
route authority, motor, collision proof, door traversal, or recovery systems.

The target is simple: an NPC standing at a furnished interior bed must receive
the same collision-backed, server-owned NavMesh route quality as an NPC
standing on ordinary outdoor terrain. The route must reach the real interior
door endpoint, open the door, cross it, and continue outside through the
existing production route stack.

This plan is controlling only for explicitly authorised navigation/pathfinding
work. `MANIFESTO.md` remains the higher-level stability contract.

## Current Evidence

Known failing replay:

```text
seed: 208158
Citadel scale: 1.25
runner: node tools/run-citadel-life-playtest.mjs --acceptance
```

The evidence rules out NPC scale, motor execution, furniture-only blockage,
door state, and missing portal ownership as the primary cause.

- `artifacts/npc/reports/citadel-life-server-link-attachment-v56.json` proves
  that the server owns the route start, door endpoints, support-seam endpoints,
  and interior-passage endpoints at zero distance. It also showed hundreds of
  Godot NavMesh edge-merge errors from overlapping support faces.
- `artifacts/npc/reports/citadel-life-stacked-support-v58.json` proves that
  suppressing lower stacked support faces removes those warnings and reduces
  published polygons from `4,556` to `2,065`. The headed NPC acceptance still
  fails because the final interior floor graph remains fragmented before the
  door.
- The v58 diagnostics prove the existing support-seam link, interior-passage
  link, door link, and exterior terrain path all work in isolation. A combined
  interior-to-exterior server route still fails with `path_endpoint_mismatch`.
- The support-cell diagnostic reports one collision-safe component from bed to
  door, but the server NavMesh cannot traverse the equivalent floor geometry.
  Therefore the defect is NavMesh publication/topology, not semantic route
  selection or physical furniture access.
- `artifacts/npc/reports/citadel-life-unified-tile-v64.json` proves that
  unifying flat support samples per tile preserves the collision-safe floor
  facts and modestly reduces publication cost, but does not repair the broken
  combined route. For the first failing home, every start, seam, passage,
  door, and exterior endpoint remains server-owned at zero distance; the
  server path still stops `3.59m` short of the interior door endpoint.
- The focused V65/V66 controls prove that a NavLink between regions is not
  usable when its owner region and the far endpoint region publish in the
  wrong order, even when the link endpoints are inset on valid surfaces.
  V67 proves the same link succeeds when the owner region is freshly
  published after the far region already exists.
- `artifacts/npc/reports/navmesh-cross-region-link-v70.json` is the current
  server-functional regression. It proves the production lifecycle: owner
  first yields one pending link; after a synchronization barrier the service
  rebuilds that owner from its descriptor; the fresh link then routes across
  both directions. This is topology evidence only, not headed NPC acceptance.
- `artifacts/npc/reports/navmesh-cross-region-link-v86.json` extends that
  proof through endpoint-region unload and restoration: the link becomes
  `pending_navigation_links`, then its owner rebuild reconnects it in both
  directions. The focused fixture, nav-world suite, route suite, and door
  suite are green after this change; none are live-game acceptance evidence.
- Three headed replays of the same seed remain failed:
  `citadel-life-staged-links-v81.json`, `citadel-life-staged-links-v84.json`,
  and `citadel-life-staged-links-v88.json`. Each observes all 12 citizens
  inside at night and none outside during the day. V84 identified unrelated
  pending links as an overly broad route gate; V88 scopes that gate to local
  endpoints, yet 40 of 42 server path queries still fail. The first sampled
  residences now fail as `no_route` or `path_endpoint_mismatch` with no
  route-local pending link, so global pending-link gating is not the remaining
  explanation.
- Focused mature-town route and door suites pass. The production route stack
  remains the reference implementation and must not be replaced.

### Current Hold Point

Do not make another link-geometry, endpoint-inset, or route-policy change
until a read-only audit explains the V88 production topology failure. The
next investigation must capture, for each failing residence, the exact
published tile descriptors, topology revisions, final region RIDs, resolved
support/passage/seam endpoints, and server-owned closest points at the time of
the failed path query. It must also explain why the V88 service records only
13 installed regions but 20,532 registered regions. This may reveal descriptor
publication churn or an ownership/revision boundary that the focused fixture
does not exercise.

Resume implementation only after that audit identifies one authoritative
publication defect and a focused fixture reproduces it. A fourth headed replay
without that evidence is not useful.

## Authority And Target Architecture

Navigation data must continue to derive from the same building and furnishing
facts that publish real collision. The building publisher does not create
scene-specific navigation meshes from visuals.

```text
BuildingPart + furnishing collision facts
  -> building/furnishing navigation manifests
  -> unified tile walkability compiler
  -> conforming NavigationServer3D region mesh
  -> staged cross-region link transaction + server synchronization
  -> route-readiness validation
  -> NPC-ready home/door records
```

The key change is the **unified tile walkability compiler**. It must compile
one topologically coherent floor representation for every affected nav tile,
instead of publishing separately sampled mini-meshes for foundations, paving,
board floors, and room parts that overlap in the same physical footprint.

## Invariants

- Building support, terrain, wall, door, and furnishing collision remain the
  source of truth. No visual-mesh scan, guessed floor, or parallel nav-only
  building representation is permitted.
- The final server NavMesh has at most one selected walkable floor inside a
  local stacked-floor band at any horizontal sample. A true upper storey stays
  separate when it has usable vertical clearance.
- The compiler must account for furniture collision, while furnishing layout
  must reserve each required bed-to-interior-door corridor. Furniture may not
  turn a valid generated home into an inaccessible home.
- Door, interior-passage, stair, and cross-tile seam endpoints must resolve to
  an inset point on a final published NavMesh face, not an authored coordinate
  or a pre-publication support sample.
- A home is `ready` only after its interior-to-door-to-exterior route has been
  proven by the server graph. Before then it is `pending_nav_data`; it is not
  `unreachable_static`.
- Production behavior must not use direct movement, teleports, generated-cell
  bridges, composed manual door routes, named-NPC behavior, widened link
  radii, or partial-endpoint success to hide a publication failure.
- The change must preserve deterministic generation and normal outdoor/town
  routing behaviour.

## Implementation Phases

### Phase 1: Build One Walkability Ownership Map Per Tile

1. Gather terrain and building support candidates for the whole nav tile.
2. Rasterize candidates at the existing building-support resolution, with each
   sample carrying its physical top surface, normal, headroom, and collision
   clearance.
3. Select one deterministic owner for overlapping near-level supports. This
   removes buried foundations and paving while retaining a genuinely separate
   upper storey.
4. Apply furnishing, wall, door-frame, and other static collision exclusion to
   the selected map.
5. Keep the selected surface facts inspectable in the tile diagnostic report.

**Completion gate:** no overlapping stacked floor surfaces are emitted for the
same walkability sample, and the compiler output is deterministic for replayed
building manifests.

### Phase 2: Emit A Single Conforming Interior Mesh

1. Replace per-support row-strip emission with one conforming mesh emission
   pass over the selected tile map.
2. Share vertices and split boundaries consistently across every selected
   floor contributor in that tile; do not leave T-junctions or duplicate edges.
3. Keep polygon counts bounded through contour/rectangle merging. Do not
   regress to one NavMesh polygon per `0.32m` sample.
4. Preserve real gaps at walls, furnishings, stairs, and tile boundaries.

**Completion gate:** Godot emits no NavMesh edge-merge warnings for the
replayed Citadel, and the interior floor mesh is connected exactly where the
collision-safe ownership map is connected.

### Phase 3: Bind Portals To Final Mesh Faces

1. Publish regions in a staged state and synchronize `NavigationServer3D`.
2. Resolve each required door, interior-passage, stair, and support-seam anchor
   against the final server-owned face for its tile.
3. Require a valid owner region and a bounded inset distance for both endpoints
   before enabling a link.
4. Retain a cross-region link as `pending_nav_data` until all affected region
   meshes exist and one server synchronization pass has elapsed.
5. Rebuild the link-owner region from its authoritative descriptor, then
   create the resolved link during that fresh owner publication. Godot does not
   reliably attach a link appended to an already-published owner region.
6. Record the final face/region/position used by every enabled or pending
   link, including required and missing regions.

**Completion gate:** every required endpoint is server-owned and routes into
its adjacent floor surface, not merely through the link when queried from the
link endpoint itself.

### Phase 4: Validate A Home As One Topology Transaction

1. Stage all tiles and links required for a residence and its exterior landing.
2. Run read-only server-path validation from each bed/home anchor through its
   interior passage and door to an exterior standable point.
3. Mark the home NPC-ready only when all required paths end within the normal
   production endpoint tolerance and identify the expected door portal.
4. If publication is incomplete, retain the command as `pending_nav_data` and
   retry on a topology revision; do not poison it as static failure.
5. Release staged regions/links atomically on removal or replacement, defer
   dependent links, and replay their owner transaction when requirements
   return so no stale route graph remains.

**Completion gate:** generated home readiness includes valid collision,
interior, door, exterior, and server-route evidence before NPC schedules may
issue departure orders.

### Phase 5: Protect Required Furniture Corridors

1. Make furnishing generation consume the residence navigation manifest's
   required access corridors.
2. Reject or relocate a proposed furnishing placement that intersects a
   protected bed-to-door or doorway-clearance lane.
3. Keep furnishing collision in the unified walkability compiler so ordinary
   furniture still blocks real navigation elsewhere.
4. Add deterministic layout contracts for a doorway and bed access corridor.

**Completion gate:** furniture never blocks a resident from reaching the
interior door or clearing its threshold, while ordinary furniture remains a
real collision/navigation obstacle.

## Verification Sequence

Run each stage against the known failing seed before broadening coverage.

1. Deterministic manifest and tile-compiler contract tests. These prove source
   facts, selected walkability ownership, link anchors, and bounded geometry;
   they are not gameplay acceptance.
2. Focused NavigationServer fixture proving a complete cross-region route
   after owner-first pending publication, one synchronization barrier, and a
   fresh owner-region rebuild. The fixture must verify both directions and
   that no pending link remains:

   ```powershell
   VOXEL_CROSS_REGION_LINK_REPORT=artifacts/npc/reports/navmesh-cross-region-link.json VOXEL_CROSS_REGION_LINK_RUN_TOKEN=manual /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --scene res://scenes/testing/npc/NavmeshCrossRegionLinkTest.tscn
   ```
3. Existing mature route and door regression suites:

   ```powershell
   node tools/npc/run-npc-route-tests.mjs -TimeMode Both
   node tools/npc/run-npc-door-tests.mjs -TimeMode Both
   node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both
   ```

4. Headed Citadel replay with screenshots and diagnostics:

   ```powershell
   VOXEL_CITADEL_TERRAIN_READY_MAX_FRAMES=3600 node tools/run-citadel-life-playtest.mjs --seed 208158 --citadel-scale 1.25 --acceptance --timeout-seconds 600
   ```

5. Fresh random generated-town/Citadel seeds when the replay is green.
6. A full main-menu -> New Game headed playthrough if this publication path is
   used by the tutorial town.

The headed acceptance must prove all residents leave their strict interior
through the real door by day, then return to strict interior bounds at night.
It must include the command, report path, screenshots, route/link diagnostics,
and a concise explanation of what the result proves.

## Explicit Non-Goals

- Replacing `NpcRouteAuthorityV2`, the motor, door service, or route planner.
- Creating Citadel-only or named-NPC movement logic.
- Increasing `LINK_CONNECTION_RADIUS` to bridge unproven gaps.
- Accepting a partial NavMesh path and appending a target point.
- Reintroducing a collision-lattice planner or manual route composition in
  production.
- Treating synthetic tests or metadata as a substitute for headed gameplay.
