# Story Baseline

Phase 0 establishes the current post-visual, post-animation baseline before
story/worldmark implementation. This report was written from the live tree on
branch `story-worldmarks` after reading `AGENTS.md` and
`CODEX_STORY_IMPLEMENTATION_PLAN.md`.

## Git State

- Starting branch observed: `master` at `da3ab0d` (`Checkpoint visual overhaul work`).
- Existing `story-worldmarks` branch was present at `cf3bbef`.
- `story-worldmarks` was an ancestor of `master`, so it was switched to and
  fast-forwarded to `da3ab0d`.
- The working tree was clean before the branch switch. After the user-provided
  `AGENTS.md` appeared it was treated as project guidance and preserved.
- No gameplay, visual, animation, save, or test script behavior was changed by
  this phase.

## Functional Baseline

Command:

```powershell
$report = Join-Path (Get-Location) "artifacts\story\phase0-playtest-report.json"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $report) | Out-Null
Measure-Command { & .\tools\run-playtest.ps1 -ReportPath $report }
```

Result:

- Godot version: `4.6.1.stable.official.14d19694e`
- Renderer/features from `project.godot`: `Forward Plus`
- Playtest report: `artifacts/story/phase0-playtest-report.json`
- Result count: 144
- Failures: 0
- Runner progress elapsed: 5.500 seconds
- The command was interrupted at the Codex tool layer after the report was
  written; the orphaned Godot processes were stopped after confirming the
  report was complete.

The existing functional suite covers tutorial startup and rescue flow,
objectives, contracts, save/load, beacon raids, combat, NPC behavior, generated
environment visuals, generated character visuals, animated wildlife, static item
assets, terrain, weather, water, HUD, and player interactions.

## Current Architecture

The gameplay scene remains `res://scenes/Main.tscn`. The main script still uses
the deep inheritance chain documented in the plan and `AGENTS.md`:

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

Story work should not add another `Main*.gd` layer. The best integration point
is composed nodes created from `MainSetupScene.gd` or setup helpers, with thin
runtime hooks into discovery, inventory/crafting, tutorial completion,
interaction, and save snapshots.

`MainCore.gd` owns references to core composed systems:

- `inventory_system`, `crafting_system`, `objective_system`
- `structure_system`, `utility_system`, `equipment_system`
- `contract_system`, `survival_system`, `progression_system`
- `hostile_system`, `weather_system`, `tutorial_system`, `npc_system`
- `visual_asset_registry`, `static_item_asset_registry`,
  `animated_asset_registry`
- `hud`, `held_item`, and runtime world state such as discoveries, beacon
  charge, and sanctuary status

`setup_game_systems()` creates registries first, then gameplay systems, connects
signals, applies progression bonuses, grants starter inventory, and syncs
inventory totals. `setup_tutorial_system()` creates `TutorialSystem` as a child
node. `setup_hud()` creates `GameHud`, wires UI signals, and passes objectives,
contracts, equipment, inventory, and crafting into the HUD.

## Generated Asset Inventory

Blender generation scripts:

- `tools/blender/generate_environment_assets.py`
- `tools/blender/generate_character_assets.py`
- `tools/blender/generate_static_item_assets.py`
- `tools/blender/generate_animated_assets.py`
- `tools/blender/validate_generated_assets.py`

Regeneration commands:

```powershell
.\tools\blender\build-environment-assets.ps1
.\tools\blender\build-character-assets.ps1
.\tools\blender\build-static-item-assets.ps1
.\tools\blender\build-animated-assets.ps1
```

Generated environment assets:

- Manifest: `assets/visual/generated/visual-manifest.json`
- Generator: `phase5-environment-v1`
- Count: 26 GLBs
- Families: `broadleaf_tree` (6), `conifer_tree` (4), `savanna_tree` (3),
  `rock` (6), `bush` (4), `stump_log` (3)
- Runtime registry: `scripts/visual/VisualAssetRegistry.gd`
- Main APIs: `setup`, `select_tree_asset_id`, `select_rock_asset_id`,
  `instantiate_tree_visual`, `instantiate_rock_visual`, `instantiate_family`,
  `instantiate_asset`, `disable_asset_for_test`
