# Phase 5 Generic Tutorial Orders

## Objective

Replace tutorial-specific NPC movement holds with ordinary scripted orders. The tutorial may describe the knock and rescue, but it must not own a separate movement authority, a named-actor hold, a route-budget exception, or a post-dialogue home-record repair.

This report follows Phase 5 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`.

## Branch And Commit

- Branch: `codex/vox-75-generic-tutorial-orders`
- Implementation commit: `c913028` (`Replace tutorial NPC holds with generic orders`)
- Linear: `VOX-75`

## Production Contract

At tutorial startup, after all ordinary actors are registered, `TutorialSystem` submits Mira one generic order:

```gdscript
order_wait(actor, "tutorial_knock_pending")
```

The visible dialogue acknowledgement submits exactly one ordinary command:

```gdscript
order_go_home(actor, "tutorial_knock_complete")
```

The returned result is surfaced as `introKnockOrders.initial` and `introKnockOrders.home`. The submission reason is immutable (`submissionReason`); later runtime status such as `go_home` or `home_interior_reached` is kept separately as `statusReason`. This prevents runtime progress from hiding what the tutorial actually requested.

`NpcSystem` now owns a generic replacement cleanup path. Replacing or cancelling any order cancels the Route Authority V2 request, releases door/traffic/smart-object ownership, releases job reservation state, clears stale route data, clears the route lease, and writes an idle state before the next generic command begins.

Dialogue focus remains generic. It can pause and face the actor being interacted with while UI is open; it has no intro-specific branch. Rescue staging uses generic `wait`, `go_to`, `go_home`, and cancellation orders. Its non-movement story facts remain in tutorial state.

The following production privileges were removed:

- `release_intro_hold_and_order_home()`;
- `holdIntroDoor`;
- `npc_hold_intro_door`;
- `npc_force_hold`;
- `npc_rescue_stranded`;
- `release_intro_elder_home_order()`;
- post-ack home-record refresh.

No generic NPC route, order, or motion code contains a named tutorial actor check.

## Shared Routing Corrections Found By Live Acceptance

The first unflagged headed run submitted the generic order immediately but Mira waited roughly 22 to 30 seconds before beginning movement. The problem was shared routing behavior, not a tutorial or Mira exception.

1. Incremental substrate searches used `doorStateRevision` as part of their key. Any unrelated door event reset unfinished search work. Door open/closed state does not change portal topology, and collision probe plus door traversal still validate the real crossing before commit.
2. The Route Authority V2 planning budget was first-caller allocation rather than scheduling. In stable NPC update order, later actors were served only by starvation recovery.
3. Global static and semantic navigation revisions changed while streamed props, chunks, and structure events were applied. Including those revisions in every A* key reset work even when the route corridor was unchanged.

The repair keeps the collision-backed contract intact:

- search work now persists through unrelated door, static, and semantic revision changes while each next expansion reads the latest collision snapshot;
- a completed route is revalidated cell-by-cell and transition-by-transition against that fresh snapshot before it can reach collision probing;
- a changed obstacle in previously explored space causes route rejection and a fresh search, never a stale commit;
- Route Authority V2 precomputes bounded grants per frame from active requests, giving priority first and rotating equal-priority requests by time since real service; starvation gets a reserved in-budget grant;
- generic scripted `go_home` retains priority 180 while ordinary schedule home behavior remains 140;
- no route budget was increased, and no movement was direct, snapped, or teleported.

## Verification

### Source Audit

Production source scan found none of the removed movement privileges. The generic routing, order, and plan-executor modules contain no named tutorial actor check. `TutorialSystem.gd` contains the direct generic acknowledgement call and no readiness/generation wait around it.

### Contracts And Route Suites

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\run-tutorial-generic-order-contract-tests.ps1
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both `
  -ReportPath artifacts\npc\reports\vox75-contract-both.json
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both `
  -ReportPath artifacts\npc\reports\vox75-route-mutable-snapshots-both.json
```

Results:

- Compile smoke: passed.
- Generic tutorial order contract: 5/5 passed.
- NPC contract suite: 74 runs, 214 assertions, 0 failures.
- Route suite: 118 day/night runs, 282 assertions, 0 failures.

The route suite includes red/green coverage for:

- unrelated door revision preserving incremental search work;
- unrelated static and semantic revision preserving incremental search work;
- update-order-independent priority grants with fair equal-priority rotation;
- a changed collision in an explored segment forcing revalidation and terminal fresh-search failure instead of stale route commit.

