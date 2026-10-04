# Chunk-owned world rendering migration goal

Status: **Active; chunk-priority and static-source/readiness cutovers are present. Canonical far-LOD tree impostors have a native chunk-owned publication path with headed receipt, lifecycle, and synthetic queue LOD-transition evidence. Worker-prepared, single-owner-cell building batches now have packet installation, revision-exact readiness, stale-packet retirement, per-advance bounded chunk-unload replay, and site-teardown release in code. Packet release now preserves its receipt until acknowledgement. Source-verified native GDExtension contracts cover packet lifecycle and the `Main.gd` chunk-container creation/retirement seam; its focused fixture uses actual `VoxelTerrainRuntime` demand/release bookkeeping with a stubbed site gate. Resident streamer-scheduled packet replay, source artifact memory, cross-cell fragments, and live-game acceptance remain open.**

## Goal

Migrate the presentation of static, non-mob world content to chunk-owned render
publications. When terrain for a visible chunk is ready, its trees, ground
plants, natural props, and static generated structures should be prepared and
published through that chunk's rendering lifecycle instead of appearing later
through a chain of independent per-object visual queues.

The inspiration is Minecraft Java 26.2's section renderer: its block section
compiler builds visible block and fluid geometry by render layer, prioritizes
near sections, compiles work asynchronously, and uploads completed geometry to
shared GPU buffers. Trees, plants, and block-built structures participate
because they are represented by block states. Minecraft still renders mobs as
independent entities. Our migration should adopt the useful chunk publication
boundary without copying Minecraft code or replacing our procedural world
authorities.

### Minecraft 26.2 source review

The local reference is `C:\Users\arkam\Documents\Minecraft Java Source Reference\26.2`.
The relevant implementation is `decompiled/net/minecraft/client/renderer/chunk/`:

- `SectionCompiler.compile` walks the 16x16x16 block volume for one section and
  emits one mesh per non-empty render layer (`SOLID`, cutout variants, and
  translucent), alongside visibility and block-entity results. Fluids join the
  same layer builders. Translucent quads carry camera-dependent sort state.
- `SectionRenderDispatcher` owns replaceable section slots. Compilation and
  upload are separate stages; the previous mesh stays installed until every
  layer's vertex and index uploads have acknowledged. Reassignment cancels old
  work. Our equivalent must additionally verify source/owner revisions at the
  final swap, including an authoritative empty section.
- `SectionTaskDynamicQueue` chooses nearby work and bounds consecutive
  recompiles so first-time sections still progress. This is a useful fairness
  property, not a quota to copy without measuring our queue mix.

This review sharpens the target boundary: the eventual publication unit is a
complete spatial section generation with a stable section-slot identity and a
sorted manifest of every current contributor. Per-building or per-tree packets
keyed by source revision are useful migration bridges, but are not the final
Minecraft-like section renderer: otherwise contributors in the same section
remain separate packets and cannot be atomically replaced or culled as one
complete section. A replacement is admitted only when its full contributor set
is declared, all render-layer/material/mesh groups are accounted for, and the
current owner epoch is revalidated. Empty output is an explicit replacement,
not missing work.

Minecraft's cell mesher cannot be copied literally for our procedural meshes.
The initial building producer declares unit-box bounds, while the partition
contract now carries a mesh-local AABB; production must source that AABB from
the actual mesh resource before tree, rock, or arbitrary structure meshes join
the shared section compiler. Tree impostor pages remain a temporary compatibility
producer until an exact section generation can replace their candidates while
preserving candidate IDs, recipe/source revisions, and independent gameplay
bodies. Section render layers/pipeline and translucent sorting are part of the
batch key and readiness proof, rather than inferred from category labels.

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

The far-tree receipt and live-traversal gate above remains open evidence for the
existing native tree-impostor path; it must pass before claiming tree publication
acceptance. It does not change the canonical implementation order. The next
production cutover extends worker-prepared building geometry, followed by
regional readiness, then source-derived building LOD and shared tree batching.
For each broader cutover, define a
revision-bound, owned-value static-visual packet for one spatial chunk, with
explicit material/LOD batches, source identity, deterministic candidate order,
and cancellation-safe replacement. Migrate one real category end to end through
packet capture, preparation, bounded upload, install, invalidation, and unload
while retaining the old accepted representation until replacement
acknowledgement. Trees remain a candidate only when their recipe, transform,
collision, prop ID, and removal contracts can be preserved inside that ordering.

