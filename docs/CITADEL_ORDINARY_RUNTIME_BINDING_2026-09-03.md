# Ordinary citadel runtime binding — focused checkpoint

Branch `codex/citadel-visuals-clean`, parent `09b5be6`. Scope: connect the
existing scene publisher to ordinary StructureSystem/Main ownership, shared
trees and doors, and existing player/loading readiness. No route planner,
NPC motor, recipe, furniture placement, town generation or save version change.

## Behavior

- StructureSystem binds after ordinary NPC services exist. A weak,
  identity-pinned adapter forwards shared tree publication and door lifecycle
  calls. Scene roots belong to Main, not the independently cleared prop root.
- Scene retirement requires an exact tree-unbind acknowledgement before
  freeing bodies. Shared tree queue cancellation is per body instance; queued
  worker, proxy and LOD results cannot attach after retirement. This is not
  harvesting and does not write durable removal deltas. Already-harvested bodies
  require the existing durable removal record; unexplained absence rejects.
- Construction pauses while the active player's actual capsule overlaps the
  reserved site. Loading can construct beneath a physics-disabled player, but
  readiness then waits for physics acknowledgement and tests the actual capsule
  for penetration without applying recovery or moving the player.
- Existing swept collision readiness holds approach to an incomplete site.
  Outside reservations no completed scene is required. Partial, stale,
  moved-root, owner-loss and reset states never become ready.
- External construction callbacks may invalidate an owner. Source/configuration
  identity and job ownership are checked again after the callback. Fairness
  inspection itself never invokes a callback.
- Repeated replacement scenes cannot bypass the existing 120-second initial
  readiness deadline. No timeout increase or spawn-position repair is added.

## Evidence and limitations

All directories below are under `artifacts/citadel-runtime-integration/`.
Each owned wrapper records parse/run logs and watchdog cleanup. Service and
synthetic results are not live gameplay acceptance. No headed launch yet.

| Fixture | Artifact directory | Result | Evidence level |
|---|---|---|---|
| Runtime callback bindings | `generated-structure-runtime-bindings-02` | 122/122 | Synthetic Main, real shared registries |
| Tree retirement faults | `scene-tree-retirement-02` | 305/305 | Real scene job, synthetic callbacks/source |
| Shared tree cancellation | `tree-publication-cancel-01` | 14/14 | Real queue and recipe worker; synthetic owner/LOD records |
| Existing tree queue regression | `tree-queue-regression-01` | 18/18 | Unchanged queue assertions via owned adapter |
| Capsule clearance | `player-clearance-01` | 6/6 | Real physics queries, synthetic capsule/floor |
| Physical readiness and callback mutation | `physical-readiness-02` | 83/83 | Real service/jobs, synthetic source/callbacks |
| Actual accepted source, ordinary owner setup | `runtime-owners-actual-03` | 27/27 | Full accepted source, real setup hooks; boot/actor processing suppressed |
| Scene-ID churn deadline | `startup-deadline-01` | 7/7 | Real Main wait, synthetic scene/terrain authorities; original 120s timeout |
| Existing world reset | `runtime-binding-world-reset-01` | 68/68 | Unchanged synthetic lifecycle contract |
| Existing scene lifecycle | `runtime-binding-lifecycle-01` | 267/267 | Unchanged synthetic lifecycle contract |
| Existing scene job | `runtime-binding-scene-job-02` | 376/376 | Unchanged synthetic orchestration contract |
| Native motion/publication gate | `native-admission-physical-gate-01` | 64/64 | Real Player motor/dodge and native terrain; synthetic admission/publication receipts |

Actual source seed `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`,
scale `1.25`; historical input `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.
The accepted-source replay checks exact collision transforms and furnishings,
20 registered doors and four ordinary tree resources, then pre-reset cleanup.
It issues no citadel route query and adds no parallel block navigation source.
Final construction took 57.670 seconds. Its 20.627 ms maximum scene atomic unit
and 20.630 ms maximum slice still fail the 8/4 ms ceilings. This is not a
performance pass. The final available-scene record is byte-identical to replay
02: SHA256 `1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
It records 3,179 collision parts, 210 furnishing bodies and 2,703 render nodes.
The startup churn test returned the exact structured timeout after 120.011895
seconds and 7,203 changing-scene queries, without moving or releasing the player.

The native motion gate preserves all 42 original controls and adds 22 checks:
pending/failed publication holds real movement and rejects dodge without stamina
cost, ready resumes the same motor/dodge, and swept bounds include both endpoints
and the requested capsule radius. It does not prove an actual citadel crossing.
`runtime-owners-actual-01` is a retained test parse failure (fixed type inference).
`runtime-binding-scene-job-01` used the wrong output mode and wrote its successful
report inside a directory named report.json. It is retained; replay 02 uses the
correct directory mode. The generic wrapper now rejects a directory pretending
to be a completed report file.

Seven final NPC suites (`runtime-binding-npc-<suite>-01`, seed `atlas-1492`, both
time modes, existing NpcAutonomyTest scene with fixed FPS 60) exactly preserve
the `door-nav-final-<suite>-01` results and byte-identical stderr: contract84/84,
motor48/48, nav_world84/84, route130/132, door48/48, traffic38/38,
interaction45/45. Known motor/nav_world/route script errors and the traffic
exit warning remain, not a clean NPC release. All jobs exit naturally, route1
and others0, with authoritative owned-zero and no forced cleanup.

## Reproduction

From this worktree, choose a fresh output directory for every run:

```powershell
./tools/run-building-contract.ps1 -Contract CitadelRuntimeOwnersActualContract.gd -OutputDirectory artifacts/citadel-runtime-integration/runtime-owners-actual-03 -ReportEnvironment CITADEL_RUNTIME_OWNERS_OUTPUT -OutputIsDirectory -TimeoutSeconds 210
./tools/run-building-contract.ps1 -Contract CitadelStartupDeadlineContract.gd -OutputDirectory artifacts/citadel-runtime-integration/startup-deadline-01 -ReportEnvironment CITADEL_STARTUP_DEADLINE_OUTPUT -TimeoutSeconds 150
./tools/run-building-contract.ps1 -Contract CitadelPhysicalReadinessContract.gd -OutputDirectory artifacts/citadel-runtime-integration/physical-readiness-02 -ReportEnvironment CITADEL_PHYSICAL_READINESS_OUTPUT -TimeoutSeconds 45
./tools/run-citadel-native-admission-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/native-admission-physical-gate-01
```

The existing BuildingScenePublicationJobContract also requires
`-OutputIsDirectory`; the other newly added focused contracts take JSON-file
outputs with their named report environment variables.
Reports include individual assertions, evidence limits and source hashes.

The independent critic approved this focused checkpoint after inspecting all
final evidence and current source hashes. This is not headed-launch approval;
the separate window-input/capture tooling still requires review.

Still required: ordinary menu/New Game/Continue, continuous
approach and physical gate use, departure/re-entry and durable edits, fresh seed,
inspected visuals, bounded cold preparation/publication and runtime performance.
Existing NPC baseline failures remain explicitly deferred by the user, not fixed
or relabeled as passing. No completed in-game spawn is claimed by this report.
