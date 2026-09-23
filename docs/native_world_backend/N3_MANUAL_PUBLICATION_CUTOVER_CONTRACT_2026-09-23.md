# N3 manual terrain publication cutover contract

Status: design and installed-engine evidence, **not** a production cutover.

## Why this boundary

The native core can already prepare exact single and multi-page Voxel Tools
channel bytes from admitted source/delta/shaping pins. The current production
`VoxelTerrainRuntime` still installs `VoxelTerrainGenerator` and
`VoxelTerrainSiteGate.advance()` turns automatic loading on after viewer
admission. A generator callback cannot retain an unresolved request. The
manual `try_set_block_data` path is therefore the intended rendering bridge:
native source preparation retains demand and supplies complete data blocks;
Voxel Tools meshes them. There must never be a fallback script generator or
automatic-air interpretation when a dependency is pending.

The owner belongs in a composed runtime service below `VoxelTerrainRuntime`,
not another `Main*.gd` layer. `CitadelTerrainAdmission` remains the source-site
admission owner; the new service consumes its ready/pending/failed result and
the native backend's exact block pin, rather than reimplementing those facts.

## Retained block lifecycle

Each key is `(seed/source epoch, block coordinate, LOD)` and carries the
requested source/content identity, urgency, generation/attempt number, and
the viewer/consumer demand set. The owner must maintain these explicit states:

1. `waiting_source`: a viewer or gameplay consumer requests a block; the
   corresponding site/shaping pages are not yet ready. Retain and retry it.
2. `queued`: all source pins are admitted; reserve an actual bounded job slot
   before starting immutable native encode. Priority can increase without
   duplicating the key; aging ensures non-urgent progress.
3. `encoding`: one immutable captured source/delta/shaping generation is in
   flight. On reset, edit or cancellation, retain demand but reject its result.
4. `prepared`: complete bytes are owned and counted against a hard prepared-
   byte cap. If the paired viewer is not yet registered or
   `try_set_block_data` rejects, keep the same prepared result for a bounded
   retry; never treat rejection as an acknowledgement.
5. `inserted_waiting_mesh`: a main-thread call accepted a unique buffer.
   `has_data_block` proves data residency only. Mesh and physics readiness
   remain separate; the engine may asynchronously replace or retire them.
6. `published`: a current block has the required mesh/physics receipt. This
   state must be invalidated by edits, unload, viewer departure and reset.
7. `retired`: no active demand or old epoch; release large bytes through the
   measured retirement owner after all workers/aliases have drained.

The transition from prepared to installed must recheck the source epoch and
pin identity on the main thread. A stale completion is discarded and current
demand requeued. Viewer motion changes priority/demand, not source identity.
An accepted `try_set_block_data` call must not imply collision readiness.
Mesh entered/exited signals and a current-revision physical proof are needed
before an actor can use the block. On unload, retain active demand and requeue
for a revisit; an absent data block is never considered empty terrain.
Reconcile demanded keys against `has_data_block` and mesh-exit evidence on a
bounded cadence, because viewer-driven eviction need not correspond to a
single queue-owned unload call. Do not create a second readiness authority:
translate current block receipts into the existing `published_mesh_blocks`,
gameplay-chunk edit revision, startup, motion and navigation invalidation
contracts atomically, or replace those consumers together at their cutover.

## Engine-specific constraints established so far

- The installed-engine lifecycle fixture rejects insertion before a viewer is
  paired. Once paired, it accepts 27 halo blocks and publishes a real physics
  collider. The queue must retry a rejected insertion.
- A moved viewer unloads manually inserted data even with automatic loading
  disabled. Revisit accepted explicit reinsertion and restored collision.
- Two immediate center-block replacements published the latest height and it
  remained stable for 60 physics frames in one synthetic run. This is not a
  proof of all asynchronous replacement orderings. Revision-aware/serialized
  replacement still needs focused stress evidence before actor-safe cutover.
