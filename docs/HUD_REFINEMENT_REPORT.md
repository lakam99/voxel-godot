# HUD Refinement Report

## Scope

Focused HUD presentation pass for normal gameplay. Gameplay, inventory logic, input bindings, item behavior, world rendering, procedural generation, and save schema were preserved.

## Changed Files

Source:

- `scripts/GameHud.gd`
- `scripts/GameHudLayoutBuilder.gd`
- `scripts/GameHudOverlayController.gd`
- `scripts/GameHudPanelBuilder.gd`
- `scripts/GameHudRenderer.gd`
- `scripts/InventorySlotButton.gd`
- `scripts/MainCore.gd`
- `scripts/MainDiscoveryFlow.gd`
- `scripts/MainHudFlow.gd`
- `scripts/MainRuntimeTools.gd`
- `scripts/MainWorldEntities.gd`
- `scripts/PlaytestRunner.gd`
- `scripts/visual/HudStyleFactory.gd`
- `scripts/visual/VisualCaptureRunner.gd`

Artifacts:

- `artifacts/hud-refinement/playtest-report-direct.json`
- `artifacts/hud-refinement/playtest-report-final.json`
- `artifacts/hud-refinement/captures-1280x720/`
- `artifacts/hud-refinement/captures-1920x1080/`
- `artifacts/hud-refinement/captures-3440x1440/`
- `docs/HUD_REFINEMENT_REPORT.md`

## HUD Changes

- Removed the persistent normal-gameplay title from the status label; debug mode still shows title, seed, chunks, and coordinates.
- Added a compact location panel with biome, day/time, and weather.
- Replaced survival text rows with compact HP/ST/HN label-and-bar rows.
- Displayed armor as compact `SHD` value and danger state as a themed safety badge.
- Added a subtle central reticle.
- Removed the permanent `Active:` line and suppressed `Selected empty`.
- Added a brief selected-item label for non-empty slot changes.
- Moved XP/action/status messages into temporary notifications.
- Standardized themed hotbar slot content: shortcut top-left, icon centered, count bottom-right, durability strip support.
- Added HUD scale runtime setting from 80% through 140% in 20% steps.
- Extended the existing root Theme through new variations instead of unrelated per-control styling.

## Event And Prompt Hooks

- Selected-slot feedback now comes from inventory selection changes, not persistent HUD polling text.
- Action messages use `show_notification`.
- Interaction prompts are generated from the existing source focus path in `focused_interaction_prompt()`.
- Prompt capture verifies `[RMB] Open door` from a door ray hit within action reach. `[RMB]` is intentional to preserve the existing input binding.

## Save/Load Behavior

- `scripts/SaveSystem.gd` remains at `SAVE_VERSION := 1`.
- No save snapshot or load schema was changed for HUD scale.
- `hudScale` is runtime settings presentation only.
- `save_load_round_trip` passed: player, inventory, survival, progression, equipment, contracts, exploration, terrain, and block state all loaded.

## Screenshots

Each folder contains six PNGs plus per-case JSON and `visual-captures.json`:

- `artifacts/hud-refinement/captures-1280x720/`
- `artifacts/hud-refinement/captures-1920x1080/`
- `artifacts/hud-refinement/captures-3440x1440/`

Cases:

- `hud_daylight.png`
- `hud_night.png`
- `hud_combat.png`
- `hud_inventory_use.png`
- `hud_empty_hotbar.png`
- `hud_interaction.png`

Validated dimensions:

- 1280x720: 6 PNGs, 6 metadata files, interaction prompt `[RMB] Open door`, door ray within reach.
- 1920x1080: 6 PNGs, 6 metadata files, interaction prompt `[RMB] Open door`, door ray within reach.
- 3440x1440: 6 PNGs, 6 metadata files, interaction prompt `[RMB] Open door`, door ray within reach.

Visual inspection notes:

- 1280x720 readability is improved for status, vitals, XP, hotbar shortcuts, and prompt text.
- Empty-hotbar capture has inventory closed, no interaction prompt, and no `Selected empty` text.
- Inventory-use capture intentionally shows the inventory/crafting panel.
- Ultrawide capture keeps HUD anchors coherent and avoids overlap.

## Tests

Fresh final playtest:

- Command: `Godot_v4.6.1-stable_win64_console.exe --headless --fixed-fps 60 --path . --scene res://scenes/Playtest.tscn`
- Report: `artifacts/hud-refinement/playtest-report-final.json`
- Results: 167 passed, 0 failed.

Relevant passing checks:

- `hud_refinement_composition`: location/vitals/reticle/notifications present.
- `debug_readouts_gated`: normal status has no persistent game title; debug status still exposes title/seed/chunks/coords.
- `hotbar_reuses_slots`: existing themed hotbar slots are reused and selected frame remains intact.
- `inventory_*`: slot clicks, drag/drop, inventory panel behavior, and hotbar visibility passed.
- `hud_refresh_throttling`: messages use notification lane.
- `survival_food_and_hud`: bars update from survival state.
- `settings_runtime_controls`: `hudScale` reached 1.4.
- `save_load_round_trip`: save/load behavior preserved.
- `mining_tool_requirements`: action feedback goes through HUD notification.

Additional checks:

- `Godot_v4.6.1-stable_win64_console.exe --headless --path . --quit`: passed.
- `Godot_v4.6.1-stable_win64_console.exe --headless --path . --scene res://scenes/VisualCapture.tscn --quit`: passed.
- `git diff --check`: passed.
- Visual captures: 18 PNGs generated successfully with the Vulkan/Forward+ path.

## Performance

Playtest debug performance check:

- `performance_playtest_debug_hud`: frame `7.00`, hostiles `0.98`, HUD refresh keys `8`.

Capture metadata, daylight case:

- chunks `49`
- props `886`
- blocks `1219`
- physics bodies `2177`
- draw estimate `6007`

The HUD pass adds presentation controls and cached slot subcontrols. It does not change chunk generation, world rendering, item behavior, or save data.

## Risks And TODOs

- Visual captures must run non-headless on this Windows Godot build. Headless uses the dummy renderer and cannot read viewport textures.
- Capture runs intermittently print an existing `NpcSystem.update_forager_goal` freed-instance warning at `scripts/NpcSystem.gd:588`; final playtest passed and capture commands exited 0.
- Existing objective completion toasts still appear in screenshots because objective behavior was preserved.
