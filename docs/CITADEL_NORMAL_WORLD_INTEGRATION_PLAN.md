# Citadel Normal-World Integration

## Decision

The citadel is a seeded landmark in the ordinary survival world. The existing
citadel life fixture is not an authority: after migration it observes a normal
world citadel and drives ordinary player/NPC behaviour only.

## Immutable Manifest

`CitadelSiteManifestPlanner` uses an explicit 420-cell region grid, a
seed-derived existence roll, deterministic interior candidates and exact
reserved bounds. Its stable ID, placement, level, footprint radius, blueprint
seed, prop exclusion bounds and immutable terrain operations are the source
for all later work. The planner does not publish geometry and is intentionally
inactive until every consuming authority is wired.

Eligibility receives a natural-terrain sample record, not a height guess:
`surfaceY`, solidness, fluid and biome must all be valid across the entire
foundation and approach envelope. Candidate envelopes are constrained to their
own region with a one-cell gap, so implicit citadels never require cross-region
winner arbitration and existence cannot depend on load/query order. Town and
typed landmark reservations reject a candidate; story placement consumes the
same landmark field and moves to another deterministic candidate rather than
silently deleting the citadel.

The production catalog resolves exactly one region candidate against complete
nearby town reservations and typed landmarks. Direct landmark registration is
fail-closed against typed overlap.

The manifest must be visible to `VoxelWorldGenerationContext` before workers
generate affected chunks. Its `flatten_disc` and `grade_approaches` terrain
operations must update terrain volume material, solidity, collision, lighting
and prop exclusion from the same record before meshing. Town records remain
town-only; citadel records need a typed landmark registry/query and must not
change tutorial-town biome, home or readiness semantics. Registration rejects
overlap with town and typed landmarks through one deterministic spatial
conflict policy.

Worker contexts share one mutex-protected, single-flight manifest cache.
Opaque leases, heartbeats and retry-on-stale publication prevent a timed-out
worker from returning or publishing a second result. Missing cache, prewarm
dependencies or worker generation callbacks report through a shared typed
terrain-failure authority; runtime readiness and terrain publication then fail
closed instead of treating the failure as an empty landmark region.

## Publication Contract

`StructureSystem` owns the normal-world scan and existing frame-budget queue.
The implemented first publication slice consumes the exact manifest, builds
the shared castle blueprint, and sends one source part per queued operation
through `BuildingPartPublisher`; it does not copy the PoC generator or create a
second scene authority. Pure recipe construction runs as an accounted worker
job; reset retains retired jobs until completion and prevents a same-site
replacement from starting concurrently. Navigation and exact door portal IDs
remain retryable and are recorded for symmetric reset cleanup. A terminal
failure retires the visual/collision root rather than leaving unregistered
geometry in the world. The remaining lifecycle is:

1. Register the seed-derived manifest before terrain generation.
2. Reserve terrain/foundation and wait for affected voxel collision.
3. Publish the sampled castle blueprint incrementally through
   `BuildingPartPublisher`.
4. Register the produced building-navigation manifest and exact published door
   bodies through existing `NpcSystem` public APIs.
5. Publish residents through ordinary home/schedule interfaces only after the
   collision and navigation records are ready.
6. Acknowledge installed topology and door registration before releasing any
   resident spawn/order request.
7. On unload/reset, cancel retained work and unregister the same navigation
   and door IDs before freeing their scene nodes.

The state machine is `queued -> terrain_ready -> collision_verified ->
doors_registered -> navigation_acknowledged -> residents_released -> playable`.
Every pending dependency is retained with bounded retry counters and a
site-scoped terminal failure report.

No fixture-owned terrain, collision probes, direct NPC movement, `main.blocks`
door injection, or separate nav graph is permitted.

## Acceptance Sequence

- Before wiring, record unchanged NPC contract/all-suite and headed generated
  world baselines. Rerun the identical firewall after each terrain or
  publication change.
- Seed/manifest contract proves stable IDs, spawn density, unique
  non-overlapping bounds, protected-site exclusion, full footprint support and
  seed variation.
- Normal `New Game` headed run approaches the streamed citadel, crosses a real
  player-operated gate, and confirms terrain/collision continuity.
- A real NPC lifecycle run proves generic citizen movement, door traversal and
  indoor night return without protected routing changes.
- Departure/re-entry and save/reload prove deterministic reconstruction with
  durable world deltas retained.
- Known plus fresh random seeds, existing NPC baselines and a representative
  runtime performance observation remain clean.