- Fallback: tree and rock creation paths keep primitive fallbacks and preserve
  gameplay collision.

Generated character assets:

- Manifest: `assets/visual/generated/characters/character-manifest.json`
- Generator: `phase10-characters-v1`
- Count: 30 GLBs
- Families: `npc_torso`, `npc_head`, `npc_headwear`, `npc_arm`,
  `hostile_torso`, `hostile_head`, `hostile_eye`, `hostile_core`,
  `hostile_shard`
- Runtime registry: `scripts/visual/CharacterAssetRegistry.gd`
- Runtime factories: `NpcVisualFactory.gd`, `HostileVisualFactory.gd`
- Main APIs: `instantiate_family`, `instantiate_exact_or_family`,
  `apply_material_map`, `disable_all_for_test`
- Fallback: NPC and hostile visual factories build primitive bodies when
  generated character assets are unavailable.

Generated static item assets:

- Manifest: `assets/generated/static/static-item-manifest.json`
- Generator: `static-items-v2`
- Count: 45 GLBs
- Families: `tool`, `utility`, `equipment`
- Story-relevant item assets already include `wardLantern`, `surveyLens`,
  `sanctuaryBeacon`, `riftAnchor`, `nightBlade`, `wardArmor`, and `wardAmulet`.
- Runtime registry: `scripts/visual/StaticItemAssetRegistry.gd`
- Runtime factory: `ItemVisualFactory.gd`
- Main APIs: `asset_ids`, `family_ids`, `instantiate_item`,
  `validate_assets`
- Fallback: `ItemVisualFactory` calls `try_build_static_item` and falls back to
  procedural meshes for held and pickup items.

Generated animated assets:

- Manifest: `assets/generated/animated/animated-manifest.json`
- Generator: `animated-poc-v1`
- Runtime registry: `scripts/visual/AnimatedAssetRegistry.gd`
- Assets and expected state names:
  - `door_open_close` -> `door_open_close`
  - `chest_open_close` -> `chest_open_close`
  - `boar_idle_walk` -> `boar_idle_walk`
  - `deer_idle_walk` -> `deer_idle_walk`
  - `hare_idle_walk` -> `hare_idle_walk`
- Main APIs: `instantiate_asset`, `animation_names`,
  `expected_animation_name`, `find_animation_player`, `validate_animations`
- Runtime use: wildlife profiles in `MainInteractionFlow.gd` attach animated
  boar/deer/hare visuals when the registry can instantiate them; missing assets
  fall back to procedural wildlife visuals. Animated door/chest GLBs are
  available in the registry and preview scene, but there is not yet a general
  encounter animation controller.

Preview/validation scenes:

- `scenes/AnimatedAssetPreview.tscn`
- `scenes/StaticItemAssetPreview.tscn`

## Current Save Format

`SaveSystem.gd` uses `SAVE_VERSION := 1` and currently rejects saves whose
`version` is not exactly 1. Future optional story data should therefore be added
without bumping the version unless an explicit migration path and tests are
implemented.

`MainSaveState.gd.create_save_snapshot()` currently writes:

- `seed`
- `timeOfDay`
- `weather`
- `tutorial`
- `player`
- `inventory`
- `terrain`
- `removedProps`
- `survival`
- `progression`
- `equipment`
- `objectives`
- `contracts`
- `exploration`
- `deathCount`
- `respawnPoint`
- `beaconCharge`
- `beaconRaidStage`
- `sanctuaryEstablished`
- `blocks`

`apply_save_snapshot()` restores those fields additively where possible and
uses defaults when optional sections are absent. There is no `story` snapshot
field yet.

Exploration persistence stores discovered biome, town, shrine, mine, ruin, and
camp keys. Player block persistence includes utility storage/furnace state.

## Tutorial Completion Baseline

Tutorial state is owned by `TutorialSystem.gd`, with helpers:

- `TutorialSceneBuilder.gd`
- `TutorialRepairQuest.gd`
- `TutorialDialogueSystem.gd`
- `TutorialRescueSystem.gd`

The final tutorial rescue is complete when
`TutorialRescueSystem.complete_final_night()` sets:

- `final_night_active = false`
- `final_night_complete = true`
- completed steps `finalNightComplete` and `miraBlessing`
- message `Niko is safe inside the lanterns. Dawn can come now.`

`TutorialSystem.update_progress()` also marks `finalNightComplete` and
`readyForWilds` when their state predicates are true. `ObjectiveSystem.gd`
treats `tutorial_final_night` as complete when `finalNightComplete` is true and
makes `tutorial_ready` available after the final night is complete.

The post-intro stage starts after the first sleep and Mira morning briefing.
`TutorialDialogueSystem.gd` records `miraMorningBriefing`; current post-tutorial
handoff logic should hook after the final rescue is truly complete, not merely
after morning briefing or generic readiness.

## Rift And Beacon Progression

The existing late-game scaffold is separate from the planned Worldmark story:

- `MainCore.gd` tracks `beacon_charge`, `beacon_raid_stage`, and
  `sanctuary_established`.
- `MainSaveState.gd` persists those fields directly.
- `ObjectiveSystem.gd` includes `beacon`, `riftRaid`, `riftColossus`, and
  `riftAnchor` objectives.
- `ContractSystem.gd` includes `riftTrophy` and rift-anchor-style contract
  checks through objective state.
- `HostileSystem.gd` can spawn a `rift` variant as a beacon-raid boss and drops
  `riftCore` when defeated.

Story implementation must not delete or reinterpret these fields. Treat them as
legacy gameplay progression and add region-specific story state beside them.

## Discovery And Interaction Path

Discovery currently flows through `MainWorldEntities.gd`:

- `update_exploration_state(cell, biome)` records first biome and town
  discoveries.
- `discover_landmarks_near(position, radius)` scans generated structure
  candidates and calls `discover_landmark`.
- `discover_landmark(tier, key, position)` records mine, ruin, and camp keys,
  awards discovery XP, updates objectives/contracts, and may trigger an ambush.
- `discover_shrine_cache(block)` records shrine discovery, spawns guardians, and
  updates objectives/contracts.
- `objective_state()` combines inventory, discoveries, generated tier counts,
  hostiles, beacon state, tutorial state, equipment, survival, and structures.

Interaction currently flows through `MainRuntimeTools.gd` and
`MainInteractionFlow.gd`:

- `use_or_place()` attempts active consumables before block placement.
- `try_use_active_consumable()` consumes active food/tonic-style items through
  inventory APIs.
- `place_selected_block()` reads `inventory_system.active_stack()`, creates the
  block, consumes the active stack, calls tutorial block placement, awards place
  XP, and updates objectives/contracts.
- Crafting facts originate from `CraftingSystem.gd` via the `crafted` signal and
  `MainHudFlow._on_recipe_crafted`.
- Utility processing/trading originate in `UtilityBlockSystem.gd` and are wired
  through `MainHudFlow`.

Story facts should be emitted at these source operations, not from HUD polling.

## NPC, Hostile, Weather, HUD, And Test Runner Audit

NPC system:

- `NpcSystem.gd` is a composed `Node3D` with registered NPC entries and
  `npc_by_id`.
- Stable tutorial NPC IDs are `mira`, `rowan`, `niko`, and `sera`.
- Generic town NPCs come from structure home records.
- Metadata includes home/porch/guard cells, role, job, dialogue focus, job phase,
  inventory, combat ability, and scripted targets.
- Movement and jobs are delegated to `NpcPathing.gd`; combat is delegated to
  `NpcCombat.gd`; summary stats come from `NpcStats.gd`.

Hostile system:

- `HostileSystem.gd` owns ordinary enemy state and `HostileProjectileSystem.gd`.
- Variants include `shadow`, `frost`, `seer`, `skitter`, and `rift`.
- Spawn entry points include `spawn_near_player`, `spawn_tutorial_perimeter`,
  `spawn_beacon_raid`, `spawn_landmark_ambush`, and `spawn_shrine_guardians`.
- `seer` uses projectiles; `rift` acts as the current boss-style variant and
  drops `riftCore`.
- Story encounters should delegate ordinary minions/projectiles here while
  keeping Worldmark phase authority in a story encounter controller.

