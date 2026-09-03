# Shared runtime retirement and pre-reset drain

Branch `codex/citadel-visuals-clean`, starting at `1fe7618` with a clean worktree.
The user explicitly approved necessary citadel spawn integration without further
routine permission requests, preserving existing gameplay and routing/movement.
This checkpoint does not enable ordinary citadel scenes or claim headed readiness.

## Behavior

- Shared navigation retirement removes exactly one portal's live state and link
  RIDs. Retained descriptor copies lose only that portal's door arrays; geometry
  and caller descriptors remain unchanged. Dirty rebuild cannot resurrect those
  removed entries. Reverse indexes track retained descriptors, not historical
  tombstones. Filtering invalidates the cached signature instead of rehashing
  unrelated surfaces. Explicit dead door references are rejected on installation.
- Autonomy/NpcSystem expose thin streaming cleanup receipts. A partially finished
  door unregister retains its exact body/registry/navigation identity for retry.
  A same-ID replacement cannot be retired by that old request. Grouped survivors
  retain their links and refresh the shared live state.
- Resource unbinding is not harvesting. Existing depletion survives; ordinary
  available resources can rebind on re-entry. Navigation removal is emitted at
  scene exit using captured world bounds, not while teardown still leaves a
  discoverable body. Old instance/world-registry exits cannot target replacements.
- Staged New Game drains generated scenes before changing the seed, deleting a
  save or replacing NPC registries. Dispatch stays suspended through the drain
  and any seed/configuration changes. Only explicit post-registry-reset
  completion plus a fresh worker-drain observation reopens it. The synchronous compatibility path
  refuses a live-scene reset before mutating the world. A defensive guard also
  rejects direct runtime reset while scene retirement remains outstanding.
- Graceful exit drains terrain/structure publication before releasing the NPC
  navigation owner, so callbacks still have their original registry.

No route planner, route executor, motor, terrain recipe, furniture recipe, tree
grammar, or save format is changed. Citadel doors are not inserted into the
adapter's `main.blocks` source. Shared state registration is not a new citadel
navigation topology or a claim that NPCs can traverse it. External callers must
still invalidate their own old snapshots before resubmission.

## Evidence

All commands below were run from this worktree using fresh output directories.
The wrapper runs parse and headless execution in an owned Windows process job.
Each completed job proved zero remaining owned processes, natural exit and no
forced cleanup. Other worktrees' Godot processes were identified and left alone.

```powershell
./tools/run-building-contract.ps1 -Contract DoorNavigationRetirementContract.gd -OutputDirectory artifacts/citadel-runtime-integration/door-nav-retirement-01 -ReportEnvironment DOOR_NAVIGATION_RETIREMENT_OUTPUT -TimeoutSeconds 60
./tools/run-building-contract.ps1 -Contract CitadelWorldResetContract.gd -OutputDirectory artifacts/citadel-runtime-integration/world-reset-04 -ReportEnvironment CITADEL_WORLD_RESET_OUTPUT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract CitadelSceneLifecycleContract.gd -OutputDirectory artifacts/citadel-runtime-integration/runtime-retirement-lifecycle-02 -ReportEnvironment CITADEL_SCENE_LIFECYCLE_OUTPUT -TimeoutSeconds 45
```

- `door-nav-retirement-01/report.json`: **135/135**. Real NavigationServer maps,
  regions and links with synthetic descriptors; exact/prefix-sibling isolation,
  duplicate-record cleanup, descriptor filtering, dirty rebuild, fresh re-entry,
  actual shared Autonomy door/resource forwarding, and explicit synthetic
  fail-once retry. Reports record source hashes. The sampled two-region forget
  took 58 microseconds; final Autonomy forget took 30 microseconds. These tiny
  fixture timings do not prove full-world performance ceilings.
- `world-reset-04/report.json`: **68/68**. Synthetic tiny source with real worker,
  scene job and publishers; complete and partial scenes, no dispatch during
  retirement, explicit reopen, balanced tree callbacks and resource release.
  Also calls the production Main loading/drain helper on a player-free host,
  tests cancellation immediately after dispatch (before a fresh poll), and
  proves automatic generation/configuration cannot reopen the reset fence.
  Source hashes recorded. The helper advances once per loading yield, not twice.
- `runtime-retirement-lifecycle-02/report.json`: **267/267** unchanged service
  scene lifecycle assertions. No recipe or acceptance assertion was weakened.
- Earlier `world-reset-01` passed 40/40; `-02` passed 51/51 but the critic
  **rejected** reset readiness because configuration reopened the fence and the
  drain consulted cached worker state. These were missing adversarial cases,
  not a valid acceptance pass. `-03` passed the repaired 68/68; `-04` verifies
  the final single-advance loading helper. All earlier evidence is retained.
- Both directories contain parse/runtime stdout, stderr and watchdog files.
  Logs are clean. These are service/contract tests, not live player acceptance;
  there are no screenshots or live movement traces to claim.

Seven existing NPC suites ran seed `atlas-1492`, time mode `both`, fixed 60 FPS,
using `NpcAutonomyTest.tscn` and the owned scene watchdog with a 45-second limit.
For each suite, `artifacts/citadel-runtime-integration/door-nav-final-<suite>-01/`
contains its report, progress, traces, stdout/stderr and watchdog; the watchdog
records the exact launch command. Environment selects `VOXEL_NPC_TEST_SUITE`,
`VOXEL_NPC_TIME_MODE=both`, `VOXEL_TEST_SEED=atlas-1492`,
`VOXEL_NPC_TEST_SEED=atlas-1492`, `VOXEL_PLAYTEST=1` and fresh artifact/user paths.

| Suite | Assertions/results passed | stderr bytes | Exit |
| --- | --- | ---: | ---: |
| contract | 84/84 | 0 | 0 |
| motor | 48/48 | 2788 | 0 |
| nav_world | 84/84 | 3276 | 0 |
| route | 130/132 | 170166 | 1 |
| door | 48/48 | 0 | 0 |
| traffic | 38/38 | 124 | 0 |
| interaction | 45/45 | 0 | 0 |

Every stderr file is byte-identical to `scene-door-npc-<suite>-01` at the
pre-change checkpoint. Route retains the known day/night detour budget failures;
motor/nav/route retain their script errors, and traffic its existing exit warning.
This is baseline preservation under the user's explicit deferral, not a clean
NPC release. No test was weakened or rerun to disguise those failures.

## Open acceptance

The independent critic approved this focused cleanup/pre-reset checkpoint and
commit after checking final source hashes, adversarial controls, regression
evidence, logs and process ownership. That approval excludes the separately
prepared runtime-binding files and does not approve activation. Ordinary runtime
binding, acknowledged tree cleanup at the scene-job boundary, access during
incremental construction, New Game/Continue and physical gate traversal remain.
Full-scene publication previously reached 22.544 ms and still fails the budget;
cold source latency, visual preservation in the actual world, save/re-entry and
headed performance remain unverified. No headed test was launched here.