- The installed Voxel Tools implementation marks injected blocks edited. Save
  v2 must continue to serialize only player/durable world deltas, never a
  Voxel Tools generated-block dump.
- Meshing needs a data-block halo and is asynchronous. The producer must
  reserve/prepare the halo and record real admission/encode/copy/upload atom
  costs, not hide them outside the shared 6 ms gameplay envelope.
- `NativeVoxelBlockDemandFootprint.data_blocks_for_mesh_blocks` now provides
  a deterministic, 128-data-block-capped one-block X/Y/Z halo for a supplied bounded set of
  mesh blocks. Its pure contract passes eleven cases, including a y=2 input
  layer for an adjacent upper mesh block and negative coordinates. Report:
  `artifacts/native-world-backend/n3-block-demand-footprint-20260923.json`.
  It does not yet choose mesh blocks from runtime viewer/chunk demand or
  reserve the resulting native jobs; those integration steps remain open.
  The cap matches the native retained queue's 128-entry ceiling, but existing
  consumers can still make a newly requested footprint temporarily full;
  admission must retain and retry any `queue_capacity` result.
  This is a *batch* bound, not enough capacity for the whole production viewer.
  Even an 11-by-11 mesh-block XZ square across the five startup vertical mesh
  blocks would require a 13-by-13-by-7 data halo (1,183 keys), before extra
  foreground/retained viewers. The actual viewer footprint is not that exact
  square, but the 128-entry global retained map cannot be assumed sufficient.
  Production integration must measure real resident demand, size the queue and
  byte caps accordingly, and use bounded incremental registration/retirement;
  it must not drop old resident ownership simply to admit a new window.
- `NativeTerrainBlockPublisher` is a composed manual-data bridge that admits
  shaping pages, retains a bounded native block request, inserts complete
  channel buffers into a paired `VoxelTerrain`, and keeps mesh/physics/unload
  receipts separate. A headed mechanism fixture inserted 27 halo blocks,
  obtained a real mesh and collision ray, rejected premature physics
  acknowledgement, then accepted the proven receipt and observed viewer
  unload/release/drain. Command:
  `node tools/run-n3-native-terrain-block-publisher.mjs`. Report:
  `artifacts/native-world-backend/n3-native-terrain-publisher-1790167849684-f2d7691f/report.json`.
  A synthetic pending-page interval retained demand without registering a
  native block. A shifted frontier inserted new blocks while the old frontier
  remained physically resident and native-owned; stop waited for actual
  engine unload before releasing all requests. The fixture uses one ready
  source page and an exclusive backend. Production viewer/chunk/foreground
  demand union, real pending-source completion, live edit replacement and reset
  are not yet connected. Runtime reset must retire or clear the paired physical
  terrain before acknowledging a new seed.
- Retained native demand now uses a page-local physical-content pin and
  authoritative affected-section invalidation. Distant shaping resolution and
  durable edits preserve a prepared block; a local edit rejects its old receipt
  and retries with edited bytes. Focused service report:
  `artifacts/native-world-backend/n3-local-retained-demand-1790167723582-3295ccac/report.json`.
  This is not an installed-engine edit-replacement or loaded-save throughput
  result; old installed bytes must remain unpublished until a current physical
  replacement is proven.
- A committed durable-mirror receipt now carries the exact changed cells.
  `NativeTerrainEditRepublicationPlan` maps those cells to replacement data
  blocks, affected neighboring mesh blocks, and their full data-input halo,
  with receipt matching and finite plan caps. Focused planner report:
  `artifacts/native-world-backend/n3-edit-republication-plan-1790168077551-776f5a78/report.json`;
  linked shadow-mirror report:
  `artifacts/native-world-backend/n3-durable-edit-mirror-1790168114011-2af6c598/report.json`.
  The normal runtime still scans script edited cells and pastes through
  `VoxelTool`; native same-block physical replacement and actor-safe receipt
  are prerequisites to deleting that path.

## Integration order and fail-closed checks