Weather system:

- `WeatherSystem.gd` owns clouds, stars, rain, snow, water influence, biome
  profiles, and snapshots.
- `force_weather(kind, intensity, cloud_cover, observer)` is available for
  controlled weather cases.
- `snapshot()` reports weather kind, cloud cover, intensity, water influence,
  precipitation flags, and presentation diagnostics.
- Future story weather influence should be removable and region-local rather
  than permanently forcing global weather.

HUD:

- `GameHud.gd` owns panels for inventory/crafting, utility blocks, objectives,
  contracts, dialogue, settings, playtest routes, teleport, mini-map/navigation,
  performance debug, sleep fade, and victory.
- UI construction is split into `GameHudLayoutBuilder.gd`,
  `GameHudPanelBuilder.gd`, `GameHudRenderer.gd`, and
  `GameHudOverlayController.gd`.
- HUD events are signal-driven and connected in `MainSetupScene.setup_hud()`.
- A future story tracker/journal should follow this builder/renderer pattern
  instead of adding ad hoc controls in gameplay scripts.

Existing runners:

- Functional suite: `scenes/Playtest.tscn` and `scripts/PlaytestRunner.gd`,
  launched by `tools/run-playtest.ps1`.
- Visual capture suite: `scenes/VisualCapture.tscn` and
  `scripts/visual/VisualCaptureRunner.gd`, launched by
  `tools/run-visual-captures.ps1`.
- Deterministic world signature suite: `scenes/WorldSignature.tscn` and
  `scripts/visual/WorldSignatureRunner.gd`, launched by
  `tools/run-world-signature.ps1`.
- Future story coverage should use a dedicated story runner with only a small
  smoke test added to `PlaytestRunner.gd`.

## Known Story Integration Risks

- `SaveSystem.gd` rejects non-version-1 saves, so adding story data should be
  optional under version 1 until a tested migration path exists.
- The main inheritance chain is already deep; story systems must remain
  composed nodes with narrow hooks.
- Discovery currently mutates objectives/contracts immediately; story event
  emission must be idempotent and must not duplicate XP, rewards, ambushes, or
  discovered keys.
- Base world generation uses deterministic caches and stable visual selection.
  Story placement must derive stable IDs without consuming or reordering terrain,
  town, prop, structure, loot, or spawn RNG.
- Tutorial completion has several related readiness flags. The story handoff
  should use the final rescue completion condition rather than earlier training
  milestones.
- The animated registry is available, but there is no reusable encounter
  animation controller yet. Worldmark encounters need safe fallbacks if an
  animation state is absent.
- Existing beacon/rift progression overlaps thematically with Worldmarks and
  must remain compatible instead of being silently replaced.
- `PlaytestRunner.gd` is already large; expanding story coverage there would
  make it harder to maintain.
- `artifacts/story/` is intended for local reports/captures in the story plan,
  but was not yet listed in `.gitignore` at this baseline.

## Exact Commands Used

