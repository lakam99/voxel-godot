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
The request boundary reads N5's current resident cap and returns explicit
`resident_mesh_capacity_backpressure` with required block count, cap, demand
identity and retained request count when the complete mesh closure is too
large. It drains a superseded producer before applying that backpressure and
never offers an oversized ready source snapshot to N5. This is a bounded
service response, not spatial retirement or a solution for legitimate larger
world demand. The two-block/one-block-cap focused preflight is covered in
`artifacts/native-world-backend/n3-triangle-artifact-1790178589610-4fd2eab5/report.json`.
The focused two-distant-block shaping test at
`artifacts/native-world-backend/n3-triangle-artifact-1790178952729-d395b59f/report.json`
proves a remote registry revision preserves the first block's canonical row
while the distant block is produced. The broker reports idle as pending even
after its request queue empties; only the source snapshot can declare its
logical artifact closure, and only N5's physics receipt can declare physical
readiness. The test does not prove a live collision owner or gameplay release.
