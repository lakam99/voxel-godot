# Native World Backend Migration — New-Chat Handoff

Date: 2026-09-17. Status: **PLANNED; NOT IMPLEMENTED; original Gate 5 remains OPEN.**

## 1. Mission and user decisions

Move the game's entire procedural world-generation and world-collision backend to C++, in reviewable stages. The seeded world plus durable edits is the authoritative physical world: collision, rendering inputs, navigation inputs, interaction geometry and saves must agree on that same source. This is not a request to move a few hot loops while leaving generation/solidity authority in GDScript.

Keep a standalone, engine-independent C++ core with unit tests for every new first-party C++ component, aiming for **100% line, function and branch coverage**. Keep Godot bindings thin. Delete superseded production implementations at each successful cutover, not in an indefinite cleanup phase. Commit after each verified stage/coherent change. Use development and independent-review subagents; do not rely exclusively on failed playtests to find architectural bugs.

The migration is complete only when BOTH the native scope is complete AND the original world-streaming **Gate 5 acceptance matrix passes on the final native build**. A passing native test suite, fast microbenchmark or short smooth sprint is not completion.

This supersedes the earlier decisions to defer deterministic collision tiles until after Gate 5 and to implement their architecture in GDScript first. Those older instructions remain in the current AGENTS backlog and original plan; reconcile their status in Stage N0 without erasing the historical evidence. The new decision does not waive any Gate 5 safety, gameplay, performance or evidence requirements.

Conversation decisions to preserve:

- Native backend: seeded terrain/caves/materials, deterministic features/structures/trees, sparse delta composition, immutable regional snapshots, collision extraction, spatial indexes, geometry preparation and bounded work scheduling. The discussion also supports native navigation topology and route computation, while retaining gameplay intent and execution semantics.
- Script side: UI/input, quests/tutorial, NPC intent/jobs/schedules, combat/survival policy, interaction decisions, save coordination, animation and presentation. Godot still owns engine physics/rendering. This is not a rewrite of the entire game or a custom physics engine.
- Protected route planning/proof, approach-cell certification and movement-admission scheduling were explicitly authorized in the prior Gate 5 work. Preserve exact route ordering, collision proof, motors, door behavior, traffic ownership and gameplay semantics. This is not permission to opportunistically replace the whole movement/door stack.
- Citadels retain their broad, continuous ground paving/platform, **without random holes or artificial raised civic terraces**. Natural terrain incline/decline is allowed; foundations supporting buildings are allowed. Do not flatten every citadel or restore elevated wall-like platforms as a migration shortcut.
- Disable audio during automated tests. Godmode is permitted for disclosed diagnostics, not as evidence that ordinary survival works.
- A prior one-hour Gate 5 work deadline ended. Do not restart that expired work campaign or recreate its stop automation. This handoff defines the new migration, not an assertion that Gate 5 was closed.

## 2. Exact starting checkout — preserve it

Use this worktree explicitly, even if the new chat starts in its sibling:

```text
C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot-citadel-visuals
branch: codex/world-streaming-maturity-migration
HEAD before this documentation checkpoint:
d507d01a97dca78ad1c29b4602a4af2c7b8e093d
```

The sibling `voxel-biome-world-godot` is a different worktree, observed on `codex/citadel-texture-poc`. It does NOT contain this working-tree state merely because both directories belong to the same repository.

At handoff there are approximately 98 pre-existing modified/untracked entries from Gate 5, including runtime fixes, routing changes, audio suppression, runner hardening, loading/journey runners and tests. They are not all in HEAD. Preserve them. Inspect `git status --short`, staged changes and the current diff before acting. Do not reset, clean, stash blindly, discard, overwrite or start from a new HEAD-only worktree and lose them. Ignored `artifacts/` evidence is local, not automatically transferred by Git.

Stage N0 must inventory/review this inherited state and checkpoint coherent work honestly, including known failures. A checkpoint is not Gate 5 acceptance. A migration branch, if created, should use `codex/` and start from the preserved checkpoint. No merge, push, master-checkout modification or history rewrite is authorized.

Read in this order before implementation:

1. This worktree's complete `AGENTS.md`, then `MANIFESTO.md`.
2. `docs/WORLD_STREAMING_MATURITY_MIGRATION_PLAN_2026-09-14.md`, especially §6 and the latest checkpoint ledger. Gates 0–4 are historical completed checkpoints; G5 is open.
3. `CODEX_PERFORMANCE_PLAN.md`, `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`, `Minecraft-Equivalent Terrain Migr.md`, `docs/KILOMETRE_BIOME_FIELD.md`.
4. `native/terrain_meshing/README.md`, its SConstruct/pinned bindings revision, `tools/build-native-terrain-meshing.mjs`, the current Voxel Tools integration and relevant owned-process runners.
5. Relevant historical routing plans only for the explicitly scoped native navigation/query work. Do not restart the old pathfinding replacement campaign.

If an unchanged baseline exposes a pathfinding regression, follow the manifesto: preserve evidence and report it before implementation. Existing authorizations cover the named planning/proof/admission work; a new motor, door-behavior or traffic-policy redesign still requires explicit scope agreement.

## 3. Where the current authority and work actually live

Paths below are relative to the worktree in §2. Inspect current callers; this is an orientation map, not a license to delete whole files.

