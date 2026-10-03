# Chunk-owned world rendering migration goal

Status: **Active; chunk-priority and static-source/readiness cutovers are present. Canonical far-LOD tree impostors have a native chunk-owned publication path with headed receipt, lifecycle, and synthetic queue LOD-transition evidence. Live-game visual acceptance and unified revisioned static render packets remain unimplemented.**

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

## Category scope and ordered cutovers

The list below defines the content domains and their ownership invariants; it
does not override implementation order. Follow the canonical ordered sequence
in `migrations/world-streaming/world-streaming-architecture-plan.md`: measured
baselines, worker-prepared building geometry, regional dependency readiness,
source-derived building LOD/shared tree batching, then native kernels where
measurements justify them. The approved plan lives in the separate
`voxel-godot-docs` repository. Keep its readiness constraints reconciled with
this game's current startup contract (near field plus camera-facing coarse
horizon; progressive background streaming).

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
| Trees | `TreePublicationQueue` keeps recipe authority and passes canonical shared meshes/materials to the registered C++ `ChunkStaticRenderBackend` GDExtension class. It batches far impostors in chunk-owned MultiMesh pages keyed by recipe family, biome, range, and resource identity. Gameplay bodies retain collision and identity; `HorizonEcologyTreeBatch` remains only the temporary waiting silhouette publisher. | Near/mid recipe geometry remains per-tree. The far-impostor receipt uses fresh, value-only candidate metadata and validates live body/chunk IDs, prop ID, canonical recipe signature, and all installed MultiMesh slot transforms; repeat publication validates the incoming recipe and transform. A headed synthetic contract proves receipt handoff, rejection of wrong candidate/recipe/owner, slot mutation invalidation/recovery, body-move invalidation/recovery, changed-recipe replacement across render groups, source/world/view revision reacceptance, readiness invalidation of the superseded recipe, swap-removal compaction, body-exit cleanup, and chunk-publisher retirement on unload. A separate headed production-queue fixture proves canonical worker publication at impostor LOD followed by near-LOD promotion and native slot release. Transition parity/no-pop, page bounds, page-boundary replacement, and live traversal remain unverified. `TreeChunkBatchRenderer` remains an isolated prototype. |
| Ground flora and natural props | Chunk prop state produces ordinary prop nodes and grouped detail `MultiMesh` children. `HorizonEcologySource` retains visual-only roots for view chunks without gameplay chunks. | Candidate selection is chunk-scoped, but ordinary object visuals are not compiled into immutable chunk geometry, and publication remains a separate prop state machine. Existing detail batches are a partial batching precedent, not proof of full category cutover. |
| Generated structures | `GeneratedStructureVisualManifest` and `OrdinaryStructureVisualSourceCapture` capture and validate installed structure visuals for readiness. | Capturing installed structure nodes is not chunk-owned structure geometry publication. Cross-chunk ownership and revisioned visual fragments still need a production contract. |
| Mobs and NPCs | Existing actor systems create and render actors independently. | This is the intended boundary and must remain independent. |
| Coordinator | `VisibleWorldDemandController` schedules terrain, prop, and structure producers and collects revision-bound receipts in `VisibleWorldReadiness`. | It is a readiness/source coordinator, not a unified static render compiler, immutable geometry packet, or shared chunk upload owner. |

### Current stage charter: native far-tree readiness and traversal evidence

- **Outcome:** a native far-tree impostor becomes a current, revision-checked
  readiness receipt only when the exact canonical tree candidate is installed
  under its current chunk publisher. Replaced, stale, removed, or unloaded
  installations become pending immediately.
- **Authorities:** `TreeSpawnService` and the canonical recipe builder continue
  to own tree identity and geometry inputs; the `StaticBody3D` continues to own
  trunk collision and mutable gameplay identity. `TreePublicationQueue` owns
  publication scheduling, `ChunkStaticRenderBackend` owns the native page,
  `ChunkPropVisualManifest` captures candidates, and `VisibleWorldReadiness`
  owns revision-bound receipts. `VisibleWorldDemandController` remains only the
  scheduler/coordinator.
- **Non-goals:** this stage does not batch near/mid tree geometry, move gameplay
  bodies, change tree RNG/recipes, change terrain authority, or retire the
  per-tree fallback.
- **Baseline:** current branch is
  `codex/chunk-owned-world-rendering-migration` at `4b2d7556` (2026-10-03),
  with a clean tracked tree. The earlier cave diagnostic is not tree or startup
  acceptance evidence.