1. Build the retained native block owner and a focused contract for duplicate
   demand, promotion, page-pending retry, capacity, edit/epoch cancellation,
   insertion rejection, unload/revisit and bounded retirement. Drive pure
   encoding off Main with immutable snapshots; keep engine calls on Main.
2. Add an explicit manual-data mode to `VoxelTerrainSiteGate`. Keep the same
   admitted viewer attachments but do not enable automatic loading. A foreign
   viewer remains a terminal fail-closed gate error in either mode. Pairing
   must precede insertion attempts; register its demand before or with the
   attachment, then retry after the engine observes the viewer. Stop/reset
   must detach viewers and invalidate all old-epoch jobs and receipts before
   new demand can dispatch. Current production mode must remain unchanged
   until an atomic cutover.
3. In one runtime cutover, remove the script generator assignment, enable
   manual mode, and route all terrain demand, including startup, secondary
   viewers and movement ahead-of-travel, to the retained owner. The existing
   script edit-paste path must be replaced by native delta invalidation and
   affected block/halo republish; do not leave two edit authorities. This is
   only the render/publication slice of N3: separately switch digging/drops,
   placement, underground air, nav occupancy, lighting source facts and v2
   snapshot composition to native terrain queries before claiming N3 exit.
   Preserve the existing public facade only where it forwards policy or
   typed batches, not as a fallback sampler.
4. Preserve Voxel Tools as the sole temporary collision owner until N5's
   explicit native collision cutover. Do not install parallel native colliders
   to mask stale Voxel Tools publication. At N5, disable viewer-generated
   collision and make native collision receipts the sole physical readiness
   proof while Voxel Tools may remain a render consumer. From observation of
   an edit until replacement is physically acknowledged, affected cells must
   remain blocked for motion/nav admission; preserve the current edit-revision
   guard and actor-safe old/new snapshot behavior rather than treating an
   accepted data insertion as a safe collision swap.
5. Prove pending-to-ready, edits/reload, fresh/known seeds, travel reversals,
   viewport/secondary-viewer movement, teardown while jobs run and real actor
   containment in focused fixtures before the broad Gate 5 matrix. A
   screenshot/real scene must validate visual and gameplay behavior; synthetic
   lifecycle reports are mechanism evidence only.

The current fixture command is `node tools/run-n3-manual-voxel-lifecycle.mjs`.
Its report is
`artifacts/native-world-backend/n3-manual-lifecycle-1790155856338-906a0c30/report.json`.
The headed native-byte injection evidence and limitations are recorded in
`N3_MANUAL_VOXEL_BLOCK_INJECTION_FIXTURE_2026-09-23.md`.

## Immutable encode preparation checkpoint

`NativeCapturedVoxelEncodeJob` now owns a copied source definition, a pinned
immutable delta snapshot, all shaping-page pins, and the typed block request.
Its `encode()` invokes only the pure native encoder, so the prepared object can
outlive later delta/registry mutations and be moved to a worker without calling
Godot or consulting mutable backend state. Focused tests exercise that pin
lifetime while a worker runs, plus incomplete, mixed-provenance, unresolved and
failed captures. This does **not** make capture atomic by itself: the adapter
must still serialize capture on Main and compare source, delta and registry
identities/revisions before dispatch and again when a result returns.

`NativeVoxelBlockDemand::defer(ticket)` releases a stopped capture/worker's
reserved slot without falsely classifying source-pending admission as an empty
terrain block. It retains current consumer demand in `waiting_source` and
requires a new source-ready receipt before redispatch; stale revision/epoch
workers release their physical reservation but cannot revive stale work.
At that pure-core checkpoint, off-Main dispatch, Godot marshalling,
viewer-paired insertion and live mesh/physics publication were unimplemented.

## Async shadow adapter checkpoint

