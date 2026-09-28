# Node runner migration — 2026-09-08

The Citadel worktree now uses Node.js entry points exclusively. The earlier
`5652eaa` migration left the PowerShell originals and omitted newer Citadel
runners. This change supplies the missing 40 entry points and removes all 152
PowerShell files. `tools/node-runner-migration-manifest.json` records the old
source hashes and corresponding Node commands against baseline `e09cc95`.
Historical reports retain their original commands; they are evidence of those
runs, not current launch instructions.

## Running tests

Run commands from this worktree, using its installed Node runtime. Both existing
`-PascalCase` arguments and documented `--kebab-case` arguments are supported by
the migrated runners. Use `--help` to inspect a runner without launching Godot.

| Purpose | Entry point |
| --- | --- |
| Broad game integration | `node tools/run-playtest.mjs` |
| Focused building contract | `node tools/run-building-contract.mjs -Contract <Name>.gd -OutputDirectory artifacts/citadel-runtime-integration/<fresh-name> -ReportEnvironment <VARIABLE>` |
| Full candidate recipe | `node tools/run-citadel-candidate-recipe-diagnostic.mjs` |
| Headed candidate diagnostic | `node tools/run-citadel-candidate-teleport-playtest.mjs` |
| Direct owned launch | `node tools/run-godot-scene-watchdog.mjs` |
| Inspect/control a runner-owned game window | `node tools/invoke-owned-game-window.mjs` |
| Evidence integrity self-test | `node tools/test-evidence-registry-self-test.mjs` |
| NPC shortcut guard self-test | `node tools/npc/test-npc-acceptance-guard.mjs` |

`-OutputIsDirectory` applies only when the GDScript fixture explicitly expects
a directory. Both `CITADEL_CIVIC_CLEARANCE_REPORT` and
`CITADEL_CIVIC_INFILL_OUTPUT` expect a report **file**, despite the latter name.

The candidate runner retains its separate source and physical-proof budgets.
The handoff's failing candidate is seed `atlas-30895044`, region `-1,0`, recipe
seed `541151883`; these differ from the runner's default region/recipe seed.
Do not replay Recipe 17 merely to rediscover the recorded clearance failure.
The handoff's critic approval requirement before headed Citadel testing remains.

## Ownership and evidence

Node orchestrates every launch. Windows APIs unavailable in Node's standard
library use small C# helpers under `tools/native/`, compiled directly with the
installed .NET Framework compiler into a content-addressed temporary cache.
There is no PowerShell invocation. The owned watchdog requires Windows 10 /
Server 2016 or later, x64, and the .NET Framework compiler. It fails explicitly
on unsupported hosts rather than claiming equivalent process ownership.

The watchdog atomically assigns the suspended process to a private Windows Job
Object, resumes it, and controls only that job. It records functional exit,
timeouts, forced cleanup, and authoritative zero-member evidence separately.
Generic Godot launches retain logs and receipts under
`artifacts/node-tools/process-runs/`. Focused Citadel runners retain their fresh
per-run directories and frozen source hashes. Existing saves are not used by
the focused contract runners.

Node phase-B structural checkpoints require fresh Node phase-A evidence. Old
PowerShell checkpoint fingerprints must fail source-identity validation rather
than silently being treated as equivalent execution.

The migration also restores evidence checks lost in the earlier Node port:
the four real evidence self-test controls; all original NPC source-audit and
shortcut-guard rules; six scenario orchestration; distinct production
no-flags tutorial and two-process save/Continue workflows. No-flags gameplay
is uncapped, carries no test seed or player protection flag, and requires live
report tokens. The normal tutorial's player-protection setting remains explicit
and must not be represented as no-flags acceptance.

## Verification and limitations

The migration is tested with Node unit/synthetic checks, harmless real Windows
child-process integration tests, and short headless Godot source contracts.
These do not establish Citadel spawning, visuals, traversal, or NPC acceptance.
No headed game, full candidate recipe, or broad gameplay suite was run for this
tooling migration. The Citadel foundation-clearance defect remains unchanged.

Final verification: **157/157 Node tests**, including syntax and launch-free
help for all 152 entry points; **53/53 native-window synthetic checks**;
**20/20 civic-clearance**, **196/196 civic-infill**, and **38/38 checkpoint-codec**
checks in headless Godot. The restored underground static audit passes all 37
rules. Independent read-only reviews covered the watchdog, adapter/tutorial
workflows, building/checkpoint ports, and remaining aggregate/legacy workflows.

Saved evidence:

- `artifacts/node-migration/node-tests.tap`: combined Node tooling suite.
- `artifacts/node-migration/evidence-self-test.json`: original four controls.
- `artifacts/citadel-runtime-integration/node-migration-civic-clearance-final/`:
  20/20 checks and exactly 154 regenerated furniture parts; clean owned exit.
- `artifacts/citadel-runtime-integration/node-migration-civic-infill-final/`:
  196/196 checks; clean owned exit. Attempt `01` received a directory where
  the fixture expects a report file, naturally exited 2, and left zero owned
  processes. Attempt `02` corrected only that command argument.
- `artifacts/citadel-runtime-integration/node-migration-codec-final/`:
  38/38 adversarial checkpoint-codec checks; clean owned exit. This is a codec
  contract, not a full structural Phase A/B recipe run.
- `artifacts/node-migration/underground-audit.json`: all 37 source checks pass.

The restored aggregate now consumes `defaultArgs`, honors supported overrides,
derives each NPC suite's report/capture paths, isolates user data, rejects stale
reports, and validates evidence. The six-case tree matrix runs both harvest/save
and Continue stages for every case before reporting success. The interactive
underground runner retains ownership until exit; observer failures use a
run-specific abort even if the stop-request file cannot be written.

The restored standalone NPC acceptance-guard self-test reports 3/4: its
real-tutorial case omits the existing `final_rescue_fixture_setup_allowance`
for the fixture's line-581 setup teleport. That failure was hidden by the prior
Node self-test's hard-coded pass. The migration preserves and reports it; it
does not weaken the guard or modify NPC/gameplay behavior to hide it.
