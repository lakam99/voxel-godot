# N3 terrain cell-source vertical slice and caller ledger

Status: service-level native read path implemented; production `WorldGenerationSystem`
and `TerrainVolumeService` are **not** cut over. No legacy path is deleted yet.

The inert `NativeTerrainRuntimeOwner` now accepts bounded, typed durable cell
transactions against its current native revision. It checks source identity,
rejects stale edits, and returns the existing edit republication plan with
`physicalReady: false`. The same owner subsequently reads the edited cell and
exports its v2 save volume; clearing the edit uses the same native authority.
The installed-engine service contract passes at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790171666415-c810bcff/report.json`.
This is not wired to gameplay edits or physical replacement, and does not
establish New Game/Continue or normal-game acceptance.

Follow-up edit sequencing gate: a committed edit is retained as a pending
physical barrier. The owner preflights the bounded republication footprint
before committing, verifies the native affected-section receipt, and informs
the block publisher immediately after commit. A second edit returns pending
without advancing the native save revision. There is intentionally no barrier
release method yet: the owner remains fail-closed after one edit until N5 can
provide exact live collision acknowledgement, occupancy safety, and a
revision-bound release contract. This service component is not suitable for
production edits in its present state. Focused evidence:
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172076190-ccda949c/report.json`.
The receipt guard now requires exact deduplicated set equality between the
native conservative affected sections and the preflighted mesh halo. The
focused real receipt plus forged foreign, duplicate, and missing-section
checks pass at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172197383-6f38d9b7/report.json`.
The stronger missing-neighbor check passes at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172570225-d0c9c2f2/report.json`
in the isolated N3 worktree.
Release-candidate inspection now binds the pending plan to the live owner
instance, source identity/epoch, native revision and barrier identity before
checking all subwindow/mesh receipts. Forged owner, stale revision, foreign
epoch, partial and duplicate candidates are covered by the installed-engine
service fixture at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172721925-a15dd1ec/report.json`.
Even a structurally complete candidate returns
`production_physical_owner_unbound`: caller dictionaries cannot attest to live
collision or actor occupancy, and this method never clears the barrier.

`NativeTerrainOccupancySource` now derives `terrain_occupancy_at_cell`'s
ten gameplay fields from one native three-cell batch (center, above, below).
The owner exposes the typed result with pending/revision propagation. The
installed-engine service fixture first compared a saved edited stone cell and
saved air over support, then independently compared a generated same-seed
neighbor triple after initializing the real `WorldGenerationSystem` sampler.
All comparisons passed at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790173005001-accdc039/report.json`.
An earlier fixture run initialized `TerrainVolumeService` with no generator;
its unedited neighbors returned air and were not a valid generated parity
oracle. Production `WorldGenerationSystem.terrain_occupancy_at_cell` and nav
consumers still use the script service; this bridge supplies source facts only
and does not prove physical publication or safe navigation occupancy.

The native initialization request can now take the explicit v2 terrain-volume
snapshot already present in Continue's save envelope. The existing
`from_main_with_current_volume` bridge delegates to that schema builder;
the explicit path succeeds without a script volume owner and is accepted by
the native backend. Focused service evidence:
`artifacts/native-world-backend/n3-world-source-request-1790173161009-94e2b53d/report.json`.
`MainSaveState` still restores into `TerrainVolumeService`; this only prepares
the later atomic save/Continue owner switch.

