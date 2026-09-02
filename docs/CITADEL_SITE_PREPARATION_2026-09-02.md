# Source-only citadel site preparation

Independent critic approved this source-only boundary on 2026-09-02. It is not
runtime activation, a valid full candidate, or permission for headed testing.

`CitadelSitePreparation.prepare` binds the real site field's recipe seed, land
biome and stable site identity to the shared recipe. It derives terrain input
from the actual prepared building/furniture manifest, not a fixed reference
citadel. Preparation never creates scene nodes, trees, residents, navigation,
terrain meshes or save state. Both terrain/publication readiness remain false.

`prepare_terrain` is a separately testable source operation. It preserves raw
ordinary structure candidates, town reservations, all visual bounds, actual
support/clearance masks, and the site's disjoint region bounds. It surveys the
entire prospective envelope, chooses a cell-quantized minimax cut/fill plane,
and expands/resurveys the apron until the existing blend-gradient contribution
bound is met or the declared maximum is exceeded. This bound does not certify
native mesh slope or player traversal. Visual-only bounds reserve space without
turning into a blanket terrain plateau. Oversized geometry is rejected, never
clipped, shrunk, relocated or replaced by a known seed.

Inputs use ordinary region size/spawn policy from the future caller. Immutable
terrain-profile admission and the native streaming boundary remain separate.
There is no live caller, worker lifecycle or source cache yet. Long synchronous
recipe stages are explicitly worker-only and are NOT acceptable main-frame work.

## Cancellation API

Shared `CitadelRecipePreparation.prepare` accepts an optional continue-stage
callback. The default drains the same builder/composer sequence. False cancels
at the next callback boundary; cancellation is tracked through nested composer
failure and returns only `ready=false, reason=cancelled`. Site propagates that
status without exposing blueprint, furniture, interior or profile data.
Builder diagnostics are retained when an actual build fails. Cancellation does
not yet interrupt a long builder or structural-completion operation internally.

## Evidence

All paths below are under `artifacts/citadel-runtime-integration/`; exact Godot
invocations and process ownership are in each `watchdog.json`. All are headless.

- `site-preparation-contract-03/`: 14/14, 26.781 seconds, exit 0, clean logs and
  zero owned processes. Run `scripts/testing/buildings/CitadelSitePreparationContract.gd`
  via `tools/run-godot-scene-watchdog.ps1 -Headless -Scene '--script'`, with fresh
  absolute `VOXEL_CITADEL_SITE_PREPARATION_REPORT` and
  `VOXEL_CITADEL_SITE_PREPARATION_PROGRESS` paths. This deliberately uses the
  immutable reviewed reference's geometry for admission diagnostics across real
  candidate locations. It is NOT evidence that the accepted location's own
  recipe succeeds. Tests preserve roots, volume support, exact repeated profile,
  rejection of forged candidates and prework cancellation. Initial failed
  center-elevation attempt 01 is retained; 02 predates the final support mask.
- `preparation-cancellation-contract-02/`: 22/22, 24.461 seconds, clean logs,
  natural exit 0 and owned-process zero. Reproduce with
  `./artifacts/citadel-runtime-integration/cancellation-sidecar-tools-01/run.ps1 -RunName <fresh-name>`.
  Source entry cancellation, real Site survey followed by Source cancellation,
  and real Builder followed by nested Composer cancellation. Correct statuses,
  no later callbacks or recursively returned objects/source artifacts, caller
  input unchanged, all recorded source hashes stable. Attempt 01 is a retained
  test-only parse failure. This is boundary cancellation, NOT latency acceptance.
- `source-parity-05/profile.gd`: full shared source preparation matches the
  immutable 237207443 reference byte-for-byte, 8/8 checks, 4,649 building parts,
  146 furnishings, 6,748,364 handoff bytes and all 82 source hashes stable.
  Natural exit 0, empty stderr, zero owned processes. Details and limitations in
  `CITADEL_SUPPORT_CONTEXT_2026-09-02.md` (support repair reviewed separately).
- `actual-site-source-03/run.gd`: actual `atlas-1492`, region `(1,-3)`, recipe
  1298433643, plains, scale 1.25. Its own builder and shops complete, but final
  structural completion FAILS on paving segments 02/04/80 and the civic east
  sign arm after 319.453 seconds. No prepared blueprint/profile returned. Stable
  dependency hashes, structured report/progress/result binary, natural exit 1,
  zero owned processes. This is a failed full-candidate test, not a successful
  landmark or a reason to substitute the frozen reference into the game.

All runs use bounded owned watchdogs. Screenshots are neither required nor
claimed for this source-only evidence. No full physical-gate pass for a new
candidate, final site density, native collision, live Main/New Game spawning,
trees/doors, save/Continue or runtime performance acceptance is established.
