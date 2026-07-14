# Phase 8: Cleanup, Documentation, and Release

## Objective

Complete Phase 8 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: remove obsolete tutorial-town NPC movement privilege and fallback paths, leave one understandable production ownership contract, guard that boundary with static audits, and rerun the full contract, live, save/Continue, and performance matrices before closing VOX-78 and VOX-21.

This report applies the plan's acceptance hierarchy. Contract and synthetic tests support invariants, but the release claim comes from the headed Main Menu -> New Game run with no gameplay-affecting flags, real generated structures and doors, real `CharacterBody3D` actors, real physics, visible player interaction, and a strict generated-home interior result.

## Branch and implementation commit

- Branch: `codex/vox-78-cleanup-documentation-release`
- Implementation commit: `c5ae9d6` (`Remove tutorial NPC privilege and bound release harnesses`)
- Report commit: the separate documentation commit containing this file
- Linear phase issue: `VOX-78`
- Parent acceptance issue: `VOX-21`

## Changed files

The implementation commit contains 39 scoped files. Principal changes are grouped below.

- `scripts/StructureSystem.gd`, `TutorialSceneBuilder.gd`, and `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`: publish and consume generic private-interior records instead of inferring a tutorial starter shelter during NPC/runtime behavior.
- `scripts/NpcSystem.gd`, `TutorialSystem.gd`, `TutorialDialogueSystem.gd`, `TutorialRescueSystem.gd`, `HostileSystem.gd`, `HostileProjectileSystem.gd`, and `MainWorldEntities.gd`: separate story/presentation scope from generic NPC identity, claim tutorial-town population before generic spawning, submit only generic orders, and validate rescued hostile/NPC lifetimes before use.
- `scripts/npc_ai/behavior/NpcPerceptionService.gd`, `NpcPlanExecutor.gd`, `NpcTaskPlanner.gd`, and `resources/npc_behavior/task_catalog.tres`: remove fallback inside-home success and tutorial-named action vocabulary; strict generated interior is the only successful home terminal.
- `scripts/testing/player/LivePlaytestPlayerNavigator.gd` and `scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd`: use production collision-backed route authority for moving-target interaction, exact door action cells, rescue-gate traversal, and bounded scripted-combat execution.
- `scripts/TerrainMeshingService.gd` and `scripts/testing/TerrainMeshingBoundsContractRunner.gd`: retire completed payloads through a bounded low-priority cleanup queue with release telemetry.
- `scripts/testing/TutorialActorRegistrationContractRunner.gd`, `TutorialGenericOrderContractRunner.gd`, `StartupLoadingReadinessContractRunner.gd`, and `TownRuntimeManifestContractRunner.gd`: audit named movement branches, tutorial-time home generation, combined intro APIs, production fallback coordinates, duplicate population, and incomplete loading manifests.
- `tools/npc/run-all-npc-tests.ps1`, `tools/run-all-test-runners.ps1`, `tools/run-npc-navigation-tests.ps1`, `tools/run-playtest.ps1`, `tools/story/run-story-playtest.ps1`, and the no-flags wrapper: bound missing-progress waits, clean child processes, preserve concise aggregate output, and keep no-flags proof handling null-safe.
- `docs/tutorial_town_loading/PHASE_0_BASELINE_AND_PRIVILEGE_AUDIT.md`, `PHASE_4_TUTORIAL_ACTOR_REGISTRATION.md`, and `TUTORIAL_TOWN_LOADING_ARCHITECTURE.md`: update the inventory and describe final production ownership.

Generated `.import`/`.uid` files, the test-mutated `atlas-1492` world-signature baseline, and unrelated pre-existing working-tree files were deliberately excluded.

## Final contract decisions

