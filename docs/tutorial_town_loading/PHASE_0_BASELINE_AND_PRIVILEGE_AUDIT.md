# Phase 0 Baseline And Privilege Audit

## Objective

Freeze the real post-knock behavior before production changes, distinguish command latency from route latency, and inventory tutorial-specific NPC privileges.

## Scope And Branch

- Branch: `codex/vox-70-tutorial-npc-baseline`
- Production baseline under test: `d8760656e97c94ef41e572522414bcd12ea902b2`
- Linear: `VOX-70`
- Production gameplay changes: none
- Passive test change: bounded real-boot timing, order, route, movement, and door observations
- Phase commit: the commit containing this report; exact hash is recorded in Linear after commit

## Real-Boot Evidence

Command:

```powershell
.\tools\npc\run-actual-gameplay-mira-porch-regression.ps1 `
  -RealBoot `
  -ReportPath '.\artifacts\npc\reports\vox70-phase0-real-boot.json' `
  -ProgressPath '.\artifacts\npc\progress\vox70-phase0-real-boot.txt' `
  -ScreenshotDir '.\artifacts\npc\screenshots\vox70-phase0-real-boot' `
  -TimeoutSeconds 480 `
  -StaleProgressSeconds 90
```

Run facts:

- Seed: `atlas-16449406`
- Launch: project main scene, existing `MainMenu.tscn`, visible New Game button input
- `VOXEL_PLAYTEST`: unset
- `VOXEL_TEST_SEED`: unset
- `VOXEL_SAVE_PATH_OVERRIDE`: unset
- Player automation: disabled
- Direct NPC APIs, teleports, tutorial staging, and route injection: absent
- Acceptance cleanliness guard: passed, 13 rules, 0 matches
- Runtime script scan: passed, 0 matches
- Runner result: passed eventual return-home acceptance

The eventual pass does not make the latency acceptable. The timeline reproduced a long stationary period after a valid command and route request.

## Timeline

| Event | Run time | Delta from acknowledgement | Evidence |
| --- | ---: | ---: | --- |
| New Game click | 0.100s | - | Real menu button input |
| Startup loading complete | 10.383s | - | `startup_loading_active=false` |
| Player door interaction | 12.317s | - | In-reach first-person raycast and RMB input |
| Dialogue acknowledgement | 13.183s | 0.000s | Visible Close button input; tutorial state acknowledged |
| Go-home command first observed | 13.200s | 0.017s | `mira:go_home:1`, `ACTIVE`, route stack enabled |
| Route request first observed | 13.200s | 0.017s | `mira:v2:1:5`, `pending_budget`, `search_budget_deferred` |
| First nontrivial displacement | 34.967s | 21.784s | 0.163m from acknowledgement position |
| Player porch cleared | 36.617s | 23.434s | More than 4.05m away for 30 settled frames |
| Mira home door opened | 64.750s | 51.567s | Generated home door state changed open |
| Mira home door closed | 66.233s | 53.050s | Same door observed closed after opening |
| Strict home arrival | 66.600s | 53.417s | Real body inside strict generated interior for 30 frames |

Route state transitions:

```text
13.200s  pending_budget / search_budget_deferred
34.900s  probing / collision_probe_budget
35.000s  moving / lease_executor_started
64.800s  moving with home-door portal ownership
66.200s  arrived / home_interior_reached
```

The authority accumulated 2,656 `pending_budget` frames. Mira was stationary at the player porch while a valid generic order and request existed. This run is a route-service delay, not a missing-command delay.

## Home Records At Acknowledgement

`homeRefreshAtAcknowledgement` reported:

- `ok=true`
- `reason=refreshed`
- `requiredGenerated=true`
- `generatedRecordCount=4`
- `updated=6`
- town key `280,0`
- Mira home, porch, door, landing, strict interior bounds, and route cells present

This proves the current run did not take the source-level early return for missing generated records. That early-return hazard still exists and remains in scope for the loading/manifest phases.

## Screenshot Review