`NativeTerrainRuntimeOwner.setup` now consumes that explicit v2 snapshot when
provided. An installed-engine service fixture initializes and drains separate
owners for Continue (saved edited volume with no script volume owner) and New
Game (empty script durable volume), and verifies exact native save export for
each. Evidence:
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790173249875-7ac791c3/report.json`.
This is owner setup only. `MainSaveState` and `VoxelTerrainRuntime` remain
script-owned in production, and live New Game/Continue loading, physical
collision replacement, and save-after-play are unproven.

Save-v2 optional-field audit: `SaveSystem` checks version 2 but does not
require `terrainVolume`. `MainSaveState.apply_save_snapshot` applies historical
`terrain` column edits first, then, when a nonempty `terrainVolume` exists,
resets and restores that volume. Current new saves write `terrain: []` and a
full volume, but valid earlier v2 saves may omit or empty `terrainVolume`.
`from_main_with_v2_save` now resolves absent/empty volume plus empty `terrain`
to one canonical empty native volume, and uses a present full volume with the
same precedence as current restore. A nonempty historical `terrain` list with
no full volume returns pending `native_legacy_terrain_conversion_required`
instead of silently discarding terrain edits. Both accepted shapes round trip
through the installed native backend, and the pending/precedence cases pass at
`artifacts/native-world-backend/n3-world-source-request-1790173418313-94456927/report.json`.

The valid-v2 conversion must derive each column's prior surface
from the native source in save order, apply the historical excavation cells
as typed durable native transactions, and export one canonical volume before
playable Continue. It must admit shaping pages and retain pending work, bound
large columns across frames, and preserve the current `terrainVolume` override
rule. No production Continue cutover is safe until conversion is wired into
loading and headed reload evidence exists.

The loading-only `NativeV2LegacyTerrainConverter` now converts historical v2
`terrain` columns when `terrainVolume` is absent or empty. It reads the native
effective surface in save order, prepares at most 64 cells per frame, and
commits each excavated column as one typed native transaction so global and
section revisions match `MainSaveState.restore_volume_edits`. A resolved save
enters the ordinary native v2 import path. The focused service contract
compares exact full snapshots against that production restore method for a
negative column, duplicate ordered columns, and a deep column; it also covers
pending page admission, cancellation, malformed input, and oversized-column
failure. Report: `artifacts/native-world-backend/n3-world-source-request-1790174219980-877b22e0/report.json`.
The converter now uses a private native staged durable transaction: it appends
at most 64 typed cells per loading step, then commits one full column off the
Godot frame and exports the completed v2 volume on a worker. A column beyond
the adapter's 4096-operation one-shot limit matches the complete historical
script snapshot, including its single revision and section stamps. Cancelling
after a partial append or during the native commit drains the worker without
publishing a playable owner. The focused report at
`artifacts/native-world-backend/n3-world-source-request-1790176366615-6417e805/report.json`
records a 1,721-microsecond maximum `advance` step for the >4096-cell fixture;
the native core executable passed 520/520 tests. This is a service fixture,
not a headed loading-cadence measurement. The converter's
scheduling and save-shape adapter are transitional; v2 terrain-list support
must remain through an authoritative native conversion API at production
cutover. This service report does not prove headed reload, physical
publication, or runtime frame budgets.

`NativeTerrainRuntimeOwner.setup` now retains this conversion as a pending
loading state, and `advance` imports the completed canonical save before
activating the terrain publisher. Stop cancels pending conversion. The owner
contract checks no partial save export during conversion, exact restored v2
snapshot after activation, and cancellation, at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790174495648-296ca828/report.json`.
This is an owner-level service checkpoint. No production Main caller retains
this owner across pending setup yet; loading feedback, headed Continue, and
physical world readiness remain unproved.

The converter's temporary GDScript numeric-boundary scan has been removed.
`NativeEffectiveTerrainPage.sample_continuous_surface` now exposes the
existing native continuous-volume surface calculation from its pinned source,
with source identity and revision receipts checked by the converter. Exact
historical v2 snapshots still match `MainSaveState` for negative, duplicate,
and deep columns. The focused report at
`artifacts/native-world-backend/n3-world-source-request-1790175217913-96ac5117/report.json`
records maximum conversion-step durations of 1,424 microseconds for the
ordinary fixture and 1,912 microseconds for the deep fixture. The native core
executable passed 519/519 tests. These are isolated service measurements, not
headed loading-frame cadence or production Continue evidence.
`NativeTerrainCellSource.read_cells` is a bounded, all-or-nothing gameplay-cell
query over `NativeWorldBackend.pin_effective_page` and
`NativeEffectiveTerrainPage.sample_batch`. It retains caller order and
duplicates, groups by 280-cell source page, maps the native cell-center record
to the existing cell-state vocabulary, and rejects absent owner, pending or
failed page, incomplete result, mixed source identity, and delta revision
change during the read. It has no GDScript generation or saved-edit fallback.
The exact edited-air, edited-stone, cross-page, light/metadata, and
post-commit fresh-pin contract passes at
`artifacts/native-world-backend/n3-terrain-cell-source-1790169372413-f9b5e411/report.json`.
This does not establish generated-cell parity, normal-game latency, live
collision, visual behavior, or N3 production authority.

`NativeTerrainNumericSource.read_numeric_batch` is the next source slice. A
mixed batch pins pages once per page and requests `worldNumeric` with
`terrain_mesh` intent and `surfaceProjectionNumeric` with
`terrain_collision` intent, both semantic revision 1. It rejects page
pending/failure, mixed source identity, incomplete/misordered results, and
delta or shaping revision changes without returning partial rows. The
focused installed-adapter test compares exact Godot `Vector3` values with
`TerrainVolumeService.numeric_sample_world` and
`WorldGenerationSystem.volume_surface_numeric_sample_at_grid_cell` at
positive and negative coordinates, including a negative durable-air edit in
both channels. Its contract passes at
`artifacts/native-world-backend/n3-terrain-numeric-source-1790169978387-9adf2694/report.json`.
The mock pending/failure cases are service-level propagation checks. This
numeric projection is **not** the higher-level walkable-surface/occupancy
projection and does not prove engine collision or nav readiness.

## Production caller/deletion map

