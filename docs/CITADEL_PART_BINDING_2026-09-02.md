# Exact part bindings without repeated recipe copies

## Scope

Started at clean `9737a08`, `codex/citadel-visuals-clean`. The preceding service
replay measured a 24.972 ms service maximum, including final mutable source
checks. The independent critic approved targeting the repeated snapshot-copy
cost, not dropping validation or retaining a proof across yields.

`BuildingPartBinding.encode` serializes the exact original snapshot key order,
types and live values, but borrows the recipe only during the synchronous encode
instead of first deep-copying it. Only the exact `BuildingPart` script takes
this path. Inherited, overridden and duck-typed implementations still dispatch
their original `snapshot()` method. No cache, retained reference, normalization,
mutation, yield or new callback is introduced.

Two aperture source comparisons and one ordinary-paving source comparison use
the helper. Initial owned snapshots/geometry copies, source membership/order,
declarations, peer geometry, history, context and final validation frequency are
unchanged. Recipes, furniture, trees, NPCs, navigation, doors and save format are
not changed. This does not enable normal-world spawning or authorize a headed run.

Main owned the consumer changes, scene-job mutation controls and evidence.
The worker owned only the helper and its independent oracle contract. Both read
AGENTS.md and MANIFESTO.md; the critic is independently read-only.

## Binding and mutation evidence

Commands below run from this worktree. Each directory is beneath
`artifacts/citadel-runtime-integration/`, with a completed report, separate
parse/run logs and owned-process watchdog summaries.

```powershell
./tools/run-building-contract.ps1 -Contract BuildingPartBindingContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-binding-contract-01 -ReportEnvironment BUILDING_PART_BINDING_OUTPUT
./tools/run-building-contract.ps1 -Contract BuildingScenePublicationJobContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-binding-job-02 -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory
./tools/run-building-contract.ps1 -Contract MasonryAperturePublicationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-binding-aperture-01 -ReportEnvironment VOXEL_MASONRY_PUBLICATION_REPORT
./tools/run-building-contract.ps1 -Contract PavingFootingPublisherContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-binding-paving-01 -ReportEnvironment VOXEL_PAVING_FOOTING_PUBLISHER_REPORT
./tools/run-building-contract.ps1 -Contract BuildingStaticBatchFlushContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-binding-flush-01 -ReportEnvironment BUILDING_STATIC_FLUSH_REPORT
```

- Binding oracle: **103/103**, using the frozen original snapshot body and a
  hash-checked original `BuildingPart.gd`. Nested values, typed/packed containers,
  shared aliases, field and recipe mutations, dictionary order, frozen inputs,
  object IDs, subclass overrides and duck-typed dispatch retain the tested bytes.
  Helper SHA256: `6842968c41a54987eb8587c20352eaabb7f6c524e8f9b156ea0b04ee9c3ef154`.
- Scene-job controls: **376/376**, including all prior 328 checks. Six new cases
  change a nested value, integer to float, or dictionary order during pending
  paving and after paving completes but before finalization begins. They require
  the exact binding-related failure, unchanged metadata presence/identity, no
  furniture/tree progression, and owned retirement. These cases do not inject
  mutations during a yielded metadata-copy phase.
- Unchanged aperture **185/185**, paving/footing **139/139**, static flush
  **131/131**. The pre-edit aperture/paving runs also passed in
  `scene-publication-binding-baseline-{aperture,paving}-01`.

The first new scene-job run, `scene-publication-binding-job-01`, is rejected
evidence: the test queried absent metadata with a null default, which Godot
reports as an error. The watchdog stopped it (exit 126, forced cleanup, owned
zero). The test now checks presence before reading; `job-02` is the clean rerun.
No production fix was needed for that test error.

Godot's raw NodePath encoder has previously documented unwritten padding.
The oracle observed zero mismatches in 128 samples here and separately proved
the unwritten bytes with poisoned storage. This is not a universal raw-byte
stability guarantee for NodePath. Production still uses the same raw encoder;
it does not switch to the distinct canonical static-record binding format.
Cycles were already unsupported and are not made safe by this optimization.