| Current owner | Migration responsibility / retained boundary |
|---|---|
| `scripts/WorldGenerationSystem.gd`, `scripts/world/BiomeRegionField.gd` | Native deterministic generation and macrobiome authority; preserve seed output and the one surface-biome query contract |
| `scripts/TerrainVolumeService.gd` | Native material/density/solidity/fluid channels, edited cells, section snapshots and authoritative queries |
| `scripts/terrain/VoxelWorldGenerationContext.gd`, `VoxelTerrainGenerator.gd` | Remove per-voxel GDScript generation and duplicate saved-edit composition after native cutover |
| `scripts/terrain/VoxelTerrainRuntime.gd`, `VoxelTerrainSiteGate.gd` | Replace broad-viewer collision demand with explicit bounded native collision artifacts and exact installation receipts; keep necessary engine integration |
| `scripts/TerrainMeshingService.gd`, `native/terrain_meshing/` | Reuse/extract existing native mesh algorithms into the testable core; separate packed CPU artifacts from Godot objects |
| `scripts/buildings/`, `scripts/StructureSystem.gd` | Native recipes, support/ownership classification, structures/citadels, exact shape manifests, foundations, apertures, stairs, furniture placements and generated home/door records |
| `scripts/environment/TreeEcologySampler.gd`, recipe builders/cache | Native deterministic ecology/tree recipes and declared trunk blockers; script/render adapters retain wind/presentation |
| `scripts/world/WorldStreamingCoordinator.gd`, `CitadelPublicationService.gd`, site queues | Native demand/dependency/job state where it owns backend scheduling; engine mutation/acknowledgement remains an adapter responsibility |
| `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd` and routing substrate | Consume revisioned source artifacts; migrate agreed CPU topology/query/proof preparation without changing route/lease/motor/door contracts |
| `scripts/MainSaveState.gd`, `scripts/SaveSystem.gd` | Retain save-envelope/gameplay coordination; native backend owns canonical world-delta validation, snapshots and import/export |
| `scripts/MainChunkTerrain.gd`, `MainPropFactory.gd`, `WorldEditFollowupQueue.gd` | Replace duplicate world solidity/support/geometry derivation with backend calls; retain gameplay policy and central interaction paths |

There is already C++ here. `addons/zylann.voxel/voxel.gdextension` supplies native Voxel Tools functionality; the existing custom GDExtension exposes `TerrainMeshingBackend` and `BuildingSupportKernel`. The custom backend currently uses Godot types and offers packed section methods alongside legacy callback methods such as `build_chunk_mesh(main, cx, cz)` and `collision_shape_for_mesh`. The script generator extends `VoxelGeneratorScript` and fills density/material channels using scripted sampling and saved edits. Do not describe the starting game as entirely GDScript or rebuild working native facilities without checking them.

Current custom native build entry points:

```text
node tools/build-native-terrain-meshing.mjs --fetch-godot-cpp --target template_debug --api-version 4.6
node tools/build-native-terrain-meshing.mjs --target template_release --api-version 4.6
```

Bindings are pinned in `native/terrain_meshing/godot-cpp-revision.txt`; verify the checkout, compiler and effective flags. The project targets Godot 4.6 single precision. `BuildingSupportKernel` currently requires strict floating point and has documented script fallbacks. Migrate owned production fallback logic into tested native code or fail explicitly on unsupported inputs; do not leave an alternate world authority hidden behind optional-extension discovery.

Keep Voxel Tools if it can act as a native rendering/meshing consumer of the same source. Inventory its real public API and dependencies in N0/N2. Its broad viewer-generated collision must cease owning production collision after the collision cutover. If a public-API limitation prevents the design, produce a minimal reproduction and ask before introducing a custom engine fork/module. GDExtension is the default, not a promise that every engine API is preemptible.

## 4. Target design: one physical source, several compiled artifacts

```text
World identity: seed + generator/recipe/schema versions
                 |
Native deterministic baseline: terrain volume + feature manifests
                 |                    |
       durable typed deltas ----------+
                 |
       immutable effective regional snapshot
                 |
       +---------+----------------+-------------------+
       |                          |                   |
 collision/shape artifacts   render/lighting data   nav/support/interaction data
       |                          |                   |
 Godot physics adapter      Godot render adapter   navigation/query adapter
       |                                              |
 exact current physical receipt ------> admitted collision-backed movement
```

### 4.1 Composition, not two independently seeded generators

Conceptually:

```text
baseline(region) = generate(seed, generator_version, recipes, region + required halo)
effective(region, revision) = resolve(baseline(region), committed_deltas(region, revision))
physical_world = effective terrain field + effective declared feature shapes
collision_artifact = compile_physics_geometry(physical_world, collision_recipe)
render_artifact = compile_render_data(the_same_snapshot, render_recipe)
```

`resolve` is a typed, ordered operation, not arithmetic addition of arbitrary geometry. Define precedence and conflict behavior explicitly before porting. A tree/house placed by deterministic generation belongs to the baseline. Chopping the tree, removing a wall or placing a player building is a durable delta. A missing override means use the baseline; an explicit air override means empty. Never collapse those cases.

Terrain density/material, underground air, fluids and typed exact feature shapes form the source. Do not force doors, sloped roofs or small furniture into a lossy occupancy voxel if an exact primitive/mesh manifest is needed. Static collision can contain multiple shape types while still having ONE authority. Decorations declare nonblocking behavior; do not accidentally give leaves/branches collision. Trunks/declared blockers retain theirs.

A seed determines source geometry; it does not instantly produce an installed physics body. CPU extraction, native allocations, main-thread registration, physics synchronization and stale-result rejection still exist and must be bounded/measured. “The map is the collision map” means both queries and colliders derive from identical resolved physical facts, not that a solidity lookup replaces capsule sweeps, dynamic contacts or Godot physics.

### 4.2 Stable identity, edits and persistence

Specify and test these contracts:

- World identity includes seed representation, generator/recipe/schema version and relevant configuration. Use canonical serialization and a specified hash, never runtime container hashes or memory addresses.
- Audit actual arithmetic precision at every boundary: script scalar calculations, engine vectors, noise inputs and native buffers need not use the same precision. Preserve operation/cast order where output depends on it; specify rounding, overflow and fused-operation policy. Do not enable fast-math, depend on unordered-container iteration or bump a generator version merely to bless accidental world changes. State the supported cross-build/platform determinism guarantee and test it explicitly.
- Cell keys use signed integer coordinates; document floor division/modulo for negative positions, boundaries, origin transforms, voxel size and supported range.
- Generated features have stable semantic IDs, independent of traversal, worker order, allocation or camera. Preserve existing IDs where saves depend on them. New ID schemes require explicit mapping and tests, not silent reseeding.
- Deltas include terrain overrides, generated-feature tombstones/patches, player-created instances and durable feature state. Tombstones prevent regeneration resurrecting a removed tree/wall. Player creations use a durable ID namespace and counter/identity persisted in saves.
- Commit edits as validated transactions. Define sequence ordering, duplicate/idempotent application, conflicting edits and a pinned read revision. Do not invent multiplayer CRDT semantics for this single-player migration.
- Chunk content identity covers its relevant baseline, local deltas, intersecting feature geometry and required halo/seam dependencies. An unrelated edit must not invalidate the whole world. A global transaction sequence can identify a save snapshot without becoming every tile's cache key.
- Cache keys also include artifact-builder version and geometry/precision configuration. Content hashes establish equivalence, not live installation ownership.
- Sparse delta snapshots may compact history while preserving effective state, tombstones, ordering where meaningful and replay equivalence. Avoid an unbounded event log.
- Preserve save format v2 and existing v2 saves. `MainSaveState` currently carries terrain-volume data, `removedProps`, player blocks and gameplay state. Inventory all durable fields before cutover; round-trip them, including missing optional fields. No v1 revival or silent save-format reset.
- Save a consistent pinned world revision, not a mixture of cells/features from different frames. Protect original saves; use copied fixtures and atomic/validated persistence through existing save coordination. Compiled geometry caches are disposable, not save authority.

### 4.3 Canonical geometry and smooth rendering

The current project has density-based smooth terrain. Preserve actual volume, material identity and physical surface correspondence. Determine and document density sign, isovalue, quantization, sample positions, interpolation and halo rules; existing voxel generation negates/scales density into the native SDF channel. Do not port it with an assumed sign convention.

Collision and rendering may use different packing/detail, but must use the same canonical surface rules at traversable detail. Test maximum permissible visual/physical displacement, stairs/steps, holes, cave ceilings and dig boundaries. Freeze justified tolerances before comparisons; do not widen them after failures. A blocky solidity approximation that introduces invisible walls or floaty feet is not parity.

Start by evaluating collision tiles aligned to the current native mesh-block grid (the backlog proposes 16-cell tiles). Confirm actual units/LOD/grid settings first. Define deterministic boundary ownership, shared border samples, feature clipping/ownership, winding/normals, collision layers and cross-tile seams. Terrain render LOD must not remove near-player physical detail or create a second terrain interpretation. Nav tiling may differ, but mappings and vertical spans must be explicit and revision complete.

### 4.4 Source, compiled, installed and usable are different states

Proposed state progression:

```text
demanded -> snapshot pinned -> queued -> compiling -> prepared
         -> installation admitted -> installed -> physics acknowledged
         -> navigation acknowledged (where required) -> consumer ready
```

Each state retains its dependency set, cancellation epoch, owner generation, retry age, error/pending reason and bounded payload ownership. Authoritative empty artifacts receive explicit receipts; missing data is not empty success.

Use a small value-based contract along these lines (names are illustrative, not implemented API):

```text
SnapshotKey { world_id, region, relevant_source_revisions, schema }
CollisionArtifact { key, builder_version, bounds, shapes, seam_dependencies }
InstallationReceipt { key, owner_generation, installation_epoch, physics_ack }
NavigationReceipt { source_keys, physical_installations, nav_revision, sync_ack }
EditTransaction { expected_revision, typed_operations, transaction_id }
```

Identical content from a replacement owner does not validate an old receipt. Reject stale results before cache reuse, install and final acceptance; validate after asynchronous acknowledgement too. Content version alone does not detect arbitrary engine collider mutation. Centralize owned collider mutations and use a physics-boundary protocol that retains exact final physical proof.

For edited/replaced geometry, define pending versus active physical snapshot explicitly. Do not publish a new gameplay-solidity query while the engine silently collides against an incompatible old shape, or acknowledge an edit and then reinstall the old source. Prepare replacement, guard occupancy, switch at a safe physics boundary and acknowledge the active revision; keep unrelated regions playable. Cross-tile edits need an affected-set transaction. Old valid collision stays until safe replacement, but pending removal/addition state and player feedback must remain truthful. Include actors entering between guard and installation, edits during a pending swap and cancellation at every phase.

Doors are dynamic feature instances with shared door authority and state. Their declared geometry/portal originates in the snapshot; open/closed collision and navigation state changes follow the existing door controller and acknowledgements. Moving NPCs/players/hostiles are dynamic physics occupants, not seed-generated terrain or durable per-frame terrain deltas. Never bypass them with static occupancy proof.

### 4.5 Scheduling and language boundary

- Pure core contains no Godot `Node`, `Object`, `RID`, `Variant`, `Dictionary`, `Callable`, engine singleton or scene-tree dependency. Use owned typed values, explicit allocators/lifetimes where needed, immutable buffers and dependency-injected services.
- Core algorithms generate packed arrays/manifests. The GDExtension adapts batches, not one Godot/GDScript call per voxel, shape, candidate or graph edge. Measure conversion/copy/seal costs; making only the inner loop native may leave the expensive wrapper untouched.
- Core tasks operate on immutable source snapshots. Engine mutations happen only in their supported execution context. Avoid a second unrestricted worker pool competing with Voxel Tools, rendering and simulation; inventory total worker capacity first.
- Enforce limits on admitted work, in-flight jobs, prepared bytes, retained caches and retirement. A threshold checked before submitting a broad viewer is not a hard task cap. Report admitted work units and real underlying queued work separately.
- Prioritize local swept safety demand and completion, then predicted approach/reversal margin, then optional appearance. Deduplication must promote urgency without dropping retained demand. Aging provides progress; an occupied doorway must not pin independent buildings.
- Preserve source identity across camera changes. Camera motion only changes priority, not source revision, artifact membership or installed receipts.
- Preserve the existing 6 ms aggregate gameplay publication envelope, with Citadel at most 4 ms and never above the shared remainder. Include admission, selection, copying, callbacks, upload, acknowledgement and retirement, not just worker execution. Loading may use separate larger bounded slices with responsive progress.
- Cooperative budgets cannot preempt a single engine call. Measure maximum atom cost and subdivide controllable geometry. A compiler speedup does not excuse a 50 ms installation/destruction atom.
- Retire large buffers and final shared aliases through the measured retirement owner; do not move generation off Main while freeing gigabytes synchronously on Main. Cancel/shutdown drains owned workers before unloading bindings.