| Existing API/owner | Observed production consumers | Native cutover requirement |
| --- | --- | --- |
| `TerrainVolumeService.get_cell_state` via `WorldGenerationSystem.get_cell_state` | `SubsurfaceSystem` material/drop scan; `MainChunkTerrain` scene-block placement/removal; `WorldGenerationSystem` occupancy/other derived queries | Replace computational cell lookup with native gameplay cell-center batch. Keep gameplay callers and typed state vocabulary. Do not return a guessed generated cell while a page is pending. |
| `sample_world`, `sample_cell`, density/solid/material/biome wrappers | `HostileSystem`, `MainGameLoop`, `MainPlaytestTools`; many internal `WorldGenerationSystem` consumers | Native world-numeric query must preserve position-intent semantics, full sample dictionary, and pending state. The new cell facade alone is not a substitute. Remove `generate_sample_without_volume` fallback only at atomic cutover. |
| `numeric_sample_world`, `volume_surface_numeric_sample_at_grid_cell`, meshing payload and bounds | `VoxelTerrainRuntime`, `MainPlaytestTools`, terrain/fluid meshing services | `NativeTerrainNumericSource` now covers the first two numeric queries with exact native intent and pinned revision. It does not replace bulk meshing payload construction, bounds scans, or native block publication. Preserve render/collision halo. |
| `terrain_occupancy_at_cell`, `surface_projection_for_cell`, walkability and related surface queries | `MainPropFactory`, `StructureSystem`, `NpcSystem`, `GeneratedWorldNavigationAdapter`, `MainPlaytestTools`, `VoxelTerrainRuntime` | Derive from one native snapshot with explicit pending/physical publication. Do not change NPC/navigation consumers independently or infer collision readiness from a cell query. |
| `set_cell_state`, clear, box/sphere/deformation and incremental edits | `SubsurfaceSystem` digging, `MainChunkTerrain` scene blocks, `MainSaveState` legacy volume restore, `WorldGenerationSystem` brush conversion | Replace `TerrainVolumeService.edited_cells` composition with typed native transactions. Keep incremental gameplay budgeting, exact changed cells, drops, light followups, and actor-safe physical replacement. Scene overlays are a distinct non-mesh namespace. |
| `save_terrain_volume_deltas`, `load_terrain_volume_deltas`, section delta/revision | `MainSaveState` New Game/Continue, `SubsurfaceSystem` authority check, `VoxelTerrainRuntime` edit discovery, terrain/fluid publication | Preserve v2 envelope and pin one native revision for export/import. Delete full script snapshot/`edited_cells` scan only after native edit, save and publisher receipts are connected. Never persist Voxel Tools injected blocks as generated world deltas. |
| Light/fluid source and dirty-section APIs | `WorldGenerationSystem`, `VoxelTerrainRuntime` and gameplay lighting/fluid consumers | Retain orchestration where appropriate, but move canonical light/fluid source facts and delta invalidation to native before declaring N3 complete. |

The caller audit used `rg` across production `scripts/*.gd` (excluding
`scripts/testing/**`), then inspected `WorldGenerationSystem`'s public
forwarders and `TerrainVolumeService`'s owner methods. `NpcNavigationTestRunner`
is a test entry point, not production gameplay. The table is a cutover checklist,
not permission to delete a mixed-responsibility file. No code in NPC/nav was
changed. Next vertical slices should add bulk/derived queries and
transaction/save orchestration, before atomically replacing the
production `WorldGenerationSystem` forwarding paths.

## Production terrain owner handoff

`MainRuntimeTools.ensure_voxel_terrain_authority` is the concrete production
constructor. It creates `VoxelTerrainRuntime`, calls synchronous `setup(self)`,
and accepts only `{ok:true}`. That setup installs the script generator on
`VoxelTerrain`, attaches the script-backed site gate, and immediately sets
`authority_ready`. `MainCore.reinitialize_voxel_terrain_authority_staged`
retains the runtime on Continue, calls `reset_for_current_seed_staged` when its
generation context changes, and requires `authority_ready` plus the expected
seed before publication. The reset drains Voxel Tools tasks, then replaces the
script generator and site gate. The native owner has not entered either path.

The replacement must preserve the runtime-facing chunk admission/release,
foreground collision demand, edit collection, gameplay publication, startup
collision bounds/proofs, viewer expansion, shutdown drain, and diagnostics
contracts used by `MainRuntimeTools` and `MainCore`. A native owner returning
`pending` from setup cannot fit the current synchronous constructor: loading
must retain that same instance, advance conversion and publication each frame,
show progress, and handle cancellation. For Continue, `MainSaveState` currently
restores historical `terrain` synchronously into the script volume before the
runtime's staged reset; initial Continue does the same before bootstrap. A
production switch must route one save snapshot to native conversion/import,
keep the current full `terrainVolume` precedence, and remove that script
terrain restore at the same authority cutover. The script volume cannot remain
a second save/edit/mesh source after native publication begins.

