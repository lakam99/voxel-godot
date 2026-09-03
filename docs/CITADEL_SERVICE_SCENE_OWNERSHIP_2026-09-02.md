# Service-owned citadel scene lifecycle

## Scope and remaining boundary

Started from clean `1db7099` on `codex/citadel-visuals-clean`. Main changed the
existing `CitadelPublicationService` and added the accepted-source service fixture.
The worker owned only `CitadelSceneLifecycleContract.gd`. Existing builders,
recipes, furniture, tree generation/publication, NPCs, navigation, shared doors,
save format, Main startup and terrain code are unchanged.

The service now owns prepared-to-constructing-to-constructed-to-retiring jobs.
This is **not ordinary-play activation**. Production has not bound a scene owner:
it remains explicitly pending with `scene_lifecycle_capability_missing`. The
independent critic approved implementing this ownership boundary in a player-free
host, not enabling visible partial cities. Door cleanup permission is unanswered;
permission alone will not substitute for implemented, verified lifecycle and
player-safe admission. No headed run occurred, and the spawning goal is open.

## Implementation

- One prepared holder is consumed by the existing `BuildingScenePublicationJob`.
  The service retains its exact admission binding/profile and owns its scene until
  retirement. No second builder or scene/source authority was added.
- World configuration serial, site/source/generation binding, root identity and
  callback receiver identity fence publication. Root removal, movement or
  reparenting invalidates both partially built and completed scenes, including
  during drain-only calls. The legitimate pre-root `building_begin` phase is
  exempt from the root-existence check, not from binding/owner validation.
- Prepared, constructing, constructed and retiring ownership prevents duplicate
  source reconstruction. A genuinely evicted, unowned re-entry requests ordinary
  deterministic reconstruction. Scene roots are not a durable save representation.
- One requested 2,500-microsecond service budget is shared among jobs; requests
  outside 1–4,000 are rejected. Constructing sites rotate fairly; retirement also
  receives work. This does not make existing atomic overruns meet the budget.
- A drain-only call pauses current, still-valid construction without interpreting
  an absent observer sample as departure. Retirement continues. Reset, source
  invalidation, closing or owner loss cancels scene ownership independently of
  dispatch availability. Explicit empty demand with dispatch enabled is departure.
- Nested advance is rejected. A reset/close inside a tree callback cannot publish
  stale completion/failure into its replacement configuration. A retiring owner
  remains visible during callbacks, preventing premature root rebinding.
- Scene nodes are freed incrementally on main through the unchanged job. Detached
  payloads and retained entry data go to the existing preparation worker for
  disposal. Site ownership persists through both pending and submitted disposal
  batches until worker completion/join, preventing premature reconstruction or
  owner rebinding. Tree retirement callbacks run before freeing registered tree bodies.
- `scene_ready` means construction finished, not playable readiness. Both
  `publicationReady` and `gameplayReady` remain false; no door registration or
  fabricated capability is performed by these fixtures.

## Synthetic lifecycle evidence

```powershell
./tools/run-building-contract.ps1 -Contract CitadelSceneLifecycleContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-service-scenes-02 -ReportEnvironment CITADEL_SCENE_LIFECYCLE_OUTPUT -TimeoutSeconds 90
```

**267/267**, 1.706 seconds. Real Admission, preparation worker, scene job and
publishers consume synthetic tiny source data. Tree acknowledgements and callback
faults are explicitly synthetic. Coverage includes capability denial, current
owner idempotence, different-owner rejection, source eviction/deduplication,
departure/re-entry, same/different-seed reset, stale revision and late worker
results, root damage, fair progress, shutdown, callback reset/shutdown, nested
advance rejection and weak-reference release after retirement. This is not real
source reconstruction, live trees, doors, gameplay, GPU or hard-budget evidence.

The critic rejected the first 181-check revision: publishing-root damage was
not invalidated while paused, and retirement ownership ended before worker
disposal. The final controls retain those 181 checks and add publishing-root
move/reparent/free, parent movement, legitimate pre-root absence, and a real
semaphore-gated worker disposal. Re-entry and rebinding remain blocked after
node cleanup and payload handoff, then become available after disposal/join.
The tested service SHA256 is
`91e8fe9501f60788936af5ffe1a24fcc8bbd71cf3d8f2d423b595eaf37dccd88`.
Earlier reports remain historical evidence, not proof of these repaired intervals.

## Accepted-source service construction