## 5. Staged migration and deletion gates

Stages N0–N9 are new migration checkpoints, not renumbered original Gates 0–5. Execute in order; bounded independent work can run in parallel when ownership/contracts are settled. Each stage ends with a developer report, independent review, relevant tests, evidence paths, a deletion/caller audit and a focused commit. Do not mark a stage complete with TODO correctness paths or a permanent script fallback.

### N0 — Preserve baseline; lock scope and contracts

Inventory the dirty worktree and existing native/plugin/build dependencies. Checkpoint inherited changes in coherent groups after review; record unresolved Gate 5 failures rather than calling them complete. Reconcile superseded backlog entries and this migration's authority map. Inventory every production generator, solidity/collision query, edit/save path, structure/tree recipe, nav source and compatibility fallback.

Capture unchanged focused contracts and relevant headed baselines, with known seed plus fresh seeds. Establish a source-to-consumer ownership/deletion ledger. Define determinism/precision/version contracts, the integration boundary for Voxel Tools, supported compiler/platform targets and loading comparator policy. Record exactly which native nav/query work is in scope; preserve motors/doors/traffic policy.

Exit: reviewed design/ledger and reproducible baseline; no unexplained baseline regression hidden. No runtime authority deleted yet.

### N1 — Standalone core, build, tests and coverage from day one

Create a pure core and native test executable plus thin adapter target. A proposed organization is `native/world_backend/{core,tests,godot}`; settle actual integration with the existing SCons build before adding another dependency stack. A CMake/CTest core is an option, not an existing tool claim. Keep executable automation entry points under existing Node conventions. No PowerShell runner replacement.

Introduce typed IDs/coordinates, snapshot identities, deterministic utilities, cancellation/ownership primitives and minimal adapter smoke. Pin dependency versions/licenses. Build debug and release, run core tests without launching Godot, and produce machine-readable coverage from a verified supported toolchain. Fail CI on missing discovered source files or missing coverage reports. Test error paths and invalid inputs immediately.

Exit: clean reproducible core build/test/coverage and engine load/unload smoke. No generator cutover yet. Remove only scaffolding that has actually been superseded, not live code.

### N2 — First end-to-end vertical slice

Port a bounded real terrain region's deterministic generation and delta resolution into core, producing collision geometry and render inputs from one snapshot. Exercise solid terrain, a slope/cave, an edit crossing a tile seam, explicit air, a declared feature blocker, reload and cancellation. Compare against current typed source output, not only an image or hash. Use the real GDExtension and physics fixture to prove installation acknowledgement and collision-backed movement.

Begin with diagnostic shadow output that cannot influence production routing or install duplicate colliders. Then activate the native path in a narrowly scoped fixture with exactly one collision owner. Demonstrate independent collision compilation without waiting for a render mesh. Decide Voxel Tools integration using this evidence before porting the entire city generator.

Exit: source parity, seam/delta tests, real physics integration and bounded end-to-end timings. Delete temporary spike implementations. Do not yet delete the rest of the production generator or pretend this slice completes migration.

### N3 — Full terrain, biome and world-delta authority cutover

Port all production terrain/underground/material/fluid source rules, macrobiomes and applicable world generation queries; preserve current RNG/noise semantics, negative coordinates and seed IDs. Port native sparse edit resolution and v2 world-delta import/export, including durable removals/player creations. Preserve deterministic placement inputs consumed by later feature stages through typed batch APIs.

Switch all terrain consumers to the native source: digging/drops, placement, underground air, generation, mesh/collision inputs, navigation occupancy and save snapshots. Keep only thin script service facades where they provide integration/policy.

Exit: known plus two fresh seeds, order/cancel permutations, v2 save parity, terrain/dig/lighting visual tests and routing regression coverage. Delete migrated GDScript sampling/edit authority and per-voxel callbacks. No second runtime sampler, legacy heightfield, save-selected generator or silent fallback remains.

### N4 — Deterministic features, structures, citadels and ecology

Port recipe computation, typed geometry, support/ownership classification, spatial indexing and generated manifests for towns/houses/citadels, trees/props and other world-generating features found in N0. Preserve cozy silhouettes/materials, existing generated GLBs/registries, ecology family grammar, furniture, doors/windows/stairs/porches, home assignments and stable IDs. Split into committed sub-stages by feature family if necessary; every family gets its own native tests and caller/deletion audit.

Publish each feature's geometry and physical semantics together. Script scene creation consumes the native artifact rather than reconstructing collision from visual nodes. Preserve ground paving continuity and terrain-following foundations. Implement generic lifecycle/destruction ownership if needed for the tutorial perimeter defect; no named-NPC/one-seed patches.

Exit: typed ordered geometry/support/ID parity, baseline/fresh-seed visuals and actual furnished interiors, durable destruction/reload tests and live generated-home/door checks. Delete migrated script recipes, geometry rediscovery and owned script support-kernel fallbacks. Retain presentation/assets, not duplicate recipe authority.

### N5 — Production collision-first publication and bounded streaming