N5's physical install, rollback, collision, and actor admission receipt must
gate `authority_ready` and gameplay release; a logical native page or edit
commit alone is insufficient. Until those runtime contracts are implemented
and verified through headed New Game and Continue, the N3 owner remains an
inert service and the production script runtime remains authoritative.

`NativeTerrainTriangleArtifactProducer` now provides the source-bound input
side for N5's future resident collision owner. It asks the native backend for
an asynchronous padded 19-cell block (Transvoxel padding 1/2), loads all three
native SDF/indices/data channels, and calls the installed Voxel Tools
`VoxelMesherTransvoxel.build_mesh` API. The resulting triangle soup is scaled
and translated from local 16-cell block coordinates to world coordinates.
This is a native-source consumer using Voxel Tools meshing, not a first-party
pure-C++ geometry authority or an installed collision shape. Rows retain
source/pin/content identities, native and shaping revisions, owner/source and
cancellation epochs, a deterministic artifact key, world bounds, and a probe
segment. Empty blocks produce an explicit no-shape row. The source-owned
`collision_artifact_row` returns a deep copy so N5 can reject caller-modified
vertices even if a key is reused.

Required mesh membership is derived independently in
`NativeTerrainDemandPlanner` from the same viewer/chunk source geometry as
data-block demand, without its data halo. Identical demand refreshes retain
their revision and closure token; a changed closure gets a new identity. The
producer's `collision_source_snapshot` stays pending until every required
block has a source-bound artifact with current local page pins.
Artifact keys digest the exact native channels and source identity; an
unrelated durable edit can refresh row revisions without changing an unchanged
block's key. A global shaping revision change rechecks each row's padded
block primary-page pins through the native effective-page API. A distant page
change leaves unrelated rows current; a changed local physical pin requires
the affected row to be encoded again. This contract is still a service boundary:
the production `VoxelTerrainRuntime` does not consume it, N5 has not installed
its full resident collision set, and Voxel Tools remains the live collider
authority. Focused evidence:
`artifacts/native-world-backend/n3-triangle-artifact-1790178008748-faeb26fd/report.json`
passes native payload/triangle attribution, empty blocks, stale worker drain,
immutable row copy, no-op demand identity, negative/adjacent analytic seams,
and a measured maximum `advance` step of 2,237 microseconds in that fixture.
It does not prove headed loading cadence or full-world collision parity.

The inert `NativeTerrainRuntimeOwner` now composes
`NativeTerrainArtifactRequests` from its existing backend, shaping page
admission, site admission and demand planner. N5 can read
`required_collision_mesh_blocks()`, retain exact demanded blocks through
`request_collision_artifact(block)`, make one bounded producer step through
`advance_collision_artifacts()`, and fetch the current source snapshot and
source-owned rows. A changed demand closure or native source revision drains
the prior producer before a new pinned producer is created; requested blocks
still in demand remain queued. The owner increments cancellation identity for
each producer and preserves its owner generation. It does not install or retire
colliders, set `authority_ready`, or change Main/Continue. The focused service
fixture covers request retention and demand-change producer replacement at
`artifacts/native-world-backend/n3-triangle-artifact-1790178474287-be48d6b6/report.json`.
The earlier cap-aware pending boundary is superseded by deterministic spatial
windows. Directly binding the unpartitioned source to one N5 owner stays
pending when the full mesh closure exceeds that owner's cap.
The focused two-distant-block shaping test at
`artifacts/native-world-backend/n3-triangle-artifact-1790178952729-d395b59f/report.json`
proves a remote registry revision preserves the first block's canonical row
while the distant block is produced. The broker reports idle as pending even
after its request queue empties; only the source snapshot can declare its
logical artifact closure, and only N5's physics receipt can declare physical
readiness. The test does not prove a live collision owner or gameplay release.

The planner now partitions the exact logical mesh closure into 16³ mesh-block
spatial windows. A 17³ (4,913-block) demand yields eight disjoint windows,
each at most 1,296 blocks, and the union equals all 4,913 demanded blocks.
The broker provides an independent parameterless source facade for each
window. Its local token and membership provenance remain stable when a
distant demand source changes. The global layout still carries the full block
list and logical closure token for N5 to verify one complete aggregate
physical receipt. Changed windows retain their canonical rows and facade
until an explicit drained-owner retirement acknowledgement. Idle broker and
unbuilt windows remain pending. A demand change during async face extraction
drains and discards that worker result before rebinding the producer.
Focused evidence:
`artifacts/native-world-backend/n3-terrain-demand-planner-1790179731210-2c24f5ab/report.json`
and `artifacts/native-world-backend/n3-triangle-artifact-1790179724985-2e1fc94e/report.json`.

