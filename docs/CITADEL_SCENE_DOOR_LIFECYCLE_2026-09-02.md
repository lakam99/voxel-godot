# Connect scene-owned doors to shared registration and retirement

## Scope

Started clean at `6140447`, branch `codex/citadel-visuals-clean`. The previous
turn completed shared door/interaction cleanup APIs. This step makes the real
building scene job and its owning CitadelPublicationService use a balanced
registration/retirement callback pair. It does not yet bind ordinary Main.

Main owns the scene job and accepted-source fixture. One worker owns service
configuration and its independent binding fixture; another owns scene-door fault
controls. The critic is read-only; all read AGENTS.md/MANIFESTO.md. No protected
NPC/navigation code, source recipe, furniture or tree generator is edited.

- After building finalization, an explicit cursor scans actual published nodes,
  registering door bodies once. Each candidate is claimed before external code.
  A pending registration may retry only with an explicit no-side-effects receipt.
- Cancellation or a failed/malformed acknowledgement retains cleanup ownership.
  Unregister happens before descending into the body's children. Only the shared
  owner's `unregistered`/`absent` acknowledgement permits freeing that body.
- Lost roots/claims remain unresolved instead of reporting successful teardown.
  A lost cleanup receiver may be repaired in teardown only, using the SAME
  authoritative registry; an empty replacement registry cannot prove cleanup.
- Existing tree retirement also moves before child removal. Its legacy void
  callback is unchanged: this is not new acknowledged/retryable tree cleanup.
- Service callbacks are weak, captured per job and cannot be replaced while
  scenes or retirement payloads remain owned. Optional construction diagnostics
  expose door lifecycle as unavailable; once configured, receiver loss cannot
  fall back to that mode. Ordinary activation must require all capabilities.

## Actual accepted-source replay

All paths below are beneath `artifacts/citadel-runtime-integration/` in this
worktree. Every run uses the existing owned-process watchdog, never process-name
termination. No headed run occurred.

```powershell
./tools/run-building-contract.ps1 -Contract CitadelServiceSceneContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-door-actual-01 -ReportEnvironment CITADEL_SERVICE_SCENE_OUTPUT -OutputIsDirectory -TimeoutSeconds 210
```

**27/27 checks pass**, with all 24 recorded source hashes matching final files.
The fixture consumes the hash-verified accepted source `actual-site-source-05`
(world `atlas-1492`, region `(1,-3)`, recipe `1298433643`, scale `1.25`), not a
new source build. It runs real service/worker/building/furniture/tree publication
and real shared SmartObject/DoorPortal registries in a player-free Main subclass.