Promote explicit native collision artifacts across terrain and feature owners. Migrate player/NPC physical-readiness consumption, startup readiness and edit/retirement receipts. Use bounded local swept demand and ahead-of-travel preparation, with hard admission/byte limits and retryable demand. Rendering runs independently from the same source and cannot control collision readiness.

At cutover disable/remove the old VoxelTerrain viewer-generated collision authority; do not leave two colliders installed and select whichever query succeeds. Viewer rendering may remain if it is a native source consumer. Audit all old collision probes/readiness aliases and dependency consumers before deleting them.

Exit: real movement, slopes/caves/seams/dig/build/feature blockers, actor-safe replacement, startup/Continue, rapid reversals, retirement/revisit and pending shutdown pass. Short focused streaming tests show queue stability and no recurrent holds before paying for final long runs. Delete obsolete collision extraction/readiness/fallback paths and broad-viewer collision scheduling. Safety remains fail-closed; hiding “waiting for collision” text is not a performance fix.

### N6 — Native navigation and backend spatial queries

Build compact nav/support/clearance artifacts from the same native source and exact feature geometry. Preserve tile mapping, shared vertical-span/seam contracts and physical/navigation revision acknowledgements. Door state toggles existing declared portals instead of rediscovering static topology. Preserve actual walkable-boundary/structure-semantic connectivity; no unrestricted lattice or geometry-repair fallback.

Move the agreed CPU route computation/proof preparation and approach candidate/spatial-index work into the pure core behind established route authority contracts. Preserve deterministic ordering, readiness classifications, lease lifetime, cancellation, LOD eviction, final live collision/occupancy proof and current motor/door/traffic behavior. Source-level candidates can be cached by source revision; actor/job/town policy and current reservations still filter them. Never globally cache actor-specific final approach slots.

Exit: native route/graph/property tests, existing route/behavior/nav/door suites, real home/job/tutorial flow and current-revision engine proof. Delete superseded production graph/query/planning kernels and duplicate topology derivation. Thin script facades and gameplay policy can remain; native porting is not permission to alter route behavior. A newly necessary motor/door-policy change requires scope review.

### N7 — Complete backend consumers, persistence and lifecycle

Use N0's inventory to close remaining generation/collision holes: world creation/resets, exploration discovery, prop/tree respawn, support/destruction, player building, saves, lighting/fluid source facts, bounds queries, edits during jobs, stale owner replacement and shutdown. Move residual computational backend scheduling/query logic out of scripts; keep engine calls and gameplay orchestration where they belong.

Audit plugin/native worker ownership, memory caps and request progress under backpressure. Verify idempotent registration and revision changes only for semantic changes. Complete coverage and independent-review gaps across all first-party native code added/modified, including extracted pre-existing kernels.

Exit: no production GDScript generation/solidity/delta-composition/collision-extraction authority remains. Final deletion ledger accounts for every old entry point. Native binding failure produces an explicit actionable startup error, not fallback world generation. Normal saved games still work.

### N8 — Focused performance convergence and release-candidate freeze

Profile the entire native path: source sampling, recipe generation, resolution, allocation/copy/hash, shape extraction, worker contention, upload, physics/nav synchronization, gameplay queries and destruction/retirement. Remove duplicated work before tuning instruction costs. Test representative short real-world traversal and the 32-NPC workload before full-matrix runs. Keep all inherited performance criteria; do not enlarge budgets or retune thresholds after seeing a failure.

Resolve remaining tutorial flow defects and reproducible native/engine crashes. Establish the loading comparator numerically before final runs. Rebuild/install both native configurations, record their actual hashes, and freeze all source/binary/test-input identities.

Exit: focused results justify the expensive acceptance run; no known in-scope blocker is being waived. Delete diagnostic runtime switches, shadow authorities and temporary probes that would contaminate acceptance. Retain bounded useful telemetry and test-only reference oracles.

### N9 — Full original Gate 5 and final handoff

Execute §8 in full on the frozen final native build. Any implementation change invalidates affected evidence and requires new final identities/reruns. Finish with coverage reports, independent reviews, migration/deletion ledger, commands/captures, known limitations and a clean, committed worktree. State **ready for the user's merge decision**, not merged.

Exit: all native scope complete AND every original Gate 5 row PASS. Otherwise explicitly report INCOMPLETE and the remaining blockers; do not use “migration done, Gate 5 later.”

## 6. Test and coverage contract

Aim for 100% first-party native line/function/branch coverage, with tests added in the same change as code. Unit-test every new C++ component, including adapter-side decisions factored into pure helpers. Godot registration/marshalling/lifetime code also needs engine integration tests. Clearly report standalone coverage and combined/integration coverage separately; standalone tests cannot prove real engine installation.

Set a ratcheting automated floor after the initial measured baseline and publish the exact numerator/denominator and uncovered lines/branches per stage. Target 100%; do not silently redefine the denominator to reach it. Any unavoidable gap must identify file/line/branch, reason, risk and alternative verification and receive explicit review; behavioral gaps block stage completion. Do not exclude first-party error/cancellation paths, mark them untestable merely because they are inconvenient, or report third-party/generated binding code as project coverage. Instrumentation failure or a missing source in the report is a failure, not 100%.

Minimum test groups:

1. Coordinates/identity: negative coordinates, floor/mod, extrema/overflow rejection, canonical serialization, seed string hashing, noise/RNG parity and stable feature IDs.
2. Generation: every biome/stratum/cave/fluid boundary, feature family, foundation/stair/aperture/support rule and malformed recipe input. Compare typed values and order against preserved baseline fixtures and independent small analytic examples.
3. Delta algebra: absent versus air, tombstones, duplicate/ordered/conflicting transactions, player-created IDs, compaction, v2 round trip, missing optional fields, corrupted input, load while tasks are pending and edit/revert behavior.
4. Geometry: analytic solids/cavities/slopes, clipping, seam ownership, triangle winding/degeneracy, canonical surface tolerance, exact feature shapes, collision layers and material/dig-drop consistency.
5. Revision/lifetime: out-of-order worker completion, edit during compile/install/ack, same hash/new owner, explicit empty output, cancellation at every phase, unload/reload, reset, cache eviction and no lost retained requests.
6. Scheduling: hard queue/byte caps, urgency promotion, fairness, occupied-versus-independent groups, completion/retirement progress, shutdown drain. Use a deterministic scheduler/fake clock for algorithmic tests; real timing remains separate evidence.
7. Native navigation/query: required crossings, agent footprint/headroom, supported surfaces, route ordering, pending versus unreachable, occupancy revision churn, reservation changes, strict interiors and door state transitions.
8. Robustness: malformed/truncated/oversized serialized input, fuzz/property tests, seeded randomized order permutations, allocation/lifetime failures where practical, sanitizers/race detection where supported. Never claim a sanitizer ran on a platform/toolchain that cannot run it.
9. Adapter and live integration: batch marshalling, precision, registration/freeing, physics/nav acknowledgement, scene teardown, actual capsule movement, doors and edited terrain. Test debug and release binaries.

Freeze small golden datasets independent of the newly ported code; copying the same wrong algorithm into the oracle proves little. Property tests across many seeds supplement, not replace, known regressions and real gameplay. Check test usefulness through deliberate perturbations/mutation checks on high-risk invariants where practical. Coverage is an execution metric, not proof of correct physics or smooth gameplay.

The standalone C++ executable must run without opening Godot. Reuse existing Node orchestration/watchdogs for builds, coverage, reports and Godot integration. Add documented runners only after confirming the chosen native toolchain; proposed future runner names are not commands that already exist.

## 7. Inherited evidence and outstanding defects

These are historical results from the dirty Gate 5 state, NOT validation of the future native backend. Verify artifact presence and source identity before relying on them. Missing ignored evidence must be rerun, not reconstructed from recollection.

### 7.1 Work worth preserving

- Terrain preparation: a 1.5 ms gameplay slice/64-cell combined terrain-fluid work ceiling, shared deadline, pending/retry retention and stale-input rejection. Reported focused results: 14/14 bounds and 7/7 fluid contracts.
- Incremental immutable source-manifest/microphase work across `WorldStreamingCoordinator`, `CitadelPublicationService` and Main packet bridge. Reported 133/133 streaming, 95/95 retention, 15/15 packet bridge contracts.
- Protected route tranche: exact deferred heap ordering, restart-safe cursorized occupancy/final certification, route-local door identity, LOD cancellation/eviction and resumable first approach. Reported 190/190 route and 83/83 behavior tests, plus compilation. Do not reintroduce whole-route atomic work or stale occupancy acceptance during the port.
- Nested NPC performance telemetry and runner provenance hardening. Runner review reported 41/41 adversarial tests: complete input inventory, engine plus console-launcher hashes, native binary hashes, transactional `final-acceptance.json`, preserved save bytes and fail-closed Continue provenance/loading policy.

### 7.2 Why Gate 5 is still open

Last minimal-gauge headed diagnostic:

```text
artifacts/performance/gate5-32npc-route-reviewed-minimal-1080p-10s-120warmup-06/report.json
seed atlas-1492; 1920x1080; only 10 seconds measured after 120 warmup frames
route planning p99 0.781 ms; measurement max 1.427 ms
cheap steps 48/48; validators 2/2; route compliance true
Main p99/max 27.548 ms
presentation p99 47.6 ms; max 52.885 ms; 88 frames over 33 ms
aggregate physical route service p99 8.884 ms
owned process receipt: godot-DTEWa6/watchdog.json (reported natural zero drain)
```

This passes the measured route atom criterion but fails the normal-town whole-frame criterion. It does not prove a full-duration run. The more instrumented sibling `gate5-32npc-route-reviewed-1080p-10s-120warmup-05/report.json` recorded Main p99/max 23.796/30.447 ms and presentation p99/max 46.3/50.935 ms; detailed telemetry intentionally omitted compliance gauges, so that run was diagnostic, not acceptance. Do not compare instrumentation/resolution variants as identical experiments.

Remaining measured CPU owners included 5–6 ms trader reservation/scope rebuilding and aggregate per-actor physical route service. `SmartObjectService.query_scope_revision` scans/sorts/hashes object state; registration/re-indexing may churn unchanged objects; resource approach selection can synchronously validate many candidates. Inspect the exact current implementation before fixing. Favor idempotent semantic registration and source-level candidate/index reuse, while retaining live actor/reservation filters and final proof. Native language alone does not remove redundant work.

Earlier focused wilderness evidence in `artifacts/world-streaming-maturity/g5/focused-sprint-viewer-workload-attribution-01/report.json` covered 533.75 m, zero holds and 12.776 ms p99/22.608 ms max, but startup was 103.159 s and native queued work peaked at 708 tasks. The 8-task admission threshold never capped the jobs a broad viewer could enqueue. This is the architectural motivation, not a release pass.

The full final five-minute matrix, continuous journey, paired loading matrix/comparator, current-source long soak, broad gameplay, known plus fresh-seed parity and final clean checkpoint were not completed. Do not infer their success from the local contract counts.

### 7.3 Known flow and crash issues