- `menu_before_new_game.png`: real title menu with New Game and Continue; the runner attached to the project boot rather than launching a staged gameplay scene.
- `player_pov_intro_dialogue_open.png`: live Mira dialogue and visible Close button after the player approached and clicked the generated starter door.
- `player_pov_dialogue_acknowledged.png`: dialogue closed and objective completion visible; Mira remains at the player threshold. The downward player camera makes only the upper-edge actor silhouette visible, so the timeline is stronger evidence for the stationary interval.
- `observer_mira_post_knock_final_state.png`: Mira is visibly inside the generated home with the double door closed. This agrees with strict-interior and door-state telemetry.

## Privilege Inventory

| Owner / symbol | Current use | Classification | Required disposition |
| --- | --- | --- | --- |
| `TutorialSceneBuilder`: named actor specifications | Names, roles, dialogue, colors, generated-home slot selection | Presentation and quest/story data | Keep as scenario data |
| `TutorialDialogueSystem`: named actor branches | Dialogue and tutorial objective progression | Quest/story state | Keep out of generic movement code |
| `TutorialSceneBuilder`: `tutorial=true` | Identity copied into every tutorial NPC profile | Presentation identity that currently unlocks behavior privilege | Retain only if needed for UI/story; remove generic AI branching |
| `NpcScheduleService`: tutorial role/profile selection | Replaces ordinary role schedule when `entry.tutorial` is true | Prohibited movement privilege | Use ordinary role/job/schedule data |
| `HierarchicalRoutePlanner`: tutorial foreground branch | Raises planning class from tutorial identity | Prohibited route-budget privilege | Remove identity branch; use generic order priority/service policy |
| `GeneratedWorldNavigationAdapter`: tutorial starter bounds | Reads `TutorialSystem` and infers starter private interior bounds | Prohibited navigation privilege and guessed geometry | Consume validated structure/manifest topology |
| `NpcSystem`: tutorial-town spawn exclusion | Calls `TutorialSystem` to skip ordinary generated-town NPC spawn | Startup ownership privilege | Replace with manifest-owned registration/deduplication |
| `NpcSystem`: `npc_tutorial` metadata | Publishes tutorial identity on the body | Presentation data carrier | Remove if no presentation consumer remains |
| `NpcRouteMovementController`: collider kind `tutorial_npc` | Treats tutorial actor bodies as dynamic actor obstacles | Generic collision compatibility | Register actors under the ordinary `npc` kind |
| `NpcTaskPlanner`: `tutorial_action` position | Hard-coded semantic target branch, currently only exercised by tests | Generic capability with tutorial naming | Replace with generic story/smart-object action before production use |
| `requiredVisibleScripted` profile/body metadata | Permanently pins all tutorial NPCs against simulation demotion | Prohibited identity-derived simulation privilege | Use bounded generic visible-sequence/order ownership only when active |
| `NpcSimulationLodService`: visible scripted check | Honors generic visible sequence plus tutorial-derived permanent flag | Generic capability contaminated by tutorial privilege | Keep generic pin; remove permanent tutorial default |
| `holdIntroDoor` profile/entry | Holds Mira outside and changes arrival semantics | Prohibited movement privilege | Replace with ordinary `order_wait` owned by tutorial orchestration |
| `NpcPerceptionService`: `holdIntroDoor` | Reports actor held by script | Prohibited movement privilege | Observe generic active wait/suspension order |
| `NpcSystem.npc_is_held_by_intro_or_dialogue` | Reads tutorial state directly and conditionally clears intro hold | Prohibited tutorial orchestration in generic AI | Remove after generic order migration |
| `NpcSystem.clear_intro_hold_for_entry` | Clears route, door, traffic, and hold metadata | Prohibited combined movement repair | Delete; normal order replacement owns cancellation |
| `NpcSystem` exact-arrival check using `holdIntroDoor` | Alters route arrival contract for intro actor | Prohibited movement privilege | Use ordinary order arrival contract |
| `npc_hold_intro_door` metadata | Legacy clear-only intro movement state in `NpcSystem`/`TutorialSystem` | Prohibited movement privilege | Remove with intro hold migration |
| `release_intro_hold_and_order_home` | Combined tutorial release, route reset, and go-home command | Prohibited tutorial-specific generic API | Delete; tutorial calls ordinary `order_go_home` |
| `npc_force_hold` | Generic update loop suppresses movement based on ad hoc body metadata | Prohibited movement privilege | Replace rescue choreography with generic wait/suspension/order ownership |
| `npc_rescue_stranded` | Marks Niko's rescue story condition; generic AI does not interpret it | Quest/story state | May remain as story state, but must not imply movement control |
| Named IDs in `NpcSystem` and `scripts/npc_ai/` | Exact-word audit for Mira, Niko, Rowan, Sera, Toma, and Lyra returned no matches | Compliant | Preserve this boundary |