The building path prepares immutable masonry, paving, and roof instance segments
on an owned worker. `BuildingStaticBatchFlush` now routes eligible prepared
segments to `ChunkRenderPacketBackend` in bounded append/upload/commit steps.
Eligibility requires a stable source binding and material cache key plus segment
bounds fully inside the source's declared owner cell. The chunk-local root
transform is derived from the live site/chunk transforms, and the scene visual
receipt rechecks the backend generation, source revision, packet digest, chunk
instance, and installed packet before accepting a packet-backed member. Other
groups still follow the site-root path until they have equivalent ownership
proof. The publisher now retains immutable prepared segments for per-advance
bounded chunk-unload replay through the resident scene scheduler; physical group
receipts remain independent. The focused fake-backend replay contract passes
five checks, including release-failure retention and acknowledged retry, and the
scene-job orchestration contract passes 606 checks. A native GDExtension
contract passes twelve checks through both `BuildingStaticBatchFlush` and the
actual `ChunkRenderPacketBackend`: it verifies chunk attachment, owner-cell
rejection, install/replace, stale-release rejection, chunk owner destruction
and recreation, resident building packet replay, and acknowledged release. Its
launch verifies the loaded debug DLL's build manifest names the exact current
C++ source hash. This proves the production building flush/replay protocol
against native packet nodes; it does not yet exercise `MainRuntimeTools` terrain
streaming selection or admission through the real terrain site gate. A follow-up
19-check contract now extends the real `Main.gd` chain, creates a chunk through
`create_voxel_authority_chunk_container`, verifies the native packet owner and
deferred prop request, then retires it through the production chunk-retirement
helper. It uses actual `VoxelTerrainRuntime` demand maps and `release_gameplay_chunk`
with a ready stub site gate; it confirms release precedes registry removal and
owner destruction, and retained/startup-auxiliary demand prevents deletion until
released. It does not run `VoxelTerrainRuntime.setup()` or prove resident Citadel
scheduler replay after streamer-driven unload/reload. Cross-cell ownership and
live gameplay also remain open. The repeatable command is
`node tools/run-native-chunk-render-packet-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/native-chunk-packet-streamed-owner-retirement`;
its report is `report.json`, and the watchdog recorded exit 0, clean shutdown,
and authoritative zero owned-process members. Source artifact memory still lacks an aggregate budget. Replay recipes reference the same
immutable segment buffers retained by prepared masonry/surface or physical-family
artifacts, so evicting only replay descriptors would not reclaim those buffers.
Any memory budget must also release/rebuild the owning source artifacts safely.
Obsolete packet
IDs are scheduled for release after each committed scene boundary, and tracked packet
generations are released incrementally when the owning site job retires. The
backend's explicit zero-batch packet API is not used; removal currently retires
prior IDs after a new accepted scene boundary. Collision, doors, interactions,
furnishings, and navigation retain their existing authorities.

Packet release now retains its receipt and replay recipe until the native owner
acknowledges `released`; a failed generation match is surfaced as a retirement
failure instead of silently dropping ownership bookkeeping. The focused fake
backend contract covers failure retention and successful retry. The resident
scene job and publisher hold canonical packet artifacts that can support a
capture-only replay for masonry, paving, and roof families, but there is no
bounded artifact-eviction/rebuild lifecycle. Re-running normal part publication
is unsafe because it can republish collision, metadata, and physical boundaries.
Any memory-control path must coordinate the lifetime of replay references and
their owning prepared artifacts; missing source authority must remain an explicit
pending/failure state, never empty success.

**Installed-packet capacity failure (2026-10-03):** the native owner has a hard
128-installed-packet limit. A new source at capacity previously returned
`backpressure/installed_packet_capacity` from commit, which the static flush
retried forever while retaining its staged packet. `BuildingStaticBatchFlush`
now distinguishes that permanent capacity condition from transient backpressure,
aborts the un-installable stage, and reports an explicit
`chunk_packet_installed_capacity` publication failure (including a distinct
abort-unacknowledged failure). Transient backpressure still retries. The native
contract fills all 128 slots with real backend packets, then runs the production
flush path for packet 129 and verifies the failure is terminal and staged packet
count returns to zero. Command:
`node tools/run-native-chunk-render-packet-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/native-chunk-packet-capacity-v5`.
The report passed all 21 checks; watchdog exit was 0, cleanup passed, and
authoritative owned-process membership returned to zero. This is a native/service
contract, not evidence that real worlds cannot exceed the cap. A demand-aware
slot release/eviction policy or justified capacity sizing remains necessary for
production parity at scale.