- **Resolved defect:** the native validator compared `String` arguments directly
  with `Variant` values returned from its snapshot dictionary. The values were
  identical, but the comparison rejected every valid receipt. Explicitly cast
  the installed prop ID and recipe signature to `String` before comparing.
  Fresh value-only publisher metadata now carries the live candidate body,
  parent chunk, and recipe signature on every manifest submit; future readiness
  queries reuse that accepted metadata and revalidate the native installation.
- **Verification (2026-10-03):** `node tools/build-native-terrain-meshing.mjs`
  completed successfully. The reproducible headed command
  `node tools/run-visible-world-readiness-contract.mjs -Headed -OutputDirectory artifacts/citadel-runtime-integration/visible-world-readiness-headed-chunk-unload`
  passed all 229 checks. Its report proves native publication, current receipt
  handoff, rejection of wrong candidate, recipe, body/chunk owner, tier, and
  representation, actual three-role slot transforms, mutation invalidation and
  recovery, body-move invalidation and recovery, swap-removal compaction, and
  body-exit cleanup with a surviving receipt, and chunk-owned publisher
  retirement on unload. That earlier revision kept a changed recipe pending
  while preserving the old slot; the atomic replacement follow-up below resolves
  that behavior. The watchdog reported
  `functionalExitCode: 0`, `cleanupPassed: true`, and
  `authoritativeZeroProven: true`. The headless command using
  `artifacts/citadel-runtime-integration/visible-world-readiness-headless-lifecycle`
  passed 212 non-rendering checks and explicitly skipped the MultiMesh slot
  check because Godot's headless rendering server returns identity transforms.
  Both reports are synthetic owner/receipt contracts, not live-gameplay proof.
- **Additional headed queue evidence (2026-10-03):**
  `node tools/visible-world/run-horizon-tree-headed.mjs -OutputDirectory artifacts/citadel-runtime-integration/visible-world-horizon-tree-headed-native-3`
  passed 10 checks with watchdog cleanup and authoritative empty owned-process
  membership. The fixture uses the real `TreePublicationQueue`, canonical recipe
  worker, native chunk renderer, renderer frames, and four 1280x720 captures.
  It verified `chunk_tree_impostor` publication at canonical impostor LOD with a
  ready native slot and no per-tree visual, then approached the same body and
  verified near-recipe publication plus native impostor-slot retirement. The
  near and distant endpoint captures are in that run's `captures/` directory.
  This is a synthetic headed production-queue fixture, not ordinary seeded
  gameplay. It does not establish continuous transition parity/no-pop, page
  capacity or memory bounds, source revision replacement, chunk streaming,
  startup, or traversal performance. The run also exposed an absent metadata
  lookup in `TreePublicationQueue.body_is_collision_visible`; the production
  path now checks `has_meta` before reading publisher metadata.
- **Seeded headed traversal evidence (2026-10-03):** the normal MainMenu/New
  Game sprint runner reached a fully represented first outdoor view and moved
  58.57m using the shared obstacle-aware player navigator with sprint enabled.
  Its final run still failed the full-view gate after movement: terrain mesh
  coverage and six chunk prop-source manifests were pending at the new center.
  The captures show populated world content, but do not prove a continuous
  tree LOD transition, page-boundary replacement, native page/draw bounds, or
  a passing frame-cadence gate. See
  `artifacts/citadel-runtime-integration/visible-world-fast-turn-sprint-tree-migration-20261003-e/report.json`.
- **Atomic recipe replacement (2026-10-03):** the native publisher previously
  returned `pending` indefinitely whenever an installed tree's recipe changed.
  It now installs the prepared replacement slot before compacting out the old
  slot in the same call. `node tools/build-native-terrain-meshing.mjs` rebuilt
  the extension, then
  `node tools/run-visible-world-readiness-contract.mjs -Headed -OutputDirectory artifacts/citadel-runtime-integration/visible-world-readiness-headed-atomic-recipe-replacement-v7`
  passed 238 checks. The replacement case changes canopy geometry and visibility
  range, proving that the installed transform and native render group change,
  exactly one tree remains registered, and the previous readiness receipt is
  invalidated. A fresh candidate snapshot then reaccepts the installed recipe;
  the same native installation is reaccepted after source, world, and view
  revision changes, while the old view remains pending. Subsequent removal
  compacts the replacement group's surviving slot. Intermediate fixture runs
  exposed assumptions about render-group retention, refreshing the manifest
  candidate, and completing all source coverage in the revised view; the final
  fixture now exercises the full transition and passes. The watchdog recorded
  exit 0, clean shutdown, and authoritative zero owned process members. This is
  still a synthetic owner/receipt contract; it does not establish a visually
  seamless in-game replacement.
