# Spatial world streaming and rendering architecture

Approved implementation plan, 2026-09-10. Baseline: 2c71199. Work branch:
codex/world-streaming-architecture, in the existing citadel-visuals worktree.

## Acceptance contract

- Cold New Game/Continue: playable nearby world within 90 seconds of visible input.
- Required area: 64m horizontal radius, expanded for structural support, crossings
  and scenario dependencies. Tutorial retains complete town/actor readiness.
- 60 FPS at 1920x1080 on the RTX 5060 Ti, including ordinary sprint traversal.
  Five-minute observations: p99 <=33ms, no recurring streaming stalls >33ms,
  no frame >100ms. Measure rendering CPU/GPU and frame cadence independently.
- Preserve near geometry, material character, terrain solidity and interaction IDs.
  Distant interiors/cosmetic detail may remain pending. Record full-site completion
  separately; do not relabel partial readiness as complete citadel readiness.
- Cold means fresh process and empty generated-artifact caches; warm runs separate.
- User explicitly authorizes terrain/structure publication changes to navigation;
  route search, movement, door execution and traffic behavior remain protected.

## Ordered cutovers

1. Extend existing observations: monotonic frame cadence, rendering CPU/GPU,
   draw/primitive counts, worker work, upload/registration and queue latency.
   Capture startup, approach, courtyard, forest, sprinting and unloading.
2. Extend BuildingPublicationPreparation/BuildingScenePublicationJob to compile
   final spatial geometry/transform/custom-data buffers on owned workers. Preserve
   full-resolution physical output and existing readiness for this first cutover.
3. Introduce regional dependency-complete readiness and composed scheduling.
4. Add source-derived building LOD, conservative wall occluders and shared tree
   batching through the existing production tree grammar/detail system.
5. Profile remaining generation costs; move dominating pure geometry/voxel work
   into the existing native extension. Terrain LOD is a separate verified cutover,
   never an unmeasured simplification/backend toggle.

## Contracts

Render packets bind seed, source revision, durable edits, recipe/material version,
spatial cell and detail tier. Initial grid: 32 terrain cells / 43.2m, XZ. Keep native
terrain blocks and navigation tiles on their own grids with explicit intersections.
Stable part owners and cross-cell references prevent duplicate collision/interaction
objects. Group by spatial cell/material/geometry family; preserve instance data and
part ownership. Main thread uploads/attaches bounded segments; keep the previous
visual until its replacement is complete. Keep the 4ms cooperative budget initially;
split oversized atomic operations before increasing throughput. Preserve one-shot
consumption, stale rejection, weak ownership, cancellation and worker retirement.

The composed coordinator prioritizes existing owners; it is not a geometry or
readiness authority. Interfaces: request_region(bounds, priority, reason),
region_readiness(bounds) -> ready/pending/failed with dependencies and revisions,
release_region(request_id). Retain retryable demand under backpressure.

Regional readiness requires validated source and terrain changes, prepared visuals,
collision and interaction artifacts, safe publication outside occupied geometry,
then revision-matched navigation acknowledgement for all necessary crossings. Audit
terrain/door/stair/porch/seam ownership before changing publication. Do not revive
the rejected native navigation-bake replacement. Cosmetic expansion may not discover
new physical obligations. Preserve determinism across staging and cancellation.

Priority: safety/edits, required scenario/interactions, predicted traversal, visible
detail, background refinement. Predict ten seconds ahead from movement/facing;
retain a surrounding ring for reversals, an extra region ring and ten-second unload
hysteresis. Bound queues/memory without dropping demanded work. Surface loading
feedback rather than expose unsafe territory; acceptance traversal must not stall.

Visual distances from camera to bounds: near 0-96m full quality, middle 96-192m
simpler decoration/reduced small shadows, far 192-384m source-derived silhouettes
and coarse terrain/vegetation. Retire unneeded visuals beyond that while preserving
demanded gameplay. Keep apertures, landings and collision readable at transitions.
Occluders derive conservatively from opaque geometry and exclude movable doors.

## Verification and delivery