This is source and planner contract evidence. N5 still needs aggregate owners
and an exact union physical receipt; no 4,913-block physical completion is
claimed. A global durable terrain revision still changes every window's N5
identity, even when the edit is distant. Native affected-section and local
content identities may support a later scoped proof, but this change does not
retain physical owners across such revisions.

Superseded window rows remain available to the coordinator until it supplies
a drained physical-owner retirement acknowledgement. N3 now accounts their
window count, row count and vertex bytes. More than 64 unretired windows or
256 MiB of retained vertex arrays pauses new source publication with
`collision_window_retirement_backpressure` and the exact retired tokens;
acknowledging a drained window releases its rows and permits retry. The
broker preflights the projected retired set before creating another layout,
then stops further layout materialization while retirement backpressure is
active. The focused 66-to-1-window contract proves the count cap, two more
demand changes without record or byte growth, explicit acknowledgement and
resumption at
`artifacts/native-world-backend/n3-triangle-artifact-1790180079292-6b43bb0b/report.json`.
If the demand returns to the previous current layout before physical drain,
N3 revokes the projected retirement intent. A formerly pending token cannot
then be acknowledged, and all original window facades remain current. A third
rejected target recomputes the exact pending token set without allocating
another record. Focused regression:
`artifacts/native-world-backend/n3-triangle-artifact-1790180209479-f46d5f1e/report.json`.
The runtime coordinator must derive each acknowledgement from the corresponding
N5 owner's actual `stop_and_drain()` result; the source fixture supplies a
contract-shaped receipt and does not prove that production coordinator path.

N3's scoped durable-edit candidate accepts only the runtime owner's native
committed receipt after exact `affectedSections`/edit-plan parity. A bounded
revision journal records conservative affected mesh blocks. Across a global
terrain revision, a prior window keeps its local physical identity and
source-owned row only when every intervening verified edit excludes all of
its mesh blocks, the shaping revision matches, and fresh native local page
pins equal the row's recorded pins. The layout carries the current global
source/save revision; each window member carries its local identity and a
proof digest through that global revision. Missing receipt/revision, changed
local mesh, or changed page pin fails closed and demands a new artifact. Proof
work yields after a 2 ms per-frame budget. Focused source contract
`artifacts/native-world-backend/n3-triangle-artifact-1790180958697-e9200b71/report.json`
shows a distant edit retaining the near window token with global revision 1,
a missing-journal broker retiring it, and a local edit invalidating the
affected window. This does not yet prove N5 aggregate physical acceptance
under a new global revision; the joint fixture must compare the old physical
owner receipt to local identity and the aggregate receipt to global identity.

## Production Cutover Checkpoint: Ordered Owners And Atomic Staging

Production remains fail-closed. `MainRuntimeTools.ensure_voxel_terrain_authority`
currently installs the script `VoxelTerrainGenerator` into the Voxel Tools
terrain runtime, while `NativeTerrainRuntimeOwner.setup` requires a manually
populated `VoxelTerrain` with its generator absent and automatic loading
disabled. Calling the owner from Main today would not transfer the active
terrain/collision authority; it would create an incomplete or competing
publisher. The N3 source-cell adapter parity report and N5 physics fixtures
listed above do not establish a safe Main cutover.

### Preconditions And Responsible Owners

Complete these gates in order. A later gate cannot compensate for an earlier
one:

1. **Freeze source identity and load inputs — `WorldGenerationSystem` / Main
   loading owner.** Finalize seed, generation and biome revisions/constants,
   town/site inputs, and the one save-v2 terrain snapshot before constructing
   the native effective source. New Game must use the canonical empty delta;
   Continue must preserve current v2 precedence, including historical `terrain`
   conversion and nonempty `terrainVolume` overrides. Pending source pages must
   retain the load transaction and visible loading state until retry, cancel, or
   structured failure.
2. **Prove generated-cell and delta composition parity — N3 native source
   owner.** Match production facts for material, biome, fluid, solidity,
   density, light, and edited state across representative boundaries and seeds.
   Explicitly reconcile cell-center versus lattice coordinates, negative floor
   division, page/section dimensions, FastNoiseLite and hash behavior, fluid and
   underground thresholds, identifiers, metadata, and durable-edit precedence.
   No script-generated fallback may answer a native pending or failed query.
3. **Provide retryable query and mutation lifecycle — Main loading / world
   query facade owner.** The synchronous gameplay callers must either await a
   retained result or receive an explicit unavailable state; no intent may be
   dropped while a native page is pending. Cancellation and teardown must drain
   outstanding work before releasing the owner. This is required before
   `WorldGenerationSystem` can delegate cell queries and durable edits.
4. **Bind one source to physical publication — N2 terrain publisher and N5
   physical-window owner.** Manual voxel blocks, mesh, collision, unload,
   revisit, and replacement must derive from the same pinned native source
   revision. N5 must provide aggregate physical acknowledgement and actor
   admission evidence; a service receipt or fixture-shaped acknowledgement is
   insufficient. Keep the existing collision-backed world active until the
   replacement artifact is acknowledged, and define rollback and stop/drain
   behavior before switching.
