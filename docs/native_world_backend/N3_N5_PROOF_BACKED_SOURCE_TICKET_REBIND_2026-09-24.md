# N3/N5 proof-backed source-ticket rebind — 2026-09-24

## Authority decision

An unrelated durable edit may advance the broker's global layout identity while
an installed collision window remains byte-for-byte current. In that case N5
does **not** republish or relabel the collider. The owner retains its original
local artifact identity and accepts only a new source-ticket envelope after N3
proves all of the following:

- the current broker ticket names the exact retained window identity,
  membership provenance, resident block order and stable source lineage;
- its explicit `verified_native_affected_mesh_exclusion/v1` proof reaches the
  current global revision and is carried by that same current ticket;
- every current broker artifact key for the retained membership equals the key
  installed in the owner's `_live` entry;
- the source ticket is still current after the bounded scan, and the owner has
  no publication or replacement in progress.

Only `_source_ticket` and the receipt envelope advance. The local artifact
identity remains revision 0 in the focused case while the global layout and
proof reach revision 1. The owner then invalidates cached health, waits for a
physics acknowledgement, and cursor-validates every installed body and shape
before returning a new physical receipt. Missing, stale or foreign proof,
identity relabelling, and any artifact-key difference fail closed. An edit that
affects the window still requires full physical republication.

## Focused evidence

All commands ran with audio playback disabled. The runners own their Godot
process trees and the listed watchdogs prove zero remaining owned processes.

```powershell
$env:VOXEL_DISABLE_AUDIO_PLAYBACK='1'; node tools/run-n3-n5-proof-rebind.mjs
$env:VOXEL_DISABLE_AUDIO_PLAYBACK='1'; node tools/run-n3-n5-windowed-physical.mjs
$env:VOXEL_DISABLE_AUDIO_PLAYBACK='1'; node tools/run-n5-resident-collision-owner.mjs
$env:VOXEL_DISABLE_AUDIO_PLAYBACK='1'; node tools/run-n5-window-aggregate-contract.mjs
```

- Proof-backed rebind: **PASS**, engine exit 0.
  `artifacts/native-world-backend/n3-n5-proof-rebind-1790236379465-26fd9406/report.json`
  and `artifacts/node-tools/process-runs/godot-vbijhx/watchdog.json`.
  The real N3 producer/broker/N5 owner path retained local revision 0 under
  global revision 1, scanned both resident keys in a maximum 66 microseconds,
  returned both identities plus the proof digest, preserved real
  `CharacterBody3D` contact, produced a ready aggregate, and drained the
  coordinator and broker with zero children/barriers/processes. Its negative
  cases reject incomplete, stale, foreign, relabelled and changed-key inputs.
- Full window lifecycle: **PASS**, engine exit 0.
  `artifacts/native-world-backend/n3-n5-windowed-physical-1790236346892-3d019e2b/report.json`
  and `artifacts/node-tools/process-runs/godot-SV0mMa/watchdog.json`.
  Retained-window rebind, affected-window physical republication, retirement
  lease, drain/reversion, reactivation, live contact and final teardown all
  complete. Two asynchronous checkpoints require `pending` plus a nonempty
  reason instead of one exact reason: earlier valid producer/layout blockers
  may precede the retirement-specific blocker without weakening fail-closed
  behavior. All later retirement and reactivation assertions remain intact.
- Resident collision owner: **PASS**, engine exit 0.
  `artifacts/native-world-backend/n5-resident-collision-owner-1790236271979-44664b4b/report.json`
  and `artifacts/node-tools/process-runs/godot-r8zkyi/watchdog.json`.
  Main/staged publication and all bounded cancellation/drain phases remain
  green.
- Window aggregate contract: **PASS**, engine exit 0.
  `artifacts/native-world-backend/n5-window-aggregate-1790236285773-985333cd/report.json`
  and `artifacts/node-tools/process-runs/godot-yMOxVF/watchdog.json`.
  The 4,913-block/eight-window cursor completes within its 96-operation and
  1,500-microsecond per-step budgets; oversize input still fails closed.

## Scope

This is fixture/shadow evidence only (`productionCutover: false`). It does not
enable production native collision or change route, movement, door, or gameplay
semantics. The real retained window contains two resident blocks, so this run
proves complete bounded enumeration for that window but not a production-scale
resident-set timing distribution.

## Primary-worktree replay

The candidate was independently reviewed on exact commit
`fcfd4dd08a9f3b1092e46d8b12730810d504357d`: shadow GO, production NO-GO,
with no P0/P1 findings. The reviewer confirmed the ticket/proof/source/owner/
epoch/membership checks, bounded all-resident key scan, drift rejection,
ticket-only adoption, forced body/shape revalidation, fail-closed negative
cases, live contact and teardown. Review report:
`C:\Users\arkam\.codex\worktrees\n5-proof-rebind\voxel-biome-world-godot\artifacts\reviewer\N5_PROOF_REBIND_INDEPENDENT_REVIEW_2026-09-24.md`.

The exact candidate was cherry-picked to the primary tree as
`1b7d635b8f03d8c485865a33e215b472e14c7121`. Both directly affected runners
were replayed there with audio disabled and exited 0:

- `node tools/run-n3-n5-windowed-physical.mjs`:
  `artifacts/native-world-backend/n3-n5-windowed-physical-1790236788364-b5b37cb9/report.json`;
  owned-process receipt `artifacts/node-tools/process-runs/godot-gQmI1Q/watchdog.json`.
- `node tools/run-n3-n5-proof-rebind.mjs`:
  `artifacts/native-world-backend/n3-n5-proof-rebind-1790236800469-0b1c9909/report.json`;
  owned-process receipt `artifacts/node-tools/process-runs/godot-luYewq/watchdog.json`.

The dedicated integrated report records local revision 0 retained under
global revision 1, both resident keys validated, a ready aggregate, real
post-rebind actor contact, and coordinator/broker drain. These remain
fixture/shadow reports (`productionCutover: false`). The reviewer also notes
that this two-block resident fixture does not close production-scale behavior,
Main integration or original Gate 5; bounded multi-window closure and actual
production binding remain open.

The debug extension loaded by the primary replays has SHA256
`47cf064f2c60736f71768f70aebb4b582b6ece7e6f0f8d1a1b3309edd4149cd4`.
It was rebuilt from current native source before this GDScript-only N5
integration. The release DLL has not been rebuilt or validated in this step.

After the rebind integration, `node tools/run-n5-window-aggregate-contract.mjs`
also passed on primary commit `5d3fd65`: the synthetic 4,913-block/eight-window
cursor completed in 154 advances, 84 maximum operations and 243 µs maximum
step (96-operation/1,500-µs configured caps); oversize input failed closed.
Report `artifacts/native-world-backend/n5-window-aggregate-1790236900563-0bdc9af8/report.json`;
owned receipt `artifacts/node-tools/process-runs/godot-RI8Z7U/watchdog.json`.
This checks aggregate cursor scaling only. It does not prove installation,
health receipts or physical contact for a 4,913-block native-produced demand;
that remains the next N5 scale checkpoint.