1. **Loading owns publication.** `startup_loading_completed` remains false until required structure work drains, the town manifest validates semantically, required homes/porches/door portals and strict interiors exist, actor assignments register, terrain collision is authoritative, and initial navigation publication is ready. Dialogue and NPC behavior do not repair missing town data.
2. **Tutorial actors are ordinary NPCs.** Scenario code may select Mira, Niko, Rowan, or Sera and decorate story/UI state through `story_actor_scope`, but generic NPC systems do not branch on tutorial identity or named actors.
3. **Story choreography uses generic retained orders.** The visible knock replaces a generic wait order with ordinary `go_home`; rescue uses ordinary `go_to`. Readiness, collision proof, motor execution, doors, traffic, recovery, arrival, and save/Continue remain production NPC authority.
4. **Home success is strict.** Porch, threshold, door cell, wall edge, roof, and fallback coordinates do not count as inside. A home order succeeds only in the manifest's strict interior, past and clear of the generated door portal.
5. **Population has one owner.** Tutorial orchestration claims its generated-town population before registering actors; generic population spawning skips claimed towns instead of creating duplicates.
6. **Private interiors are generic world data.** The player starter shelter is registered as a normal private interior, so navigation no longer scans for or guesses a tutorial-specific shelter.
7. **Diagnostics and cleanup are bounded.** Generic route/order telemetry remains bounded and useful; retired terrain payload destruction is limited to four jobs per low-priority cleanup pass. Missing-progress harnesses now terminate and clean their process trees instead of hanging indefinitely.

## Verification commands and results

### Focused source and contract matrix

These checks support the ownership and schema contracts; they are not cited as live gameplay acceptance.

| Command | Report/result | Outcome |
| --- | --- | --- |
| `.\tools\run-project-compile-smoke.ps1` | console report | Passed |
| `.\tools\run-startup-loading-readiness-contract-tests.ps1` | startup readiness report | Passed: 7/7 |
| `.\tools\run-tutorial-actor-registration-contract-tests.ps1` | actor registration report | Passed: 7/7 |
| `.\tools\run-tutorial-generic-order-contract-tests.ps1` | generic-order/source audit | Passed: 5/5 |
| `.\tools\run-tutorial-save-compatibility-contract-tests.ps1` | save compatibility report | Passed: 7/7 |
| `.\tools\run-town-runtime-manifest-contract-tests.ps1` | runtime manifest report | Passed: 11/11 |
| `.\tools\run-structure-town-manifest-contract-tests.ps1` | structure manifest report | Passed: 10/10 |
| `.\tools\run-terrain-meshing-bounds-contract.ps1` | terrain cleanup bounds report | Passed: 4/4 |
| `.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/contract-both.json` | Passed: 82 runs / 240 assertions |
| `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/behavior-both.json` | Passed: 73 cases / 182 assertions |
| `.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both` | `artifacts/npc/reports/interaction-both.json` | Passed: 41 runs / 81 assertions |

The generic-order audit recursively scans `NpcSystem.gd` and `scripts/npc_ai/` for tutorial identity, named-NPC movement, starter-home guesses, runtime home refresh/generation, fallback home coordinates, and combined release-and-home APIs. The startup/manifest audits reject incomplete loading publication.

### Authoritative unflagged tutorial run

