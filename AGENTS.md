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

## Important Plans And Docs

- `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`: controlling mandatory specification for the NPC autonomy/pathfinding replacement. When executing this work, reread the current phase, global invariants, test protocol, and prohibited-shortcuts section before editing. Follow one phase branch/report/merge cycle at a time.
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
- Foragers should use hunger, personal inventory, and berry gathering as a first goal loop.
- NPCs should not wander aimlessly into walls.
- Pathing should account for terrain, obstacles, doors, town limits, and reachable work areas.
- Door behavior should open before crossing, clear collision while open, and close after NPC/player clearance.
- Door crossings should keep per-actor active ownership until the actor clears or is cancelled; route replacement must not silently drop an active portal reservation.
- `canFight` is combat capability only. Explicit guard-duty assignment decides who may stay outside at night.
- Porch, threshold, exterior wall edge, or roof locations do not count as inside.

When changing NPC pathing, add or update playtest coverage around:

- obstacle avoidance;
- doors opening/closing;
- avoiding buildings/windows/walls;
- returning home without teleporting through walls;
- forager target selection and inventory;
- hostile collision with buildings and fences.

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
