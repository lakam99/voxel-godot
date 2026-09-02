# Citadel background publication preparation

Parent `6919fbe`, branch `codex/citadel-visuals-clean`. Scope: remove the measured
CPU diagnostic replay from the existing publisher's prepared entry, retaining
the exact post-resolution source and reports. The independent critic approved
the scoped code and tests, including the baseline classification below; its
required correction of the final route error count is included in this report.
This is not ordinary-world city activation or headed acceptance.

## Implementation

`BuildingPublicationPreparation` restores accepted building/furniture snapshots
on an owned caller worker and runs the existing raised-surface geometry
diagnostics followed by physical validation. Both physical resolutions remain:
the second updates derived classification facts. No geometry, placement,
furniture, material or tree recipes are changed. No protected navigation, door,
NPC or save code is changed.

An opaque one-shot holder owns the complete post-resolution blueprint,
furnishings and diagnostic reports. Its site/source/generation binding is copied
and frozen before any callback. The publisher consumes it only for the owner's
matching current binding, without full source hashing or proof replay. Stale,
wrong-site, wrong-generation and repeated consumption reject without clearing an
already active publication. The new entry rejects structural-authority
substitution; legacy synchronous begin retains its existing override behavior
through the same diagnostic helper.

Cancellation is latched across phases and cannot yield a prepared holder.
Existing physical checkpoints are reused. Geometry-diagnostic partition,
surface, sample, foundation, junction and handoff loops now have cancellation
checkpoints. They remain source geometry diagnostics, not NPC route planning.

Scene/history/paving/masonry preparation remains on the main thread. Failed
scene preparation detaches its source/report/paving/masonry/history references
into an explicit retirement payload. The lifecycle owner must retain and dispose
of that payload safely; no ordinary runtime worker dispatcher or retirement
lifecycle is claimed by this chunk. The publisher reports diagnostic preparation,
scene preparation and subsequent publication time separately.

## Actual-source evidence

```powershell
./tools/run-building-publication-preparation-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-preparation-03
```

Frozen input: `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`;
world `atlas-1492`, region `(1,-3)`, recipe `1298433643`, scale `1.25`,
4,703 building parts and 210 furnishings. No recipe generation is repeated.

Final result **67/67**, empty stderr, natural exit 0, owned-process zero:

- Complete typed new/explicit-legacy route and physical reports match.
- Complete post-preparation typed snapshot matches the historical preflight-02
  post-begin snapshot. No geometry or physical-fact exemptions.
- Historical full report JSON values also match. This is supplementary
  presentation evidence; typed comparisons above remain required.
- Input snapshots, furnishings and access reservations remain exact.
- Actual background execution, 29 synthetic cancellation-stage controls,
  binding mutation, stale/double consumption, active-state preservation and
  failure after real jointed-paving preparation are covered.

| Measured section | Time | Limit of evidence |
| --- | --- | --- |
| Prior main-thread begin, preflight-01 | 18,871.290 ms | Existing instrumented baseline |
| New worker diagnostic preparation | 18,696.120 ms | Same computation off game thread, not faster generation |
| New main-thread prepared begin | 17.321 ms | Whole call; still above a 4 ms slice / 8 ms atomic target |
| New scene preparation inside begin | 17.301 ms | Masonry still `pending_budget`; no parts published |
| Largest observed worker callback gap | 70.852 ms | Observation, not a universal cancellation bound |
| Actual cancellation test total | 192.052 ms | Includes restoration and work before the third support checkpoint, not just response latency |

The earlier preparation-01 failed 3 of 63 checks and is retained. Two compared
raw reserialized JSON text across native and parsed numeric representations;
the corrected checks compare all JSON values, without deleting fields. The
third incorrectly expected jointed-paving ownership from a fixture with no
joint declaration. The replacement constructs real jointed paving and injects
a synthetic rejection at the following masonry stage. Production behavior was
unchanged between these two runs.

Preparation-02 passed 64/64. Final preparation-03 additionally verifies callback
release and complete blueprint preservation after successful cleanup. Review
restored the public builder constant used by existing visual-preparation code,
changed clearing of the aliased paving-treatment array into relinquishing the
alias, and transferred/reset the progress callback during failed preparation.
These are the final production changes covered by preparation-03.

Both runs' main-begin timings exclude test-only snapshot inspection and teardown.
They are not whole-frame measurements. Reports, logs, source hashes and owned
watchdogs reside in their fresh output directories. No screenshots are claimed.

## Focused regression evidence

```powershell
./tools/run-building-route-diagnostic-cancellation-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/route-diagnostic-cancellation-01
./tools/run-building-validation-cancellation-contract.ps1 -AuthorizeLaunch -OutputDirectory artifacts/citadel-runtime-integration/publication-physical-cancellation-01
./tools/run-building-publication-ownership-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-ownership-01
```

New geometry-diagnostic controls pass **122/122**: four tiny fixtures, exact
typed omitted/empty/true-callback report and post-snapshot comparisons, 14
first/repeated/terminal cancellation cases, and no callback or source mutation
after rejection. Existing physical-validation cancellation controls pass
**465/465**. Additional ownership controls pass **15/15**: rejection after the
real masonry initializer retains its real blueprint in the retirement payload,
detaches the publisher aliases, and preserves the direct legacy publisher's
separate-authority call. A nonempty synthetic paving-treatment array survives
clear unchanged. These fixtures are not masonry mesh/publication acceptance.
All finish naturally with empty stderr and zero owned processes.

NPC regression uses the same baseline scene, seed `atlas-1492`, time mode `both`,
`--fixed-fps 60`, and process-owning watchdog with a 45-second cap. Full engine
commands are in each `watchdog.json`; seed/suite/run-token are in `report.json`.
The scene is `res://scenes/testing/npc/NpcAutonomyTest.tscn`. Output directories
are `publication-preparation-npc-{contract,motor,nav_world,route}-02` under the
same integration artifact root, each with report/progress/traces/logs/watchdog.

Assertion results match the committed terrain-admission checkpoint: 84/84
contract, 48/48 motor, 84/84 nav-world, and 130/132 route. Final engine error
header counts are respectively 0, 4, 4, **250**, versus 244 for baseline route.
The same two diagnostic home collision-lattice detour failures remain. Exact
stderr-block comparison found only one existing stack's frequency changed,
26 to 32: `role_leash_radius_cells` -> `cell_allowed_area` ->
`cell_bridge_search_pathable` -> `_exact_collision_lattice_search` ->
`test_route_home_collision_lattice_exact_detour`. Every other stack and count
matches. Both modes made five visits rather than four under the unchanged
32,000-microsecond time budget, with four rather than three static rejections.
The diagnostic's existing timed expansion loop accounts for the extra repeated
off-tree probes; this is not a new error type or a repaired NPC baseline.
Protected implementation/test files have no diff. The accepted baseline
exception remains necessary. All four owned process jobs empty naturally.
The earlier `-01` quartet had identical assertion results and exactly 244 route
error headers before the final cleanup fixes; it is not substituted for `-02`.

## Remaining before a spawned city

Wire owned preparation into ordinary StructureSystem lifecycle with revision
checks and retirement; budget remaining history/masonry/part/finish work;
publish preserved furniture and shared trees; finish shared-door registration
and symmetric cleanup. Explicit protected shared-door cleanup authorization is
still pending. Main/New Game approach, real gate use, visual fidelity,
unload/re-entry, save/Continue and runtime traversal performance remain unproven.
The physical-publication bypass remains explicit and is not relabeled passed.
