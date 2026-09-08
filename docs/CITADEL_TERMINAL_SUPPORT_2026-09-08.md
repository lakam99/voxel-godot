# Citadel candidate admission and terminal support

Candidate 19's successful source is not a spawnable site. Exact source restoration
and ordinary terrain admission in `candidate19-integration-continuation-01`
rejected it for `ordinary_structure_overlap`: a generated mine at (-908,643).
That run exited naturally with code 1 and authoritative owned zero. Publication
preparation was not reached. Do not bypass that exclusion or rebuild this source.

A fresh random world, `atlas-3376622889`, was screened using Candidate 19's
envelope solely as a selection proxy. `candidate-envelope-screen-01` selected
region (-2,-2), center (-3334,-2815), recipe seed 1393179273. Proxy selection
does not prove that candidate's actual recipe or terrain admission.

## Failure and owning decision

`candidate-recipe-20` reached shops but failed `terminal_recipe_failed`.
The error watcher stopped the engine: functional code 1, forced cleanup,
overall code 126, cleanupPassed false, authoritative owned zero. This was not
a clean successful run. Its pinned input SHA256 is
`f73675b03661f5637095a906f99c0c9dea10ef5274a02a07a141ce2be0518c5c`.

`CitadelShopFailureCapture.gd` intentionally cancels the actual composer before
shop preparation, then regenerates furnishings and invokes the real shop recipe.
`candidate20-shop-capture-01` captured 4,395 parts and 178 furnishings, reproducing
`terminal_public_support_unproven` / `incomplete_rooted_support_coverage`.
Its pre-shop input SHA256 is
`314b05afeb053e6f57737c83aaff43231c200fa6d37699b874c07b1407280e66`;
failure SHA256 is
`685a05891cea5338f2c169564427f2319793c147bd8ee438de57c365c1195b9c`.

`candidate20-terminal-support-probe-01` confirms that the selected paving has
no whole-source support at (30.93,0.62,27.045). This is not a missing dependency
in the isolated closure. Ordinary physical checks pass, but the terminal's
stronger complete 25-sample rooted-support requirement does not. Four other
surfaces pass that requirement; the probe alone did not prove a valid placement.

## Change

The terminal planner checks candidate paving with the existing support-closure
authority after cheap size/distance filtering and before ordered layout search.
Only a completed `incomplete_rooted_support_coverage` result excludes a surface.
Other failures propagate explicitly. Empty IDs and invalid transformed bounds
are rejected before proof construction. At most 128 surface proofs and a
conservative 16 million source-record visits are reserved before closure calls,
including rejected surfaces; exhaustion fails without returning an earlier choice.
Existing per-closure context, dependency and validation-grid limits remain.
Rejected paving remains in the source and
obstacle geometry. Ordinary market policy, ranking, full frontage, circulation,
furnishing reservations and the final transformed-frame proof remain intact.
No paving geometry, seeded producer output or NPC/navigation code is changed.

The pinned real-component replay now selects paving segment 00 and completes
all terminal bindings, preserving the planned frame footprint and caller-owned
source/furniture. This is component evidence, not full-source or gameplay proof.

## Focused evidence

All directories below are under `artifacts/citadel-runtime-integration/`.
Run with `node tools/run-building-contract.mjs -Contract <script> -OutputDirectory
artifacts/citadel-runtime-integration/<fresh-directory> -ReportEnvironment <env>
-TimeoutSeconds <seconds>`.

| Script | Environment | Seconds | Evidence directory | Result |
|---|---|---:|---|---|
| CitadelShopFailureCapture.gd | CITADEL_SHOP_CAPTURE_REPORT | 120 | candidate20-shop-capture-01 | 10/10 diagnostic checks |
| CitadelTerminalSupportProbe.gd | CITADEL_TERMINAL_SUPPORT_REPORT | 80 | candidate20-terminal-support-probe-01 | 5/5 diagnostic checks |
| CitadelShopEligibilityReplay.gd | CITADEL_SHOP_ELIGIBILITY_REPORT | 90 | candidate20-shop-eligibility-03 | 7/7; shop preparation 2.961 seconds |
| RigidHouseholdLayoutContract.gd | VOXEL_RIGID_HOUSEHOLD_LAYOUT_REPORT | 120 | terminal-support-layout-04 | 146/146 synthetic cases |
| BuildingSupportClosureContract.gd | VOXEL_SUPPORT_CLOSURE_REPORT | 90 | terminal-support-closure-01 | 86/86 synthetic checks |
| TerminalElevatedSupportFrameContract.gd | VOXEL_TERMINAL_ELEVATED_FRAME_REPORT | 90 | terminal-support-frame-01 | 6 positive and 28 negative cases pass; legacy parity fails |

The first five rows have clean logs, natural exit 0, no forced cleanup and
authoritative owned zero. The frame suite exited naturally with code 2 and owned
zero; its direct API comparison expects identical old/new frame geometry. That
expectation remains unchanged and is not reported as passing. The changed planner
is not called by that comparison. Independent read-only review confirmed that
HEAD already documents deliberately different legacy and explicit frame geometry;
this is a pre-existing contract mismatch, not a baseline execution claim.
The initial layout run failed only the new
determinism assertion's inclusion of elapsed time; the corrected assertion uses
the existing exact stored-pose decision comparison, including transform and
clearance rectangles. All original cases remain intact.

Full candidate construction, exact terrain admission, publication preparation
and headed Main.tscn evidence remain required. No headed approval or live spawning
claim is made by these results.

Harsh read-only review returned PASS after the input and aggregate-work guards
were added. It independently verified layout04 and replay03 and approved a
focused commit followed by exactly one Candidate 21 source run for the same
seed/region/recipe, at unchanged 540/450/60-second budgets. This is not headed GO.

## Candidate 21: next honest gate

The behavior was committed as `6559488`. Command:

`node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-21 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady`

Shop preparation advanced. Source preparation failed after 62.390 seconds at
`citadel_structural_completion_failed -> facade_completion_failed ->
opening_head_completion_failed -> trimmed_panel_blocks_aperture`, house
`urban_row_03_left`. Independent physical proof was not reached. The error
watcher stopped the run: functional exit 1, forced cleanup, overall exit 126,
no timeout and authoritative owned zero. Every recorded source hash remained
unchanged. Input SHA256:
`bbf8e2e3ece371e6fb0f7447563bfe89438d3dc47ba44206b3c632354f6c565e`;
failure SHA256:
`f494841a1155ba601c2498ee08608802c185871d5651ac3435a22126d7ccb300`.

This is progress past the terminal gate, not a complete source or spawning pass.
Do not rerun unchanged: inspect the exact trimmed-panel/aperture geometry first.

The focused `CitadelOpeningHeadFailureCapture.gd` run in
`candidate21-opening-capture-01` passed eight diagnostic checks with clean natural
exit 0 and owned zero. It cancels the actual composer before structural work,
then invokes the failed house directly with an explicitly synthetic empty
furnishing policy. It reproduces the same geometry failure before furnishing
checks; it is not recipe acceptance. Capture took 43.788 seconds and the direct
house replay 0.123 seconds. Captured source SHA256:
`29b6b34ba6b4d8e0b5a7d3d2b6005ad4d601b95e33c90e3bd5f31f934a8775cc`.
The exact offending part is `urban_row_03_left_upper_facade_010`; its upper face
overlaps the opening above it by approximately one float32 step. Determine
whether that overlap originates in the original panel or retained-panel
construction before fixing geometry. Clearance tolerance remains unchanged.
