# Codex Story and Worldmark Implementation Plan — Voxel Biome World Godot

Historical phase reports are preserved in the [documentation repository](https://github.com/lakam99/voxel-godot-docs/tree/main/game-design/story/history). New story reports for resumed work belong under `game-design/story/reports/` in that repository.

This roadmap turns the existing tutorial, procedural world, NPCs, combat, objectives, settlements, generated Blender assets, and animation system into the first complete narrative arc, then generalizes that arc into a reusable Worldmark framework.

It is written for the uploaded project snapshot. The live repository has since received visual and animation work, so Codex must inspect the current tree before editing and treat the filenames below as integration landmarks rather than permission to overwrite newer systems.

Execute one phase at a time. Do not ask Codex to implement the whole roadmap in one run. That is how a deer boss becomes the legal owner of the save system.

---

# 1. How to use this plan

1. Put this file at the repository root as `docs/roadmaps/story-implementation.md`.
2. Begin every Codex session with:

   **“Read `docs/roadmaps/story-implementation.md`. Execute only Phase N. Stop after its report and commit.”**

3. Review the phase report, test output, and in-game result before authorizing the next phase.
4. Never let Codex silently combine a story phase with unrelated graphics, animation, combat, or architecture cleanup.
5. Keep the deterministic template-writing path working before any local LLM integration is attempted.

Every phase must end with:

- The existing functional playtest suite passing.
- The dedicated story playtest suite passing.
- Existing saves loading successfully.
- The same seed producing the same gameplay-relevant world generation.
- A short report covering changed files, save compatibility, tests, and manual verification.
- One focused Git commit.
- Codex stopping before the next phase.

---

# 2. Project-specific starting point

The uploaded snapshot contains the following useful foundations:

- Godot 4.6 using Forward+.
- A runtime-generated world driven by `Main.tscn` and a deep `Main*.gd` inheritance chain.
- `TutorialSystem.gd`, `TutorialDialogueSystem.gd`, `TutorialRepairQuest.gd`, and `TutorialRescueSystem.gd` already implement:
  - the stormy-night opening;
  - fence and lamp repair;
  - shelter and sleep;
  - survival, gathering, crafting, weapons, and NPC lessons;
  - a final rescue beyond the lantern perimeter.
- `MainWorldEntities.gd` already recognizes discoveries for biomes, towns, shrines, mines, ruins, and camps.
- `ObjectiveSystem.gd` already tracks broad progression milestones.
- `ContractSystem.gd` already tracks repeatable or generic town jobs.
- `NpcSystem.gd` already supports generated town residents, jobs, pathing, combat, and scripted movement.
- `HostileSystem.gd` already supports ordinary hostile variants, landmark ambushes, a rift-class boss, loot, and combat statistics.
- `WeatherSystem.gd` already supports forced weather and weather snapshots.
- `MainSaveState.gd` already centralizes runtime snapshots and restore logic.
- `SaveSystem.gd` currently accepts `SAVE_VERSION == 1` exactly.
- The current save snapshot includes tutorial, exploration, inventory, progression, equipment, objectives, contracts, terrain changes, blocks, beacon state, and other gameplay data.
- Existing item and progression vocabulary already includes useful story-compatible concepts such as:
  - `nightShard`;
  - `wardLantern`;
  - `surveyLens`;
  - `wardTonic`;
  - `sanctuaryBeacon`;
  - `riftAnchor`;
  - `riftCore`.
- `PlaytestRunner.gd` is already a large automated integration runner. Do not keep expanding it indefinitely; add a separate story runner and retain only a small story smoke test in the main suite.
- The current live project also has generated Blender assets and an animation system. Phase 0 must inventory their actual APIs, state names, manifests, and import paths before any encounter code is written.

The main gameplay script currently ends a deep inheritance chain:

```text
Main.gd
→ MainPropFactory.gd
→ MainChunkTerrain.gd
→ MainInteractionFlow.gd
→ MainPlaytestTools.gd
→ MainRuntimeTools.gd
→ MainDiscoveryFlow.gd
→ MainHudFlow.gd
→ MainWorldEntities.gd
→ MainCharacterState.gd
→ MainGameLoop.gd
→ MainSetupScene.gd
→ MainSaveState.gd
→ MainCore.gd
→ MainInterface.gd
```

Do not add another story layer to this inheritance chain. Story must be implemented through composed nodes and small integration hooks.

---

# 3. Canonical narrative brief

Codex must treat these as design constraints, not optional flavor:

## Core fantasy

> Venture into the unknown, understand what has claimed the land, and make civilization possible again.

## Tone

- Cozy but dangerous.
- Towns are warm, practical, and human.
- The wilderness is beautiful, lonely, mythic, and sometimes frightening.
- The game is not grimdark.
- Coziness must be represented through meals, repairs, letters, work, celebrations, returning wildlife, and ordinary town life—not merely by reducing the amount of blood.

## Player identity

- The player is not important because of prophecy, lineage, or a secret cosmic title.
- The player becomes important by doing useful work:
  - repairing;
  - building;
  - feeding people;
  - mapping routes;
  - learning the land;
  - protecting others;
  - resolving regional threats.
- Keep the player’s past lightly defined unless the user later chooses a specific background.

## Worldmarks

- A Worldmark is both a regional entity and the mark its presence leaves on the land.
- It must causally affect weather, ecology, enemies, landmarks, settlement behavior, resources, or travel.
- It is not merely a random boss waiting in a room.
- Every Worldmark must have:
  - a domain;
  - a condition;
  - a desire;
  - visible signs;
  - a public belief;
  - a hidden truth;
  - preparation requirements;
  - one or more resolution methods;
  - an aftermath.
- Not every Worldmark is evil.
- Some may be slain, healed, released, relocated, bound, or bargained with.

## Civilization and wilderness

- Civilization is fragile, but it is not automatically morally correct.
- The wilderness is dangerous, but it is not automatically evil or empty.
- Some regional conflicts must be caused or worsened by old settlements, old technology, broken agreements, or current human mistakes.
- The player builds safety through understanding and stewardship, not only through conquest.

## Procedural narrative

- Mechanics and canon facts are deterministic game data.
- Generated prose may decorate facts but may never invent mechanics, rewards, required items, NPC states, locations, or boss weaknesses.
- Once generated prose is accepted, it is cached in the save and must not mutate between sessions.
- The entire game must remain playable without an LLM.

---

# 4. First vertical slice

Implement one authored regional arc before building a general generator.

## Arc title

**The Storm That Stays**

## First Worldmark

**The Gloam Hart**  
**Worldmark of the Ringing Storm**

## Public belief

The Hart hates fire and is sending creatures to extinguish the frontier lanterns.

## Hidden truth

The oldest lantern network contains material taken from the Hart or from a shrine bound to it. Reactivating the network causes pain, disorients wildlife, and keeps the regional storm circling.

## Regional signs

At least three ordinary signs must be available:

1. Pale antler-shaped scars on trees.
2. Boundary stones that ring or vibrate during rain.
3. Broken lantern equipment pushed away from the forest rather than toward town.

One optional historical sign must reveal the nonlethal resolution:

4. A journal, shrine inscription, or abandoned survey record explaining the old compact and the lantern material.

## Arc flow

1. Complete the tutorial rescue and return inside the lantern perimeter.
2. Dawn arrives, but the storm remains fixed over a distant region.
3. Speak with Mira.
4. Speak with Sera.
5. Travel to the affected forest or taiga region.
6. Discover at least two of three ordinary clues.
7. Discover the optional historical clue to unlock the release resolution.
8. Prepare a countermeasure using existing crafting and ward systems where possible.
9. Retune or repair two boundary stones.
10. Enter the Worldmark encounter.
11. Slay the Hart or release it from the old network.
12. Return to the starter town.
13. Watch settlement and regional aftermath unfold over one or two in-game days.

## Resolution outcomes

### Slay

- Greater immediate town confidence and safety.
- A unique combat-oriented reward or recipe.
- Fewer hostile events.
- Wildlife returns more slowly or remains reduced.
- Some NPCs approve; others are unsettled.

### Release

- Wildlife and natural ambience return sooner.
- A nature, traversal, navigation, or stewardship-oriented reward.
- The Hart may appear harmlessly in the distance later.
- Some guards remain concerned.
- No trophy weapon equivalent.

Do not display a giant morality score. Communicate consequences through the world and NPC reactions.

---

# 5. Non-negotiable engineering rules

Codex must obey these throughout the roadmap:

1. **Preserve current visual and animation work.** Do not replace the generated-asset registry, Blender pipeline, animation controller, UI theme, or imported `.glb` files with parallel systems.
2. **Preserve deterministic world generation.** Story placement may derive new deterministic values from stable IDs, but it must not consume or reorder RNG used by terrain, towns, props, structures, loot, or gameplay spawns.
3. **Keep story as composition.** Do not add another `Main*.gd` inheritance layer.
4. **Keep gameplay authority outside prose.** Dialogue text must never determine a quest condition or combat rule.
5. **Keep objectives and contracts.** `ObjectiveSystem` remains broad progression; `ContractSystem` remains generic jobs. Story quests are separate.
6. **Add save data additively.** The first story implementation must work with existing version-1 saves by treating missing story data as empty/default.
7. **Do not bump `SAVE_VERSION` merely to add an optional `story` field.** Bump only after implementing and testing an explicit migration path.
8. **Make events idempotent.** Re-entering a region, reloading a save, or rediscovering a landmark must not duplicate clues, rewards, quests, NPCs, or story effects.
9. **Do not persist an unbounded event log.** Persist derived facts, counters, quest states, region records, and bounded dedupe keys. Keep only a small capped debug history.
10. **No permanent off-screen destruction.** Settlements may change only through visible events, explicit player choices, or reversible simulation states.
11. **Use authored fallbacks.** Missing animation, model, sound, generated text, or optional LLM service must not block progression.
12. **No automatic autosave exploit.** Save/load during encounters must not duplicate consumed items, rewards, enemies, or resolution choices.
13. **No unrelated cleanup.** Do not use a story phase to rewrite terrain, UI architecture, NPC pathfinding, or combat unless the phase explicitly requires a narrow hook.
14. **Test negative coordinates.** Region ID helpers must use floor division, not truncation toward zero.
15. **Do not delete or weaken tests to make a phase pass.** Update implementation-specific assertions only when the behavioral guarantee remains covered.
16. **Use JavaScript for any companion service.** If the optional local LLM uses HTTP or sockets, implement the service in JavaScript using RedWeb. Do not introduce Express, Fastify, Flask, or another server framework.

---

# 6. Intended story architecture

Create these folders gradually:

```text
docs/
  story/
resources/
  story/
    quests/
    worldmarks/
    settlements/
scenes/
  story/
  story_testing/
scripts/
  story/
    arcs/
    data/
    encounters/
    providers/
    testing/
tools/
  story/
  story-llm-server/      # optional, Phase 13 only
artifacts/
  story/                 # ignored local reports/captures
```

Primary systems:

```text
StoryEventBus
  Receives structured facts from gameplay systems and emits one signal.

StoryDirector
  Owns campaign state, region records, current story region, dedupe,
  provider selection, and coordination among story systems.

StoryQuestSystem
  Tracks story quest availability, activation, stage, completion,
  counters, optional objectives, and tracked quest.

RegionStoryGenerator
  Creates deterministic region records from the world seed and region ID.
  Generated records are persisted and never silently regenerated.

SettlementStateSystem
  Tracks settlement tier and consequence flags.

StoryWorldOverlaySystem
  Spawns deterministic story-specific props, clues, boundary stones,
  encounter entrances, and aftermath overlays without changing base terrain.

WorldmarkInfluenceSystem
  Applies and removes region-local weather, hostile, ambience, and visual
  influence while the player is inside affected regions.

NarrativeTextProvider
  Interface for authored templates and, later, the optional local LLM.

TemplateNarrativeTextProvider
  Mandatory deterministic fallback for every text request.

WorldmarkEncounterController
  Owns encounter activation, phase rules, countermeasures, resolution,
  save recovery, and coordination with the existing animation/combat systems.
```

Recommended setup:

- Add preloads or class references through the existing system-registration style.
- Add variables in the current shared state owner, likely `MainCore.gd` or its current equivalent.
- Instantiate story nodes from `MainSetupScene.gd` or the current setup coordinator.
- Ensure story systems exist before `try_load_world()`.
- Add only thin calls from existing scripts into `StoryEventBus` or `StoryDirector`.

---

# 7. Core data contracts

These contracts should be documented in `docs/game-design/story/data-contracts.md` and validated by code.

## Stable story region ID

Use the existing `TOWN_REGION_CELLS` grid initially.

```gdscript
var region_x := floori(float(cell.x) / float(TOWN_REGION_CELLS))
var region_z := floori(float(cell.y) / float(TOWN_REGION_CELLS))
var region_id := "r:%d,%d" % [region_x, region_z]
```

Do not use ordinary integer division for negative cells.

## Story event envelope

```gdscript
{
    "schemaVersion": 1,
    "type": "landmark_discovered",
    "subjectId": "ruin:12,-8",
    "regionId": "r:2,0",
    "dedupeKey": "discover:ruin:12,-8",
    "worldTime": 1842.5,
    "position": [12.0, 18.0, -8.0],
    "payload": {
        "landmarkType": "ruin"
    }
}
```

Rules:

- `type` is required.
- `subjectId` identifies the gameplay entity or fact.
- `regionId` is required for regional events when known.
- `dedupeKey` is required for one-time facts.
- Repeated events may omit `dedupeKey` and update counters instead.
- Events must contain facts, not prose.

## Region story record

```gdscript
{
    "schemaVersion": 1,
    "generationVersion": 1,
    "id": "r:2,0",
    "regionX": 2,
    "regionZ": 0,
    "seed": 9384234,
    "dominantBiome": "forest",
    "state": "rumored",
    "worldmark": {
        "id": "worldmark:r:2,0",
        "definitionId": "gloam_hart",
        "domain": "storm_and_light",
        "condition": "bound",
        "desire": "silence_the_old_lanterns",
        "publicBeliefId": "gloam_hart_public",
        "hiddenTruthId": "gloam_hart_truth",
        "foundClueIds": [],
        "preparationFlags": {},
        "encounterState": {},
        "resolution": ""
    },
    "settlement": {
        "tier": 0,
        "flags": {}
    },
    "generatedText": {}
}
```

## Story snapshot

```gdscript
{
    "schemaVersion": 1,
    "campaign": {},
    "regionRecords": {},
    "quests": {},
    "settlements": {},
    "processedDedupeKeys": [],
    "generatedText": {},
    "debugRecentEvents": []
}
```

## Settlement tiers

```text
0 — struggling
1 — secure
2 — growing
3 — connected
```

Example settlement flags:

```text
trade_route_open
smith_arrived
guard_patrol_active
bakery_open
festival_available
wildlife_returned
remembers_worldmark_resolution
```

## Quest state

```gdscript
{
    "id": "story.gloam_hart.signs",
    "status": "active",
    "stage": "find_clues",
    "tracked": true,
    "facts": {
        "ordinaryCluesFound": 1,
        "historyClueFound": false,
        "boundaryStonesRetuned": 0
    },
    "optionalObjectives": {
        "learn_old_compact": false
    }
}
```

---

# 8. Integration map for the current project

Codex must inspect current equivalents before editing. In the uploaded snapshot, the likely hooks are:

| Existing area | Story integration |
|---|---|
| `MainInterface.gd` | Add declarations only if required by the current inheritance/interface style. |
| `MainCore.gd` | Hold references to composed story systems. |
| `MainSetupScene.gd` | Instantiate and wire story systems before save loading. |
| `MainSaveState.gd` | Add optional story snapshot/reset/restore. |
| `SaveSystem.gd` | Keep version 1 for additive story data; add migration tests before future bumps. |
| `TutorialSystem.gd` | Emit one explicit tutorial-completed fact after the rescue arc is truly complete. |
| `TutorialDialogueSystem.gd` | Add the post-tutorial Mira handoff without putting the whole Worldmark arc here. |
| `MainWorldEntities.gd` | Emit discovery events at the point the discovery is first recorded. Do not rely on HUD polling. |
| `MainRuntimeTools.gd` | Add a narrow `story_interactable` hook before ordinary placement fallback. |
| `NpcSystem.gd` | Supply stable NPC IDs, town IDs, roles, and knowledge scopes. |
| `CraftingSystem.gd` / `InventorySystem.gd` | Emit crafted/acquired facts only at successful source operations. |
| `HostileSystem.gd` | Continue managing ordinary enemies and minions; delegate Worldmark phase logic to encounter controller. |
| `WeatherSystem.gd` | Add removable story influence rather than permanently forcing global weather. |
| `GameHud*` | Add story tracker/journal using the existing theme and control-reuse patterns. |
| Animation/asset registry | Use existing generated assets, animation state APIs, and fallbacks. Do not create a competing controller. |
| `PlaytestRunner.gd` | Add one story-system smoke test only. Put detailed tests in the dedicated story runner. |

---

# 9. Testing strategy

Add a dedicated story runner rather than turning the existing 5,000-line runner into the Library of Alexandria.

Recommended additions:

```text
scenes/story_testing/StoryPlaytest.tscn
scripts/story/testing/StoryPlaytestRunner.gd
tools/story/run-story-playtest.ps1
```

The dedicated runner should support pure-system tests and small integration tests.

Required coverage by the end of the vertical slice:

- Same seed and region produce identical region records.
- Negative coordinates map to correct region IDs.
- Different region IDs produce different stable records.
- Old saves without `story` load with valid defaults.
- Story save/load round trips exactly.
- Restore does not replay one-time rewards or events.
- Duplicate discovery events do not duplicate effects.
- Tutorial completion creates the first quest once.
- A completed-tutorial old save receives the handoff once after loading.
- The first Worldmark region is deterministic and reachable.
- Story clue placement avoids water, excessive slope, town interiors, and duplicate cells.
- Two ordinary clues advance the investigation.
- The optional history clue unlocks the release route.
- Without the optional clue, the release route is unavailable.
- Countermeasure crafting or activation advances only after successful gameplay operations.
- Boundary stones count once each.
- Both encounter resolutions complete correctly.
- Save/load during the encounter follows the documented recovery policy.
- Slay and release aftermaths produce different settlement and regional flags.
- Missing model or animation falls back without blocking the encounter.
- Missing local LLM falls back to deterministic authored text.
- Generated text never changes quest mechanics.

Each phase should add only the tests relevant to that phase.

---

# 10. Reusable Codex operating prompt

Paste this before every phase-specific prompt:

```text
Work only on the requested phase of docs/roadmaps/story-implementation.md.

Before editing:
1. Read the relevant current scripts completely.
2. Run git status and preserve all user work.
3. Run the existing functional playtest.
4. Run the story playtest if it exists.
5. Inspect the current generated asset and animation architecture whenever
   the phase touches presentation or encounters.

During editing:
- Preserve gameplay, save compatibility, deterministic generation,
  visual assets, and animation behavior outside the requested scope.
- Add story through composition, not another Main inheritance layer.
- Keep ObjectiveSystem and ContractSystem intact.
- Keep prose out of gameplay authority.
- Use stable IDs and idempotent events.
- Reuse existing systems before adding parallel ones.

After editing:
1. Run the existing functional playtest.
2. Run the dedicated story playtest.
3. Run any phase-specific manual scenario.
4. Report changed files, tests, save compatibility, and known limitations.
5. Commit with the requested commit message.
6. Stop. Do not begin another phase.
```

---

# Phase 0 — Audit and protect the current post-visual, post-animation game

## Goal

Establish the real current baseline. The uploaded zip predates some visual and animation work, so this phase must discover the live architecture instead of assuming it.

## Codex prompt

```text
Execute Phase 0 only.

Do not change gameplay or story content.

1. Run git status and preserve every existing file.
2. Checkpoint the current work if it is not already safely committed.
3. Create a branch named story-worldmarks from the current state.
4. Run the full existing functional playtest and record:
   - result count;
   - failures;
   - elapsed time;
   - Godot version;
   - renderer.
5. Inventory the current visual and animation implementation:
   - generated Blender scripts;
   - generated GLB paths;
   - asset registry classes;
   - animation controller classes;
   - animation state names;
   - fallback behavior;
   - regeneration commands.
6. Audit the current versions of:
   - TutorialSystem and related tutorial scripts;
   - MainWorldEntities;
   - ObjectiveSystem;
   - ContractSystem;
   - NpcSystem;
   - HostileSystem;
   - WeatherSystem;
   - MainSaveState;
   - SaveSystem;
   - HUD scripts;
   - existing test runners.
7. Create https://github.com/lakam99/voxel-godot-docs/blob/main/game-design/story/history/story-baseline.md describing:
   - current architecture;
   - current save format;
   - current tutorial completion condition;
   - current rift/beacon progression;
   - current interaction path;
   - current animation integration points;
   - known risks for story integration;
   - exact commands used.
8. Commit only documentation or checkpoint changes.
9. Use commit message:
   Checkpoint game before story implementation
10. Stop.

Do not reset, clean, rebase, discard, or rewrite existing visual or
animation work.
```

## Acceptance criteria

- Current work is protected in Git.
- Baseline tests are recorded.
- Animation and generated-asset APIs are documented.
- No gameplay behavior changed.

---

# Phase 1 — Canon documentation and dedicated story test harness

## Goal

Turn the narrative brief into enforceable project documentation and establish an isolated test loop before adding runtime story state.

## Add

```text
docs/game-design/story/canon.md
docs/game-design/story/data-contracts.md
docs/game-design/story/first-worldmark-arc.md
scenes/story_testing/StoryPlaytest.tscn
scripts/story/testing/StoryPlaytestRunner.gd
tools/story/run-story-playtest.ps1
```

## Codex prompt

```text
Execute Phase 1 only.

Do not add runtime story progression yet.

1. Create docs/game-design/story/canon.md from the canonical narrative brief in
   this plan. Include explicit prohibitions against prophecy-driven player
   importance, wilderness-equals-evil framing, and prose controlling mechanics.
2. Create docs/game-design/story/data-contracts.md containing the event, region,
   quest, settlement, and save schemas from this plan.
3. Create docs/game-design/story/first-worldmark-arc.md defining The Storm That Stays and
   The Gloam Hart, including both resolutions and aftermaths.
4. Add a dedicated StoryPlaytest scene and runner.
5. Initially test only:
   - test runner bootstraps;
   - project scripts can be loaded;
   - current Main scene can be instantiated in story-test mode;
   - story artifacts directory can be written;
   - runner exits with correct success/failure code.
6. Add a PowerShell wrapper consistent with the existing playtest tooling.
7. Add artifacts/story/ to .gitignore while keeping selected docs committed.
8. Run both test suites.
9. Use commit message:
   Add story canon and test harness
10. Stop.
```

## Acceptance criteria

- The story runner can run independently.
- No production behavior changes.
- Canon and data contracts are explicit enough that later Codex sessions do not invent conflicting mechanics.

---

# Phase 2 — Story event bus, stable region IDs, and composed setup

## Goal

Create the minimal runtime skeleton without adding quest content.

## Add

```text
scripts/story/StoryEventBus.gd
scripts/story/StoryRegionId.gd
scripts/story/StoryDirector.gd
scripts/story/StoryDebugState.gd        # optional helper
```

## Required design

- `StoryEventBus` is a Node with one structured event signal.
- It validates required fields and normalizes event envelopes.
- It does not contain quest logic.
- `StoryRegionId` provides pure helpers for:
  - cell to region coordinates;
  - world position to region coordinates;
  - region coordinates to stable ID;
  - stable ID parsing;
  - region center cell.
- Use `TOWN_REGION_CELLS` initially.
- `StoryDirector` owns references and a capped recent-event debug buffer, but no authored arc yet.
- Story systems are instantiated before save loading.
- Add a debug-only F6 dump or equivalent current debug action that prints:
  - current story region;
  - recent story events;
  - director setup state.

## Codex prompt

```text
Execute Phase 2 only.

1. Add StoryEventBus, StoryRegionId, and a minimal StoryDirector.
2. Integrate them through composition in the current setup flow.
3. Do not add another Main inheritance layer.
4. Ensure story systems exist before try_load_world runs.
5. Implement and test floor-based region conversion for positive and negative
   world cells using TOWN_REGION_CELLS.
6. Implement event envelope validation and a capped debug event buffer.
7. Do not connect gameplay event sources yet except for one debug-only test
   event emitted by StoryPlaytestRunner.
8. Add debug state dumping without exposing it in normal release UI.
9. Add tests for:
   - positive and negative region mapping;
   - stable ID formatting/parsing;
   - malformed event rejection;
   - valid event delivery;
   - recent event buffer cap.
10. Run both suites.
11. Use commit message:
    Add story event and region foundation
12. Stop.
```

## Acceptance criteria

- Story foundation is present and inert during normal play.
- Negative region mapping is correct.
- No gameplay or save changes yet.

---

# Phase 3 — Deterministic region records and additive story persistence

## Goal

Generate stable regional story records and save them safely without changing gameplay.

## Add

```text
scripts/story/RegionStoryGenerator.gd
scripts/story/data/WorldmarkState.gd
scripts/story/data/RegionStoryRecord.gd    # use Resource or validated Dictionary wrapper
```

## Required design

- Region records derive from:
  - world seed;
  - region coordinates;
  - generation version.
- Use a dedicated story hash/RNG stream.
- Never consume terrain, town, structure, prop, hostile, or loot RNG.
- Determine a dominant biome from deterministic terrain samples, not from the current HUD string.
- Once a record is generated, save the full record.
- Do not silently regenerate an existing record after code changes.
- Add optional `story` data to `MainSaveState` snapshots.
- Keep `SAVE_VERSION == 1` during this additive phase.
- During restore, temporarily suppress event processing so reconstruction does not duplicate progression.

## Codex prompt

```text
Execute Phase 3 only.

1. Add deterministic RegionStoryGenerator and validated region/worldmark state
   representations.
2. Add StoryDirector.snapshot(), restore(), and reset().
3. Add an optional story field to MainSaveState snapshots.
4. Existing saves with no story field must load as empty/default story state.
5. Do not bump SaveSystem.SAVE_VERSION.
6. Suppress story event handling during restore and reconstruction.
7. Persist complete generated records once created.
8. Store generationVersion in every record.
9. Add tests for:
   - same seed + region ID = identical record;
   - different region IDs = different stable record;
   - story record round trip;
   - old save without story data;
   - reset clears runtime story state;
   - restore does not emit duplicate events;
   - no change to terrain/town deterministic signatures.
10. Run both suites.
11. Use commit message:
    Persist deterministic region story records
12. Stop.
```

## Acceptance criteria

- Old saves still load.
- Story data survives save/load exactly.
- Base world signatures remain unchanged.

---

# Phase 4 — Story quest state machine and real gameplay event sources

## Goal

Add story quest tracking and connect facts from existing systems without yet spawning Worldmark content.

## Add

```text
scripts/story/StoryQuestSystem.gd
scripts/story/data/StoryQuestState.gd
```

## Connect these events first

- `tutorial_completed`
- `biome_discovered`
- `town_discovered`
- `shrine_discovered`
- `mine_discovered`
- `ruin_discovered`
- `camp_discovered`
- `npc_spoken`

## Required rules

- Emit discovery events exactly where the corresponding discovery dictionary is first updated.
- Do not infer discovery from HUD refresh.
- Add an explicit tutorial completion signal/fact based on final rescue completion, not merely `readyForWilds`.
- For older completed-tutorial saves, synthesize the fact once after restore if needed.
- NPC events need stable IDs and town IDs.
- StoryQuestSystem tracks status, stage, facts, optional objectives, and tracked quest.
- Keep quest advancement explicit. Do not build a giant generic scripting language yet.

## Codex prompt

```text
Execute Phase 4 only.

1. Add StoryQuestSystem and serializable quest states.
2. Connect the initial gameplay events listed in the phase.
3. Add an explicit tutorial_completed fact after the rescue tutorial is truly
   complete.
4. Ensure a previously completed tutorial save emits or derives that fact once
   without replaying rewards.
5. Emit discoveries from their source operations, not HUD polling.
6. Emit npc_spoken only after a dialogue interaction actually succeeds.
7. Add dedupe handling in StoryDirector.
8. Do not add The Gloam Hart quest content yet.
9. Add tests for:
   - each event source;
   - duplicate discovery suppression;
   - tutorial completion exactly once;
   - old completed tutorial save handoff eligibility;
   - quest state snapshot/restore;
   - event processing independent of HUD refresh.
10. Run both suites.
11. Use commit message:
    Connect story quests to gameplay events
12. Stop.
```

## Acceptance criteria

- Gameplay facts reach story systems reliably.
- Existing objectives and contracts behave exactly as before.
- No authored Worldmark arc is active yet.

---

# Phase 5 — Author The Storm That Stays handoff and first-region selection

## Goal

Start the first real story arc immediately after the tutorial and select its deterministic region.

## Add

```text
scripts/story/arcs/GloamHartArc.gd
resources/story/worldmarks/gloam_hart.tres      # or current project’s preferred data format
resources/story/quests/gloam_hart_*.tres        # optional if Resource definitions fit current style
```

## First-region selection

- Start from tutorial region `(1, 0)` or derive it from the current tutorial system.
- Search deterministic rings outward.
- Prefer the nearest suitable region whose dominant biome is forest or taiga.
- Reject:
  - the tutorial region;
  - mostly ocean regions;
  - regions with no reachable dry sample area;
  - regions whose required story sites cannot be placed safely.
- Save the selected region ID in campaign state.
- Never reselect it after save/load.

## Quest chain

Use several short quests or chapters rather than one endless checklist:

```text
story.gloam_hart.storm
story.gloam_hart.signs
story.gloam_hart.network
story.gloam_hart.confrontation
story.gloam_hart.homecoming
```

At this phase, implement only the handoff and travel objective.

## Opening handoff

- After tutorial completion, the fixed storm remains visible or is described as circling the distant region.
- Mira gives the first lead.
- Sera gives practical testimony about lantern attacks.
- The quest asks the player to enter the affected region.

## Codex prompt

```text
Execute Phase 5 only.

1. Add the authored GloamHartArc controller and data definition.
2. On tutorial completion, make story.gloam_hart.storm available exactly once.
3. Add the post-tutorial dawn handoff:
   - the storm remains fixed over the selected region;
   - Mira introduces the mystery;
   - Sera provides the lantern-attack testimony.
4. Deterministically select and persist the nearest suitable forest or taiga
   story region outside the tutorial region.
5. Add only these stages:
   - speak with Mira;
   - speak with Sera;
   - enter the affected region.
6. Do not spawn clues, boundary stones, or the boss yet.
7. Preserve current tutorial dialogue and completion behavior before the final
   handoff.
8. Add a minimal tracked-story objective using the current HUD theme, but do not
   build the full journal yet.
9. Add tests for:
   - deterministic first-region selection;
   - suitable-biome selection;
   - old completed-tutorial save receiving the quest once;
   - Mira/Sera stages;
   - entering the correct region advances;
   - entering another region does not advance;
   - save/load at every stage.
10. Run both suites and manually play the tutorial handoff.
11. Use commit message:
    Begin The Storm That Stays arc
12. Stop.
```

## Acceptance criteria

- The tutorial leads naturally into the first story quest.
- The first region is deterministic and persisted.
- No Worldmark content exists outside the selected region.

---

# Phase 6 — Story world overlay, regional influence, and clue interactions

## Goal

Make the affected region visibly and mechanically distinct, then implement investigation.

## Add

```text
scripts/story/StoryWorldOverlaySystem.gd
scripts/story/WorldmarkInfluenceSystem.gd
scripts/story/data/StorySitePlacement.gd
scenes/story/StoryInteractable.tscn
```

## Story site placement

Deterministically place:

- three ordinary clue sites;
- one optional historical clue site;
- two boundary stones;
- one future encounter entrance or arena marker.

Placement constraints:

- Dry terrain above water margin.
- Acceptable local slope.
- Outside occupied town interiors and generated structure footprints.
- No duplicate or adjacent-overlap cells.
- Reachable from a reasonable nearby ground sample.
- Stable from seed and region record.
- Persist chosen cells in the region record.

## Regional influence

While the player is inside the affected region and the Worldmark is unresolved:

- request a removable rain/storm weather bias;
- add subtle ringing or storm ambience through the current audio system;
- alter local hostile composition or behavior through explicit modifiers;
- spawn story overlay props and signs;
- do not permanently change base biome generation.

When the player leaves, remove temporary influence cleanly.

## Interaction hook

Add a narrow interaction path before placement fallback:

```text
kind = story_interactable
storyInteractionId
storyRegionId
storyPrompt
```

Interacting emits structured facts and shows authored text. It does not directly modify quest state from UI code.

## Codex prompt

```text
Execute Phase 6 only.

1. Add StoryWorldOverlaySystem, WorldmarkInfluenceSystem, deterministic story
   site placement, and a reusable story interactable.
2. Place three ordinary clues, one optional history clue, two boundary stones,
   and one encounter marker in the selected region.
3. Store all selected site cells in the persisted region record.
4. Add a narrow story_interactable hook to the existing interaction flow before
   ordinary use/place fallback.
5. Implement clue discovery events and authored deterministic clue text.
6. Require any two ordinary clues to complete the investigation stage.
7. The optional history clue must set a separate fact but not be mandatory for
   reaching the encounter.
8. Apply removable regional storm/ambience/hostile influence only while the
   player is in the affected unresolved region.
9. Do not modify base terrain, biome, town, or prop RNG.
10. Add fallback primitive visuals only if the current asset registry has no
    suitable clue or stone asset.
11. Add tests for site validity, determinism, dedupe, region enter/exit cleanup,
    clue progression, optional clue state, and save/load.
12. Run both suites and manually visit all clue types.
13. Use commit message:
    Add Gloam Hart regional investigation
14. Stop.
```

## Acceptance criteria

- The region warns the player before any boss appears.
- Clues feel tied to the Hart’s cause and condition.
- Leaving the region cleans up temporary influence.

---

# Phase 7 — Story journal, Worldmark dossier, and NPC knowledge scopes

## Goal

Give the player a clear investigation interface and allow NPC reactions without turning every resident into an omniscient quest vending machine.

## Add

```text
scripts/story/StoryJournalModel.gd
scripts/story/StoryDialogueRouter.gd
scripts/story/data/NpcKnowledgeScope.gd
```

Extend the existing HUD/theme rather than creating unrelated controls.

## Journal contents

- Tracked story quest.
- Current stage.
- Optional objectives.
- Worldmark dossier.
- Found clues.
- Unknown entries shown as `???`.
- Known preparation.
- Affected settlement status.
- Resolution history after completion.

Do not overwrite the current `J` contracts binding without a deliberate UI decision. Prefer:

- a Story tab in the existing objectives/contracts interface; or
- an unused configurable key such as `L` if the current UI architecture makes tabs impractical.

## NPC knowledge

Every story dialogue request must include what the NPC is allowed to know:

```text
personal observations
public town rumor
found player-shared clues
role-specific knowledge
post-resolution memory
```

NPCs must not reveal hidden truth before the player discovers it.

## Codex prompt

```text
Execute Phase 7 only.

1. Add a themed story journal and Worldmark dossier using the existing HUD
   architecture and Theme.
2. Do not rebuild controls every frame.
3. Show unknown dossier entries as questions, not leaked facts.
4. Add StoryDialogueRouter and NPC knowledge scopes.
5. Extend generic NPC interaction only as narrowly as needed for story dialogue.
6. Give Mira, Sera, Rowan, Niko, and selected generated residents stage-aware
   reactions.
7. NPCs may disagree about the Hart, but they must not know the hidden truth
   before it is discovered.
8. Keep contracts and broad objectives available.
9. Add tests for journal state, hidden information, tracked quest behavior,
   knowledge filtering, dialogue fallback, and save/load.
10. Validate UI at 1280x720 and 1920x1080.
11. Run both suites.
12. Use commit message:
    Add story journal and NPC knowledge
13. Stop.
```

## Acceptance criteria

- Investigation progress is readable without exposing undiscovered facts.
- NPC dialogue reflects role and knowledge.
- Existing HUD functionality remains intact.

---

# Phase 8 — Preparation and boundary-stone countermeasure

## Goal

Make investigation lead to concrete preparation rather than immediately opening a boss door.

## Preferred reuse

Before adding new items, try to use the existing systems:

- `surveyLens` for reading or tuning old markers;
- `wardLantern` for stabilizing boundary stones;
- `nightShard`, glass, copper, or relic fragments for costs;
- anvil/workbench/shrine interactions for preparation.

Add a new item only if the current item architecture makes a distinct countermeasure substantially clearer. If added, it must receive:

- catalog definition;
- icon/visual fallback;
- recipe;
- held-item behavior if relevant;
- save and inventory tests;
- no disruption to existing recipes.

## Boundary stones

- Each stone can be retuned once.
- Retuning consumes or verifies the intended countermeasure through existing inventory APIs.
- It emits `boundary_stone_retuned` with a stable stone ID.
- Retuning both stones weakens the storm and unlocks the encounter.
- The history clue unlocks the nonlethal ritual path; ordinary preparation alone unlocks combat.

## Codex prompt

```text
Execute Phase 8 only.

1. Implement the preparation stage using existing surveyLens, wardLantern,
   nightShard, shrine, and crafting systems where practical.
2. Add a new countermeasure item only if reuse would produce confusing or
   brittle behavior; document the decision.
3. Add interaction and state for both boundary stones.
4. Each stone must count once and persist its state.
5. Retuning both stones must:
   - reduce regional storm intensity;
   - unlock the encounter stage;
   - preserve the optional history-clue flag separately.
6. Do not spawn the Worldmark encounter yet.
7. Emit successful crafting/acquisition/stone events from source operations,
   not from inventory polling or HUD refresh.
8. Add tests for costs, failed attempts, duplicate interactions, persistence,
   storm weakening, history-clue gating, and old saves.
9. Run both suites and manually complete preparation through normal gameplay.
10. Use commit message:
    Add Gloam Hart preparation and boundary stones
11. Stop.
```

## Acceptance criteria

- The player’s research changes what they build and how they prepare.
- Combat is available after mandatory preparation.
- Release remains locked unless the old compact is understood.

---

# Phase 9 — Gloam Hart animated encounter and two resolutions

## Goal

Implement the first complete Worldmark encounter using the current generated-asset and animation pipeline.

## Add

```text
scripts/story/encounters/WorldmarkEncounterController.gd
scripts/story/encounters/GloamHartEncounter.gd
scenes/story/GloamHartEncounter.tscn
```

Use current project conventions for generated Blender assets and animation state machines.

## Asset and animation requirements

- Audit the existing animation system first.
- Generate or extend a low-poly Gloam Hart asset through the existing Blender pipeline if no suitable asset exists.
- Reuse current palette and material conventions.
- Expected animation concepts, mapped to the current controller’s naming style:
  - idle/breathe;
  - walk or stalk;
  - charge windup;
  - charge recovery;
  - antler sweep;
  - storm pulse;
  - stagger/vulnerable;
  - death;
  - release/calm.
- Animation markers may signal damage windows, but gameplay must retain fallback timing.
- Missing animation must fall back to a safe state and never make the encounter unwinnable.

## Encounter phases

### Phase 1

- Readable charge windup and charge.
- Antler sweep.
- Recovery windows.

### Phase 2

- Storm pulse.
- Arena lights or ward objects are disrupted.
- Existing hostile types may be summoned as minions.
- The player’s countermeasure reduces pulse severity.

### Phase 3

At low health or a defined vulnerable threshold:

- Continue attacking to slay.
- If the historical clue was found and both stones were retuned, activate the ritual/shrine interaction to release.

## Save recovery policy

Do not save raw animation time or every projectile.

Document and implement this policy:

- If loaded during an active encounter, return the player to the encounter entrance or safe checkpoint.
- Reconstruct the encounter at the start of the last reached phase or restart it cleanly.
- Preserve consumed story preparation only if it was intended to remain consumed.
- Do not duplicate rewards, minions, or resolution state.
- Once resolved, the resolution is immutable for that save.

## Codex prompt

```text
Execute Phase 9 only.

1. Inspect and use the current generated Blender asset and animation systems.
2. Add WorldmarkEncounterController and GloamHartEncounter through composition.
3. Create or extend the Gloam Hart asset using the existing Blender generation
   pipeline if necessary. Do not create a parallel asset pipeline.
4. Implement the three encounter phases from the plan with readable telegraphs.
5. Use HostileSystem for ordinary minions/projectiles where appropriate, but
   keep Worldmark phase authority in the encounter controller.
6. Implement both slay and release resolutions.
7. Release is available only when the history clue and preparation conditions
   are satisfied.
8. Add safe animation fallbacks and gameplay-timed fallback damage windows.
9. Implement the documented encounter save-recovery policy.
10. Prevent reward, item, enemy, and resolution duplication.
11. Add tests for:
    - phase progression;
    - countermeasure effect;
    - animation fallback;
    - slay path;
    - release gated path;
    - release unavailable path;
    - save/load recovery;
    - reward idempotency;
    - cleanup after resolution.
12. Run both suites and manually complete both resolutions on separate saves.
13. Capture a short encounter report listing animation states actually used.
14. Use commit message:
    Add the Gloam Hart Worldmark encounter
15. Stop.
```

## Acceptance criteria

- The encounter is understandable from animation and environment cues.
- Both resolutions work and are mechanically distinct.
- Save/load cannot duplicate outcomes.

---

# Phase 10 — Region aftermath and settlement growth

## Goal

Make the resolution visibly matter beyond a reward popup.

## Add

```text
scripts/story/SettlementStateSystem.gd
scripts/story/RegionAftermathSystem.gd
resources/story/settlements/starter_town.tres   # or current data format
```

## Shared aftermath

Over one or two in-game days:

- the fixed storm clears;
- hostile pressure decreases;
- starter settlement moves from tier 0 to tier 1;
- new dialogue appears;
- one route or trade link opens;
- one service, resident, or work activity appears;
- the town records the chosen resolution;
- a small celebration, shared meal, repaired public space, or other cozy scene occurs.

## Slay-specific aftermath

- Combat reward or recipe.
- Guards and some residents show confidence.
- Wildlife recovery is slower.
- A trophy, memorial, or uneasy reminder may appear.

## Release-specific aftermath

- Wildlife returns more quickly.
- Navigation, gathering, nature, or traversal benefit.
- The Hart may later appear as a non-hostile distant encounter.
- Some guards express uncertainty.

## Existing beacon/rift compatibility

- Do not delete the existing `sanctuary_established`, beacon, rift, or victory progression during this phase.
- Add region-specific story state alongside it.
- Any eventual migration must happen in the generalization phase with compatibility tests.

## Codex prompt

```text
Execute Phase 10 only.

1. Add SettlementStateSystem and RegionAftermathSystem.
2. Implement starter settlement tiers beginning with 0=struggling and 1=secure.
3. Apply aftermath changes over one or two in-game days rather than replacing
   the region instantly.
4. Add shared changes and distinct slay/release consequences from the plan.
5. Add visible NPC work or migration so the player creates the conditions for
   recovery rather than personally placing every improvement.
6. Add one cozy aftermath scene or routine.
7. Preserve existing beacon/rift/sanctuary progression and old saves.
8. Ensure aftermath state is idempotent and reconstructs after load.
9. Add tests for both outcome flags, delayed changes, settlement tiers,
   dialogue memory, trade/service unlocks, wildlife flags, and save/load.
10. Run both suites and manually advance two in-game days after each outcome.
11. Use commit message:
    Add Worldmark aftermath and settlement recovery
12. Stop.
```

## Acceptance criteria

- The town and region visibly remember the player’s choice.
- Recovery feels communal.
- No settlement is destroyed off-screen.

---

# Phase 11 — Generalize Worldmarks without producing trait soup

## Goal

Extract a reusable Worldmark framework from the completed Gloam Hart arc.

## Add or formalize

```text
scripts/story/data/WorldmarkDefinition.gd
scripts/story/data/WorldmarkTraitCatalog.gd
scripts/story/WorldmarkGenerator.gd
scripts/story/WorldmarkCompatibilityRules.gd
```

## Concept-first generation

Generate in this order:

1. Archetype or conceptual core.
2. Domain.
3. Condition.
4. Desire.
5. Regional consequence.
6. Human history.
7. Public belief.
8. Hidden truth.
9. Compatible movement/attack/defense/minion traits.
10. Preparation and resolution families.
11. Aftermath possibilities.

Do not independently roll every mechanic column.

## Initial reusable modules

Movement:

```text
charge
flight
burrow
stalk
hover
```

Attack:

```text
sweep
projectile
pulse
summon
terrain_burst
```

Defense:

```text
armor
regeneration
mist
shield
burrow_escape
```

Condition:

```text
wounded
corrupted
trapped
starving
enraged
protecting
```

Resolution:

```text
slay
heal
release
relocate
bind
bargain
```

## Add two constrained prototypes

- A fungal or swamp Worldmark.
- A flying ember Worldmark.

These do not need the same content depth as the Hart yet, but each must have a coherent cause-and-effect chain and at least one non-identical resolution family.

## Regional state migration

- Begin replacing global story assumptions with region-specific records.
- Keep legacy beacon/rift fields as compatibility shims until old saves and existing progression have explicit migration coverage.

## Codex prompt

```text
Execute Phase 11 only.

1. Extract reusable definitions, traits, compatibility rules, and generation
   from the completed Gloam Hart implementation.
2. Preserve the Gloam Hart behavior exactly through regression tests.
3. Implement concept-first generation; do not independently randomize traits.
4. Add a fungal/swamp prototype and a flying ember prototype.
5. Give each prototype coherent domain, condition, desire, signs, preparation,
   resolution, and aftermath data.
6. Reuse modular encounter components only where behavior truly matches.
7. Begin region-specific replacement of global story state while preserving
   legacy beacon/rift save compatibility.
8. Do not add the LLM.
9. Add compatibility-matrix tests, generation determinism tests, incoherent
   combination rejection tests, and Gloam Hart regression tests.
10. Run both suites and manually inspect generated dossiers for several seeds.
11. Use commit message:
    Generalize the Worldmark framework
12. Stop.
```

## Acceptance criteria

- The Hart remains intact.
- New Worldmarks are coherent, not random bundles of mechanics.
- Region-specific state is the new direction without breaking legacy progress.

---

# Phase 12 — Add the authored campaign spine inside the endless world

## Goal

Give the endless frontier a finite emotional and thematic arc.

## Campaign structure

### Act I — Beyond the Lantern Line

- Tutorial.
- The Storm That Stays.
- First Worldmark resolution.
- Establish that Worldmarks shape regions and can be understood.

### Act II — The Far Roads

- Reconnect several settlements.
- Encounter Worldmarks with different relationships to their regions.
- Introduce recurring characters such as a trader, naturalist, builder, messenger, or storyteller.
- Reveal that the old frontier network and current instability are related.

### Act III — The Old Compact

- Discover how the previous civilization regulated or exploited Worldmarks.
- Learn why the system failed.
- Decide what principles the rebuilt frontier follows.
- Reach a campaign conclusion without stopping endless procedural generation.

## Implementation scope

- Add campaign state and anchor milestones.
- Define a finite set of authored anchor Worldmarks or revelations.
- Use procedural regions between those anchors.
- Do not require every generated region for campaign completion.
- After the conclusion, keep the endless frontier available.

## Codex prompt

```text
Execute Phase 12 only.

1. Add a finite campaign-state layer above regional Worldmark stories.
2. Implement the three-act structure from the plan as data and milestone logic.
3. Add recurring-character records and stable relationship/memory flags.
4. Define authored anchor revelations about the old frontier network and the
   Old Compact.
5. Do not reveal the player as chosen by prophecy or bloodline.
6. Ensure campaign completion does not disable endless world generation.
7. Keep regional stories playable before and after campaign completion.
8. Add tests for act progression, anchor selection, recurring-character state,
   campaign completion, and post-campaign endless play.
9. Run both suites.
10. Use commit message:
    Add the authored frontier campaign spine
11. Stop.
```

## Acceptance criteria

- The player has a long-term question and eventual answer.
- Endless generation no longer erases narrative momentum.
- The campaign can end while the world continues.

---

# Phase 13 — Optional offline LLM narrative provider

## Goal

Use a local model to phrase deterministic facts without giving it gameplay authority.

Do not begin this phase until the template provider can fully support the game.

## Provider architecture

```text
NarrativeTextProvider
  ├─ TemplateNarrativeTextProvider
  └─ LocalLlmNarrativeTextProvider
```

The local provider may generate:

- rumors;
- dialogue variants;
- Worldmark titles;
- journal prose;
- letters;
- aftermath reflections;
- settlement flavor text.

It may not generate:

- quest requirements;
- item costs;
- boss stats;
- weaknesses;
- rewards;
- NPC alive/dead state;
- new locations;
- canonical facts not supplied in input.

## Input contract

Provide only structured facts:

```text
region identity
Worldmark definition and condition
public facts
hidden facts allowed for this request
NPC identity and knowledge scope
current quest stage
player actions
resolution
required terminology
maximum text length
tone tags
```

## Output contract

- Strict JSON.
- Schema validated.
- Length limited.
- No unsupported proper nouns, objectives, rewards, or mechanics.
- Rejected output falls back to templates.
- Accepted output is cached in the save by stable request key.

## Companion service

If HTTP or sockets are used:

- implement the companion service in JavaScript;
- use RedWeb;
- read the current RedWeb documentation at `https://redweb.magnisolution.com/docs` before implementation;
- do not introduce another server framework;
- bind locally by default;
- make the service optional;
- use short timeouts and cancellation;
- never block combat, saving, or scene loading on prose generation.

## Codex prompt

```text
Execute Phase 13 only.

1. Confirm TemplateNarrativeTextProvider covers every current text request.
2. Add NarrativeTextProvider abstraction and LocalLlmNarrativeTextProvider.
3. If a local HTTP/socket companion is required, implement it in JavaScript
   with RedWeb after reading the current RedWeb docs.
4. Send only structured immutable facts and NPC knowledge scope.
5. Require strict JSON output and validate it.
6. Reject unsupported mechanics, rewards, states, locations, or proper nouns.
7. Cache accepted text by stable request key in story save data.
8. Use short timeout, cancellation, and deterministic template fallback.
9. Never generate during combat or other time-sensitive gameplay.
10. The game must launch and remain fully playable with the service absent.
11. Add tests for absent service, timeout, malformed JSON, schema failure,
    hidden-knowledge leakage, unsupported claims, cache stability, and fallback.
12. Run both suites with the service disabled and enabled.
13. Use commit message:
    Add optional local narrative text provider
14. Stop.
```

## Acceptance criteria

- The LLM changes wording only.
- Mechanics remain deterministic and testable.
- Saves retain accepted prose permanently.
- Missing service has no gameplay consequence.

---

# Phase 14 — Story polish, accessibility, authoring tools, and release gates

## Goal

Make the system maintainable and pleasant to play after the core architecture works.

## Add

- Story pacing checks.
- Text-speed and subtitle options.
- Journal font scaling and controller navigation.
- Color-independent clue indicators.
- Optional replay of discovered journals and letters.
- Debug tools for:
  - jump to quest stage;
  - reveal clue;
  - enter region;
  - start encounter;
  - choose resolution;
  - advance aftermath day;
  - dump region record;
  - clear generated prose cache.
- Authoring documentation for adding a Worldmark safely.
- Full save migration documentation.
- Performance and node-count budgets for regional overlays.

## Codex prompt

```text
Execute Phase 14 only.

1. Add story accessibility options consistent with the current settings UI.
2. Add debug-only authoring commands for quest stages, clues, encounters,
   resolutions, aftermath, and record dumps.
3. Create docs/game-design/story/adding-a-worldmark.md with a complete checklist.
4. Create docs/game-design/story/save-and-migration.md.
5. Add validation tooling that reports missing definitions, text keys,
   animation states, clue sites, incompatible traits, and fallback gaps.
6. Add performance instrumentation for story overlay nodes and encounter cost.
7. Run the full functional suite, story suite, visual captures, and both
   Gloam Hart resolution playthroughs.
8. Record final known limitations and deferred content.
9. Use commit message:
   Polish and document the story framework
10. Stop.
```

## Acceptance criteria

- Story systems are debuggable without editing saves by hand.
- The journal and dialogue are accessible.
- Adding another Worldmark follows a documented, validated process.

---

# 11. Completion definition for the first story milestone

Do not declare the first story milestone complete until all of the following are true:

- The entire tutorial still works.
- The final rescue transitions naturally into The Storm That Stays.
- The selected Worldmark region is deterministic and saved.
- The region visibly changes before the boss is known.
- The player can discover ordinary clues in any valid order.
- The optional clue changes available resolution options.
- Preparation uses real crafting, inventory, travel, and interaction systems.
- The Gloam Hart has readable animation telegraphs and safe fallbacks.
- Slay and release both work.
- Save/load works at every quest stage and during encounter recovery.
- The region and starter town visibly change afterward.
- NPCs remember the resolution.
- Existing objectives, contracts, beacon/rift progression, visual systems, and animation systems remain functional.
- No LLM is required.
- The same seed still produces the same gameplay-relevant base world.

---

# 12. First command to give Codex

```text
Read docs/roadmaps/story-implementation.md and execute Phase 0 only.
Preserve all current visual, Blender-generated asset, and animation work.
Stop after the baseline report and commit.
```