- **Remaining risks:** the queue fixture establishes only the endpoints of an LOD transition, not continuous
  visual parity or a no-pop transition. Neither fixture establishes page
  capacity/memory bounds or actual gameplay traversal. Page-boundary replacement
  remains untested. The
  diagnostic manual cave launch from 2026-10-03 is not
  tree or startup acceptance evidence. A real headed traversal with screenshots
  and frame/page observations is still required.
- **Exit evidence:** focused contracts must prove native publication replaces
  the horizon placeholder and accepts a current publisher receipt; reject
  wrong candidate, recipe, owner, source/view/world revision and stale slot;
  preserve receipt correctness through swap-removal, body exit, chunk unload,
  and re-publication; and complete a changed-recipe replacement while retaining
  the old accepted slot through preparation. The native contract now proves the
  replacement install and old-receipt invalidation, while the headed queue
  fixture proves canonical far publication and near-promotion slot release in a
  synthetic scene. Page-boundary behavior remains untested. A headed gameplay
  traversal must still verify silhouette/material
  parity, no transition pop, draw/page bounds, and frame cadence. The current
  evidence does not close this stage.

### Next production cutover

After the far-tree receipt gate passes, reconcile the next category against the
approved ordered world-streaming plan before implementation. That plan first
extends worker-prepared building geometry, then regional readiness, then source-
derived building LOD and shared tree batching. For each broader cutover, define a
revision-bound, owned-value static-visual packet for one spatial chunk, with
explicit material/LOD batches, source identity, deterministic candidate order,
and cancellation-safe replacement. Migrate one real category end to end through
packet capture, preparation, bounded upload, install, invalidation, and unload
while retaining the old accepted representation until replacement
acknowledgement. Trees remain a candidate only when their recipe, transform,
collision, prop ID, and removal contracts can be preserved inside that ordering.

The current building path already prepares immutable masonry, paving, and roof
instance segments on an owned worker and uploads completed `MultiMesh` batches
in bounded main-thread slices. It still merges by material and render tier under
the site scene root. The first chunk-owned building slice should therefore use
one packet-eligible, single-owner-cell masonry group, admitted through the
existing physical-group dependency closure. Carry its source binding, member
bindings, canonical material ID/version, render tier, owner cell, deterministic
instance order, bounds, and explicit empty/non-empty batch counts through packet
installation and its revision-bound receipt. Resolve Godot material resources on
the main thread. Keep collision, doors, interactions, furnishings, and navigation
under their current site/actor owners.

The canonical static owner grid is 32 terrain cells (43.2m) in XZ. Resolve a
member's unique owner from its world-space anchor with negative-safe floor
division, while retaining that packet as a dependency of every intersecting
visible cell. Do not duplicate the full visual or gameplay member across cells.
Install beneath the actual `Chunk_x_z` owner through a chunk registry, not by
reparenting a completed site batch: the current site job validates its root and
publication witnesses. On replacement, retain the accepted old packet until the
new owner confirms installation; on chunk unload, retire its packet while
preserving source demand needed by still-visible intersecting cells.

The approved ordered architecture plan and maturity plan are maintained in the
separate `voxel-godot-docs` repository at
`migrations/world-streaming/world-streaming-architecture-plan.md` and
`migrations/world-streaming/world-streaming-maturity-migration-plan-2026-09-14.md`.
The prior tree-renderer decision is
`systems/procedural-ecology/history/vox-134-procedural-tree-renderer-decision.md`.
These are planning/evidence constraints, not substitutes for this goal's
end-to-end chunk-owned static publication requirement. Preserve the existing
hybrid tree renderer until its replacement passes the stated evidence gates.

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
acceptance contracts in the canonical `voxel-godot-docs` plans named above.
Reconcile checkout, baseline, and gate requirements before each cutover. The
canonical order is authoritative when this goal's category list could be read as
a different implementation sequence.

Minecraft is a reference for chunk/section ownership, asynchronous prioritization,
and shared static geometry publication. Its block-state representation is not a
drop-in fit for this game's smooth editable voxel terrain, procedural tree
recipes, generated building scenes, or actor simulation. This is an architecture
goal, not authorization to copy proprietary code or assets, to replace
authoritative world data, or to make a broad cutover without measured gates.
