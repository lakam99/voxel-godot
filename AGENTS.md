# AGENTS.md

Guidance for future Codex instances working on **Voxel Biome World Godot**.

## Project Context

This is a Godot 4.6 Forward+ voxel survival game evolved from a Three.js prototype. The current priority is to preserve the cozy voxel visual direction, generated asset pipeline, survival/crafting gameplay, tutorial town flow, NPC systems, and automated playtest coverage while adding features incrementally.

The project root is the Godot project root. Main scene:

```text
res://scenes/Main.tscn
```

The main gameplay script is intentionally split through a deep inheritance chain. Do not add another `Main*.gd` layer unless the user explicitly asks and there is no cleaner composition-based option.

Current main chain:

```text
Main.gd
-> MainPropFactory.gd
-> MainChunkTerrain.gd
-> MainInteractionFlow.gd
-> MainPlaytestTools.gd
-> MainRuntimeTools.gd
-> MainDiscoveryFlow.gd
-> MainHudFlow.gd
-> MainWorldEntities.gd
-> MainCharacterState.gd
-> MainGameLoop.gd
-> MainSetupScene.gd
-> MainSaveState.gd
-> MainCore.gd
-> MainInterface.gd
```

Prefer composed systems under `scripts/` or `scripts/story/` over expanding that chain.

## Game Model And Authority Map

The game is a coherent survival world, not a collection of isolated scenes.
When changing one layer, identify the authoritative owner and preserve the
contracts below and above it:

```text
world seed
  -> WorldGenerationSystem + BiomeRegionField
  -> authoritative terrain volume / edited cells
  -> chunk mesh, collision, lighting, navigation publication, props
  -> player/NPC interaction, survival, crafting, combat, story and tutorial
  -> save snapshots, HUD, loading feedback and playtest evidence
```

- A visible result must have a real source of truth. Do not create a second
  visual, collision, save, navigation, or metadata-only authority to mask a
  defect in the first one.
- `WorldGenerationSystem.surface_biome_for_cell3` is the sole production
  surface-biome query. It always composes the deterministic kilometre-scale
  `scripts/world/BiomeRegionField.gd`; there is no legacy sampler or
  save-selected biome mode.
- Terrain volume is the authority for material, solidity, digging and
  underground air. Meshes, colliders, light, props and navigation publish from
  that authority rather than inventing their own terrain interpretation.
- The tutorial is a scenario layered on ordinary game systems. It may choose
  actors, goals and presentation, but must not become a parallel world,
  movement, home, door, or save system.
- A save records player-made and durable world deltas; it must not replace
  deterministic generation with a second generated-world implementation.

## Core Project Map

Start orientation with these files and folders rather than searching from an
individual symptom:

- `project.godot`, `scenes/Main.tscn`, and the `Main*.gd` chain define the
  production runtime. `scenes/Playtest.tscn` hosts the broad integration
  fixture; `scenes/testing/` and `scenes/story_testing/` host focused fixtures.
- `scripts/WorldGenerationSystem.gd`, `scripts/TerrainVolumeService.gd`,
  `scripts/terrain/VoxelTerrainGenerator.gd`, and
  `scripts/terrain/VoxelTerrainRuntime.gd` own generation, editable volume,
  terrain publication, and streaming.
- `scripts/world/BiomeRegionField.gd` is the pure, deterministic macrobiome
  field. `scripts/environment/BiomeEnvironmentCatalog.gd` turns biome identity
  into environment/foliage policy.
- `scripts/environment/` and `scripts/visual/` own procedural ecology and
  rendering. `scripts/perf/RuntimePerformanceMonitor.gd` owns runtime
  performance observations. Do not put their work into a `Main*.gd` layer.
- `scripts/SaveSystem.gd` owns the save envelope and `MainSaveState.gd` owns
  the gameplay snapshot. The current intentional format is `SAVE_VERSION = 2`;
  version-1 local saves were retired, not migrated.
- `scripts/tutorial/`, `scripts/Tutorial*.gd`, `scripts/story/`, and
  `scripts/missions/` own scenario and story composition. Dialogue presents
  state; it does not become the state authority.
- `scripts/npc_ai/` owns the mature routing/movement stack. Read
  `docs/architecture/npc-navigation-manifesto.md` before considering any change there.

## Core Principles

- Build a survival game where ordinary play works end-to-end: gather, craft,
  build, explore, fight, sleep, progress the story, save, reload, and leave
  the game without breaking the world around those actions.
- Prefer a few composable, inspectable authorities over parallel “helpful”
  fallbacks. A system should be reusable by the tutorial, generated towns,
  normal gameplay, a focused PoC, and tests through the same public contract.
- Preserve determinism. Seeded generation may vary richly, but a seed and its
  durable deltas must reproduce the same world without mutable global RNG,
  query-order dependence, or hidden authored repairs.
- Favour systemic correctness over a patch for a screenshot. Ask what owns
  the failing fact, then repair that contract at its source.
- Treat smoothness, loading feedback, collision and visual readability as
  gameplay correctness. A feature that works only after a visible stall,
  through missing collision, or without readable feedback is incomplete.
- Keep the cozy voxel direction through silhouette, material identity, warm
  light and dark nights—not by flattening the world into generic primitives.

## Project North Stars

- This is a survival game, not a tech demo. Terrain, structures, NPCs, weather, lighting, inventory, crafting, combat, story, saves, and performance must continue to work together in normal gameplay.
- Preserve the cozy voxel look while keeping the world physically coherent. Smooth visuals are welcome, but terrain must still have real collision, depth, density, and material identity.
- The real game flow matters: launch to main menu, choose `New Game` or `Continue`, load the world with visible feedback, play through tutorial town, save/load, and exit without long unresponsive freezes.
- Live gameplay is the source of truth for user-facing behavior. Unit, contract, and service tests are necessary but cannot overrule a headed playtest or screenshot showing broken gameplay.
- Avoid narrow patches that only fix the latest screenshot. Most recent regressions came from band-aids around terrain holes, NPC doors, route budgets, or test metadata instead of repairing the underlying system contract.

