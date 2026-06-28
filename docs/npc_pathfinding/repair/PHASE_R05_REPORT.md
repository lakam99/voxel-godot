# Phase R05 Report - Forager And Resource Recovery Hardening

Branch: `npc-pathfinding/repair-06-final-cleanup-gate`

Base commit: `c8e381f975a95a3848eb1c5f7eeb43605dab5cfa`

Branch final commit: commit containing this report.

Merge commit: pending final merge to `master`.

Status: PASS for focused R05 interaction hardening checks on the branch.

## Scope Note

R05 is documented here because the full R04 runner already exposed and fixed Niko/forager live behavior in commit `c8e381f`, but the exact R05 case IDs were not present in the focused interaction suite. This pass adds those exact focused tests without weakening existing tests.

## Implementation Summary

- Added exact R05 interaction case IDs to `scripts/testing/npc/NpcInteractionTestCases.gd`.
- Covered live-only candidate selection, reachable approach slots, target-gone reselection, unreachable target suppression, reservation/arrival authority, wall-blocked effects, and a focused Niko forage cycle.
- Kept resource effects behind SmartObjectService authority: reservation, valid approach, no wall obstruction, and completion request.

## Files Changed

- `scripts/testing/npc/NpcInteractionTestCases.gd`

## Focused R05 Coverage

Command:

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\interaction-r06-focused.json
```

Result:

- `resultCount=33`
- `selectedCases=33`
- `assertions=60`
- `failureCount=0`
- duration `0.064s`

New R05 cases:

| Case | Proof |
| --- | --- |
| `npc_interaction_forager_live_candidate_only` | stale/freed candidate is suppressed; live candidate remains queryable |
| `npc_interaction_forager_reachable_approach_slot` | reservation owns a registered approach slot and harvest completes from that slot |
| `npc_interaction_forager_no_wall_bump_on_morning_exit` | wall obstruction blocks effect and reservation can be released before reselection |
| `npc_interaction_forager_target_gone_reselects` | removed target terminates old request and live alternate is selected |
| `npc_interaction_forager_route_blocked_marks_target_unreachable` | unreachable metadata suppresses bounded retry and live alternate remains |
| `npc_interaction_forager_harvest_requires_reservation_and_arrival` | missing reservation fails, far actor fails, arrived actor succeeds |
| `npc_interaction_niko_full_forage_cycle_morning` | Niko selects live berries, reserves, arrives, harvests, and consumes/carries food |

## Live Runner Cross-Check

Report:

```text
artifacts\test-runners\npc-real-tutorial-playthrough.json
```

Relevant live Niko proof:

- selected object: `prop:atlas-1492:273,39:3`
- approach slot: `slot:0`
- reservation: `prop:atlas-1492:273,39:3:slot:0:niko:2185`
- job phase after observation: `returning`
- personal inventory after cycle: `{ "berries": 2 }`
- `motorBlockedContact` remained empty in sampled Niko timeline entries
- `scriptErrorScan.status=passed`

## Acceptance Mapping

- Live candidates only: focused stale/freed tests and real runner target-node validity.
- Reachable approach slots: focused reservation/slot test and real runner approach slot proof.
- No wall harvest: focused wall-blocked test.
- Reservation and arrival required: focused authority test.
- Removed/depleted resources do not remain queryable: R01 stale tests plus R05 target-gone/reselect test.
- Niko full cycle: focused Niko cycle and real R04 tutorial runner.

## Verdict

R05 hardening coverage is now present with exact case IDs, and the focused interaction suite is green.
