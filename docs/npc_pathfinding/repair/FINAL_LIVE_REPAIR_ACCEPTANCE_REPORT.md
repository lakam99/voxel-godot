# Final Live Repair Acceptance Report

Status: branch aggregate gate passed; in progress until the merged-`master` aggregate gate passes.

Branch: `npc-pathfinding/repair-06-final-cleanup-gate`

Seed: `atlas-1492`

## Real Tutorial Runner

Report:

```text
artifacts\test-runners\npc-real-tutorial-playthrough.json
```

Result:

- `testId=npc_tutorial_real_knock_repair_sleep_morning_foragers`
- `failureCount=0`
- `resultCount=7`
- `scriptErrorScan.status=passed`
- `forbiddenCallSelfScan.status=passed`

## Player Action Timeline Proof

The real runner report includes:

- player position timeline
- door state timeline
- interaction timeline
- inventory timeline
- sleep timeline

The opening door interaction used the focused block hit and real use/place input path, not tutorial internals.

## Mira Home-Return Proof

From `artifacts\test-runners\npc-real-tutorial-playthrough.json`:

- `miraMaxFlatSpeed=6.401`
- `miraSpeedLimit=7.360`
- `miraTotalFlatDistance=101.236`
- `miraFinalHomeInteriorStatus.strictInside=true`

No `speed = 20.0` or `holdIntroDoor` speed override exists in the static scan.

## Night Duty And Interior Matrix

The real runner records `nightGuardNonGuardMatrix`. The acceptance rule remains:

- assigned guards may be outside on duty or en route to duty;
- non-duty NPCs must be inside strict interiors/shelters;
- porch, threshold, roof, and exterior wall edge do not count as inside.

## Repair And Sleep Proof

The real runner records:

- `repairTargetPlacementProof`
- `sleepTransitionProof`
- `interactionTimeline`
- `inventoryTimeline`

The runner uses the real repair chest/material flow and real placement input path. The forbidden-call scan has no matches for direct `on_block_placed`, direct inventory injection, or direct sleep completion.

## Morning Departure Proof

The real runner records `morningNpcDepartureMatrix` with six NPC entries. Niko, Rowan, Sera, Toma, and Lyra left home during the observed morning window; Mira remained home after completing the required night return-home proof.

## Niko/Forager Full Cycle Proof

Real runner report:

- selected object: `prop:atlas-1492:273,39:3`
- approach slot: `slot:0`
- reservation: `prop:atlas-1492:273,39:3:slot:0:niko:2185`
- job phase after observation: `returning`
- personal inventory: `{ "berries": 2 }`
- sampled blocker fields: empty `motorBlockedContact`

Focused R05 coverage:

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\interaction-r06-focused.json
```

Result: `resultCount=33`, `failureCount=0`, `assertions=60`.

## Script-Error Scan

Real runner report:

- `scriptErrorScan.status=passed`
- no freed-instance warnings were reported.

Focused interaction suite also passed stale/freed resource cases:

- `npc_interaction_stale_registered_resource_ignored`
- `npc_interaction_queue_free_resource_query_no_script_error`
- `npc_interaction_stale_resource_unindexed`
- `npc_interaction_stale_resource_reservation_released`
- `npc_interaction_query_cache_invalidates_on_resource_removal`
- `npc_interaction_forager_query_after_harvest_no_crash`

## Forbidden Shortcut Scans

Real runner shortcut scan:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
```

Result: no matches.

Speed-hack scan:

```powershell
rg -n "speed\s*=\s*20\.0|holdIntroDoor.*speed|speed.*holdIntroDoor" scripts/NpcSystem.gd scripts/npc_ai scripts -g "Tutorial*.gd"
```

Result: no matches.

## Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-r06-branch.json -StopOnFailure
```

Result: `resultCount=23`, `failureCount=0`, `stoppedEarly=false`, `durationSeconds=681.162`, exit code `0`.

## Merged Master All-Runner Evidence

Pending:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-r06-master.json -StopOnFailure
```

## Deviations

- R04 was fast-forwarded to `master` before this report was written, so there is no separate R04 merge commit.
- R05 focused exact-ID coverage was added during the final cleanup branch because the live R04 fixes were already merged in `c8e381f`.

## Final Verdict

Pending merged-`master` all-runner gate.
