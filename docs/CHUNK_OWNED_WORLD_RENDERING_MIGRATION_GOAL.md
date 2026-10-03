# Chunk-owned world rendering migration goal

Status: **Active; initial chunk-priority and static-source/readiness cutovers are present in the master worktree. Full migration remains incomplete.**

## Goal

Migrate the presentation of static, non-mob world content to chunk-owned render
publications. When terrain for a visible chunk is ready, its trees, ground
plants, natural props, and static generated structures should be prepared and
published through that chunk's rendering lifecycle instead of appearing later
through a chain of independent per-object visual queues.

The inspiration is Minecraft Java 26.3's section renderer: its block section
compiler builds visible block and fluid geometry by render layer, prioritizes
near sections, compiles work asynchronously, and uploads completed geometry to
shared GPU buffers. Trees, plants, and block-built structures participate
because they are represented by block states. Minecraft still renders mobs as
independent entities. Our migration should adopt the useful chunk publication
boundary without copying Minecraft code or replacing our procedural world
authorities.

## Target architecture

```text
world seed + durable edits
  -> existing authoritative terrain, tree, ecology, and structure systems
  -> immutable chunk render packet(s), keyed by source revision and render tier
  -> worker-side geometry preparation and chunk/material/layer batching
  -> bounded GPU upload and revision-checked installation
  -> chunk-owned static world visuals

actors (mobs, wildlife, NPCs, player)
  -> existing actor simulation, collision, and independent entity rendering
```

The chunk packet is a presentation artifact, not another world authority. It
must be built from owned value data and bind its seed, source revision, durable
edits, recipe/material version, chunk identity, and detail tier. Worker inputs
must not contain Nodes, RIDs, WeakRefs, or Callables. A stale, cancelled, or
partially uploaded packet cannot replace the last valid visual. Upload,
installation, retirement, and memory use must remain bounded and observable.

Spatial chunking owns render batching and publication. It does not force the
terrain volume, building descriptions, tree recipes, collision shapes,
interaction records, or navigation to share one grid or representation. Keep
their existing authorities and join them through explicit chunk intersections
and stable source ownership. Cross-chunk objects need one declared owner or
explicit per-chunk visual fragments so they neither disappear at boundaries
nor publish twice.

Chunk readiness must distinguish source generation, packet preparation, GPU
upload, installed visibility, and gameplay dependencies. Loading feedback follows
the current runtime contract: initial near-field readiness and the
camera-facing coarse horizon band gate startup; the surrounding render cache
continues in the background. This goal does not add a fixed kilometre startup
gate or require uploading off-screen high-detail geometry.

## Category cutovers

1. **Terrain and coordinator boundary.** Inventory current native terrain
   chunk/LOD publication and define how its accepted render artifact participates
   in the chunk readiness report. Preserve terrain volume, collision, digging,
   light, and save authority.
2. **Trees.** Consume the canonical deterministic tree recipes and publish static
   branch/foliage batches by chunk, material, and LOD. Keep gameplay trunks,
   stable IDs, removal, and recipe generation under their current owners. The
   existing `TreeChunkBatchRenderer` is a prototype only: its prior decision
   records costly slot-swap removal and fixed-capacity memory, so do not promote
   it until bounded removal, capacity/backpressure, culling, and live traversal
   performance are demonstrated.
3. **Ground flora and natural props.** Move their visual preparation and
   installation into the chunk packet path, preserving deterministic placement,
   ecology policy, harvesting/removal, and prop identity. Do not use a test-only
   or visual-only duplicate to hide delayed production content.
4. **Generated buildings and static structure visuals.** Adapt existing
   building batches into chunk-owned render artifacts. Keep structure recipes,
   doors, collision, interactions, and navigation dependencies under their
   current authorities. Split or reference cross-boundary geometry with
   revisioned ownership rather than duplicating gameplay records.
5. **Actors and dynamic visuals.** Keep mobs, wildlife actors, NPCs, and the
   player on independent entity/simulation paths. Dynamic weather, particles,
   held items, and other transient presentation are not static chunk geometry;
   they may reference chunk state but retain their appropriate lifecycle.
6. **Retirement.** Remove superseded static visual queues only after each
   category has production parity, headed evidence, safe cancellation/unload,
   and no lost demand. There must remain one source of truth for every visible
   result.

## Required evidence and acceptance

- Same seed and durable edits produce the same complete static content,
  identities, interactions, and source geometry regardless of worker order,
  cancellation/retry, approach direction, or chunk unload/reload.
- For a visible chunk, terrain and its required static trees, flora, props, and
  structures publish from revision-matched chunk artifacts. Readiness reports
  identify the exact pending producer, upload stage, owner, and source revision.
- Headed screenshots and continuous player traversal show no prolonged bare
  ground after terrain readiness, missing tree crowns, chunk-edge duplication,
  visual holes, unsafe collision gaps, or stale visuals after edits/removal.
- Compare matched seed, viewport, camera path, detail settings, and cache state.
  Report time-to-visible-content, queue latency/depth, CPU frame cadence, render
  CPU/GPU timings, draw submissions, memory, and upload/retirement costs
  separately. Worker time is not main-thread time. Include sprint traversal and
  unloading; check worst-frame and tail cadence, not only averages.
- Preserve existing performance targets and run the relevant deterministic,
  lifecycle, save/reload, structure, tree, and headed gameplay coverage at each
  production cutover. A synthetic or prototype runner alone is not acceptance.
- Mobs and NPCs remain present, animated, simulated, and independently culled
  according to their existing gameplay rules; static batching cannot create a
  second actor authority or suppress required actors.

## Planning relationships and limits

This goal extends, but does not silently replace, the ordered cutovers and
acceptance contracts in `WORLD_STREAMING_ARCHITECTURE_PLAN.md`. Reconcile it with
`WORLD_STREAMING_MATURITY_MIGRATION_PLAN_2026-09-14.md` before implementation and
follow that plan's checkout, baseline, and gate requirements. Preserve the
procedural tree decision in `vegetation/VOX_134_PROCEDURAL_TREE_RENDERER_DECISION.md`;
the current production hybrid renderer remains authoritative until a replacement
passes its evidence gates.

Minecraft is a reference for chunk/section ownership, asynchronous prioritization,
and shared static geometry publication. Its block-state representation is not a
drop-in fit for this game's smooth editable voxel terrain, procedural tree
recipes, generated building scenes, or actor simulation. This is an architecture
goal, not authorization to copy proprietary code or assets, to replace
authoritative world data, or to make a broad cutover without measured gates.