**Next stage charter — chunk-layer aggregation and resident-slot reuse:**
Replace the current per-building-part native packet residency with compiled
chunk-owned outputs aggregated by render tier/material layer. Preserve a
revision-bound contribution receipt for every building source part so the
scene/readiness authorities can still prove exactly which records are present.
The chunk publication identity should be stable across source revisions where
owner and batch family remain stable; a moved source contributes to its new
owner and retires its old contribution only after replacement is accepted.
Keep the prior visible packet until every required batch for its replacement
has upload and installation acknowledgements. Retain/rebuild demand for visible
intersecting chunks, cancel superseded work, and release resident slots only
when demand leaves or replacement commits. Geometry crossing owner cells must
produce explicit deterministic visual fragments with source mapping, while
collision, interaction, and save ownership stay singular and unchanged.

**Atomicity constraint:** `BuildingStaticBatchFlush` currently commits eligible
packets one source/material/tier group at a time, before the enclosing
publication boundary advances. A later group failure can therefore leave an
earlier group replaced even though that boundary did not complete. Do not wire
the contributor ledger only into `_commit_publication_boundary()` and treat
that as atomic rendering. The next section path must stage a full affected
section snapshot from the closed contributor set, then promote the section
generation and contributor receipts only after the complete candidate is
installed. `BuildingScenePublicationJob` must continue to keep physical,
door, collision, and interaction acknowledgements separate from that visual
receipt.

Entry evidence is the native capacity contract above plus the existing
source-revision and chunk-replacement contracts. Before changing packet identity,
map all consumers of `_chunk_static_packet_expected`, receipt recording/replay,
stale-source retirement, and `BuildingScenePublicationJob.visual_receipt_installed`.
The focused exit gate must fill a chunk with many source parts sharing a small
set of material/tier batches, replace one and then several contributors, reject
stale worker results, verify all contributor receipts against the installed
generation/digest, unload/recreate the owner and replay from retained immutable
data, and prove buffers/slots are reclaimed after demand release. It must also
cover a contributor spanning adjacent XZ owner cells and show per-cell fragments
without duplicate gameplay records. Then run a representative seeded headed
building/town traversal and measure upload work, draw/page count, frame cadence,
and resident packet/byte high-water marks. This follows the 26.2 reference
contract: one recycled section owner compiles layer outputs, queued work favors
near initial builds, and installation waits for all required upload receipts;
it does not copy Minecraft's block-state authority or fixed 16-cube dimensions.

`BuildingSpatialDependencies.OWNER_SIZE` defines a 32-cell (43.2m) logical
source-owner grid in XZ. `Main.chunks`, however, is keyed in the 28-cell
(37.8m) gameplay chunk grid. These are separate authorities: derive the static
source owner for contributor coverage, but resolve native packet lifetime
against the actual streamed chunk key. Render-section origins and bounds can
cross both grids; record every intersecting dependency while assigning one
canonical visual owner. Do not duplicate the full visual or gameplay member
across cells. Install beneath the actual `Chunk_x_z` owner through a chunk
registry, not by reparenting a completed site batch: the current site job
validates its root and publication witnesses. On replacement, retain the
accepted old packet until the new owner confirms installation; on chunk unload,
retire its packet while preserving source demand needed by still-visible
intersecting cells.

**Current worktree progress (2026-10-03):** `ChunkRenderPacketBackend` is
registered in the native terrain extension with bounded staged packets,
revision/digest receipts, explicit commit/abort/release, and attachment checks
against the actual `Chunk_x_z` parent. Streamed chunk containers create this
owner when the extension is available. Building worker entries retain and
validate owner-cell/bounds data. The production flush now detects eligible
prepared segments, hashes source, material key, render policy, mesh dimensions,
site-to-chunk transform, bounds, and instance buffers incrementally, retries
backpressure without advancing the cursor, revalidates the live chunk owner,
and stores a generation-exact receipt. The visual readiness callback requires
that exact receipt for packet-backed members while preserving existing site-root
and collision witnesses. Stale packet IDs are released incrementally after each
committed scene boundary; tracked packet generations are also released
incrementally as the site job retires. Cancellation aborts the staged
generation and retains the flush payload for retirement. The GDScript path now
passes its scene-job orchestration contract and a synthetic fake-backend
unload/recreate replay contract. Replay waits rotate the site scheduler instead
of spinning one blocked owner through the frame budget, and receipt validation
uses a lookup-only chunk resolver so readiness checks cannot attach renderer
nodes as a side effect. Those contracts do not establish native
renderer integration, cross-cell fragment coverage, or live gameplay. The
service contract currently has three failed frozen-source fixture/hash checks;
it still compiled and ran through the edited scheduler, and its watchdog proved
clean process shutdown.