```powershell
Get-Content -LiteralPath "C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot\CODEX_STORY_IMPLEMENTATION_PLAN.md"
rg -n "^# Phase|^## Phase|Phase 0|Codex prompt|Acceptance criteria|Use commit message" CODEX_STORY_IMPLEMENTATION_PLAN.md
git status --short --branch
rg --files
git branch --list story-worldmarks
Get-Content -LiteralPath tools\run-playtest.ps1
Get-Content -LiteralPath tools\run-visual-captures.ps1
Get-Content -LiteralPath tools\run-world-signature.ps1
git rev-parse HEAD
git rev-parse story-worldmarks
git log --oneline --decorate -5 --all
git merge-base --is-ancestor story-worldmarks HEAD
git switch story-worldmarks
git merge --ff-only master
rg --files -g "AGENTS.md" -g "agents.md" -g "Agents.md"
Get-Content -LiteralPath AGENTS.md
Get-Process | Where-Object { $_.ProcessName -like '*Godot*' }
$report = Join-Path (Get-Location) "artifacts\story\phase0-playtest-report.json"; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $report) | Out-Null; Measure-Command { & .\tools\run-playtest.ps1 -ReportPath $report }
Get-Content -LiteralPath playtest-progress.txt -Tail 40
Get-Content -LiteralPath artifacts\story\phase0-playtest-report.json
Get-Process | Where-Object { $_.ProcessName -like '*Godot*' -and $_.StartTime -gt (Get-Date).AddMinutes(-30) } | Stop-Process -Force
& "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" --version
rg -n "renderer|rendering|Forward|Compatibility|mobile|application/config/name|features|run/main_scene" project.godot
Get-Content -Raw -LiteralPath artifacts\story\phase0-playtest-report.json | ConvertFrom-Json
Get-ChildItem -LiteralPath scripts\visual -Filter *.gd
Get-Content -Raw -LiteralPath assets\generated\animated\animated-manifest.json
Get-Content -Raw -LiteralPath assets\generated\static\static-item-manifest.json | ConvertFrom-Json
Get-Content -Raw -LiteralPath assets\visual\generated\visual-manifest.json | ConvertFrom-Json
Get-Content -Raw -LiteralPath assets\visual\generated\characters\character-manifest.json | ConvertFrom-Json
rg -n "animated_asset_registry|AnimatedAssetRegistry|animation_names|expected_animation_name|find_animation_player|AnimationPlayer|play\(" scripts scenes assets docs tools
Get-Content -LiteralPath scripts\visual\AnimatedAssetRegistry.gd
Get-Content -LiteralPath docs\ANIMATED_ASSET_PIPELINE.md
rg -n "func (interact|try_|place|use|discover|update_beacon|spawn|raid|objective_state|update_objectives|on_|_on_|apply_|snapshot|restore)|BEACON|RIFT|SANCTUARY|beacon|rift|sanctuary|interactable|metadata|story" scripts\MainInteractionFlow.gd scripts\MainRuntimeTools.gd scripts\MainWorldEntities.gd scripts\MainGameLoop.gd scripts\MainDiscoveryFlow.gd
rg -n "^(extends|class_name|const|signal|var|func) |spawn_|defeat|variant|boss|rift|colossus|ambush|projectile|snapshot|restore|weather|force_weather|snapshot\(" scripts\HostileSystem.gd scripts\HostileRules.gd scripts\HostileProjectileSystem.gd scripts\WeatherSystem.gd
rg -n "^(extends|class_name|const|signal|var|func) |setup|register|stable|npc_id|dialogue|home|job|guard|path|combat|snapshot|restore|focus|move|forage" scripts\NpcSystem.gd scripts\NpcPathing.gd scripts\NpcCombat.gd scripts\NpcStats.gd scripts\NpcProfileRules.gd
rg -n "^(extends|class_name|const|signal|var|@onready|func) |objective|contract|dialogue|journal|hud|theme|set_|toggle|visible|inventory|message|target" scripts\GameHud.gd scripts\GameHudRenderer.gd scripts\GameHudPanelBuilder.gd scripts\GameHudLayoutBuilder.gd scripts\GameHudOverlayController.gd scripts\MainHudFlow.gd
rg -n "func test_|func run|add_result|assert|story|save|load|tutorial|animated|visual|wildlife|beacon|contract|objective|runner|report|results" scripts\PlaytestRunner.gd scripts\visual\VisualCaptureRunner.gd scripts\visual\WorldSignatureRunner.gd tools\run-playtest.ps1 tools\run-visual-captures.ps1 tools\run-world-signature.ps1
rg -n "func (state|snapshot|restore|update|is_complete|is_available|intro_followup_unlocked)|POST_INTRO|miraMorning|readyForWilds|finalNightComplete|tutorial" scripts\ObjectiveSystem.gd scripts\TutorialDialogueSystem.gd scripts\TutorialSystem.gd
rg -n "func (use_or_place|try_use_active_consumable|place_selected_block|interact|discover_shrine_cache|on_block_placed|_on_recipe_crafted|_on_utility_processed)|crafted|acquired|consume|add_item|remove_item|active_stack" scripts\MainRuntimeTools.gd scripts\MainInteractionFlow.gd scripts\CraftingSystem.gd scripts\InventorySystem.gd scripts\UtilityBlockSystem.gd scripts\MainHudFlow.gd
```
