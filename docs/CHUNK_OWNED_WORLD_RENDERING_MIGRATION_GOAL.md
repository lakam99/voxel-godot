# Chunk-owned world rendering migration goal

Status: **Active; chunk-priority and static-source/readiness cutovers are present, and canonical far-LOD tree impostors now publish through the native chunk-owned renderer. Full migration remains incomplete and the new visual path still needs runtime evidence.**

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

## Current architecture audit

The first migration commit established chunk priority, source manifests, and
revision-aware readiness. Those pieces prove that required source content has
an accepted visible representation; they do not yet make every representation
part of one chunk render artifact. Current ownership at the checked-in baseline:

| Category | Current publication path | Remaining migration gap |
| --- | --- | --- |
| Terrain | `VoxelTerrainRuntime` owns native terrain chunk mesh and collision publication. `VoxelTerrainVisualManifest` participates in visible-world demand. | Terrain is chunk-owned already, but static content is still published through separate producers and is joined at readiness time. |
| Trees | `TreePublicationQueue` keeps recipe authority and passes canonical shared meshes/materials to the registered C++ `ChunkStaticRenderBackend` GDExtension class. It batches far impostors in chunk-owned MultiMesh pages keyed by recipe family, biome, range, and resource identity. Gameplay bodies retain collision and identity; `HorizonEcologyTreeBatch` remains only the temporary waiting silhouette publisher. | Near/mid recipe geometry remains per-tree, and far impostors fall back to the per-tree renderer if the native class or resource installation is unavailable. Native page culling, transitions, invalidation, removal, and headed traversal need runtime verification before extending batching. `TreeChunkBatchRenderer` remains an isolated prototype. |
| Ground flora and natural props | Chunk prop state produces ordinary prop nodes and grouped detail `MultiMesh` children. `HorizonEcologySource` retains visual-only roots for view chunks without gameplay chunks. | Candidate selection is chunk-scoped, but ordinary object visuals are not compiled into immutable chunk geometry, and publication remains a separate prop state machine. Existing detail batches are a partial batching precedent, not proof of full category cutover. |
| Generated structures | `GeneratedStructureVisualManifest` and `OrdinaryStructureVisualSourceCapture` capture and validate installed structure visuals for readiness. | Capturing installed structure nodes is not chunk-owned structure geometry publication. Cross-chunk ownership and revisioned visual fragments still need a production contract. |
| Mobs and NPCs | Existing actor systems create and render actors independently. | This is the intended boundary and must remain independent. |
| Coordinator | `VisibleWorldDemandController` schedules terrain, prop, and structure producers and collects revision-bound receipts in `VisibleWorldReadiness`. | It is a readiness/source coordinator, not a unified static render compiler, immutable geometry packet, or shared chunk upload owner. |

### Next production cutover

The far-tree impostor is the first narrow native production slice, using the
existing Godot 4.6 terrain-meshing GDExtension and the exact shared
mesh/material transforms from its former per-tree publisher. Its native DLL
compiles, but runtime parity and culling behavior still need headed evidence.
For broader category work, first define a revision-bound, owned-value static-visual packet for one spatial chunk, with
explicit material/LOD batches, source identity, deterministic candidate order,
and cancellation-safe replacement. Then migrate one real category end to end
through packet capture, preparation, bounded upload, install, invalidation, and
unload while retaining the old accepted representation until replacement
acknowledgement. Trees remain the first category candidate because their current
per-tree publication path and prototype provide a measurable baseline; the
cutover must consume canonical recipes and must preserve the continuous trunk,
foliage appearance, collision, prop IDs, removal, and tree recipe authority.

The checked-in branch does not contain the referenced
`WORLD_STREAMING_ARCHITECTURE_PLAN.md`,
`WORLD_STREAMING_MATURITY_MIGRATION_PLAN_2026-09-14.md`,
`vegetation/VOX_134_PROCEDURAL_TREE_RENDERER_DECISION.md`, or
`Minecraft-Equivalent Terrain Migr.md`. Their historical decisions cannot be
revalidated from this checkout; use this goal's architecture and acceptance
contracts as the current task scope, and recover/reconcile those documents if
they become available before their specific gates are needed.

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