The microbenchmark alternates old/new encoding on the sixteen largest raw
historical recipes, which happened to be roofs, not prepared aperture requests.
Median per 512 calls was 5.381 ms versus 4.266 ms. Isolation from other processes
was not verified: this is indicative binding-cost evidence, not a target-stage,
gameplay, source-generation or hard-budget result.

## Actual replay and remaining acceptance

```powershell
./tools/run-building-contract.ps1 -Contract CitadelServiceSceneContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-binding-actual-01 -ReportEnvironment CITADEL_SERVICE_SCENE_OUTPUT -OutputIsDirectory -TimeoutSeconds 210
```

The actual replay passes **24/24**, using the existing hash-verified input
`actual-site-source-05/result.bin` (world `atlas-1492`, region `(1,-3)`, recipe
`1298433643`, scale `1.25`). It does not regenerate that source. All nineteen
recorded source-file hashes match the final files. The unchanged auditor checks
3,179 collision parts/world transforms, 210 furnishing bodies, twenty qualified
door IDs, one physics probe, four production-queue trees and clean retirement.
Door IDs are not live door registration; the physics probe is not player traversal.

The available scene record remains byte-identical, SHA256
`1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
Headless MultiMesh records contain placeholders, so this is not GPU or visual
acceptance. There are no screenshots in this checkpoint.

Compared with the preceding `scene-publication-service-actual-02` replay:

| Measured section | Before | After |
|---|---:|---:|
| Maximum service advance | 24.972 ms | 17.731 ms |
| Maximum scene-job atomic work | 24.899 ms | 17.659 ms |
| Aperture validation, 18 calls total | 137.890 ms | 105.057 ms |
| Aperture validation maximum | 11.675 ms | 6.382 ms |
| Completed-paving validation, 18 calls total | 48.676 ms | 36.288 ms |
| Completed-paving validation maximum | 4.967 ms | 3.817 ms |
| Static-flush commit maximum | 13.844 ms | 11.414 ms |
| Preparation plus construction | 49.834 s | 49.518 s |

The nested measurements overlap; do not sum their maxima. These are observations
from sequential replay runs, not universal bounds or a statistically established
loading-throughput improvement. End-to-end time excludes input loading and cold
source generation. Strict slice/atomic budgets still **fail**, including remaining
building and finalization operations above 8 ms. Validation call counts were not
reduced or cached.

## NPC preservation and process cleanup

Final directories: `scene-publication-binding-npc-{contract,motor,nav_world,route}-01`
beneath `artifacts/citadel-runtime-integration/`. The owned scene watchdog runs
`res://scenes/testing/npc/NpcAutonomyTest.tscn` headlessly with `--fixed-fps 60`,
45-second cap, seed `atlas-1492`, time mode `both`, empty case filter and
`VOXEL_PLAYTEST=1`. Both seed variables match; report/progress/trace/screenshot/
userdata directories and run tokens are fresh. Watchdogs record exact commands.

Results: **84/84, 48/48, 84/84, 130/132**. All four stderr files match the
corresponding `scene-publication-service-npc-*-02` logs byte-for-byte. The route
suite retains exactly the diagnostic exact-detour failure in day/night, four
visits against 32,000 microseconds, and 244 error headers. This is preservation
of the explicitly deferred broken baseline, not NPC acceptance.

All accepted functional/oracle runs have clean parse/run logs and natural exit
zero. NPC natural exits are 0/0/0/1 with the recorded baseline errors. Every
accepted watchdog proves zero owned processes without forced cleanup; rejected
job01 separately records its forced stop above. The final process inventory has
no Godot processes. No headed or visual launch occurred.

The independent critic approved this focused eight-file binding optimization
after reviewing encoding compatibility, mutation guards, final reports, all
nineteen source hashes, exact scene parity, the NPC baseline exception, timing
limits and process cleanup. It did not approve budget compliance, spawning or
headed/GPU acceptance. Ordinary
activation still requires authorized shared-door cleanup and verified player-safe
publication, followed by real Main/New Game/Continue, approach, gate traversal,
save/re-entry, visual and runtime-performance evidence. A binding improvement
does not satisfy those requirements.