5. **Switch source, readiness, and save together — Main setup / save-v2 / N5.**
   One cutover transaction must publish the native query source, physical
   artifact, readiness state, and save export revision as a unit. Save snapshots
   must export the same durable native deltas that queries and publication use.
   If any acknowledgement is stale, missing, or rejected, retain the old
   playable authority and retry or report a structured load failure.
6. **Delete superseded authorities — owners from the call-site census.** Only
   after the atomic switch and rollback window are accepted may the project
   remove script cell generation, duplicate durable terrain restoration, copied
   initial edits, and `VoxelTerrainGenerator`. Delete each path only after a
   caller audit proves it has no production consumer. Keep scene policy and the
   Godot-facing adapter where still required.

### Atomic Staging Plan

Stage A's intended contract is a retained Main load transaction behind the
existing production source: freeze exact source inputs and one v2 snapshot,
retain pending work, expose progress, and drain cancellation without publishing
native gameplay queries or collision. An initial prototype wired synchronous
native initialization into deferred Main startup, but review found that its
snapshot construction/deep copies and `initialize_from_save_v2()` parse the
whole durable volume inline. The explicit staged New Game and runtime Continue
paths were also not wired to that transaction. That unsafe/partial Main hook
has been removed. The fixture-fed transaction remains service evidence only;
it is not Stage A completion. See
`N3_RESPONSIVE_MAIN_LOAD_INITIALIZER_DESIGN_2026-09-23.md` for the measured
limitation and the bounded native-import design required before re-integrating
it with Main.

Stage B routes cell reads and durable mutations through that retained owner.
It cannot ship until gate 2 parity and gate 3 pending semantics pass. Stage C
publishes manual voxel artifacts from the same source and waits for N2/N5
physical acknowledgement while preserving the old collision world. Stage D
atomically switches readiness and save export with the acknowledged physical
artifact, with rollback until all stale work is drained. Stage E removes old
generation and save paths after the call-site/deletion audit. Each stage must
be independently reversible; no stage permits a script query to mask native
pending/failure while native publication is active.

### First Code PR Boundary

The first code PR should implement only Stage A if Main loading can own the
new lifecycle independently of `VoxelTerrainRuntime` setup. Before coding,
split construction of the native cell source/owner lifecycle from activation
of `NativeTerrainRuntimeOwner`'s manual `VoxelTerrain` publisher. If those APIs
cannot be separated without changing the active publisher, keep this checkpoint
as the first reviewable step and do not wire the owner into Main. A safe Stage A
must not instantiate a second terrain/collision authority, change
`startup_loading_completed`, change save contents, or alter generated queries.

The checkpoint's current evidence is deliberately bounded: the N3 cell-source
adapter report proves typed field parity for its fixed seed and listed cells;
the two N3/N5 reports prove their focused physics fixtures. Neither proves
Main New Game/Continue, end-to-end save-v2 parity, cancellation responsiveness,
or an atomic source-to-collision cutover. No gameplay code or test-only runner
is added by this ledger update. The first code PR must report its exact diff,
commit, focused lifecycle evidence, and measured worst frame / pending-page
lag before subsequent gates are considered.

## Shadow Projection Query Slice

N3 now has a shadow-only, immutable-pin projection batch beside the existing
numeric batch. It does not activate `WorldGenerationSystem`, terrain runtime,
collision publication, navigation, routing, Main, or NPC code. The batch
accepts caller-owned start cells and bounded up/down distances, returns the
first solid-to-air boundary with both complete effective cell states, and has
a separate walkable result with headroom and occupancy. Fluid remains present
in the standing state and occupancy; like the current script authority, fluid
alone does not reject walkability.

The ordinary projection returns cell-centred X/Z and the air cell's lower-face
Y. The known-height projection preserves corner-aligned X/Z and the caller's
exact smooth Y. Known-height parity follows the executable script loop
`range(probe_y, probe_y - 3, -1)`: exactly three candidate boundaries and five
unique cached cell reads. The nearby script comment that says “four cells” is
stale and is intentionally not treated as executable behavior. Both query
forms clamp to the admitted world top/bottom, normalize each negative or zero
up/down distance with `max(1, value)`, preserve negative coordinates, and fail
closed outside the pin's primary page or semantic/domain contract.