Batch fixes/checks around cutovers, using existing Node/owned-watchdog runners and
early headed inspections. Preserve baseline artifacts. Every launch proves zero
owned members. Tests cover deterministic near-output parity; lifecycle/cancellation,
stale packets, edits during compilation, reversals, unloading and shutdown; real
gate/door/stair/region movement and NPC navigation acknowledgement; real menu New
Game/Continue, save/reload/dig/build/harvest; day/night and LOD/occlusion visuals.

Final load samples: three cold known-citadel-seed runs plus one each of two fresh
seeds, all <=90s. Run broad playtest and affected navigation/lifecycle suites at
each production cutover. Baseline failures stay explicitly attributed; regressions
block promotion. Teleports are diagnostic setup, not continuous-travel acceptance.
Commit verified milestones, remove superseded production paths after cutover,
retain one world authority, preserve save format v2 and durable deltas.

## Progress

- Baseline committed and branch created.
- Phase 1 measurement milestone verified: composed opt-in render/cadence observer,
  explicit 1080p runner options, actual stretched-window size verification, and
  corrected ordinary-menu fixture input/cleanup. Baseline evidence and limits:
  `WORLD_STREAMING_MEASUREMENTS_2026-09-10.md`. Full citadel readiness remains
  152.814s in the teleport diagnostic; measured ordinary traversal fails the new pacing contract. Five-minute
  coverage, unloading and final cold-cache acceptance remain outstanding.
- First phase-2 portion implemented: worker-prepared immutable masonry segments
  and one-buffer static batch uploads, preserving completed-part boundaries,
  geometry/collision/material order and lifecycle. Exact headed source/count
  parity passed; total publication time did not materially improve.
- Initial-location diagnostic now selects the player position before attachment
  and terrain streaming, with zero subsequent teleports. Known candidate sample:
  83.373s current startup readiness, 134.274s full scene-ready. This is not the
  new 64m readiness contract or flag-free menu acceptance. Evidence, limits and
  attributed broad/NPC failures: WORLD_STREAMING_PACKETS_AND_INITIAL_SPAWN_2026-09-10.md.
- Spatial owner/cell grouping was implemented and measured at matching cameras,
  but not promoted: extra submissions did not consistently pay for their culling
  benefit. Production grouping remains f780e2c. Preserve the complete experiment
  and comparison in WORLD_STREAMING_SPATIAL_GROUPING_EXPERIMENT_2026-09-10.md.
  The existing headed runner now records settled overview/courtyard/door phases.
- Worker-owned masonry records now carry write revisions and deeply frozen
  recipes. Authoring inputs remain mutable. In the production diagnostic,
  prepared lookup fell from 637ms to 15ms and total publication CPU from 12.79s
  to 11.74s with exact source/instance/collider parity. Current startup was
  82.543s; scene-ready capture was 127.030s. This is one sample, not the 64m/90s
  contract, and publication still exceeds the 4ms cooperative budget. Evidence
  and regression outcomes: WORLD_STREAMING_OWNED_RECORDS_2026-09-10.md.
- Paving and roof geometry/final buffers now prepare on the existing worker.
  Shared paving batches retain all instances/colliders and reduce MultiMeshes
  from 1548 to 1477. Headed initial-spawn sample: 80.048s current startup,
  122.318s scene-ready; neither proves regional gameplay readiness. Broad replay
  161/163 with recorded asset/headless-capture failures. See
  WORLD_STREAMING_SURFACE_WORKERS_2026-09-10.md for commands, costs and limitations.
- The user's New Game/Continue timing distinction makes the cold 90s target
  provisional; measure cold creation, cached Continue and exploration separately.
  No replacement threshold has been chosen. Preserve the playable-radius and
  traversal requirements regardless of startup target.
- Next: add exact navigation publication acknowledgements and regional dependency
  closure, while addressing measured publication validation costs and submission
  fragmentation before reintroducing spatial subdivision, then regional
  dependency closure with real revision-matched navigation acknowledgements.
  The owner inventory and broad reference replay are in that report. The spatial
  candidate additionally stopped on an engine RID error that did not recur in
  the reference replay; that failure remains unresolved and blocks its reuse.
  Keep the cooperative budget and use initial-location startup measurements.