Command (also executed by the final registry):

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -Visible
```

Artifacts:

- Report: `artifacts/test-runners/npc-real-tutorial-no-flags.json`
- No-flags proof: `artifacts/test-runners/npc-real-tutorial-no-flags-proof.json`
- Screenshots: `artifacts/test-runners/screenshots/npc-real-tutorial-no-flags/`
- Fresh random production seed: `atlas-28713408`, read from `Main.seed_text_after_new_game_loading`

Result: passed all 9 release assertions with zero failures. The runner entered the production `MainMenu.tscn`, dispatched visible New Game/door/dialogue input, and ran with no `VOXEL_PLAYTEST`, test-seed, save-override, gameplay-god-mode, fixed-pacing, teleport, direct tutorial-handler, direct NPC movement, or metadata-success shortcut.

The decisive departure timeline is:

- Visible dialogue acknowledgement: 27.383s / physics frame 1646.
- Generic `go_home` order retained `ACTIVE`: 27.435s / physics frame 1647, submission reason `tutorial_knock_complete`, `usesRouteStack: true`.
- First collision-backed route request: 27.435s, in the same observed frame as order submission.
- First nontrivial displacement: 27.718s, 0.283s after submission.
- Player-porch clearance: 28.957s, 1.522s after submission.
- Maximum observed flat speed: 2.569m/s, below the 12.420m/s integrity ceiling.
- Final home cell: `[292,15]`, inside generated bounds `[290,10]..[295,15]`, past the door plane, off porch/door cells, with threshold, sweep, and clearance occupancy all false.

The same uninterrupted run also passed the complete visible generated-home door sequence, two other non-guard NPC home observations, night guard/non-guard behavior, 43 real repair placements, pre-repair sleep blocking, morning transition, and Niko's real forage cycle.

Inspected required captures include `phase7_menu_before_new_game`, `phase7_loading_gameplay_prerequisites`, `player_pov_dialogue_acknowledged`, `mira_route_departure`, `mira_at_home_door`, `mira_home_door_open`, `mira_inside_home_closed_door`, `non_guard_home_rowan`, `non_guard_home_niko`, and `player_pov_after_morning_forager_observation`.

### Focused live generated-home and rescue coverage

| Command | Seed/report | Result |
| --- | --- | --- |
| `.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible` | `tutorial-20260714075907-627e63fe`; `artifacts/test-runners/npc-real-tutorial-playthrough.json` | Passed 5/5, including visible Mira open/cross/strict-inside/close and other non-guard home captures |
| `.\tools\npc\run-npc-go-home-visual-playtest.ps1` | `atlas-1492`; `artifacts/npc/reports/go-home-visual-playtest.json` | Passed: one ordinary NPC, 16.2m route, 0.13m minimum door distance, strict cell `[294,20]`, portal opens then closes |
| `.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible -FinalRescue` | `tutorial-20260714073834-8344e315`; `artifacts/npc/reports/real-tutorial-playthrough.json` | Passed focused final act with all 15 captures |
| Final registry `npc_real_tutorial_final_rescue` | `tutorial-20260714080550-54a8d31a`; `artifacts/test-runners/npc-real-tutorial-final-rescue.json` | Passed 1/1: Mira briefing, Sera escort/gate, six defeats, Niko home, Sera guard |

The focused final-rescue fixture intentionally stages only the final act and may use its documented test setup. It proves that act's production route/interaction behavior; it does not replace the no-flags full-tutorial acceptance above.

### New Game/Continue and save compatibility

Command:

```powershell
.\tools\npc\run-tutorial-save-continue-playtest.ps1 -Visible
```

Report: `artifacts/npc/reports/tutorial-save-continue-playtest.json`. Result: passed 2/2 on `atlas-94476673`. The two real processes preserved stable actor home IDs and portals; Continue restored Mira's generic `go_home` route order, cleared the porch by 0.661m, and ended in strict home interior. The final aggregate `artifacts/test-runners/main-menu-continue-startup-smoke.json` also passed its child runner.

### Normal-runtime performance

Command:

```powershell
.\tools\run-normal-runtime-performance-pass.ps1
```

Report: `artifacts/performance/normal-runtime-performance-pass.json`. Result: passed on fresh seed `atlas-96573970` over 2,293 frames and 672.924m of traversal. Frame p50/p95/p99/max were 10.541/18.139/21.778/28.682ms; NPC max was 1.373ms. The run showed visible loading progress, reached gameplay in 41.511s, and reported no classified terminal spike. Top observed section maxima were hostiles 20.155ms, chunk work 16.587ms, hostile spawn 16.374ms, and props 13.023ms.

### Full regression matrices

Commands:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
.\tools\run-all-test-runners.ps1
```

`artifacts/test-runners/all-npc-both.json` completed all 17 NPC suites in 788.823s. Core contract, motor, nav-world, route, repair, door, avoidance, traffic, behavior, interaction, streaming/save, soak, full tutorial, morning, and go-home suites passed. Two unrelated live observations remain explicit:

- The fixed `atlas-1492` final-rescue observation left Niko in `pending_budget/search_budget_deferred` after its 8s fixture window; two fresh random final-rescue runs passed. Tracked by VOX-107.
- The generated-town job-cycle visual observation retains the pre-existing forager/LOD failures. Tracked by VOX-6 and VOX-97.

`artifacts/test-runners/all-test-runners-report.json` completed all 50 registered runners without early stop in 3,117.594s (51m57.6s), with 17 red registry entries. The Phase 8 tutorial loading/registration/generic-order/save contracts and all three authoritative real-tutorial runners passed. Every remaining red is unrelated to the released tutorial-town ownership contract and is explicitly tracked:

