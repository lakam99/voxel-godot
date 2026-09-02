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
  `MANIFESTO.md` before considering any change there.

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

## DO NOT FAKE GAMEPLAY TESTS

- Tests may use mocks only when they are explicitly named and reported as unit, contract, synthetic, static-audit, or service-level tests.
- A mocked, synthetic, direct-service, metadata-only, source-scan, direct-helper-call, or teleport-driven test MUST NOT be cited as acceptance evidence for live gameplay.
- NPC/pathfinding acceptance must run through the real game scene or a real headed gameplay fixture with real `CharacterBody3D` NPCs, real physics frames, real generated-world doors/buildings, real behavior scheduling, and real player/NPC interaction paths.
- NPC/pathfinding acceptance must not directly call tutorial progression handlers, `interact_with`, `on_door_opened`, `on_block_placed`, `sleep_at_bed`, `npc_system.move_npc`, `request_door_state`, `request_crossing`, or mark success through metadata such as `npc_inside_home`.
- Fixture setup may use narrowly documented placement helpers before the act phase, but the behavior being proven must proceed through live game systems.
- Door/home acceptance must prove the visible sequence: approach the door, open it before crossing, enter a strict interior location, clear the threshold, and close the door after clearance. Stats and metadata may support the claim, but they cannot be the only proof.
- New headed NPC acceptance runners must call `tools/npc/assert-npc-acceptance-runner-clean.mjs` before launching Godot.
- Every NPC/pathfinding acceptance claim must include the command, report path, screenshots or trace/timeline evidence when visual behavior matters, and a brief statement of what the test does and does not prove.

## Important Plans And Docs

- `MANIFESTO.md`: the pathfinding stability manifesto. Read it before work that
  could touch NPC routing, generated collision, doors, towns, streaming,
  navigation publication or pathfinding acceptance. The routing replacement is
  complete; its code is protected unless pathfinding work is explicitly
  authorised.
- `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`,
  `CODEX_MATURE_NAV_PLAN.md`, and `NPC_PATHFINDING_REGRESSION_HANDOFF.md`:
  historical implementation/reference material. They become controlling only
  for explicitly authorised pathfinding work; otherwise use them to preserve
  contracts, not to restart an old replacement campaign.
- `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: controlling sequential plan for making the tutorial town a fully published loading artifact and removing tutorial-specific movement privilege from generic NPC systems. Follow it before changing tutorial-town readiness, tutorial NPC spawning/home assignment, post-knock behavior, or tutorial-owned NPC commands.
- `Minecraft-Equivalent Terrain Migr.md`: terrain architecture migration context. The target is Minecraft-like terrain authority with smooth/non-blocky rendering, not a heightfield plus cave band-aids.
- `CODEX_PERFORMANCE_PLAN.md`: performance roadmap and prior performance constraints. Recheck when touching terrain, chunk streaming, structures, NPC/nav, autosave, or main menu/runtime loading.
- `CODEX_VISUAL_UPGRADE_PLAN.md`: visual polish roadmap.
- `CODEX_STORY_IMPLEMENTATION_PLAN.md`: story/worldmark roadmap. Follow one phase at a time.
- `docs/KILOMETRE_BIOME_FIELD.md`: the current single-authority regional-biome
  contract and its focused verification.
- `docs/ANIMATED_ASSET_PIPELINE.md`: generated animated asset workflow.
- `docs/STORY_SUMMARY.md`: narrative brief for story manager context.
- `docs/VISUAL_*_REPORT.md`: prior visual work and verification notes.

When executing story work, reread `CODEX_STORY_IMPLEMENTATION_PLAN.md` and follow the requested phase only. Phase reports and commits are part of the expected workflow.

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

## Runtime And Loading Rules

- The main menu should defer expensive world loading until `New Game` or `Continue` is selected.
- If loading or exiting takes noticeable time, show a loading/progress state and yield work across frames where possible. A frozen window is a bug even if the eventual result is correct.
- `startup_loading_completed` means the initial playable world is actually ready. For the tutorial town this includes drained required structure operations, a complete validated town manifest, required home/door records, registered NPC home assignments, authoritative terrain collision, and the initial navigation publication needed by those actors.
- Do not enter playable tutorial state with partial town records and repair them later from dialogue, interaction, or NPC behavior code. Missing required generated records are a loading failure, not an NPC wait state.
- Loading work may be budgeted across frames, but readiness commands and gameplay intents must never be dropped when a budget or dependency is pending. Either keep loading active or retain an explicit retryable request with bounded telemetry.
- Tutorial playtests can be smoother than normal gameplay because they may stage or constrain the world differently. Use normal runtime performance passes when diagnosing player-reported gameplay hitches.
- Treat sprinting/running traversal as a streaming stress test. It is the common path that exposes chunk, terrain, prop, NPC, and autosave spikes.

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

Pathfinding replacement is complete and protected by `MANIFESTO.md`. Do not
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

Current stable branch should be `master` unless the user asks for a feature branch.

Before major work:

```powershell
git branch --show-current
git status --short
```

For focused feature branches, use clear names such as:

```text
story-worldmarks
visual-overhaul
npc-pathing
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

For gameplay changes, run `.\tools\run-playtest.mjs` unless the change is documentation-only or the user explicitly says not to.

For visual changes, run visual captures when feasible and inspect the output. If a visual issue is viewport-dependent, test at least one normal gameplay viewport and one dark/night case.

For save/story changes, verify:

- old saves with missing fields load;
- save/load round trips preserve new state;
- duplicate events do not duplicate rewards, NPCs, clues, or props.

Report honestly when tests were not run.