- Tutorial perimeter gate/fence destruction can collapse bridge/fence components into pickups and break repair progression. Read-only investigation pointed to generic block destruction/drop handling and mixed structural-component collapse, with missing generated owner/lifecycle boundaries. The door itself is classified nonstructural, so the exact live trigger needs reproduction; do not claim the root cause is fully proved. Repair it generically at structure/lifecycle authority, preserving intentional repair gaps and ordinary player destruction/drops. Do not make adjacent player construction accidentally indestructible.
- A headless/dummy world-signature access violation was reported in prior work while visible atlas-1492 signature evidence matched. Preserve crash evidence, reproduce against exact binaries and fix or conclusively attribute it. Visible success cannot waive an unresolved backend lifecycle crash.
- Old AGENTS backlog text says occupancy finalization above 48 cells remains atomic; the reviewed dirty tranche cursorized that work. Reconcile this historical entry against current tests rather than reimplementing an already-fixed problem.
- A reported `navmesh_filter_terrain_capture` value around 119–135 ms can represent accumulated capture CPU across slices, not one frame. Distinguish per-call timing, total worker/task time and wall-clock latency in all new reports.

## 8. Non-negotiable completion matrix: original Gate 5

The original plan §6 remains the release authority. This table makes it portable into the new chat; consult the original for details. Native implementation replaces internals but does not reduce the bar. The old “no altered route stack” preservation requirement means no behavioral/authority regression during the explicitly agreed native query migration; it is not a waiver for changing motors/doors/traffic.

| Acceptance area | Required final evidence |
|---|---|
| Wilderness and Citadel cadence | 1920x1080, documented RTX 5060 Ti host/settings, real time, at least 5 minutes EACH wilderness sprint and Citadel traversal; 60 FPS target, presentation p99 <=33 ms, no recurring streaming stalls >33 ms, no frame >100 ms |
| Normal 32-NPC town | p99 target <=16.7 ms, <=22 ms tolerated; max <=33 ms; no repeating 2–7 second spikes; autosave Main section <=2 ms. Report presentation/Main/physics separately; Main-only success cannot establish frame success. Authentic ordinary town behavior, not an undisclosed synthetic NPC top-up |
| Per-call work | Full movement path bounded by local sweep; actual timing distribution; 6 ms aggregate publication, Citadel <=4 ms subordinate; no repeated controllable overrun. Preserve the route 2 ms atom expectation and current logical work/validator limits unless a reviewed equivalent bounded contract replaces the counters, not the performance target |
| Continuous journey | Actual menu -> New Game -> tutorial departure -> wilderness -> discovered Citadel -> gate -> streets -> strict home/interior -> leave/revisit. Ordinary input, no helper movement/teleport act phase, no modal loading re-entry, no recurrent collision holds; preserve stricter zero-hold runner checks and publish trajectory/input/loading traces |
| Visual and physical | Overhead/external sides, gate-facing progress, continuous streets/paving, actual beds/tables/storage, no artificial wall platforms, correct foundations, real gate/door/stair passage and terrain/cave solidity. Inspect daylight AND dark/night evidence |
| NPC and publication | Real behavior; approach/open-before-cross/strict interior/clear threshold/close sequence; current physical/nav revisions and acknowledgement; stale/cancel/reset proof; route and movement semantics preserved |
| Determinism | Known seed plus at least two fresh seeds; approach order, worker/order/cancel permutations and durable edits; typed ordered geometry, stable IDs, ownership, material/solidity and required crossing parity, not hashes alone |
| Loading | Three controlled cold known-seed samples plus one each of two fresh seeds, EACH paired with warm Continue: five cold and five warm launches. Fresh process and isolated empty generated-artifact cache define cold. Preserve actual input saves and measure equivalent readiness. Apply the fixed pre-run responsive-loading envelope below; total load duration is diagnostic, including the old provisional 90/45-second references. |
| Long-session lifecycle | At least 30 minutes, at least three retire/revisit cycles, autosave enabled, bounded queues/caches, peak and settled memory at equivalent states; no post-warmup growth >5% between comparable settled checkpoints without accounted retained assets; clean exit with no owned workers/native jobs/processes alive |
| Broad gameplay | Gather/craft/build/dig/harvest, combat/survival, manual/autosave, v2 Continue/reload, New Game startup, reload/exit/cancel during preparation/install/sync and later revisit; existing broad tests plus real visible evidence |
| Native completion | All backend inventory entries cut over, obsolete production authorities deleted, debug/release reproducible, standalone and adapter tests pass, coverage report and reviewed gaps published, no hidden script fallback |
| Final delivery | All affected evidence tied to final frozen source/binaries, compact checked-in reports, staged commits/deletion ledger, clean worktree and merge-conflict assessment; ready for user decision, NO automatic merge |

The fixed loading comparator is `gate5-responsive-loading-2026-09-23` in `tools/lib/world-streaming-loading-matrix.mjs`. For **each** cold and Continue sample it requires a first visible loading frame within 1,000 ms of menu input, loading frame-gap p99 <=33 ms and max <=100 ms, full-loading Main callback max <=33 ms, and a source-owned completed-work heartbeat with no gap >5,000 ms, including the input-to-first-work and last-work-to-ready intervals. Continuous overlay, no post-ready modal re-entry, full gameplay readiness, exact seed/save/profile pairing, immutable source/binaries, natural process exit and zero owned-process drain remain required. A watchdog timeout is noncompletion, not a user-experience load-time threshold. Input-to-ready duration, stage times, the old provisional 90/45-second references and warm/cold ratio remain recorded diagnostics; they cannot pass or fail a completed responsive sample by themselves. This policy was fixed before final runs in response to the user's clarification that loading may exceed 90 seconds if it stays responsive. It does not assert that any final sample has passed.

The evaluator returns `gate5LoadingAccepted:null` with a nonzero Gate 5 exit if authoritative completed-work proof is unavailable; functional diagnostic mode cannot issue a Gate 5 loading acceptance. Preserve all five cold plus five paired Continue launches and the fixed numbers for the final frozen-source run. Do not use the known bad 127.627-second snapshot as a successful standard or interpret a loading-row pass as the full Gate 5 release pass.

A pre-existing defect that blocks the ordinary required journey remains a blocker. List unrelated defects separately; do not rebrand a flow-breaking baseline bug as out of scope to close G5.

## 9. Execution and evidence discipline