Test-only observations and contract fixtures that read these fields are evidence consumers, not production privileges. They must be updated when each production privilege is removed; they must not preserve obsolete behavior.

## Phase 8 Resolution

Phase 8 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` closed every prohibited production item in the inventory above:

- tutorial actor profiles no longer contain `tutorial`, and ordinary bodies use `kind=npc`;
- story presentation uses `story_actor_scope=tutorial` only in the tutorial/dialogue layer;
- generic scheduling, routing, navigation, collision, home settlement, and simulation LOD do not read tutorial identity;
- the starter shelter is published through `StructureSystem.register_private_interior()` instead of inferred by generic navigation from tutorial state or nearby blocks;
- tutorial-town population ownership uses the generic `claim_town_population()` startup contract instead of a tutorial-town exception;
- the resource-backed smart-object task is now `complete_scripted_world_action` / `scripted_action`;
- rescue travel and return use generic `order_go_to` / `order_go_home`; the unused rescue teleport fallback was deleted;
- the porch/home fallback helper and partial-inside compatibility path were deleted; only strict interior semantics can set `insideHome`;
- the static Phase 8 audit recursively scans `NpcSystem.gd` and `scripts/npc_ai/` for named actors, tutorial movement metadata, guessed starter bounds, combined intro APIs, and obsolete home fallback symbols.

The original table remains as the historical baseline; this resolution section records its final production disposition.

## Contract Decisions

1. Complete generated records must be a startup invariant. Dialogue must not generate or refresh home records.
2. The tutorial must replace a generic wait order with one generic go-home order.
3. Accepted command latency and route-service latency are separate contracts.
4. The current route delay must not be hidden by tutorial priority, direct movement, collision bypass, or named retries.
5. If the route delay persists after privilege removal, it must be repaired as a shared route-authority issue with profiler evidence.

## Verification

| Command | Result |
| --- | --- |
| `.\tools\run-project-compile-smoke.ps1` | Passed |
| `assert-npc-acceptance-runner-clean.ps1` for the real runner | Passed, 0 forbidden matches |
| Real-boot command above | Passed eventual acceptance; reproduced 21.77s stationary route-budget delay |
| Manual report/timeline inspection | Passed Phase 0 diagnosis gate |
| Manual screenshot inspection | Real menu/input flow and final strict interior/closed door confirmed |

## Residual Risks

- The current eventual-return acceptance passes despite a user-visible 21.77-second post-command stall. Later acceptance needs an explicit mature latency bound.
- The source-level missing-record early return remains possible even though this seed had complete records.
- Route authority's `pending_budget` duration is now proven but not profiled or repaired in this phase.
- `requiredVisibleScripted` and tutorial route foreground behavior can make tutorial NPC evidence nonrepresentative of ordinary NPC service.
- Continue/save behavior is not covered until Phase 6.

## Exit Decision

- Phase 0 exit gate: passed
- Linear status after commit/evidence update: Done
- Next phase allowed: yes
- Next phase: Phase 1 contract definitions only; no runtime migration and no route-budget changes
