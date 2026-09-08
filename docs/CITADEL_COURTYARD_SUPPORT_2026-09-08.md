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
declarations, material, collision, height and geometry. Rectangle subtraction
checks coverage of the house foundation footprint without counting overlaps
twice or concealing holes behind a merged bounding box. Supporting courtyard
parts remain separate from house membership. Unbound and foreign parts remain
obstacles, and failure evidence uses the same exemption set as clearance.

Cache sanitation, part IDs, positions, dimensions, materials, collision flags,
house placement, furniture, doors, tree generation and navigation are unchanged.
The declaration and receipts authorize clearance underlay, not physical success.
The full source/physical and runtime integration gates still apply.

## Focused evidence

- `node tools/run-building-contract.mjs -Contract CitadelCourtyardUnderlayDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/courtyard-underlay-diagnostic-03 -ReportEnvironment CITADEL_UNDERLAY_DIAGNOSTIC_REPORT -TimeoutSeconds 60`: 38/38.
- `node tools/run-building-contract.mjs -Contract CivicHouseInfillContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-courtyard-support-05 -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -TimeoutSeconds 60`: 260/260.

Both runs exited naturally, with clean engine logs and authoritative owned-process
zero. Reports live at the stated output directories' report.json; the runner also
records source hashes and watchdog evidence.

The civic contract covers actual producer subsets, deterministic receipts,
cache sanitation, foreign/mixed owners, stale or substituted supports, changed
geometry/material/collision, unbound geometry, coverage gaps, cancellation and
immutability. It does not run complete candidate construction or the real game.
Review found and corrected inconsistent producer recognition and an ownership
check that considered only the current house. One predicate now governs
planning, binding and terminal resolution. Resolution rejects membership in
any house, including an adversarial house created through the actual producer.
The earlier archived civic-clearance diagnostic predates support receipts; its
historical report remains evidence of the earlier stage, not current acceptance.

## Remaining gates

Harsh read-only patch review returned PASS after both findings were corrected;
the critic independently verified support05's 260 checks and clean owned zero.
This clears the focused commit gate only, not headed readiness.
Next run exactly one fresh candidate-source diagnostic at the handoff's unchanged
budgets. Source/integration readiness and explicit critic GO must precede headed
candidate testing. Actual Main.tscn spawning, terrain, collision, structure,
trees, doors, furniture and screenshots remain unverified by this change.
