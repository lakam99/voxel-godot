# Story First Arc Audit

Date: 2026-06-24

Scope: focused Gloam Hart first-arc playability and presentation audit from tutorial handoff through aftermath. This pass read `STORY_PHASE2_REPORT.md` through `STORY_PHASE14_REPORT.md`, inspected the current implementation, ran story tests, ran the functional playtest, and ran visual captures. No new Worldmarks or new campaign content were added. No gameplay changes were made.

## Exact Current Flow

1. Tutorial final rescue completion emits `tutorial_final_rescue_complete`.
2. `StoryQuestSystem` starts `story.gloam_hart.storm`, titled `The Storm That Stays`, and marks a deterministic affected Gloam Hart region. With the default test seed this is starter region `r:1,0`, affected region `r:2,-1`, dominant biome `forest`.
3. The active quest starts at `speak_with_mira`. Speaking to Mira advances to `speak_with_sera`.
4. Speaking to Sera advances to `travel_to_affected_region`.
5. Entering the affected region advances to `find_ordinary_clues`. Region entry is emitted from exploration-state movement, not HUD polling.
6. `StoryWorldOverlaySystem` spawns seven deterministic story sites only while the player is in the unresolved affected region: three ordinary clues, one historical clue, two boundary stones, and one encounter marker.
7. Direct interaction with ordinary clues emits `story_clue_found`. Any two ordinary clues advance to `prepare_countermeasure_placeholder`.
8. Direct interaction with the historical clue emits `story_clue_found` with historical kind, reveals the old compact truth in the journal, and unlocks the release route flag. This is optional.
9. Boundary stone interaction checks for `surveyLens`, `wardLantern`, and one `nightShard` charge. If the required items exist, the first valid boundary interaction emits `story_countermeasure_prepared`, then retuning consumes one `nightShard` and emits `story_boundary_stone_retuned`.
10. Retuning both boundary stones sets `stormWeakened`, unlocks the encounter, unlocks the combat route, and makes the release route available only if the historical clue was found.
11. Interacting with the encounter marker starts the Gloam Hart encounter once the encounter is unlocked.
12. The encounter uses a fallback procedural Gloam Hart visual with deterministic phase behavior. Player melee/ranged damage can progress phases and slay the Hart. Phase 2 can spawn story minions. The boundary countermeasure reduces storm pulse damage.
13. The slay route resolves when the Hart health reaches zero, writes durable `slay` resolution state, grants slay rewards, cleans up minions, completes the quest, and starts aftermath.
14. The release route exists in state and tests. `try_release_story_worldmark()` succeeds only in phase 3 when the historical clue and boundary requirements made `releaseRouteAvailable` true. Current normal player controls do not expose this action.
15. Active encounter save/load stores durable phase and entrance position only, then reconstructs the encounter and moves the player to a nearby recovery position on load.
16. After resolution, `RegionAftermathSystem` starts from durable Worldmark resolution state. At 0.5 in-game days the storm clears; at 1.0 day starter settlement recovery, trade, service, and cozy-scene flags unlock; at 2.0 days aftermath becomes complete.
17. Aftermath is surfaced through journal rows, settlement state, changed NPC dialogue, and live NPC activity metadata.

## Player-Facing Weak Points

- Release path is not reachable through normal controls. The route is correctly gated and test-covered, but the only caller found is `main.try_release_story_worldmark()` from tests/debug tools. There is no `KEY_*`, mouse interaction, HUD button, prompt, or encounter marker affordance that tells a player how to perform the release rite.
- The affected region is displayed as a region ID such as `r:2,-1`. Without a map marker, compass marker, or route hint, "Travel to the marked storm region" is not actually marked in a player-readable way.
- Story sites are interactable, but discovery is search-heavy. The player gets `CLUE`, `HISTORY`, `STONE`, and `HOLLOW` labels only when near enough to see fallback site objects; there is no regional search radius, count, minimap marker, or directional cue.
- Countermeasure requirements are clearest only after trying a boundary stone. The journal says "Prepare a countermeasure" or "Enough signs found to prepare a countermeasure", but does not explicitly list `Survey Lens`, `Ward Lantern`, and `Night Shard charge` before the player reaches a stone.
- The historical clue is optional but materially changes the available ending. The journal hides the truth correctly, but it does not strongly communicate "find the old compact if you want a nonlethal option" before the player enters the encounter.
- Boundary stones do not appear to have a distinct retuned visual state. The HUD message says one stone remains or both hold, but revisiting the region relies on memory and journal state rather than visible stone changes.
- Encounter readability is mostly state messages and fallback animation states. There is no boss health bar, phase banner, release-ready prompt, vulnerability prompt, or strong telegraph VFX beyond the procedural storm ring.
- Aftermath state exists, but much of it is abstract. Settlement tier, trade link, service, cozy scene, memorial, wildlife recovery, and distant Hart flags are durable, but the visible world does not yet clearly show most of those changes.