## Development Rules

- Preserve user work. Check `git status --short` before editing.
- Use `apply_patch` for manual edits.
- Use the existing Node.js runners and shared process helpers for automation.
  Do not introduce PowerShell runner replacements or a parallel test framework.
- Keep changes focused. Avoid broad refactors while fixing gameplay bugs.
- Do not discard, reset, clean, or rewrite branches unless the user explicitly asks.
- Do not weaken tests to make a change pass.
- Save changes are normally additive. The current format is deliberately v2:
  do not reintroduce legacy biome/save compatibility, a version selector, or a
  second world-generation authority without an explicit product decision.
- Preserve deterministic world generation. Story or visual additions may derive stable IDs from the seed, but must not reorder terrain/town/prop RNG.
- Visual assets, Blender generators, generated GLBs, and registries are first-class project assets. Do not replace them with a parallel pipeline.
- Browser/Three.js work is historical context. New gameplay work should target this Godot project unless the user says otherwise.

## How To Approach Work

1. Orient before editing: read the controlling plan/manifesto, check the
   current branch and worktree, identify the owner of the fact being changed,
   and distinguish user work from task work.
2. Reproduce at the right evidence level. Use a small contract runner to
   isolate deterministic rules, then a real scene or headed playtest for
   player-visible behaviour. A screenshot can invalidate a green synthetic
   result.
3. Change the lowest correct authority. Reuse established commands and data
   flows instead of adding named exceptions, copied generators, direct
   movement, UI-state logic, or test-only pathways.
4. Keep publication incremental. Expensive generation, meshing, prop/tree
   construction, navigation publication, route work and saving belong in
   measured queues/budgets, but queued requests must remain retryable and must
   not silently disappear.
5. Verify proportionally: focused contract first, then functional/visual and
   runtime performance coverage when a player can notice the change. State
   exactly what each test proves and what it does not.
6. Leave the repository legible: update the relevant plan/Linear item when
   requested, preserve unrelated files, and commit only the requested scope.

## Mandatory Refinement, Migration, And Handoff Gates

These gates are required for cross-cutting gameplay work, architectural
changes, and migrations. A task that has not passed its current gate must not
be described as implementation-complete or ready for the next stage.

### Before implementation

- Write a short task charter before changing code: user-visible outcome and
  explicit non-goals; authoritative source and affected consumers; current
  branch/worktree and pre-existing edits; known baseline failures; dependencies
  and risks; and observable acceptance evidence. Put durable plans, matrices,
  and handoffs in the documentation repository, then link them here or in the
  task summary.
- Map the data path end to end before moving an authority: producer, immutable
  inputs, revisions/identity, worker or queue boundary, publication/acknowledgment,
  gameplay consumers, edits/saves, and retirement of the old path. Name every
  consumer that must move. A “port” or similar output is not proof of semantic
  parity; compare the actual contract and boundary cases.
- If a material dependency, owner, or acceptance criterion is unknown, make
  bounded discovery the first stage. Do not silently treat discovery, risk
  resolution, or integration as negligible work or give a confident single
  estimate before that uncertainty is reduced.

### Baselines and stage exits

- Before edits, preserve relevant failing reports and record the exact command,
  revision/build, seed or fixture, and environment. Classify each failure as
  pre-existing, introduced, test/setup, reporting, or unresolved; never attribute
  it to the migration without comparison evidence, and never change production
  code merely to make a test start or turn green.
- Define each migration stage's entry conditions, proof, and exit criteria
  before implementation. Report passed, failed, blocked, and untested rows
  separately. Passing a focused or intermediate gate proves only its named
  contract; it does not waive later stages or the original project acceptance
  matrix. HEAD/goal owner makes stage advancement and completion decisions.
- For uncertain defects, choose the smallest falsifiable check that separates
  likely causes, then make one evidence-led change. Run a long/integrated gate
  when new evidence warrants it; do not repeatedly relaunch an unchanged costly
  suite. Set the question and stop/timeout conditions before launch, use the
  owned-process watchdog, and inspect its report before retrying.
- Keep independent verification independent of implementation. Review the
  exact final diff and build/source identity; a reviewer recommendation is
  evidence, not acceptance by itself. Record remaining limitations and the next
  safe action in the handoff.

### Delegation and repository boundaries

- When work is delegated, assign one accountable lead per subsystem, explicit
  parent/worker roles, dependencies, and non-overlapping mutable file/worktree
  scopes. Keep final acceptance and global stage decisions with the goal owner.
  Reuse an agent only after its changes/findings are preserved, processes are
  drained, unresolved issues are handed off, and ownership is unambiguous.
- Before committing, inspect the staged names and diff; stage explicit task
  files rather than blanket-adding a dirty tree. Exclude editor/import churn,
  generated scratch, and unrelated user work unless explicitly requested.
- Before pushing, inspect the upstream and every commit ahead of it. Push only
  when the complete outbound commit set is within the user's requested scope;
  if it includes unrelated or unreviewed work, stop and obtain direction or
  isolate the requested changes. Report exactly what commits were pushed.
- Keep the game repository and documentation repository distinct. Do not leave
  long-term plans, reports, or handoffs only in a local worktree or game repo;
  publish canonical documentation to the documentation repository and link it
  from the code/task handoff.

## DO NOT FAKE GAMEPLAY TESTS