The adapter contract is
`n3-effective-terrain-projection-batch-request/v1` to
`n3-effective-terrain-projection-batch-result/v1`. It enforces exact top-level
and nested keys/types, channel and aggregate query caps before allocation,
per-query and aggregate candidate/read budgets, a logical payload-byte cap,
and atomic rejection without exposing partial output. Results preserve request
order and duplicates and bind source identity, pin identity, terrain-delta
revision, shaping revision, and shaping identity. Retained state accounting
includes the complete recursive metadata encoding plus block ID and edit
reason; result dictionaries expose the same complete state, fluid/light, and
occupancy facts. Fixed payload accounting is exact and padding-independent:
76 bytes for surface, 101 for walkable, and 102 for known-height before the
retained dynamic states. Focused boundaries admit a 102-byte state-free
known-height mismatch and reject it with a 101-byte cap.

Focused evidence uses audio-disabled automation:

```powershell
$env:VOXEL_DISABLE_AUDIO_PLAYBACK='1'
node tools/run-n3-native-terrain-projection-contract.mjs
```

That Godot contract invokes the debug GDExtension projection adapter and proves
schema/revision/identity, order/duplicates, full state payloads, fluid-aware
walkability, no-result shape, old-pin immutability, malformed nested requests,
and recovery after rejected channel, aggregate, vertical, cell-read, payload,
and mixed-invalid requests. The prior passing report at
`artifacts/native-world-backend/n3-terrain-projection-1790211759823-e7870de0/report.json`
predates those expanded adapter-cap cases; they must be rerun from the final
commit during integration. The broader native
gate also passed 535/535 tests in both debug and release, loaded the debug
adapter, and loaded the just-built exported-release adapter. The exported
release smoke proves the native module/class and existing save-v2 adapter
boundary, but does not itself invoke the new projection method.

The final tracked-only focused LLVM receipt is preserved at
`artifacts/native-world-backend/n3-projection-shadow-focused-coverage-postcommit-654b6fc/focused-coverage-receipt.json`
with SHA-256
`89c93678b2f4741e336b9dbbc5bb1c4bea368cc511e5370c5dd8ffb5d2b2101b`.
It records 535/535 standalone native tests and complete coverage across the two
touched pure-core source/batch translation units: 1,025/1,025 lines, 79/79
functions, and 352/352 branches. The forwarding-wrapper assertion that closes
the denominator is part of the tracked native test suite; no transformed or
untracked harness participates. These LLVM percentages cover the standalone
pure core only and do not instrument the GDExtension adapter C++. The expanded
adapter contract is runnable, but the final adapter rebuild and focused Godot
contract execution remain required on the primary integration worktree; they
must not be reported as 100% instrumented adapter coverage.

Integration verification at `e24e0af` rebuilt and installed both native
configurations. `artifacts/native-world-backend/n3-projection-final-integrated-20260923/report.json`
records 554/554 standalone tests in each configuration and successful adapter
smokes, but its overall status is `blocked`: full-core LLVM coverage is
12,552/12,562 lines, 1,591/1,591 functions, and 7,281/7,300 branches.
The missed branches are in the terrain-volume v2 import builder and ordered
surface-prop stream. This is a coverage-gate failure, not a native test pass.
The freshly installed debug adapter separately passed the audio-disabled
projection contract at
`artifacts/native-world-backend/n3-terrain-projection-1790215474218-f704ef2a/report.json`;
the owned Godot process receipt is
`artifacts/node-tools/process-runs/godot-uq74aE/watchdog.json`.
That fixture remains shadow-only and does not establish production cutover.

A follow-up independent review found that the adapter contract did not compare
pre-edit and old-pin projection content or require a negative page. Both
assertions now pass in the audio-disabled fixture at
`artifacts/native-world-backend/n3-terrain-projection-1790215676898-60614256/report.json`
(owned-process receipt `artifacts/node-tools/process-runs/godot-XBhmWe/watchdog.json`).
Reachable import-validation, disposal and surface-stream cancellation branches
now have standalone tests. The current-source recheck at
`artifacts/native-world-backend/n3-projection-reviewed-gap-20260923/report.json`
passes 558/558 tests in debug and release, but remains `blocked` on strict
full-core coverage: 12,552/12,562 lines, 1,591/1,591 functions and
7,298/7,300 branches. An audit of its coverage payload found
`coverage.core.uncovered.lines` was not trustworthy: it listed 38 lines from
14 files whose own LLVM summaries were 100%, while omitting the ten true
uncovered lines in `native_terrain_volume_v2_import_builder.cpp` (108–112,
165–169). The two actual missed branch outcomes are builder checks at lines
69 and 84. The line-69 same-section/revision-change branch is reachable and a
focused rejection/drain test has been added; the line-84 typed-snapshot
equality check is a defensive invariant not reachable through ordinary public
construction, so no production test seam was introduced. A corrected runner
now serializes uncovered lines from LLVM's LCOV DA records, requires every
manifest source and reconciles per-file line totals; replaying the existing
raw coverage export/profile reports exactly the ten importer lines and no
false positives. Its focused Node runner tests pass 13/13, and the importer
translation-unit test passes 10/10. The existing report is still tied to its
original source snapshot and the new reachable branch test has not yet been
covered by a regenerated full-core receipt. Strict coverage verification, N3
exit and Gate 5 remain open.