The adapter now has a one-worker shadow-only `begin/poll/cancel` API for a
captured voxel block. Main captures source, delta and shaping pins, enforces
16-primary/64-shaping-page caps, and gives only the immutable job to the
worker. Polling on Main compares the source, delta revision, shaping registry
identity/revision and town policy again before marshalling result bytes to
Godot; an old edit result returns `source_changed_retry` without bytes.
Cancellation marks a cooperative token; encode checks it at bounded page and
column boundaries. An active cancellation drains through poll without joining
on the gameplay call. Backend destruction also sets the token before its
safety join; production teardown must still retain/drain the owner explicitly
rather than relying on a destructor in a frame budget.

The focused installed-engine binding contract is
`node tools/run-n3-async-voxel-shadow.mjs`, with report
`artifacts/native-world-backend/n3-async-voxel-shadow-1790159308598-6441ba60/report.json`.
It passed exact async/synchronous native byte and identity parity, busy and
high-LOD capture rejection, unresolved shaping without bytes, edit-stale
rejection, edited retry, a pending nonblocking cancellation that drained, and
one teardown observation. The
teardown observation was 0 ms, but does not prove a worker was actively
encoding at destruction. This is a service-level test, not a live terrain,
collision, gameplay, or performance acceptance. At that checkpoint, the queue
owner and async adapter were still unbound to `VoxelTerrainRuntime` and each
other; the next section records their later shadow binding.
The aggregate native gate `n3-async-shadow-01` passed 502/502 debug and
release tests, both adapter smokes, and strict pure-core coverage of
11,124/11,124 lines, 1,481/1,481 functions and 6,592/6,592 branches.

## Retained queue to installed-engine mechanism checkpoint

The native adapter now binds `NativeVoxelBlockDemand` to the bounded async
encoder for canonical 16-cubed blocks. Consumer demand is retained before
source readiness; Main captures source/delta/shaping pins, reserves the exact
key, and gives immutable inputs to one worker. Its pump returns complete
prepared channel buffers, repeats them after an insertion rejection, and
requires separate accepted-insertion and mesh/physics receipts. Current
source mutations invalidate old prepared/published generations; unload
requeues active demand for a fresh source capture. The caller cannot supply a
revision or pin as an authority shortcut.

`node tools/run-n3-retained-native-block-injection.mjs` passed on the
installed debug extension. Its report is
`artifacts/native-world-backend/n3-retained-native-block-1790161472961-09906055/report.json`,
with a headed screenshot beside it. An unpaired viewer first rejected the
center insertion; the retained request then retried after viewer attachment.
All 27 native halo blocks were accepted, Voxel Tools emitted a real mesh,
a physics ray hit its collider, and a real `CharacterBody3D` landed on it.
Maximum observed pump call was 344 microseconds in this fixture, while the
full 27-block preparation elapsed about 61 seconds. The screenshot shows a
plain green terrain patch, not production biome materials or gameplay. This
is a bridge-mechanism test, not production cutover, normal-world visual
acceptance, streaming performance, edited-block collision safety, or N3 exit.
`VoxelTerrainRuntime` still installs its script generator in production.
The fixture acknowledges mesh/physics only for the center block; the other
26 blocks' receipt lifecycle and unload/revisit still need integration proof.
Source invalidation rejects old queue generations but does not itself replace
already injected Voxel Terrain data. The future runtime consumer must own that
replacement before actor/nav readiness can move to native receipts.
The same stable source set passed `n3-retained-queue-04`: 510/510 debug and
release core tests, both adapter smokes, and strict pure-core coverage of
11,180/11,180 lines, 1,488/1,488 functions and 6,650/6,650 branches.
`n3-retained-queue-01` and `-02` failed only their new queue coverage floor;
`-03` is invalid because a focused test edit changed the inventoried input
during the run. None is cited as passing evidence.

## Column-local encode performance checkpoint

Focused monotonic telemetry now separates main-thread source capture from
off-thread pure encode. Before column reuse, the installed-engine single
16-cubed unedited block took 425 microseconds to capture and 1,938,240
microseconds to encode (`n3-async-voxel-shadow-1790162143878-4bdf7ca3`).
The generated-cell lattice path evaluated `shaped_surface` once before an
edit lookup and again inside `generated_at`; moving the first evaluation into
the edited branch preserved bytes and reduced a focused encode to about
1.53 seconds. The source-bound, private `LatticeColumnScratch` then reused
immutable shaped-surface, overburden and requested-biome facts across the
Y samples of each X/Z column, retaining per-cell float32 resolution, durable
edit lookup, cave noise, material classification and cancellation checks.