All twenty actual door IDs register once and unregister once, with intact
collision children at retirement. Registries are checked empty before fixture
cleanup. The existing auditor still observes 3179 collision parts, 210 furnishing
bodies, four production trees and one physics probe. The available scene record
is byte-identical to `scene-publication-binding-actual-01`, SHA256
`1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
Headless MultiMesh placeholders do not prove GPU fidelity or visual acceptance.

Progress is `progress.txt` plus detailed stdout; results are `report.json` and
`render-baseline.json`, with parse/run logs and watchdogs. Logs are clean;
natural exit 0, zero owned processes and no forced cleanup.

Door registration scans 1854 units (including non-door nodes), packing work into
slices: maximum atomic 0.158 ms, maximum stage slice 1.899 ms, zero measured
stage overruns. These are units, not scheduler turns. Overall service maximum
is **22.544 ms**, job atomic **22.459 ms** in building finalization, versus the
prior replay's 17.731/17.659 ms. Preparation plus construction is 50.227 seconds.
Strict budgets still FAIL; this is not a performance improvement or guarantee.

## Focused controls and regression

```powershell
./tools/run-building-contract.ps1 -Contract BuildingSceneDoorLifecycleContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-door-lifecycle-03 -ReportEnvironment BUILDING_SCENE_DOOR_LIFECYCLE_OUTPUT
./tools/run-building-contract.ps1 -Contract CitadelDoorCallbackBindingContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-door-binding-03 -ReportEnvironment CITADEL_DOOR_CALLBACK_BINDING_OUTPUT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract BuildingScenePublicationJobContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-door-final-job-02 -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory
./tools/run-building-contract.ps1 -Contract CitadelSceneLifecycleContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-door-final-lifecycle-01 -ReportEnvironment CITADEL_SCENE_LIFECYCLE_OUTPUT -TimeoutSeconds 90
```

New tiny scene-door controls pass **414/414**, all eleven source hashes current.
They use real publishers/shared services, explicitly synthetic prepared proofs
and fault injection. Reports include callback traces. Coverage includes grouped
survival, pending registration before side effects, failure after registration,
invalid acknowledgements, cleanup retry before child deletion, same-registry
receiver recovery, nested advance rejection, cancellation during callbacks,
root reparenting and independent fresh jobs. External root/claim destruction and
receiver loss are asserted unresolved, then explicitly cleaned by the fixture;
they are not successful production retirement evidence.

Unchanged scene-job and service-lifecycle suites pass **376/376** and **267/267**,
matching the pre-edit `scene-door-baseline-job-01` and
`scene-door-baseline-lifecycle-01` runs. Independent service binding controls
pass **138/138**, with eleven current source hashes and clean parse/run logs.
Besides explicit synthetic configuration/disposal markers and real empty-worker
capture, two real service/publisher/shared-registry cases reset or shut down
the service inside the first door-registration callback. They preserve intact
children until unregister, do not register the second door or resurrect ready
state/counters, and release the old job/publisher resources through worker
retirement. Tiny prepared proof receipts remain explicitly synthetic.

Seven NPC suites ran in `scene-door-npc-<suite>-01`: contract 84/84, motor 48/48,
nav-world 84/84, route 130/132, door 48/48, traffic 38/38 and interaction 45/45.
They use headless `res://scenes/testing/npc/NpcAutonomyTest.tscn`, seed
`atlas-1492`, time mode both, fixed 60 fps, empty case filter, VOXEL_PLAYTEST=1,
matching seed variables, fresh report/progress/trace/screenshot/userdata paths
and run tokens, and a 45-second cap. Exact commands are in watchdogs.

Six stderr files match `smart-door-unregister-final-<suite>-01` byte-for-byte.
Route matches the older `door-unregister-final-route-01` exactly: 244 error
headers, the same day/night exact-detour failures at four visits/32000 us.
The latest prior run had three extra copies of an existing stack, already
classified as baseline timing variation. Existing motor/nav/route errors and
the traffic ObjectDB warning remain deferred, not fixed or relabeled green.
All seven exit naturally (route 1, others 0), owned zero, no forced cleanup.

## Failed/interim attempts

- `scene-door-baseline-service-01`: main supplied the wrong report environment
  to the older preparation-service fixture. Explicit owned stop, exit 126,
  zero owned processes; no acceptance. The correct lifecycle baseline passed.
- `scene-door-final-job-01`: production local ID needed an explicit integer
  type after reading a Variant node; parse failure preserved, corrected in job02.
- `scene-door-lifecycle-01`: two fixture WeakRef declarations needed explicit
  types; parse failure preserved. Run02 passed 362 checks before run03 extensions.
- `scene-door-binding-01`: fixture WeakRef inference parse failure.
- `scene-door-binding-02`: 102/104 checks passed; two immediate weak-reference
  checks retained a conditional-expression temporary. This failed run is not
  acceptance. Run03 isolates temporary ownership in a helper without weakening
  the assertions and adds the real callback-reset/shutdown controls above.

## Remaining work

The independent critic approved the focused seven-file lifecycle-hook commit
after reviewing final source hashes, reset/shutdown faults, actual scene parity,
process cleanup, baseline NPC results and both documents. Navigation door-state retirement
needs its own exact owner hookup; explicit additional permission was requested
and remains unanswered. No NavmeshWorldService change is included here. Ordinary
tree resource/navigation unbinding must preserve durable harvest state, and
Main binding must enforce player-safe publication. Normal New Game/Continue,
physical approach/gate traversal, save/re-entry, visuals and runtime performance
remain unverified. The goal remains active, not achieved.