The staged collision-demand snapshot is now consumed by both
`NativeTerrainArtifactRequests` and `NativeTerrainTriangleArtifactProducer`;
their production call paths no longer take the planner's synchronous full
`required_collision_mesh_blocks()` snapshot. The integrated focused contracts
pass on commit `f8b0e74`: demand replacement at
`artifacts/native-world-backend/n3-terrain-demand-replacement-1790216714204-f12581fe/report.json`
and triangle artifact at
`artifacts/native-world-backend/n3-triangle-artifact-1790216730988-45a5d177/report.json`.
The demand contract observed 1,247 advances / 383,030 work operations with a
256-operation maximum; triangle artifact observed 943 advances / 199,587 work
operations with the same 256 maximum. Both report no failures. The Godot
runner loaded the primary debug GDExtension with SHA-256
`026A4F2423D9B8748D9ED0DF91550A05B57410FA8232B183005FF62DBAE83D40`;
the worker's original focused reports used the same copied binary, not a
worker-built DLL. These are focused planner and Voxel Tools service-contract
receipts only (`productionCutover: false`): no VoxelTerrain runtime wiring,
publication/collision, or headed gameplay/performance acceptance is proven.
At this earlier checkpoint the production consumer still synchronously called
`collision_mesh_window_layout()`; the subsequent staged-consumer slice below
replaces that call. The synchronous method remains only as a compatibility and
test reference.

The subsequent staged collision-window consumer slice (`67089eb`) replaces
the production broker's synchronous layout call with bounded begin/advance/
cancel work, atomic publication, and stop-time lease/scratch draining. Its
focused staged-consumer, demand-replacement, and triangle-artifact reports pass
on the integrated primary build (`1cde42d`):

- `artifacts/native-world-backend/n3-staged-window-consumer-1790219285586-0a56b71d/report.json`
- `artifacts/native-world-backend/n3-terrain-demand-replacement-1790219292279-8bee3422/report.json`
- `artifacts/native-world-backend/n3-triangle-artifact-1790219307396-4d131f0a/report.json`

The consumer contract observed 348 advances / 88,560 work operations (maximum
256), including stale-source cancellation, changed-revision parity, direct
`stop()` remaining pending until drain, and both mid-build and transferred-
scratch shutdown. Demand replacement observed 1,247 advances / 383,030 work
operations (maximum 256). Triangle artifact observed 2,361 advances / 561,833
work operations (maximum 256). These remain service/planner and
Voxel-Tools-service evidence only (`productionCutover: false`). The adapted
N3N5 windowed-physical runner did not produce a report before its 60-second
watchdog timeout; its owned process was terminated and authoritative zero
membership was proven in the worker worktree
(`artifacts/node-tools/process-runs/godot-FMVVaT/watchdog.json`).
That run is timed out/unverified, not a pass, and no N3N5 physical-integration
or production-cutover claim is made from it.

The demand-replacement follow-up (`34b1f8a`, integrated as `b9ec70a`) adds a
single retryable successor slot and bounded begin/advance/cancel entry points
to the runtime owner, preventing an already-issued demand token from being
silently displaced. On the integrated primary build, the focused replacement
contract passed at
`artifacts/native-world-backend/n3-terrain-demand-replacement-1790220487394-6b09916b/report.json`
(1,250 advances, 383,610 total work operations, maximum 256), and the native
binding owner contract passed at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790220509999-8597552c/report.json`.
Both are focused service/planner evidence only (`productionCutover: false`).

A reduced 18-second N3N5 diagnostic probe reached the changed-demand staged
layout phase after backend initialization, initial layout, artifact rows, N5
physical publication, and a distant durable edit had completed. For the
shifted demand (revision 2, two required blocks), `replace_sources` returned
ready but the staged layout remained pending. A second capped probe sampled
the state at steps 25 through 275 and established an orphaned transaction: the
broker retained token 7 and returned `pending/mesh_layout_work_pending` with
zero work, while the planner builder was idle (`is_active: false`, empty kind,
token 0, no pending retirement). Code inspection then found the ownership
race: required-block and layout wrappers share one builder, and `begin` can
return generic `pending` plus another active kind's token; callers currently
treat any pending response as acceptance of their own transaction. If the
actual owner completes and transfers the result first, the mistaken caller
advances an idle builder and can wait forever. Both probes are diagnostics, not
gate passes; the second run hit its 18-second cap and was authoritatively
cleaned up with zero owned-process membership. The production fix must make
begin acceptance explicit and kind-bound, validate the expected token/kind on
advancement, and clear or retry only after proving that the owned transaction
is terminal and no retirement scratch remains. Publication still requires
exact token, revision, and closure agreement. No N3N5 integration or production
cutover claim is made until the focused regression and bounded physical
contract pass.