## Missing Visuals And Assets

- Dedicated Gloam Hart animated asset. Current encounter uses `GloamHartFallbackVisual`.
- Authored story-site assets for antler scars, broken lanterns, old compact records, boundary stones, and the storm hollow. Current sites are primitive fallback meshes plus text labels.
- Retuned boundary-stone state, such as color, particles, glow intensity, sound, or changed label.
- Region-level storm presentation beyond metadata and existing weather bias. The first arc would benefit from a recognizable fixed-storm look in the affected region.
- Encounter-specific VFX/audio for charge windup, sweep, storm pulse, stagger/vulnerable, release calm, and death.
- Aftermath visuals for public-space repair, forage path reopening, memorial/living compact marker, shared meal/cozy scene, and optional distant released Hart.
- Story-specific visual capture cases. The current visual suite captures general town/forest/water/HUD scenes, not Gloam Hart story states.

## Balance And Readability Concerns

- Item requirements may feel opaque. `surveyLens`, `wardLantern`, and two `nightShard` charges are mechanically valid, but the player needs clearer upstream guidance on where these come from and why they are required.
- Story-site spacing can be large because seven sites are spread across a region. This is mechanically deterministic and valid, but could become slow without navigation support.
- The release route currently requires reaching phase 3 and calling a hidden action. Even after a control binding is added, the player will need an explicit "release now" cue to avoid accidentally killing the Hart.
- Slay route is understandable because damage resolves it, but boss health and phase thresholds are invisible. A player may not understand why storm pulses or minions changed.
- Save/load recovery intentionally restores the active encounter at the saved phase start, not exact health or transient animation. This avoids brittle saves but may feel like lost progress if the player saved late within a phase.
- The journal is functional but dense. It lists dossier, clues, optional objective, resolution, aftermath, replay, preparation, region, and settlement in one scrolling list without tabs or priority grouping.

## Save/Load Risks

- Verified: old saves without story still load; story data remains optional; `SAVE_VERSION` stays at `1`.
- Verified: quest state, region records, story sites, historical clue, release flags, boundary retunes, active encounter recovery, resolution idempotency, and aftermath save/load are covered by story tests.
- Risk: passive story overlay and influence reappear from region-entry sync, while active encounter and aftermath have explicit recovery calls. A save/load made while standing in the affected investigation region should be manually checked to ensure story sites are visible immediately after load, not only after crossing a region boundary or forcing a movement update.
- Risk: active encounter recovery stores phase, not exact health, minions, animation time, or projectile state. That is stable but should be documented/player-tested as a deliberate checkpoint policy.
- Risk: aftermath flags persist cleanly, but several flags do not yet have visible world systems attached. A loaded post-aftermath save can be correct in state while still looking unchanged.

## Suggested Fixes In Small Phases

### Phase A: Release Affordance Bug

- Add a normal player-facing release input or interaction during active Gloam Hart phase 3 when `releaseRouteAvailable` is true.
- Show an encounter prompt such as "Release rite ready" only when the route is actually available.
- Add a deterministic story test that simulates the normal player input, not just `main.try_release_story_worldmark()`.
- Keep debug tools unchanged.

### Phase B: Navigation And Journal Clarity

- Replace raw affected region ID as the main travel hint with a compass/map waypoint or a directional journal line.
- Add journal rows for exact countermeasure requirements before boundary-stone interaction.
- Add a clearer optional-history line: "Old compact record: unlocks release route" while preserving hidden-truth filtering until discovered.
- Add found/remaining counts for ordinary clues and boundary stones.

### Phase C: Story Site Presentation

