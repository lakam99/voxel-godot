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
