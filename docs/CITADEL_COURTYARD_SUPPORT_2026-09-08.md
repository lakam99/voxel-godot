# Citadel courtyard support and civic clearance

Worktree: voxel-biome-world-godot-citadel-visuals. Branch: codex/citadel-visuals-clean.
Runner migration baseline: d2f5f63. NPC/navigation work remains explicitly deferred.

## Recorded failure and diagnosis

Recipe 17 for world seed atlas-30895044, region (-1,0), recipe seed 541151883
failed terminal east-house clearance on four courtyard foundation segments.
Both pinned binary hashes still match the handoff.

The producer emits physicalRoot, but structural completion deliberately removes
derived physical caches before returning its snapshot. Civic clearance required
that same cached flag to recognize courtyard underlay. The source diagnostic
reproduces all four terminal records byte-for-byte by applying actual cache
sanitation to the pinned pre-structural source. Their union covers the reported
house envelope at Y 0..0.62. This does not by itself prove physical bearing.

## Change

Actual segmented courtyard foundations now carry a durable producer declaration.
The civic planner records owner-specific support receipts for its rebuilt house
poses, including room/door/foundation identity and exact participating foundation
geometry. Terrace reconciliation returns the receipts from its verified source.

Terminal clearance validates each house's receipt against current membership,
declarations, material, collision, height and geometry. The house must supply
its own colliding, upright ground-reaching slab at the exact shared base height;
the existing blueprint physical authority independently recognizes that root.
Courtyard
parts remain separate from house membership. Unbound and foreign parts remain
obstacles, and failure evidence uses the same exemption set as clearance.

Cache sanitation, part IDs, positions, dimensions, materials, collision flags,
house placement, furniture, doors, tree generation and navigation are unchanged.
The declaration and receipts authorize clearance underlay, not physical success.
The full source/physical and runtime integration gates still apply.

## Focused evidence

- `node tools/run-building-contract.mjs -Contract CitadelCourtyardUnderlayDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/courtyard-underlay-diagnostic-05 -ReportEnvironment CITADEL_UNDERLAY_DIAGNOSTIC_REPORT -TimeoutSeconds 60`: 40/40.
- `node tools/run-building-contract.mjs -Contract CivicHouseInfillContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-courtyard-support-06 -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -TimeoutSeconds 60`: 266/266.

Both runs exited naturally, with clean engine logs and authoritative owned-process
zero. Reports live at the stated output directories' report.json; the runner also
records source hashes and watchdog evidence.

The civic contract covers actual producer subsets, deterministic receipts,
cache sanitation, foreign/mixed owners, stale or substituted supports, changed
geometry/material/collision, unbound geometry, coverage gaps, cancellation and
immutability. It does not run complete candidate construction or the real game.
Coverage-gap checks are geometric observations only. Actual-producer partial
courtyard coverage is accepted only for an independently grounded house;
elevated, tilted, noncolliding and wrong-thickness bases cannot mint receipts,
including when a stale physicalRoot cache claims otherwise.
Review found and corrected inconsistent producer recognition and an ownership
check that considered only the current house. One predicate now governs
planning, binding and terminal resolution. Resolution rejects membership in
any house, including an adversarial house created through the actual producer.
The earlier archived civic-clearance diagnostic predates support receipts; its
historical report remains evidence of the earlier stage, not current acceptance.

## Candidate 18 and shared-base correction

Harsh read-only patch review returned PASS after both findings were corrected;
the critic independently verified support05's 260 checks and clean owned zero.
That version was committed as a0f9d3e.

`node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-18 -Seed atlas-30895044 -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -ExpectReady`
then failed civic-quarter planning after 15.015 seconds. It exited naturally
with code 1, no timeout or forced cleanup, clean logs, authoritative owned zero,
and no changed/unreadable source hashes. Independent physical proof was not reached.

The failure exposed an overconstraint introduced by the new support resolver:
it required courtyard slabs to cover the entire house foundation. Pinned source
inspection proves that the wall house already supplies its own Y0..0.62 slab,
while the courtyard's egress cut leaves an XZ rectangle at (37.44637,-5.181999),
size (0.347462,3.82), beneath that house. Both civic foundations are geometrically
grounded by BuildingBlueprint.is_grounded_structural_root, independently of
cached flags. Requiring a second slab across that cut is not a physical contract.

The correction restricts the exemption to overlapping, independently grounded
shared bases. It does not admit elevated houses or relax clearance for foreign
structures. Union subtraction remains a test-only observation tool; full physical
validation remains the production authority. No generated geometry changed.

## Remaining gates

The grounded-base correction received a new critic PASS, independently confirming
support06's 266 checks, underlay-diagnostic05's 40 checks and both clean owned exits.
The correction was committed as 1c206e5.

## Candidate 19 and fresh integration evidence

`node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-19 -Seed atlas-30895044 -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -ExpectReady`
passed at unchanged 540/450/60-second watchdog/source/independent-proof budgets.
Source preparation took 291.631 seconds; independent physical validation took
9.249 seconds and checked all 4,486 parts with zero violations. The source retains
154 furniture parts. Dedicated furniture validation was not performed by this
diagnostic. Source SHA256:
`53942402985c5282b28f7e7a3e4f4f020e801292837485ebdee419ea9cd27059`.
The report, verification and source-hash audit agree: natural exit 0, clean logs,
no timeout or forced cleanup, authoritative owned zero and unchanged sources.

Eight fresh integration contracts also passed. For each row, run
`node tools/run-citadel-<contract>-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/<directory>`.
Evidence is each directory's report.json and watchdog.json.

| Contract | Directory | Checks | Scope |
|---|---|---:|---|
| site-selection | candidate19-site-selection-01 | 120 | Source/service; fixed and fresh random seeds |
| site-build-queue | candidate19-site-build-queue-01 | 206 | Synthetic threaded queue |
| terrain-admission | terrain-admission-candidate19-01 | 124 | Synthetic service and owned worker |
| publication-service | publication-service-candidate19-01 | 69 | Historical source, direct service and synthetic lifecycle |
| terrain-bootstrap | terrain-bootstrap-candidate19-01 | 28 | Synthetic MainCore orchestration |
| native-admission | native-admission-candidate19-01 | 64 | Installed native backend, synthetic input |
| profile-snapshot | profile-snapshot-candidate19-01 | 27 | Historical profile, real WGS/context/native buffer service |
| town-inputs | town-inputs-candidate19-01 | 52 | Synthetic startup dependencies, actual reservation/admission context |

All 690 checks passed; all eight watchdogs report natural exit 0, no forced cleanup
or timeout, and authoritative owned zero. Site selection used fresh seed
`atlas-site-53d84b9668a7419fac85968742c106c9`, its density-secondary derivative,
and fixed atlas-1492. An initial terrain-admission command used a rejected output
directory prefix and launched no engine; the corrected command is recorded above.

None of these contracts proves current candidate rendering or live gameplay.
Explicit critic GO must precede headed candidate testing. Actual Main.tscn
spawning, terrain, collision, structure, trees, doors, furniture and screenshots
remain unverified by these source/service results.