```powershell
./tools/run-building-contract.ps1 -Contract CitadelServiceSceneContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-service-actual-02 -ReportEnvironment CITADEL_SERVICE_SCENE_OUTPUT -OutputIsDirectory -TimeoutSeconds 210
```

**24/24**. Seed `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`, scale
`1.25`; input is the existing `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.
The fixture checks this input hash before injecting its receipt through real
Admission. This is accepted-source evidence, not fresh source generation.

Expected sequence: Admission → service-owned preparation → same real scene job
and publishers/shared tree queue → constructed → departure → existing loading
maintenance drains nodes/payloads → ordinary combined worker shutdown. No direct
fixture-created scene job is used. Main boot and the player are suppressed.

Actual evidence:

- One dispatch and one scene job; prepared-holder ownership is consumed once.
- Eviction during owned construction does not request a duplicate source.
- The unchanged scene auditor verifies all 3,179 blocking shapes and their world
  transforms, 210 furnishing bodies, 20 site-qualified door IDs, translated-parent
  origin application and real physics registration. It records one physics probe
  hit, not comprehensive player traversal or terrain continuity.
- Four trees use the real production publication queue. The player-free host has
  no NPC registry; a retirement observer records one before-free callback for each
  tree. This is not evidence of production navigation unregister behavior.
- Departure removes all scene nodes. Job/publisher/unit-mesh weak references are
  released; both source/preparation workers and the shared tree queue drain.
- All 18 recorded source-file hashes remain unchanged throughout the run.

The complete available scene record is byte-identical to the prior direct-job
replay, SHA256
`1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
Headless MultiMesh readback contains placeholders; this is not a screenshot or
GPU fidelity claim. There are no headed captures in this checkpoint.

Preparation plus construction is **49.834 seconds**, excluding input-file loading
and fresh multi-minute source generation. It is not normal-world startup timing.
Service maximum advance is **24.972 ms**, maximum scene-step 24.917 ms and scene
job atomic maximum 24.899 ms. Existing publication/finalization overruns remain;
no hard slice/atomic or visible-smoothness acceptance is claimed.

## Regression and process evidence

```powershell
./tools/run-citadel-publication-service-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-service-scene-ownership-regression-03
```

The unchanged preparation/runtime-maintenance suite passes **69/69** on final
service code. Earlier `...regression-01` and `...regression-02` passed before
the critic-required interval repairs; `...regression-03` is the final
source-bound regression evidence.

The same NPC owned-watchdog scene was run headlessly with `--fixed-fps 60`,
45-second cap, seed `atlas-1492`, time mode `both`, empty case filter and
`VOXEL_PLAYTEST=1`. Suite directories are
`scene-publication-service-npc-{contract,motor,nav_world,route}-02/` beneath
`artifacts/citadel-runtime-integration/`, with fresh report/progress/trace/
screenshot/userdata paths. Exact scene commands are in the watchdogs; both test
seed variables use `atlas-1492` and environment setup matches the roof report.

Results remain **84/84, 48/48, 84/84, 130/132**. All four stderr files match
the corresponding pre-repair `...-01` runs byte-for-byte. Route again fails the known exact-detour case
in both time modes at its 32,000-microsecond budget, now four visits in each mode.
Its stderr is byte-exact to `scene-publication-worker-masonry-npc-route-01`:
244 headers, rather than the roof run's 247. Unique error lines are unchanged.
This preserves the explicitly accepted broken baseline, not NPC health.

Every accepted run has clean owned shutdown with authoritative zero membership
and no forced cleanup. Functional/source fixtures have clean parse/run logs and
natural exit zero. The acknowledged NPC route suite naturally exits one and
retains its known engine errors; the other NPC suites exit zero. Reports, progress
(where emitted), separate logs and watchdogs are retained in the directories
above. No failed Godot process is intentionally left running.

The final accepted-source replay and synthetic contract bind the same final
service hash above; all 18 accepted-source hashes were independently rechecked
against the current files after execution. The full scene record SHA256 matches
both the preceding service replay and the recorded direct-job baseline. No Godot
processes remained in the final read-only process inventory.

The independent critic approved this focused five-file ownership commit after
reviewing the repaired lifecycle, final source-bound reports, unchanged scene
record, baseline NPC exception, documentation and process cleanup. Budget,
ordinary activation, spawning and headed/GPU acceptance remain explicitly
unapproved. Next is complete shared-door
lifecycle support (only after express permission), player-safe production admission
and ordinary owner binding, followed by actual Main/New Game/Continue, approach,
gate traversal, save/re-entry, visual and performance acceptance. A constructed
scene or a green service fixture cannot satisfy those remaining requirements.