The final focused async report
`artifacts/native-world-backend/n3-async-voxel-shadow-1790163523275-2e688c24/report.json`
passed byte parity and measured 400 microseconds of capture and 111,544
microseconds of encode for its unedited block; its edited retry measured
113,826 microseconds of encode. The direct GDScript differential
`artifacts/native-world-backend/n3-multi-page-shadow-1790163459488-cdab4d8f/report.json`
passes all-channel exact bytes against a freshly generated full 16-cubed
Godot block, alongside the existing seam and edited native-pin cases. The
final native gate `artifacts/native-world-backend/n3-column-reuse-02/report.json`
passes 512/512 debug and release tests, both adapter smokes, and strict
pure-core coverage of 11,206/11,206 lines, 1,490/1,490 functions and
6,682/6,682 branches.

On that installed debug build, the same headed 27-block mechanism fixture
passed in 3,821 milliseconds of preparation instead of 60,861 milliseconds:
`artifacts/native-world-backend/n3-retained-native-block-1790163467584-b89ffd9c/report.json`.
Maximum measured main-thread pump was 283 microseconds; real meshing,
collider ray and `CharacterBody3D` contact remained present. These timings
exclude broad production source admission, gameplay streaming, nav, edits,
normal materials, startup/Continue and sprinting; they are not a Gate 5
performance result or permission to cut over production collision.

The expanded direct Godot/native differential at
`artifacts/native-world-backend/n3-multi-page-shadow-1790164066152-0211c9e9/report.json`
also passes exact SDF, indices and data5 bytes for six small blocks straddling
positive/negative shaping-page seams at LOD 1 and the positive/negative
1960-cell float32 remap boundary at LOD 0 and LOD 1, plus a canonical full
16-cubed LOD 1 block crossing a negative shaping-page seam. Its LOD 10 request
remains explicitly `shaping_dependency_unresolved` with no returned bytes;
that pending result is not a parity pass. This is a focused direct generator
oracle, not a streamed or player-visible terrain result.

The retained-demand headed fixture was then extended through actual viewer
departure and revisit:
`artifacts/native-world-backend/n3-retained-native-block-1790163968047-33154225/report.json`
and its `headed-terrain.png`. VoxelTerrain evicted the center data block;
explicit native unload receipts retained all 27 halo demands. On revisit,
all 27 blocks were reinserted, the center generation advanced from 2 to 4,
and a fresh mesh and physics ray hit were observed. The screenshot shows
only a sparse plain-green fixture patch. This proves a headed bridge
lifecycle, not edit replacement, normal gameplay, full runtime streaming or
Gate 5 acceptance. A first fixture attempt sent an unload receipt only for
the center despite all 27 real blocks being evicted; that correctly failed
the 27-block revisit assertion and prompted full-halo receipt handling.

The next headed edit probe initially failed despite a committed typed source
revision, changed native SDF bytes, 27 accepted replacements and stale
generation rejection. It raised the surface from the center mesh block into
the next vertical mesh block without supplying that block's upper input halo.
The focused correction demanded and inserted the nine y=2 halo blocks before
the edit; the final report is
`artifacts/native-world-backend/n3-retained-native-block-1790164446080-aa58c3d6/report.json`
with a headed screenshot beside it. The revised 36-block replacement passed:
the old receipt was rejected, the y=1 mesh-entered signal fired, a ray hit
the raised collider, a real `CharacterBody3D` landed, and the current upper
generation obtained a mesh/physics receipt. This establishes the vertical
input-halo requirement for the future runtime demand planner. It is still a
small synthetic-world mechanism fixture, not edit safety under live player
movement, normal materials, generated structures, save reload, or Gate 5.