- Tests may use mocks only when they are explicitly named and reported as unit, contract, synthetic, static-audit, or service-level tests.
- A mocked, synthetic, direct-service, metadata-only, source-scan, direct-helper-call, or teleport-driven test MUST NOT be cited as acceptance evidence for live gameplay.
- NPC/pathfinding acceptance must run through the real game scene or a real headed gameplay fixture with real `CharacterBody3D` NPCs, real physics frames, real generated-world doors/buildings, real behavior scheduling, and real player/NPC interaction paths.
- NPC/pathfinding acceptance must not directly call tutorial progression handlers, `interact_with`, `on_door_opened`, `on_block_placed`, `sleep_at_bed`, `npc_system.move_npc`, `request_door_state`, `request_crossing`, or mark success through metadata such as `npc_inside_home`.
- Fixture setup may use narrowly documented placement helpers before the act phase, but the behavior being proven must proceed through live game systems.
- Door/home acceptance must prove the visible sequence: approach the door, open it before crossing, enter a strict interior location, clear the threshold, and close the door after clearance. Stats and metadata may support the claim, but they cannot be the only proof.
- New headed NPC acceptance runners must call `tools/npc/assert-npc-acceptance-runner-clean.mjs` before launching Godot.
- Every NPC/pathfinding acceptance claim must include the command, report path, screenshots or trace/timeline evidence when visual behavior matters, and a brief statement of what the test does and does not prove.
- For startup measurements at a particular location, select the initial spawn
  before attaching the world and starting terrain streaming. A later teleport
  measures relocation and competing streaming work, not that location's cold boot.
  An explicit-spawn diagnostic still does not prove ordinary menu/exploration flow.
- When an API becomes asynchronous, migrate synthetic fixtures to admitted input
  and accepted output while preserving their substantive assertions. Do not add a
  synchronous production fallback to satisfy an old immediate-result fixture.
  Grammar parsing is not Godot compilation, and compilation is not gameplay proof.

## Important Plans And Docs

### Documentation ownership