### Headed Actual Gameplay Acceptance

```powershell
.\tools\npc\run-actual-gameplay-mira-porch-regression.ps1 -RealBoot `
  -TimeoutSeconds 360 `
  -ReportPath artifacts\npc\reports\actual-gameplay-mira-porch-vox75-mutable-search.json `
  -ProgressPath artifacts\npc\progress\actual-gameplay-mira-porch-vox75-mutable-search.txt `
  -ScreenshotDir artifacts\npc\screenshots\actual-gameplay-mira-porch-vox75-mutable-search
```

This was a real Main Menu -> New Game run on fresh seed `atlas-80812744`. The report proves `VOXEL_PLAYTEST` and `VOXEL_TEST_SEED` were unset and no save override was used. It drove the visible door and dialogue input, then observed real `CharacterBody3D` NPC physics, collision-backed routing, door traversal, and strict interior arrival.

| Measure | Result |
| --- | ---: |
| Generic go-home submission after acknowledgement | 0.016 s |
| First physical displacement after acknowledgement | 0.683 s |
| Maximum allowed first-displacement delay | 5.0 s |
| Search expansions before route found | 994 |
| Pending-budget frames | 124 |
| Probe frames | 4 |
| Porch departure | true |
| Strict home arrival | true |
| Final route authority state | arrived |

The final search began at static/semantic revision `1436:1378` and completed at `1485:1378`. It accumulated work through the revision change, revalidated against the current collision snapshot, received a successful probe, opened the home door, cleared the threshold, and reached strict interior. Captures include the dialogue acknowledgement, player final state, and an observer view with Mira inside her home.

### Reopened Porch-Latency Gate

A subsequent live New Game observation found Mira eventually departing after roughly 30 seconds. That contradicted the intended outcome even though the runner passed: it only required a 0.135 m displacement in five seconds and permitted up to 150 seconds for actual porch clearance. Historical real-boot traces confirmed the gap: three pre-repair VOX-75 reports recorded first movement after 21.8 to 22.7 seconds and porch clearance after 23.5 to 24.3 seconds.

The acceptance runner now records `porchClearanceDelayAfterAcknowledgement` and fails when clearance takes more than 6.0 seconds. This is a test-contract correction only; it does not alter gameplay movement, route budgets, tutorial state, or player position.

Three fresh headed Main Menu -> New Game runs passed with no gameplay-affecting flags:

| Seed | First displacement | Porch clearance | Strict-home arrival |
| --- | ---: | ---: | ---: |
| `atlas-99899211` | 0.800 s | 2.450 s | 33.534 s |
| `atlas-64377753` | 0.784 s | 2.434 s | 33.517 s |
| `atlas-44991666` | 0.717 s | 2.367 s | 32.900 s |

Each report has `VOXEL_PLAYTEST=false`, an empty `VOXEL_TEST_SEED`, and no save-path override. The runner leaves the live player at the starter doorway after visible input, so the collision-backed planner must account for that player as a dynamic blocker. In every run, Mira received the generic order, planned a real collision-backed route, cleared the porch, opened her home door, crossed it, and arrived in the strict interior.

### Broad Playtest Note

`tools/run-playtest.ps1` was launched but produced no progress marker or report before the external 240-second shell limit. Its exact Playtest child processes were stopped after verifying their command line. This is neither a pass nor a gameplay failure and is not used as acceptance evidence. The focused NPC contracts, full route suite, and unflagged headed actual-gameplay acceptance above are the Phase 5 evidence. The broad Playtest runner needs separate diagnosis if it remains non-reporting.

## Exit Decision

- Generic wait order follows registration: yes.
- Visible acknowledgement submits one generic go-home order without record-generation work: yes.
- Legacy tutorial movement privileges remain: no.
- Generic replacement cleanup releases route, door, traffic, and reservation state: yes.
- Generic code contains named tutorial actor routing checks: no.
- Route budgets were increased: no.
- Mira begins home execution without schedule-selection wait: yes, 0.717 to 0.800 seconds after acknowledgement across three fresh real boots.
- Mira clears the player porch promptly: yes, 2.367 to 2.450 seconds after acknowledgement across three fresh real boots; acceptance maximum is 6.0 seconds.
- Mira reaches strict home in unflagged real gameplay: yes.
- Non-tutorial generic scripted home order remains green: yes.
- Phase 5: passed.
- Next sequential phase: Phase 6, `VOX-76`.