The native packet integration currently installs one packet per building part.
The bridge now keeps the 32-cell logical source owner separate from the actual
28-cell streamed chunk key; a focused native contract covers a part where those
keys differ. `StaticRenderSectionGrid` adds the 16-cell candidate section grid
and records all streamed chunks intersecting each section. Its 12-check
spatial contract passes. The snapshot assembler's 18-check contract now proves
compatible instance buffers coalesce deterministically, split at the native
256-instance limit, and retain source/revision ranges. Its report is at
`artifacts/citadel-runtime-integration/chunk-static-render-section-snapshot-coalesced-v3/report.json`;
the owned-process watchdog proves exit 0 and an empty job. This remains a pure
prototype: no production contributor capture, cross-section clipping, or section
installation is wired. The 26.2 comparison therefore strengthens the destination
model; it does not make the current bridge Minecraft-equivalent.

**Mesh-bound section data contract (2026-10-04):** the local 26.2 `SectionCompiler`
emits geometry from each block model inside the section walk; our static meshes
cannot assume those models are centered unit cubes. The partitioner now requires
and carries the actual mesh-local AABB through world/section transforms,
ownership selection, culling bounds, batch identity, and streamed-chunk
dependencies. The snapshot independently recomputes center ownership against
that AABB and rejects a batch/segment bounds mismatch. The ledger's building
slice explicitly declares its hard-opaque unit-box bounds. The focused
partitioner contract passes 17 checks at
`artifacts/citadel-runtime-integration/chunk-static-render-section-instance-partitioner-mesh-aabb-v11/`;
the snapshot contract passes 27 at
`artifacts/citadel-runtime-integration/chunk-static-render-section-snapshot-mesh-aabb-v10/`;
the contributor transaction contract passes 15 at
`artifacts/citadel-runtime-integration/prepared-static-contributor-ledger-mesh-aabb-v5/`.
All are pure data contracts. Producer-supplied bounds still need binding to the
actual mesh resource, and no section slot or live renderer is wired to them.

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

Minecraft Java 26.2 is the active local source reference at
`C:/Users/arkam/Documents/Minecraft Java Source Reference/26.2/decompiled/`.
That directory contains CFR-decompiled client bytecode, not Mojang's original
source tree. `SectionCompiler.java` walks the section's 16x16x16 block volume,
collects block and fluid geometry into builders keyed by render layer, records a
visibility set and block entities, and emits a mesh per nonempty layer.
Translucent geometry has a separate sort state. `SectionTaskDynamicQueue.java`
favors nearby work while limiting recompiles so initial builds continue.
`SectionRenderDispatcher.java` cancels superseded work, resets recycled section
owners, and only swaps the installed mesh after every layer's vertex/index
uploads are acknowledged.