Run one measured headed workload at a time. No concurrent builds, source edits, other benchmarks or screenshots in a timed acceptance interval. Obtain visual checkpoints separately or in explicitly delimited phases; keep genuine gameplay stalls in the timing data. Record engine version, renderer, driver, hardware, viewport AND actual window/render target, seed, flags, duration/warmup and cache state.

All automated Godot launches must use Dummy audio and `VOXEL_DISABLE_AUDIO_PLAYBACK=1` through the existing shared runner facilities. Do not audibly launch tests. Use Node owned-process watchdogs; stop failed tests promptly and terminate only their owned process job, never unrelated Godot processes. Functional result and natural/forced cleanup are separate facts; require authoritative zero-member drain evidence.

Hash the complete relevant source inventory, all installed native libraries and the actual Godot engine executable as well as its console launcher. The prior host used Godot 4.6.1 official `14d19694e`, Vulkan Forward+, RTX 5060 Ti; recheck rather than assuming. Record build flags/pinned dependencies and verify installed binaries actually correspond to edited sources. Preserve exact save bytes and source identities for paired Continue runs. Transactional final acceptance must fail if source/binaries/inputs mutate, a lifecycle check fails or required evidence is absent.

Useful existing entry points (verify supported flags before use):

```text
node tools/run-project-compile-smoke.mjs
node tools/run-world-streaming-consumer-contract.mjs
node tools/run-startup-loading-readiness-contract-tests.mjs
node tools/run-voxel-terrain-navigation-publication-mapping-contract.mjs
node tools/run-navigation-shutdown-lifecycle-contract.mjs
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/npc/run-all-npc-tests.mjs -TimeMode Both
node tools/npc/run-npc-route-tests.mjs -TimeMode Both
node tools/npc/run-npc-behavior-tests.mjs -TimeMode Both
node tools/npc/run-real-tutorial-playthrough.mjs
node tools/npc/run-npc-go-home-visual-playtest.mjs
node tools/npc/run-npc-town-job-cycle-visual-playtest.mjs
node tools/run-playtest.mjs
node tools/run-normal-runtime-performance-pass.mjs
node tools/run-world-streaming-maturity-journey.mjs
node tools/run-world-streaming-maturity-loading-matrix.mjs
node tools/run-world-signature.mjs
node tools/run-underground-visual-playtest.mjs
node tools/run-digging-visual-playtest.mjs
node tools/run-town-ground-visual-playtest.mjs
node tools/run-light-shadow-visual-playtest.mjs
```

Use fresh output directories; default runner paths can overwrite evidence. The normal performance runner chooses a random New Game seed: do not invent a `-Seed` flag. The runtime-performance-observation wrapper has historically used fixed-FPS simulation and is supporting diagnosis, not real-time cadence acceptance. Inspect its current implementation before interpreting results. A runner whose name contains “teleport” may have a later ordinary-input mode; audit its act phase and flags rather than assuming its name proves or disproves acceptance.

New headed NPC acceptance runners must invoke `tools/npc/assert-npc-acceptance-runner-clean.mjs` before Godot. No direct calls to movement/door/tutorial success handlers, no metadata-only interiors, no forced safe movement or teleports during the tested behavior. Godmode, explicit initial spawn, skipped tutorial and forced weather/daytime must be disclosed and cannot replace unflagged ordinary-flow/survival evidence.

On failure inspect progress, report, stdout/stderr, timing trace and owned-process receipt before code changes. A user-closed game is interruption, not a passing run or automatically a product crash. Reproduce the smallest meaningful defect, use an independent review, make a falsifiable fix, then rerun focused coverage before another costly journey. Do not repeat a failed full run without new evidence or a relevant change.

## 10. Deletion, review and handoff ledger

Maintain a checked-in ledger per subsystem with:

```text
old production owner / callers
new native owner / public contract
retained script policy or engine adapter and why
typed parity fixtures + standalone tests + coverage
engine integration + live acceptance evidence
old code/fallbacks/configuration deleted
reference fixture retained only in test path, if any
independent reviewer findings and resolution
commit + source/build identities + remaining limitations
```

At each cutover search imports, class registration, autoloads, scenes, resources, tests, saves and runner switches. Remove unreachable legacy files, fallback branches and obsolete configuration; update documentation in the same checkpoint. Do not delete unrelated user work, tests proving retained behavior, generated assets or whole mixed-responsibility scripts merely because some functions moved. Reference implementations may survive only as clearly isolated tests, never selectable production authority.

Assign subagents bounded roles: native-core development, engine integration or subsystem port, and independent correctness/lifetime/deletion review. Separate owned files and avoid concurrent edits during performance freezes. Review determinism, stale ownership, thread lifetimes, failure paths and baseline compatibility before launching expensive gameplay tests. Record unresolved review findings; a subagent GO is not live acceptance.

Completion report must state what moved, what remained in script and why, exactly which deprecated paths were removed, all stage commits, native build reproduction, measured coverage/gaps, end-to-end performance comparisons, every Gate 5 row and evidence limit. If any row fails or cannot be measured, report it plainly and leave migration/G5 OPEN.

## 11. Suggested first message for the new chat

> Work in the `voxel-biome-world-godot-citadel-visuals` worktree named in this handoff, not the sibling project directory. Read its AGENTS.md, MANIFESTO.md and this complete native migration handoff. Preserve the dirty Gate 5 state. Begin Stage N0: inventory and checkpoint inherited work, verify baselines and settle the authoritative C++ contracts before implementation. Execute the staged world-generation/collision backend migration with development and independent-review subagents, unit tests for all new C++ targeting 100% coverage, deletion at each cutover and a commit after each verified stage. Preserve gameplay/route/motor/door semantics. Do not claim completion until the full original Gate 5 matrix passes on the final native build. Do not merge or push.

This handoff is documentation, not an implementation result. No new native backend, coverage result or Gate 5 pass is claimed by creating it.
