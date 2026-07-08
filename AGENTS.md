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
- Keep save changes additive unless an explicit migration is implemented and tested.
- Preserve deterministic world generation. Story or visual additions may derive stable IDs from the seed, but must not reorder terrain/town/prop RNG.
- Visual assets, Blender generators, generated GLBs, and registries are first-class project assets. Do not replace them with a parallel pipeline.
- Browser/Three.js work is historical context. New gameplay work should target this Godot project unless the user says otherwise.

## DO NOT FAKE GAMEPLAY TESTS

- Tests may use mocks only when they are explicitly named and reported as unit, contract, synthetic, static-audit, or service-level tests.
- A mocked, synthetic, direct-service, metadata-only, source-scan, direct-helper-call, or teleport-driven test MUST NOT be cited as acceptance evidence for live gameplay.
- NPC/pathfinding acceptance must run through the real game scene or a real headed gameplay fixture with real `CharacterBody3D` NPCs, real physics frames, real generated-world doors/buildings, real behavior scheduling, and real player/NPC interaction paths.
- NPC/pathfinding acceptance must not directly call tutorial progression handlers, `interact_with`, `on_door_opened`, `on_block_placed`, `sleep_at_bed`, `npc_system.move_npc`, `request_door_state`, `request_crossing`, or mark success through metadata such as `npc_inside_home`.
- Fixture setup may use narrowly documented placement helpers before the act phase, but the behavior being proven must proceed through live game systems.
- Door/home acceptance must prove the visible sequence: approach the door, open it before crossing, enter a strict interior location, clear the threshold, and close the door after clearance. Stats and metadata may support the claim, but they cannot be the only proof.
- New headed NPC acceptance runners must call `tools/npc/assert-npc-acceptance-runner-clean.ps1` before launching Godot.
- Every NPC/pathfinding acceptance claim must include the command, report path, screenshots or trace/timeline evidence when visual behavior matters, and a brief statement of what the test does and does not prove.

## Important Plans And Docs

- `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`: controlling mandatory specification for the NPC autonomy/pathfinding replacement. When executing this work, reread the current phase, global invariants, test protocol, and prohibited-shortcuts section before editing. Follow one phase branch/report/merge cycle at a time.
- `CODEX_MATURE_NAV_PLAN.md` and `NPC_PATHFINDING_REGRESSION_HANDOFF.md`: current context for the systemic NPC pathfinding regression. Use these before changing NPC routing, route readiness, collision, door traversal, forager behavior, or live NPC playtests.
- `Minecraft-Equivalent Terrain Migr.md`: terrain architecture migration context. The target is Minecraft-like terrain authority with smooth/non-blocky rendering, not a heightfield plus cave band-aids.
- `CODEX_PERFORMANCE_PLAN.md`: performance roadmap and prior performance constraints. Recheck when touching terrain, chunk streaming, structures, NPC/nav, autosave, or main menu/runtime loading.
- `CODEX_VISUAL_UPGRADE_PLAN.md`: visual polish roadmap.
- `CODEX_STORY_IMPLEMENTATION_PLAN.md`: story/worldmark roadmap. Follow one phase at a time.
- `docs/ANIMATED_ASSET_PIPELINE.md`: generated animated asset workflow.
- `docs/STORY_SUMMARY.md`: narrative brief for story manager context.
- `docs/VISUAL_*_REPORT.md`: prior visual work and verification notes.

When executing story work, reread `CODEX_STORY_IMPLEMENTATION_PLAN.md` and follow the requested phase only. Phase reports and commits are part of the expected workflow.

## Test Commands

Use the bundled Godot console executable paths already encoded in the tool scripts.

Functional playtest:

```powershell
.\tools\run-playtest.ps1
```

NPC pathfinding replacement harness:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
.\tools\run-all-test-runners.ps1
```

Phase 13 focused NPC release checks:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-traffic-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Transition
.\tools\npc\run-npc-observation-tests.ps1 -TimeMode Both
.\tools\run-npc-navigation-tests.ps1
```

Live NPC and runtime regression runners:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1
.\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1
.\tools\npc\run-npc-go-home-visual-playtest.ps1
.\tools\run-normal-runtime-performance-pass.ps1
.\tools\run-runtime-performance-observation.ps1
```

Terrain, underground, and digging visual runners:

```powershell
.\tools\run-underground-visual-playtest.ps1
.\tools\run-underground-interactive-playtest.ps1
.\tools\run-digging-visual-playtest.ps1
.\tools\run-town-ground-visual-playtest.ps1
.\tools\run-light-shadow-visual-playtest.ps1
```

Visual captures:

```powershell
.\tools\run-visual-captures.ps1
```

World signature:

```powershell
.\tools\run-world-signature.ps1
```

Useful generated asset commands:

```powershell
.\tools\blender\build-environment-assets.ps1
.\tools\blender\build-character-assets.ps1
.\tools\blender\build-animated-assets.ps1
.\tools\blender\build-static-item-assets.ps1
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

For the NPC autonomy/pathfinding replacement, `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md` supersedes older NPC pathing plans. Phase work must keep the phase branch and merged `master` green and must tie every acceptance claim to a command, report, trace, capture, static audit, or commit.

Recent context: NPC failures are systemic pathfinding failures unless proven otherwise. Do not patch Niko, Mira, Rowan, or any named NPC in isolation when the symptom is an actor stopping outside a door, on a porch, at a wall, or beside a fence. Fix the shared route contract.

Current ownership:

- `scripts/NpcSystem.gd` is the gameplay integration, spawn/registry, save-facing, and public stats adapter. Do not move new route search, direct movement loops, or door authority back into it.
- `scripts/NpcPathing.gd` is a thin facade over `scripts/npc_ai/routing/NpcNavigationCoordinator.gd` for existing callers.
- `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd` owns generated-world navigation topology snapshots and consumes navigation events.
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
- Production NPC movement must not rely on generated-cell bridges, doctored vectors, teleporting, hand-authored offsets, or direct movement loops that bypass collision. Such paths may remain only in clearly labeled diagnostics or synthetic tests.
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

Commit only when the user asks or when a plan phase requires it. Commit messages should describe the behavior, not just files changed.

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

For gameplay changes, run `.\tools\run-playtest.ps1` unless the change is documentation-only or the user explicitly says not to.

For visual changes, run visual captures when feasible and inspect the output. If a visual issue is viewport-dependent, test at least one normal gameplay viewport and one dark/night case.

For save/story changes, verify:

- old saves with missing fields load;
- save/load round trips preserve new state;
- duplicate events do not duplicate rewards, NPCs, clues, or props.

Report honestly when tests were not run.