- Add distinct visuals for the three ordinary clue types, historical record, boundary stones, and storm hollow using existing asset systems or generated static assets.
- Add retuned boundary-stone visual state and metadata.
- Add simple audio/particle feedback for clue inspect and boundary retune.
- Add story-specific visual capture cases for clue, historical clue, boundary stone before/after, and storm hollow.

### Phase D: Encounter Readability

- Add boss health/phase presentation while the Gloam Hart encounter is active.
- Add visible windup/impact cues for charge, sweep, and storm pulse.
- Add a release-ready prompt and an explicit unavailable-release message if the player missed the historical clue.
- Add manual tuning passes for health, damage cadence, minion pressure, and ranged/melee readability.

### Phase E: Aftermath Presentation

- Add a return-to-town journal/status prompt after resolution.
- Tie settlement flags to visible props or NPC activities in town.
- Surface slay/release differences through a small memorial/living marker, changed work activity, and stronger dialogue rotation.
- Add visual capture cases for slay aftermath and release aftermath.

### Phase F: Save/Load And Regression Coverage

- Add a focused test for loading while standing in the affected investigation region and verifying overlays/influence are immediately visible.
- Add visual capture metadata checks for story-specific captures.
- Keep all story additions optional in save data and preserve `SAVE_VERSION == 1`.

## Manual Playtest Checklist

1. Complete the tutorial rescue normally and sleep through the post-rescue transition.
2. Confirm `L` opens the story journal and shows `The Storm That Stays`.
3. Speak to Mira and verify the journal stage changes to "Speak with Sera".
4. Speak to Sera and verify the journal stage changes to travel.
5. Navigate to the affected region without debug tools. Record whether the player can find it from current UI alone.
6. Enter the affected region and confirm weather/influence, story site spawning, prompts, and journal state.
7. Inspect two ordinary clues. Confirm dedupe by inspecting one clue twice.
8. Open the journal and verify ordinary clue labels and preparation status.
9. Inspect the historical old compact clue. Confirm hidden truth and release route information become visible.
10. Try a boundary stone without required items, then with missing `nightShard`, then with all requirements. Confirm messages are clear.
11. Retune both boundary stones and verify inventory cost, journal state, storm weakening, and any visible stone feedback.
12. Save and reload while still in the affected region before starting the encounter. Confirm sites and influence return immediately.
13. Interact with the storm hollow and start the encounter.
14. Fight through phase 2 and phase 3 using melee and ranged weapons. Check phase messages, damage readability, and minion pressure.
15. Save and reload during phase 2. Confirm recovery position, phase, and player safety.
16. Slay the Hart. Verify rewards, cleanup, journal resolution, NPC dialogue, and one-day aftermath.
17. Repeat from a pre-resolution save with historical clue found and release route available. Verify whether a normal player can perform release without debug tools.
18. After release, verify rewards, journal resolution, NPC dialogue, wildlife/trade flags, and two-day aftermath.
19. Load a post-slay save and a post-release save. Confirm resolution cannot duplicate rewards and aftermath state remains stable.
20. Capture screenshots of journal, clue, boundary, encounter, and aftermath states for presentation review.

## Verification

- Story suite: `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\first-arc-audit-story-playtest-report.json`
  - Passed: `true`
  - Results: `47`
  - Failures: `0`
- Functional suite: `.\tools\run-playtest.ps1 -ReportPath artifacts\story\first-arc-audit-playtest-report.json`
  - Passed: `true`
  - Results: `171`
  - Failures: `0`
- Visual captures:
  - Headless attempt failed because Godot dummy rendering could not read viewport textures.
  - Normal renderer command: `.\tools\run-visual-captures.ps1 -OutputDir artifacts\story\first-arc-audit-visual`
  - PNGs: `10`
  - Report: `artifacts\story\first-arc-audit-visual\visual-captures.json`
  - Non-blocking console issue: repeated pre-existing `NpcSystem.update_forager_goal` freed-instance errors during capture.

## Bottom Line

The first arc is structurally implemented and well covered by deterministic tests. The main gap is not state correctness; it is player-facing discoverability. The highest-priority fix is exposing the release route through normal controls and encounter prompts. After that, navigation, item-requirement clarity, story-site visuals, encounter telegraphs, and aftermath presentation should be improved in small passes without adding new Worldmarks or new campaign content.