- The canonical home for all new project documentation is the public
  [Voxel Biome World documentation repository](https://github.com/lakam99/voxel-godot-docs): architecture notes, design docs, implementation plans, handoffs, phase reports, test/acceptance evidence, performance records, and migration notes all belong there.
- Do not add new long-form documentation or reports under this game's `docs/`
  tree. Keep this repository's `AGENTS.md`, concise code-local `README.md` files,
  and the existing operational references below beside the code; use links to
  the documentation repository for new supporting material.
- The operational docs already listed below are grandfathered in this
  repository and may be maintained in place. Do not create new full-length
  documents alongside them. If one is deliberately migrated, make the
  documentation-repository copy canonical and leave only a short pointer here.
  New reports should cite the game commit/PR and exact test reports or artifacts
  they describe.
- The documentation repository is a separate Git repository, not a submodule.
  Make documentation changes there and publish them to its `main` branch; then
  update links here if its canonical paths change.

- `docs/architecture/npc-navigation-manifesto.md`: the pathfinding stability
  manifesto. Read it before work that could touch NPC routing, generated
  collision, doors, towns, streaming, navigation publication, or pathfinding
  acceptance. The routing replacement is complete; its code is protected
  unless pathfinding work is explicitly authorised.
- Historical pathfinding plans and phase reports are archived in the
  [documentation repository](https://github.com/lakam99/voxel-godot-docs/tree/main/gameplay/npc-navigation).
- `docs/roadmaps/tutorial-town-loading.md`: controlling sequential plan for
  making the tutorial town a fully published loading artifact and removing
  tutorial-specific movement privilege from generic NPC systems. Follow it
  before changing tutorial-town readiness, tutorial NPC spawning/home
  assignment, post-knock behavior, or tutorial-owned NPC commands.
- `docs/architecture/terrain-authority.md`: terrain architecture context. The target is Minecraft-like terrain authority with smooth/non-blocky rendering, not a heightfield plus cave band-aids.
- `docs/roadmaps/performance.md`: performance roadmap and prior performance
  constraints. Recheck when touching terrain, chunk streaming, structures,
  NPC/nav, autosave, or main menu/runtime loading.
- `docs/roadmaps/visual-upgrade.md`: visual polish roadmap.
- `docs/roadmaps/story-implementation.md`: story/worldmark roadmap. Follow one phase at a time.
- `docs/world-generation/biome-region-field.md`: the current single-authority regional-biome
  contract and its focused verification.
- `docs/pipelines/animated-assets.md`: generated animated asset workflow.
- `docs/game-design/story/summary.md`: narrative brief for story manager context.
- Dated visual reports are preserved in the [documentation repository](https://github.com/lakam99/voxel-godot-docs/tree/main/art-direction).

When executing story work, reread `docs/roadmaps/story-implementation.md` and follow the requested phase only. Phase reports and commits are part of the expected workflow.

## Procedural Ecology And Trees

Trees are generated world behaviour, not a static asset catalogue or a
decorative afterthought. The biome/environment policy and deterministic tree
recipe are the source of truth for both PoCs and the live world.

```text
BiomeRegionField -> BiomeEnvironmentCatalog -> TreeEcologySampler
  -> ProceduralTreeRecipeBuilder / family grammar -> TreeRecipeCache
  -> TreeRuntimeRequestBuilder -> TreePublicationQueue -> visual/collision publication
```

- Tree family, age, scale, trunk form, branching and leaf distribution should
  derive from stable seed/biome/ecology inputs. Do not hand-place a special
  forest stand or fork a PoC-only tree builder to get a visual result.
- The mathematical tree PoCs under `scenes/testing/MathematicalTreePocTest.tscn`
  and `scripts/testing/trees/` must call the same family recipe path as runtime
  spawning. If a tree needs to look different everywhere, improve the recipe
  grammar rather than replacing live assets by hand.
- Mature broadleaf/oak forms need greedy branching along viable split axes,
  allometric taper, outward/dome-seeking growth and recursive terminal detail.
  Conifers and savanna trees need their own grammar, not a uniformly scaled oak.
- No branch/leaf collision is required unless gameplay explicitly asks for it;
  player collision belongs to trunks/declared blockers. Visual wind, shadow and
  density must remain compatible with chunk streaming and frame budgets.
- Profile recipe construction and publication separately. Prioritise facing or
  approaching content without creating invisible solid obstacles or reordering
  deterministic spawn results.

## Test Commands

All executable tool entry points are Node.js (`node tools/<runner>.mjs`). Do
not add PowerShell runners or wrappers. Windows Job Object and window APIs
use the small native helpers under `tools/native/`, compiled directly by Node;
they must not shell out to PowerShell. See `docs/development/node-test-runners.md`.

Use the bundled Godot console executable paths already encoded in the tool scripts.

Functional playtest:

```powershell
node tools/run-playtest.mjs
```

NPC pathfinding replacement harness:

```powershell
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/npc/run-all-npc-tests.mjs -TimeMode Both
node tools/run-all-test-runners.mjs
```

Phase 13 focused NPC release checks:

```powershell
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/npc/run-npc-motor-tests.mjs -TimeMode Both
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both
node tools/npc/run-npc-route-tests.mjs -TimeMode Both
node tools/npc/run-npc-repair-tests.mjs -TimeMode Both
node tools/npc/run-npc-door-tests.mjs -TimeMode Both
node tools/npc/run-npc-avoidance-tests.mjs -TimeMode Both
node tools/npc/run-npc-traffic-tests.mjs -TimeMode Both
node tools/npc/run-npc-behavior-tests.mjs -TimeMode Both
node tools/npc/run-npc-behavior-tests.mjs -TimeMode Transition
node tools/npc/run-npc-interaction-tests.mjs -TimeMode Both
node tools/npc/run-npc-streaming-save-tests.mjs -TimeMode Both
node tools/npc/run-npc-soak-tests.mjs -TimeMode Both
node tools/npc/run-npc-soak-tests.mjs -TimeMode Transition
node tools/npc/run-npc-observation-tests.mjs -TimeMode Both
node tools/run-npc-navigation-tests.mjs
```

Live NPC and runtime regression runners:

```powershell
node tools/npc/run-real-tutorial-playthrough.mjs
node tools/npc/run-npc-town-job-cycle-visual-playtest.mjs
node tools/npc/run-npc-go-home-visual-playtest.mjs
node tools/run-normal-runtime-performance-pass.mjs
node tools/run-runtime-performance-observation.mjs
```

Terrain, underground, and digging visual runners:

```powershell
node tools/run-underground-visual-playtest.mjs
node tools/run-underground-interactive-playtest.mjs
node tools/run-digging-visual-playtest.mjs
node tools/run-town-ground-visual-playtest.mjs
node tools/run-light-shadow-visual-playtest.mjs
```

Visual captures:

```powershell
node tools/run-visual-captures.mjs
```

Biome and procedural-ecology contracts:

```powershell
node tools/run-biome-region-field-contract-tests.mjs
node tools/run-tree-spawn-performance.mjs
node tools/run-procedural-tree-performance-benchmark.mjs
```

World signature:

```powershell
node tools/run-world-signature.mjs
```

Useful generated asset commands:

```powershell
node tools/blender/build-environment-assets.mjs
node tools/blender/build-character-assets.mjs
node tools/blender/build-animated-assets.mjs
node tools/blender/build-static-item-assets.mjs
```

If a playtest times out, inspect `playtest-progress.txt` and `playtest-report.json` before changing code.

Use random seeds for broad tutorial or generated-town playtests unless replaying a known failing seed for root-cause work. When replaying a failing seed, report that seed explicitly.

## Terrain And World Generation Rules

- Treat terrain volume as authoritative. Below the surface is solid material unless the generated volume, fluid, or a saved edit explicitly says otherwise.
- Do not fix terrain leaks with mouth/back shell patches, one-off cave wrappers, or visual-only skirts. If a hole exposes sky or the far side of a hill, the volume/cell/material authority is wrong.
- Terrain visuals, collision, digging drops, lighting, underground air, fluids, spawning, nav occupancy, and saves should derive from the same generated/edited volume data.
- `underground_air` is a generated world state/biome, not a hand-authored cave exception. Underground should be procedurally generated like the surface, with solid cells, air cells, material strata, and exposed surfaces.
- Digging should remove real terrain cells/material and reveal what the volume says is underneath. Drops must come from the removed material, not from a surface guess.
- Smooth terrain rendering must not erase physical density. Block/cell authority is acceptable and often preferred for correctness; smooth the mesh over it rather than replacing volume with thin sheets.
- Lighting regressions are gameplay-visible. Daylight, skylight, torch/block light, shadows, underground darkness, and translucent/metallic-looking terrain need visual verification when terrain or materials change.
- When changing terrain generation, chunk meshing, digging, collision, lighting, or underground rules, run relevant visual playtests and inspect screenshots. Metadata-only checks are not enough for leaks, transparency, or material/lighting bugs.
- Placement height, edited-volume surface projection and the interpolated native
  collision surface are different contracts. Verify against the authority being
  tested; do not change generation or widen tolerances merely to match a placement
  helper. Keep the sampled cells/materials and actual collision hit in the evidence.

## Runtime And Loading Rules

- The main menu should defer expensive world loading until `New Game` or `Continue` is selected.
- Prefer the repository's owned-process watchdog runners for every Godot test,
  especially headed or long-running tests. A failed, timed-out, or visibly
  broken run must be stopped promptly; do not leave launched processes running
  after the result is known.
- Process cleanup is part of test correctness. Record the functional result
  separately from cleanup, terminate only the runner-owned process job, and
  require authoritative zero-member evidence before calling the run terminal.
  Never kill unrelated pre-existing Godot processes by name or PID ancestry.
- If loading or exiting takes noticeable time, show a loading/progress state and yield work across frames where possible. A frozen window is a bug even if the eventual result is correct.
- `startup_loading_completed` means the initial playable world is actually ready. For the tutorial town this includes drained required structure operations, a complete validated town manifest, required home/door records, registered NPC home assignments, authoritative terrain collision, and the initial navigation publication needed by those actors.
- Do not enter playable tutorial state with partial town records and repair them later from dialogue, interaction, or NPC behavior code. Missing required generated records are a loading failure, not an NPC wait state.
- Loading work may be budgeted across frames, but readiness commands and gameplay intents must never be dropped when a budget or dependency is pending. Either keep loading active or retain an explicit retryable request with bounded telemetry.
- Tutorial playtests can be smoother than normal gameplay because they may stage or constrain the world differently. Use normal runtime performance passes when diagnosing player-reported gameplay hitches.
- Treat sprinting/running traversal as a streaming stress test. It is the common path that exposes chunk, terrain, prop, NPC, and autosave spikes.
- Loading and teardown must gate every execution owner, including independent
  Node physics callbacks; disabling Main or actor bodies alone may leave shared
  systems advancing. Keep required preparation work runnable through its explicit
  loading path, and release gameplay only after current dependencies acknowledge.

## Asynchronous Publication And Ownership

- Distinguish source capture, worker preparation, upload/registration and owner
  acknowledgement. A queued request, completed worker or visible node alone does
  not establish that collision, interactions and navigation are usable.
- Worker inputs must be owned value data with complete source identity. Making an
  outer Dictionary read-only does not freeze nested containers or remove Nodes,
  WeakRefs, RIDs and Callables. Use the existing producer admission/immutable
  artifact contracts instead of trusting arbitrary read-only containers.
- Bind accepted results to the current world/source revision, weak owner and
  actual installation. Identical geometry from a replacement owner is not proof
  that an earlier installation is still current. Validate before cache reuse and
  again after asynchronous completion.
- Cache eviction must not lose retained demand or force a valid installation to
  reconstruct its proof. Conversely, a source-key marker cannot excuse a dirty,
  unloaded or replaced installation. An authoritative empty result also needs
  explicit acceptance and invalidation; missing data is never empty success.
- Deduplication must preserve new urgency: existing background demand can become
  player-safety work. Keep requests retryable under backpressure, and report the
  concrete pending dependency, owner/source identity and queue stage with bounded
  telemetry rather than one ambiguous readiness boolean.
- Regional dependency closure follows actual intersecting supports, crossings
  and declared scenario requirements. Do not expand every local request to a
  whole settlement or landmark by convenience, or omit a real dependency merely
  to release movement sooner. Optional appearance must not add surprise blockers.
- Retain the old valid representation until its replacement is complete. Transfer
  all large payload aliases through the existing cancellation/retirement owner;
  moving construction to a worker while destroying its last large alias on Main
  can simply move the hitch to cleanup. Shutdown must drain owned workers.
- Keep temporary copied scripts and alternate fixtures under an ignored artifact
  directory with `.gdignore`; otherwise Godot can import duplicate class names.

## Performance Standards

- Treat visible hitches and whole-game freezes as correctness bugs, especially during sprinting, chunk streaming, generated town/structure activation, NPC updates, autosave, and tutorial-town play.
- Profile before optimizing. Use runtime performance reports to identify the actual spike source, and report the command, report path, worst frame, last spike reason, and top sections.
- Do not spend project time chasing tiny threshold noise, such as sub-0.1ms differences, unless the user explicitly asks. Prefer fixes that remove noticeable spikes or reduce high-percentile/max frame stalls.
- For broad changes to terrain generation, chunk streaming, structures, NPC/nav, autosave, or HUD frame work, run a representative runtime performance observation. Include sprinting/traversal coverage when movement can load new world content.
- Do not perform large synchronous work in a gameplay frame when it can be queued or budgeted. Chunk creation, prop spawning, generated structures/towns, navmesh publishing, route work, and expensive scans should be spread across frames with measured budgets.
- Preserve deterministic world generation while optimizing. Caches, queues, and budgets must not reorder terrain/town/prop RNG or change generated-world results unless that behavior change is intentional and tested.
- If performance changes touch visual or gameplay systems, run relevant playtests in addition to benchmarks. For tutorial-town, NPC, or navigation-affecting changes, use real visual/playtest runners and inspect screenshots/trace evidence rather than relying only on metadata.
- Keep performance instrumentation useful and bounded. Add timers/counters for diagnosis, but remove or reduce noisy temporary probes once the spike source is understood.
- Loading screens, async queues, and budgets must preserve deterministic generation. Do not fix freezes by reordering terrain/town/prop RNG unless the behavior change is intentional and verified.
- For a multi-minute deterministic generator, first build the smallest pinned
  replay or failure-only observation that can distinguish competing causes.
  Make one falsifiable change, run its focused contract, then pay for one full
  source run. Do not loop the full runner without new evidence or optimize a
  subsystem that the current evidence has not implicated.
- Failure instrumentation must be bounded, cancellation-aware, and incapable
  of changing acceptance. Capture exact producer IDs/categories and source
  revisions so later work starts at the owning decision rather than repeating
  broad diagnostics.
- Measure total frame cadence separately from Main's `_process` duration,
  rendering CPU/GPU time and worker time. Worker duration is not main-frame CPU
  cost. Callback-to-callback stage intervals are not exclusive function timings;
  overlapping phases and maxima from different frames must not be added together.
- A cooperative budget cannot interrupt one oversized operation. Measure capture,
  copying/sealing, upload and registration as well as worker computation, and
  split the measured operation before increasing the budget. Spatial batching
  must earn its extra draw calls through measured culling benefit.
- Record initial playable readiness and whole-site completion separately. Compare
  equivalent readiness contracts, viewport, seed and traversal; report fresh
  process/empty generated caches separately from warm-cache results. Runner wall
  time may include setup, inspection, export and shutdown, not just generation.
- Inspect movement holds, recovery attempts and tail frame times even when a run
  reaches its destination and all diagnostic checks pass. Batch independent
  defects found in that snapshot before another full run; do not repeatedly grow
  tests/reviews while postponing the next production comparison.

## Key Systems

- `scripts/PlaytestRunner.gd`: broad integration coverage. Add only small smoke coverage here; use dedicated runners for large new domains.
- `scripts/MainSaveState.gd` and `scripts/SaveSystem.gd`: save snapshot and version handling.
- `scripts/InventorySystem.gd`, `CraftingSystem.gd`, `UtilityBlockSystem.gd`: inventory, crafting, chests, workstations.
- `scripts/TutorialSystem.gd`, `TutorialDialogueSystem.gd`, `TutorialRepairQuest.gd`, `TutorialRescueSystem.gd`, `TutorialSceneBuilder.gd`: storm-night tutorial and starter town flow.
- `scripts/NpcSystem.gd`, `NpcPathing.gd`, `NpcCombat.gd`, `NpcStats.gd`, `NpcProfileRules.gd`: NPC homes, jobs, combat, pathing, hunger/forager behavior.
- `scripts/HostileSystem.gd`, `HostileProjectileSystem.gd`, `HostileRules.gd`: enemies and projectile behavior.
- `scripts/WeatherSystem.gd`: day/night/weather presentation and weather snapshots.
- `scripts/GameHud*.gd`, `MainHudFlow.gd`: HUD, inventory UI, settings, objectives, contracts.
- `scripts/visual/*Registry.gd`: generated visual asset registries.
- `scripts/ItemVisualFactory.gd`, `HeldItemSystem.gd`, `ItemIconFactory.gd`: item meshes, held visuals, UI icons.
- `scripts/environment/TreeEcologySampler.gd`, `ProceduralTreeRecipeBuilder.gd`,
  `TreeSpawnService.gd`, and `TreePublicationQueue.gd`: deterministic tree
  ecology, recipes, request construction and budgeted runtime publication.
- `scripts/visual/ProceduralTreeVisualFactory.gd` and
  `TreeChunkBatchRenderer.gd`: live tree visuals and chunk-safe batching.
- `scripts/environment/EnvironmentWindSystem.gd`: shared wind inputs for
  foliage/grass presentation; do not add unrelated per-prop wind clocks.
- `scripts/story/StoryDirector.gd`, `StoryEventBus.gd`, and
  `StoryQuestSystem.gd`: deterministic story state, event flow and quest
  ownership.

## Tutorial Town And NPC Boundaries

- Tutorial-town NPCs are ordinary production NPCs. They use the same registration, schedule, intent, route authority, collision probes, motor, doors, traffic, save, and recovery contracts as every other NPC.
- Named NPC IDs such as `mira`, `niko`, `rowan`, or `sera` may appear in tutorial scenario data, dialogue, quest conditions, and presentation code. They must not create named movement, routing, home-readiness, collision, door, budget, or recovery behavior in `NpcSystem` or `scripts/npc_ai/`.
- Generic NPC systems must expose generic commands such as wait, go to, go home, resume schedule, or cancel. Do not add APIs such as `release_intro_hold_and_order_home`, named-NPC helpers, tutorial-only route writers, or actor-specific fallback movement.
- The tutorial orchestration layer may select an actor and issue a generic command. For example, completing the knock interaction may replace a generic wait order with `order_go_home(actor, reason)`. After command submission, normal NPC authority owns readiness, routing, execution, and arrival.
- Temporary story choreography must use generic, owner-scoped orders or suspension tokens. Do not control movement through ad hoc metadata such as `holdIntroDoor`, `npc_hold_intro_door`, or named flags that generic NPC code interprets specially.
- Generated town/home/door data is produced and validated before gameplay is enabled. Tutorial dialogue must not call town generation, refresh home records, wait for structure publication, rebuild assignments, or silently fall back to guessed home/porch/door cells.
- A town manifest must validate the records actually required by the scenario, including unique stable IDs, home cells, porch cells, door cells/portals, strict interior bounds, structure existence, and deterministic assignment. Do not use a magic record count as a substitute for semantic completeness.
- If required tutorial-town generation cannot complete, keep the loading screen active and surface a structured failure. Do not let an NPC stand indefinitely while a one-shot command is discarded, and do not rely on later schedule evaluation to mask the dropped command.
- Tutorial identity metadata may decorate dialogue, UI, quest ownership, or save state, but generic NPC behavior must not branch on `tutorial` identity when an ordinary role, job, schedule, order, capability, or story-owned state can express the requirement.
- When modifying this boundary, audit New Game and Continue, old saves, random seeds, generated-home variation, dialogue close paths, immediate command acceptance, eventual strict-home arrival, door clearance/close, and normal non-tutorial NPC behavior.
- Acceptance must include a real main-menu -> New Game headed run with no gameplay-affecting flags. Prove the command is accepted promptly after the visible interaction and that the NPC completes the same generic go-home flow; a synthetic direct `go_home` call is contract evidence only.

## Backlog

### Deterministic terrain-collision tile pipeline

> **Historical backlog note (superseded 2026-09-17):** the implementation and
> deferral decisions in this subsection predate
> the [native world-backend migration archive](https://github.com/lakam99/voxel-godot-docs/tree/main/migrations/native-world-backend). The native
> N0–N9 migration now owns this cutover, including a pure native source core,
> standalone native coverage, collision-first publication, and deletion of the
> old production path after validation. Preserve the measurements and safety
> requirements below, but do not implement a new GDScript-first collision
> authority or treat the former post-Gate-5 deferral as current policy.

The current `VoxelTerrainRuntime` obtains player terrain collision as a side
effect of moving broad `VoxelViewer` footprints. This remains acceptable as a
temporary implementation, but it is not a bounded long-term streaming design.
The existing native-task threshold is an admission check only: one accepted
80–96 m viewer can independently enqueue hundreds of Voxel Tools jobs.

Focused normal-runtime evidence is retained at
`artifacts/world-streaming-maturity/g5/focused-sprint-viewer-workload-attribution-01/report.json`.
That menu → New Game → ordinary-input run travelled 533.75 m with zero collision
holds and good measured cadence (12.776 ms p99, 22.608 ms maximum), but startup
took 103.159 s and native work peaked at 708 queued tasks. Per-request telemetry
recorded individual viewer peaks from roughly 214 to 708 tasks. A short smooth
run therefore does not prove that sustained wilderness/Citadel travel has a
bounded backlog; do not describe the 8-task admission threshold as a hard cap.

The intended replacement is:

```text
seed + durable edits
  -> authoritative terrain density/material volume
  -> deterministic, revisioned collision tiles aligned to native mesh blocks
  -> bounded collision build/install queue and exact physics receipt
  -> player/NPC collision consumers

authoritative terrain volume
  -> independently scheduled render-mesh publication
```

- Keep terrain volume as the sole authority. Collision tiles and render meshes
  are derived artifacts, not competing terrain implementations.
- Prefer 16-cell collision tiles aligned to the current native mesh-block grid.
  Player motion should request only the tiles intersecting its bounded swept
  volume, with a hard cap on builds/installations in flight.
- Key receipts by world/generator identity, tile coordinate, durable edit
  revision and collision-builder revision. A terrain edit invalidates its tile
  and required seam neighbours only.
- Build and compare the new tile path in diagnostic shadow mode first. After
  source/shape/seam parity and live collision are proven, migrate player motion
  proof and startup readiness, then disable VoxelTerrain-generated collision so
  two physical authorities never coexist in production.
- Preserve generated-structure collision ownership, the protected route/motor/
  door stack, and navigation publication contracts. Navigation may consume the
  revisioned terrain artifact but must not gain a second topology authority.
- Implement the architecture in GDScript first. Move only a measured, pure,
  deterministic tile-extraction kernel to the existing C++/GDExtension pipeline
  if profiling shows that extraction remains material after work is localized.

The user explicitly deferred this architectural replacement until after Gate 5.
The unbounded native-task count and its loading cost are therefore recorded
technical debt, not a Gate 5 blocker by themselves. This decision does not waive
physical safety, terrain solidity, clean shutdown, or the requirement to report
player-visible collision holds honestly during the headed journey. Gate 5 may
proceed on the current implementation, with the deferred architecture and its
measured limitations carried into the final handoff.

### Route-finalization occupancy scalability

> **Historical backlog note (superseded 2026-09-17):** the inherited Gate-5
> tranche cursorized the relevant planning/finalization work. Treat its exact
> ordering, validator budgets, and LOD eviction as protected behavior. Verify
> the current contracts before changing anything; N6 may optimize source and
> approach-candidate spatial indexes, including SmartObjectService indexing,
> without changing the protected route result/order or live proof semantics;
> do not reimplement the older atomic design described below. Native N6 may
> move only the CPU/query boundary defined by the migration handoff and must
> leave final live collision/occupancy proof with the existing route authority.

Gate 5's 32-NPC workload uses a 48-step cheap-work slice for incremental route
planning while retaining two collision-backed validation calls per admitted
planner call. This bounds the measured workload, but the current unversioned
dynamic-occupancy signature is still collected atomically. More than 48 relevant
occupied cells can therefore defer finalization without progress. The defined
32-NPC acceptance workload remains viable, but larger populations or concurrent
hostile occupancy require an incremental or revisioned occupancy artifact rather
than another larger per-frame allowance. Also treat `cheapStepsThisCall` as a
logical-work counter: deferred-frontier selection can scan multiple records in
one counted step, so headed timing—not the counter alone—must prove the 2 ms atom
criterion.

## Known Bugs

- Tutorial town perimeter gate/fence: the game can destroy the perimeter gate, which causes the entire bridge to appear as pickup material. This breaks the perimeter fence repair quest because there is no intact fence/gate structure left for the player to repair. Future fixes should preserve tutorial-town gate, fence, and bridge structures from unintended destruction, cleanup, or resource-drop conversion during the tutorial flow.

## Visual Style

Target style: cozy voxel, not flat prototype cubes.

Keep:

- softer palettes;
- clear silhouettes;
- readable item meshes;
- true-dark nights with fire/lantern illumination;
- warm lantern/campfire flicker;
- biome-specific foliage and prop identity;
- immersive HUD that avoids debug clutter during normal play.

Avoid:

- generic cubes for utility items;
- excessive one-color palettes;
- UI panels that feel detached from the game unless they are menus;
- over-bright nights;
- decorative objects with gameplay collision unless explicitly needed.

## NPC And AI Expectations

Pathfinding replacement is complete and protected by
`docs/architecture/npc-navigation-manifesto.md`. Do not
modify it during ordinary NPC, tutorial, terrain, loading, performance or world
generation work. If a task explicitly authorises pathfinding work, begin with
the manifesto and the relevant historical plan, then tie every acceptance claim
to a command, report, trace, capture, static audit, or commit.

If an NPC symptom might involve routing, diagnose read-only first. Do not patch
Niko, Mira, Rowan, or any named NPC in isolation when the shared route contract
is the likely owner.

Current ownership:

- `scripts/NpcSystem.gd` is the gameplay integration, spawn/registry, save-facing, and public stats adapter. Do not move new route search, direct movement loops, or door authority back into it.
- `scripts/NpcPathing.gd` is a thin facade over `scripts/npc_ai/routing/NpcNavigationCoordinator.gd` for existing callers.
- `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd` owns generated-world navigation topology snapshots and consumes navigation events.
- `scripts/npc_ai/routing/NpcRouteAuthorityV2.gd` is the production NPC route authority for migrated behavior. `scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd` owns collision-backed route proof before commit, and `scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd` owns lease-based execution through the shared motor.
- `scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd` and `HierarchicalRoutePlanner.gd` own deterministic route planning, route repair, and traversal actions.
- `scripts/npc_ai/movement/NpcRouteMovementController.gd` owns route-following through the shared `CharacterBody3D` motor.
- `scripts/npc_ai/interactions/DoorPortalService.gd`, `DoorController.gd`, and `DoorTraversalExecutor.gd` own shared player/NPC door authority.
- `scripts/npc_ai/traffic/TrafficReservationService.gd` owns bottleneck reservations, pending replans, priority aging, and active crossing cleanup.
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd` and related behavior services own job phases, schedule execution, and semantic goals.

NPCs should move with purpose:

- Every town NPC should have a home.
- Noncombatants should return indoors at night.
- Fighters may guard or engage threats.
- Foragers should use hunger, personal inventory, and berry gathering as a first goal loop. If no specific forage target is currently reachable, they should use collision-aware roaming outside town until a forage target is in range.
- NPCs should not wander aimlessly into walls.
- Pathing should account for terrain, obstacles, doors, town limits, and reachable work areas.
- Metadata may define goals, homes, jobs, doors, and work areas, but routing must prove physical reachability through collision-aware navigation before an NPC commits to movement.
- A route may be pending because nav data, tile publication, door links, traffic, or budgets are not ready. Pending nav data is not the same as an unreachable target and must not poison targets as permanently unreachable.
- Production NPC movement must not rely on generated-cell bridges, exact-home collision lattice planners, composed door routes, partial endpoint success, doctored vectors, teleporting, hand-authored offsets, or direct movement loops that bypass collision. Such paths may remain only in clearly labeled diagnostics or synthetic tests, and diagnostics must not be cited as gameplay acceptance.
- Door behavior should open before crossing, clear collision while open, and close after NPC/player clearance.
- Door crossings should keep per-actor active ownership until the actor clears or is cancelled; route replacement must not silently drop an active portal reservation.
- `canFight` is combat capability only. Explicit guard-duty assignment decides who may stay outside at night.
- Porch, threshold, exterior wall edge, or roof locations do not count as inside.

Route readiness should distinguish:

- `ready`: executable collision-backed route.
- `pending_nav_data`: required navmesh tiles, links, or topology are still loading/publishing.
- `pending_budget`: route or movement work was deferred by frame budgets.
- `blocked_dynamic`: actor, door, reservation, or local obstruction is temporarily blocking movement.
- `unreachable_static`: all relevant nav data is ready and no legal route exists.
- `invalid_goal`: the semantic target is not a valid standable/reachable goal.

When changing NPC pathing, add or update playtest coverage around:

- obstacle avoidance;
- doors opening/closing;
- avoiding buildings/windows/walls;
- returning home without teleporting through walls;
- forager target selection and inventory;
- hostile collision with buildings and fences.

For NPC regression fixes, acceptance should include at least one known failing seed, multiple fresh random generated-town runs when practical, and the full live tutorial playthrough from main menu/New Game when tutorial behavior is affected. Inspect screenshots and traces; do not rely only on result booleans.

## Story Rules

Story systems must be composition-based. Do not put quest authority in dialogue strings. Dialogue/prose decorates deterministic game state.

Follow the story plan’s constraints:

- gameplay facts are deterministic;
- prose must not invent mechanics;
- generated prose must be cacheable and optional;
- save data is additive;
- events are idempotent;
- no unbounded event logs;
- no LLM dependency for core gameplay.

Use `scripts/story/`, `resources/story/`, `scenes/story/`, and `scenes/story_testing/` as the story architecture grows.

## Git Workflow

Do not assume the active branch or default branch name. Discover both from Git,
and confirm that the current worktree is the one named by the task before
editing or running tests.
Sibling project directories may be different Git worktrees with different
branches. A branch name alone does not carry another worktree's uncommitted
changes. At handoff distinguish committed code, working-tree edits and ignored
evidence, and identify the exact directory the next agent must retain.

Before major work:

```powershell
git branch --show-current
git status --short
```

For focused feature branches, use clear names such as:

```text
codex/story-worldmarks
codex/visual-overhaul
codex/npc-pathing
```

The user has given standing approval to commit completed, verified chunks of
work regularly. Make a focused commit after each coherent change and its
applicable checks; do not wait for another commit request or accumulate a large
uncommitted backlog. State any remaining failures or acceptance limits honestly.
Stage only the task's files, preserve unrelated work, and leave generated test
artifacts/import churn out. Commit messages should describe the behavior, not
just files changed. Report the commit hash at handoff. This does not authorize
pushing, merging, resetting, cleaning, or rewriting history.

## Local Files To Avoid Committing Accidentally

`.gitignore` currently excludes:

```text
.godot/
export.cfg
export_presets.cfg
*.tmp
*.translation
playtest-report.json
playtest-progress.txt
artifacts/visual/
artifacts/world-signature/
artifacts/story/
```

Visual baseline artifacts under `artifacts/baselines/` may be intentional tracked assets. Do not delete them casually.

## Verification Standard

For gameplay changes, run `node tools/run-playtest.mjs` unless the change is
documentation-only or the user explicitly says not to.

For visual changes, run visual captures when feasible and inspect the output. If a visual issue is viewport-dependent, test at least one normal gameplay viewport and one dark/night case.

For save/story changes, verify:

- old saves with missing fields load;
- save/load round trips preserve new state;
- duplicate events do not duplicate rewards, NPCs, clues, or props.

Report honestly when tests were not run.