This exposes an important mismatch in the current native packet prototype:
its lifetime owner is the right streamed chunk, but its installed identity is
still one packet per building source part. That is a useful lifecycle bridge,
not the steady-state publication model. Keep the chunk as the residency and
retirement owner, and give it smaller render-section slots. Each slot should
compile all intersecting static contributors into compatible material/render
policy batches (the equivalent of Minecraft's layers), then atomically replace
the old section publication only after every batch is installed. The existing
backend already stages multiple batches under one packet, so this is a natural
direction for the next cutover; it does not require one backend node or draw
submission per source. Choose section size from this game's measured culling,
upload, and memory costs rather than copying Minecraft's 16-cube dimensions or
assuming the current 43.2m owner-cell is a good render granularity.

The source comparison found a promising initial dimension already used by the
terrain renderer: 16 terrain cells per axis (`VoxelTerrainRuntime.SECTION_SIZE`,
21.6m at 1.35m/cell). It is not nested cleanly in either owner grid: gameplay
chunks are 28 cells and logical static source owners are 32 cells. Keep render
section identity, logical source ownership, canonical streamed-chunk residency,
and all intersecting streamed-chunk dependencies as separate values. A section
can cross stream-chunk boundaries; anchoring it by its origin does not remove
the other chunk dependencies. Sixteen cells is a measured candidate, not an
approved performance winner. The pure spatial key contract is implemented in
`scripts/world/StaticRenderSectionGrid.gd`; its focused runner proves
negative-safe keys, half-open AABB dependencies, exact section-plane handling,
section-to-stream-chunk mapping, and the intersecting stream chunks for each
section. It does not publish render data or prove a visual benefit. The pure
instance partitioner in
`scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd` converts prepared
prepared instance transforms into section-local transforms using each batch's
declared mesh-local AABB, assigns each instance once by the transformed
world-AABB center, keeps each source and revision separate, and emits
conservative local/world bounds plus every intersected streamed-chunk
dependency. The initial building batch declares the unit-box AABB explicitly;
wide or offset meshes can now select their actual section owner. The snapshot
assembler verifies the mesh-bound and ownership claims from the instance
transforms and source ranges, rejects missing, mismatched, or forged dependency
evidence, then coalesces compatible source buffers into 256-instance batches
with revision-bound output ranges. Its compatibility key now separates explicit
opaque/cutout/translucent layers, sort policy, pipeline revision, and mesh-local
bounds in addition to material, mesh, tier, shadow, and visibility policy. The
revision and AABB remain producer-supplied metadata; production must bind them
to actual resource content.
Focused contracts cover this data path only; it is still disconnected from
production capture and section-slot installation.
The mesh-AABB partitioner contract passed 17 checks at
`artifacts/citadel-runtime-integration/chunk-static-render-section-instance-partitioner-mesh-aabb-v11/`;
the assembler and proof-validation contract passed 27 checks at
`artifacts/citadel-runtime-integration/chunk-static-render-section-snapshot-mesh-aabb-v10/`.
Both are pure data contracts, not renderer or gameplay acceptance.
Unlike Minecraft's cell mesher, this prototype partitions prepared instances
and does not yet compile a complete 3D visibility set, model/fluid layers, block
entities, or camera-dependent translucent sort state. The next production step
still needs a copy-on-write snapshot over the complete active contributor set
and section-slot publication.

Preserve a contributor manifest beside each staged/installed section so a
building, tree, or prop keeps its exact source revision and readiness proof.
Map each contributor to its ranges in coalesced batches; commit the section's
manifest and render batches together, and map contributor receipts to the
accepted section generation only after commit. Rebuild affected
sections when contributors change, keep the prior valid publication visible
until replacement succeeds, and retain source demand across unload/reload for
still-visible dependencies. Cross-section objects need an explicit coverage
dependency while retaining one canonical visual owner. Reuse Minecraft's
initial-compile versus recompile scheduling pressure and stale-task cancellation
principles when the section queue is built; do not copy its numeric quota without
measuring this workload. The current native backend can stage a complete packet
and retain the old root until commit, but its acknowledgement proves Godot-side
resource installation, not a GPU upload fence. A later section integration must
define its actual readiness receipt accordingly. The current fail-closed
128-packet capacity result is therefore a guardrail and evidence of the
per-source packet model's scaling limit, not a reason to merely raise the cap.

Minecraft is a reference for chunk/section ownership, asynchronous prioritization,
and shared static geometry publication. Its block-state representation is not a
drop-in fit for this game's smooth editable voxel terrain, procedural tree
recipes, generated building scenes, or actor simulation. This is an architecture
goal, not authorization to copy proprietary code or assets, to replace
authoritative world data, or to make a broad cutover without measured gates.

**Source-guided bridge review (2026-10-04):** inspecting the local 26.2
`SectionCompiler` and `SectionRenderDispatcher` against the in-progress bridge
confirms that the adapter boundary is the important architectural choice. The
compiler reads authoritative 16³ section contents and emits one result per
nonempty render layer, plus visibility, block-entity, and translucent-sort
state. Our current instance partitioner instead starts from already-prepared
static meshes. That is a valid incremental path for trees, structures, and
props, but it must not become a second source of world truth or be described as
the final equivalent of Minecraft's section compiler. In steady state, each
section snapshot should consume a closed, revision-bound set of terrain and
static contributor artifacts, group by real render/material policy, and
publish all batches plus the contributor manifest as one generation. Terrain
visibility/occlusion remains derived from terrain authority; mesh bounds and
stream dependencies provide conservative culling/residency for overhanging
static meshes. Static object ownership cannot substitute for terrain visibility
or block/entity simulation.

The 26.2 lifecycle distinguishes an uncompiled slot from a compiled empty
section (`CompiledSectionMesh.UNCOMPILED` versus `EMPTY`); both states affect
visibility differently. A candidate's installed-layer set is complete only
after every present layer has upload acknowledgement, while an empty result is
still an explicit accepted replacement. Its `RenderSectionRegion` captures a
3x3x3 neighborhood for reads around the section being compiled, which suggests
an explicit terrain halo contract here; worker artifacts must remain value-only
even though Minecraft's copied block-entity map can still reference objects.
In this project, `ChunkRenderPacketBackend` already atomically swaps one staged
packet slot, including a zero-batch packet, but that slot is presently named by
source and its native batch has no render-layer or translucent-sort field. The
opaque building bridge can use that capability; it does not yet implement
Minecraft's whole-section, multi-layer replacement contract.

The comparison also exposed a ledger identity bug: changed-section discovery
used producer `sourceId` even though the stable key is `sourcePartId`. A source
replacement that reused its part identity under a new producer ID could then
omit the old/new section pair from its rebuild set. Impact collection now keys
on `sourcePartId`, and the partitioner carries that identity and logical
`ownerCell` through its source manifest. The focused ledger contract now
exercises a same-part replacement with a changed source ID. It passed 16 checks
at
`artifacts/citadel-runtime-integration/prepared-static-contributor-ledger-source-part-impact-v3/report.json`;
the neighboring partitioner contract passed 17 checks at
`artifacts/citadel-runtime-integration/chunk-static-render-section-instance-partitioner-source-part-v1/report.json`;
the snapshot contract passed 27 checks at
`artifacts/citadel-runtime-integration/chunk-static-render-section-snapshot-source-part-v1/report.json`.
These prove pure identity, partition, and snapshot contracts only; they do not
prove section-level upload atomicity or live rendering. The first ledger rerun
also caught and repaired duplicate dictionary-key syntax and missing manifest
mapping fields before acceptance.

The next comparison against the 26.2 source sharpened the boundary: the new
`PreparedStaticSectionSnapshotBuilder` is a validated staging adapter for the
opaque static-contributor path, not a complete section compiler. Minecraft's
`SectionCompiler.compile` puts every block/fluid render layer from a section
into one candidate, and `SectionRenderDispatcher` keeps the prior candidate
until every present layer has upload acknowledgement; explicit empty is also a
replacement. Keep this builder as an input to a future shared section
candidate, and do not install it as an independent final publication beside
terrain, foliage, or other section content. Its validation proves internal
partition/manifest completeness, not freshness: production must pass the exact
current ledger result and revalidate world, generation, contributor revisions,
section owner, and boundary immediately before accepting receipts. A changed
`Vector3` component now changes the canonical digest at float-byte precision,
and owner-cell identity is carried and checked through source ranges, segments,
and manifests. The focused contracts passed 18 checks for the partitioner at
`artifacts/citadel-runtime-integration/chunk-static-render-section-instance-partitioner-owner-cell-20261003/report.json`
and 16 for the snapshot builder at
`artifacts/citadel-runtime-integration/prepared-static-section-snapshot-builder-owner-cell-digest-20261003/report.json`.
These remain pure contracts; they do not establish renderer installation,
GPU completion, or live visual behavior.

**Ledger prepare/install/promote gate (2026-10-04):** applying Minecraft's
old-section-retained-until-candidate-complete rule exposed that
`PreparedStaticContributorLedger.commit_boundary()` promoted its memory state
before a renderer receipt could exist. It is now split into
`prepare_boundary()` and `accept_installed_candidate()`: preparation computes
the next full partition and impacted section set while preserving the current
committed ledger; promotion requires one read-only section candidate and a
matching installed receipt for every impacted key, with the source revision
set checked again at acceptance. Incomplete receipt sets, content-digest
mismatches, and revisions that go stale after preparation are rejected while
the prior committed ledger remains active. The 17-check watchdog contract
passed at
`artifacts/citadel-runtime-integration/prepared-static-contributor-ledger-section-install-gate-v3-20261003/report.json`.
Its install receipts are contract fixtures, not calls to a live section owner;
the production caller must query and revalidate each actual slot's world,
generation, digest, owner chunk/backend identity, and residency dependencies
immediately before promotion. This gate prepares the real section cutover but
does not yet wire `BuildingStaticBatchFlush` (currently per source/material/tier
packet) or the natural detail/tree producers into section slots.