| Aggregate exception | Ownership |
| --- | --- |
| `npc_focused` | Child failures above: VOX-6, VOX-97, VOX-107 |
| Avoidance/interaction/streaming-save evidence classification, plus Main Menu `scene-load-smoke` registry rejection despite exit 0 | VOX-110 |
| User-owned modified `atlas-1492` world-signature baseline | VOX-79; baseline deliberately preserved |
| NPC navigation process wrote no startup progress before its bound | VOX-106 |
| Generated-town job-cycle visual | VOX-6 and VOX-97 |
| Underground generation/fluid wrappers return exit 1 around passing structured reports | VOX-110; genuine visual terrain/fluid issues remain VOX-43 and VOX-54 |
| VOX-43 known-save/fresh-traversal/underground-fluid/surface-cave visuals | VOX-43 and VOX-54 |
| Broad playtest wrote no startup progress before its bound | VOX-109 |
| Freed NPC job-target access observed in runtime logs | VOX-108 |

The two missing-progress harnesses are now bounded and clean their process trees. Focused watchdog verification terminated navigation after 120.535s and broad playtest after 15.7s with no orphan Godot process. Producing a normal structured child report remains owned by VOX-106 and VOX-109; this release does not misrepresent watchdog termination as gameplay success.

## Reports and captures inspected

- `artifacts/test-runners/npc-real-tutorial-no-flags.json`
- `artifacts/test-runners/npc-real-tutorial-no-flags-proof.json`
- `artifacts/test-runners/screenshots/npc-real-tutorial-no-flags/`
- `artifacts/test-runners/npc-real-tutorial-playthrough.json`
- `artifacts/test-runners/npc-real-tutorial-final-rescue.json`
- `artifacts/test-runners/screenshots/npc-real-tutorial-final-rescue/`
- `artifacts/npc/reports/go-home-visual-playtest.json`
- `artifacts/npc/reports/tutorial-save-continue-playtest.json`
- `artifacts/performance/normal-runtime-performance-pass.json`
- `artifacts/test-runners/all-npc-both.json`
- `artifacts/test-runners/all-test-runners-report.json`

Screenshots for the no-flags Mira door sequence, Rowan/Niko strict-home observation, focused go-home sequence, final rescue, and normal-runtime performance were manually inspected. They agree with the corresponding route/order timelines, portal state, collision proof, and strict-interior records.

## Pass/fail disposition

- Phase 8 source-audit gate: **passed**.
- Tutorial town loading/publication and manifest gates: **passed**.
- No tutorial-specific movement metadata/API gate: **passed**.
- Headed unflagged prompt-departure and strict-home gate: **passed**.
- New Game/Continue/save compatibility gate: **passed**.
- Normal-runtime performance gate: **passed**.
- Full-regression gate: **passed under the plan's explicit alternative**: tutorial/Phase 8 runners are green and every unrelated aggregate failure is separately tracked. The aggregate itself is not represented as globally green.

## Known residual risks

- Fixed-seed final-rescue search-budget latency remains reproducible in the short fixture window even though two fresh random final-rescue runs pass (VOX-107).
- Generated-town job/forage observation and active-work-vs-LOD semantics remain outside this plan (VOX-6, VOX-97).
- Full-registry evidence-level metadata and two wrapper exit-code contracts can create false-red aggregate entries around passing child evidence (VOX-110).
- Navigation and broad playtest startup can still fail to produce a structured report. The release bounds and cleans the waits; VOX-106 and VOX-109 own the underlying startup failures.
- World-signature and terrain/fluid visual regressions are preserved and tracked by VOX-79, VOX-43, and VOX-54. No user-owned baseline was rewritten.
- A freed NPC job target can still surface in unrelated runtime logs (VOX-108).
- This report closes the tutorial-town loading/NPC privilege plan only. It does not claim the broader NPC pathfinding replacement complete; that project retains its own controlling plan and gates.

## Linear status

- `VOX-78`: final evidence and implementation commit attached; release disposition **Done** after the report commit is fast-forwarded to `master`.
- `VOX-21`: final no-flags New Game, Continue, strict-home, door, performance, and residual-risk evidence attached; parent acceptance disposition **Done** after the same merge.
- Residual work remains open in VOX-6, VOX-43, VOX-54, VOX-79, VOX-97, VOX-106, VOX-107, VOX-108, VOX-109, and VOX-110.

## Next phase allowed

`Next phase allowed: yes`

Phase 8 is the final phase of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`. Further NPC/pathfinding work must continue under its own controlling plan rather than extending tutorial-specific privilege.
