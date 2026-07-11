# VOX-42 Phase 1: Truthful Failing Acceptance

## Scope

Branch: `codex/vox-42-forage-reservation-contract`

Linear issue: `VOX-44`

This phase adds diagnostics and tightens existing headed acceptance so a forager does not pass merely for selecting a bush, owning a reservation, or entering an outside search state. It does not change production movement or reservation behavior.

## Acceptance Contract

A forage cycle is complete only when the live NPC increments `jobRuns`. An active forage reservation without progress remains visible with its owner, slot, age, heartbeat age, route request, route generation, goal key, and last release reason.

## Verification

Compile smoke:

```powershell
.\tools\run-project-compile-smoke.ps1
```

Result: passed.

Focused reservation diagnostics:

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -Case npc_interaction_reservation_lifecycle_diagnostics -TimeMode Day -ReportPath artifacts\npc\reports\vox44-reservation-lifecycle-diagnostics.json
```

Result: passed. Report: `artifacts/npc/reports/vox44-reservation-lifecycle-diagnostics.json`.

Acceptance-runner audit:

```powershell
.\tools\npc\assert-npc-acceptance-runner-clean.ps1 -RunnerPath scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd -ReportPath artifacts\npc\reports\vox44-acceptance-runner-clean-rerun.json -TestId npc_tutorial_real_knock_repair_sleep_morning_foragers -AllowedShortcutPattern final_rescue_fixture_setup_allowance
```

Result: passed. Report: `artifacts/npc/reports/vox44-acceptance-runner-clean-rerun.json`.

Headed, real-boot, no-gameplay-flags tutorial run:

```powershell
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RealBoot -Visible -RunName vox44-truthful-failing-gate-rerun -ReportPath artifacts\npc\reports\vox44-truthful-failing-gate-rerun.json -ProgressPath artifacts\npc\progress\vox44-truthful-failing-gate-rerun.txt -ScreenshotDir artifacts\npc\screenshots\vox44-truthful-failing-gate-rerun -NoFlagsProofPath artifacts\npc\reports\vox44-truthful-failing-gate-rerun-no-flags.json -TimeoutSeconds 520 -StaleProgressSeconds 70
```

Result: failed as required with `niko_forager_cycle_not_completed`. The wrapper proved `realBoot=true`, `noGameplayFlagsProof=true`, and `fullPlayerPov=true`. Mira's knock return, repair, and sleep completed before the forage failure.

## Live Failure Evidence

At failure, Niko had `jobRuns=0`, `jobPhase=outbound`, and owned reservation `prop:atlas-30309674:248,25:3:slot:0:niko:1815`. The reservation was 3,371 physics frames old with no heartbeat and targeted `[333.45, 18.192, 33.75]`.

The active V2 route did not target that slot. Its key was:

```text
niko|forage|home_departure_clearance|266,18|true|prop:atlas-30309674:248,25:3|job_departure_home_exit|2
```

That route held a one-point collision-backed lease at `[359.098, 17.55, 23.983]`, cell `[266,18]`, and remained `arrived / lease_executor_arrived`. Thus the behavior owned a distant forage slot while repeatedly executing an already-arrived home-departure route.

The automated player probe could not leave the starter shelter, so it is not evidence for the player-facing `capacity_busy` result. The user-provided live screenshot remains the evidence for that symptom. The headed report independently establishes the stale owner, exact slot, reservation age, and mismatched route authority without test-only NPC movement.

Screenshots: `artifacts/npc/screenshots/vox44-truthful-failing-gate-rerun/`.

## Refined Defect

VOX-42 is not primarily a bush reachability failure in this reproduction. The home-departure clearance route can remain the active authority after arrival while forage target selection has already acquired a smart-object reservation. The reservation lifetime is not bound to an actively progressing V2 route for its exact slot, so capacity can remain occupied indefinitely.

## Phase Gate

Phase goal achieved: the live no-flags playthrough now fails truthfully when forage work does not complete, and the failure report exposes the reservation/route mismatch.

Next phase allowed: yes.
