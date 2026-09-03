# Citadel window-bearing spacing — 2026-09-03

## Scope and baseline

Worktree: `voxel-biome-world-godot-citadel-visuals`; branch
`codex/citadel-visuals-clean`; starting commit `d9f6570`.
Initial changes were the untracked entry-capture/eligibility diagnostics and the
delegated, unwired bunting helper/contract. No reset, cleanup, merge or protected
NPC/navigation/routing/movement edits were performed.

Candidate: world `atlas-30895044`, region `(-1,0)`, center `(-796,659)`, recipe
seed `541151883`, forest, scale `1.25`. Site identity:
`citadel-site-v1:14:atlas-30895044:-1,0`.

Recipe13 finished ordinary source construction in 276.600785 seconds, but its
terminal structural proof rejected 37 IDs: 24 facade panels, four lintels, eight
door brackets, one bunting rope. It was not a source or gameplay pass. Its
structured error caused an immediate owned-job stop; zero owned processes was
proven. That was forced cleanup, not a natural exit.

## Owning defect and change

Narrow street-house window spacing did not reserve enough masonry beside the
door for the existing lower-bearing recipe. The first actual proposal showed
the original gravity patch crossing protected room access. Moving only an added
support could not repair that conflict without weakening the existing proof.

`StreetHouseOpeningLayout` now owns shared opening/access dimensions, the existing
stone-course calculation and window offset. It derives space from the ordinary
door publisher's per-primitive swept bounds, restricted to the complete bearing
assembly's height. Touching outward-rounded bounds remain included. Both corbels
are constructed inside the sill Y strip; focused tests check real connection
placements at five house heights.

The offset reserves both padded corbel socket domains and the original gravity
patch with the existing 0.05 m physical-contact inset plus construction room.
It does not change contact thresholds, door geometry, access bounds or admission.
The final default minimum offset is 2.0375001192092896 m; minimum house depth is
5.915000238418579 m. Already sufficient offsets remain unchanged. Row packing
uses the maximum required minimum across both actual house heights. Houses too
shallow for their opening layout reject before emitting geometry.

The same offset positions apertures, glass and the window box. Existing sill
plants/candles follow their windows through the unchanged interior program.
`ConstructionBearingDimensions` shares existing support dimensions with the
lower-bearing and connection recipes; their values and proof rules are unchanged.

Civic preview/rebuild callbacks now propagate an explicit producer `false`,
including when a producer emitted partial geometry first. Legacy void callbacks
retain their existing behavior. No failed preview is accepted by silently using
its partial records.

## Source preservation

Capture01 is the real pre-structural input before the spacing edit; capture03 is
the regenerated input after the final dimensional edit. Both have 4,224 parts,
154 furnishing records and 154 furnishing obstacles. Their room/access records
are byte-identical.

The exact source comparison permits only 176 facade panels changing Z position/
span, 24 windows changing Z, and eight window boxes changing Z. All other part
fields and records remain exact, including roofs, foundations, doors, materials,
rotations and building footprints. This is source preservation, not visual proof.

The policy comparison independently replays the actual interior furnishing and
obstacle producers on both captures. Exactly 48 window-sill plants/candles and
their 48 obstacles follow the 24 changed windows; their sizes, materials,
rotations, variation and unrelated fields remain exact. All other policy bytes
and ordering remain unchanged. No old-plus-delta float approximation is used.
Nine deliberately corrupted policy variants must fail the relevant guards.

Capture hashes:

- capture01 `input.bin`: `796a2375d8d6209d3a779f73d18ad638e0efee1b40e1d7407074ba0a20ac81e7`
- capture03 `input.bin`: `1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c`
- post-opening eligibility02 `prepared.bin`: `eaa26557bec12db62dc3f4445ddebdc26aba2ead83e5bf28201a7e649c56369c`

The capture interceptor is an offline composer mirror, with global class-name
removal and one structural-entry dependency redirect. It exports the real
preceding source/policy, deliberately returns cancelled, and cannot publish a
ready recipe. Capture03 predates the later civic callback-return propagation;
that change is independently tested and does not alter successful house records.
The capture fixture subsequently changed to dynamic mirror loading so ignored
diagnostic resources are not a project parse dependency. Historical run hashes
remain the authority for the fixture versions actually executed.

## Focused commands and evidence

All paths below are under `artifacts/citadel-runtime-integration/`. Each run has
`report.json`, parse/run engine logs and owned-process watchdog evidence. These
are headless source/contract tests: no screenshots, player traversal, scene
collision, save/re-entry, runtime smoothness or NPC acceptance is claimed.

Common command form:

```powershell
./tools/run-building-contract.ps1 -Contract CONTRACT -OutputDirectory artifacts/citadel-runtime-integration/RUN -ReportEnvironment ENV -TimeoutSeconds SECONDS
```

| CONTRACT | RUN | ENV | SECONDS | Observed result |
|---|---|---|---:|---|
| StreetHouseOpeningLayoutContract.gd | street-opening-layout-06 | STREET_OPENING_LAYOUT_REPORT | 30 | 81/81 |
| CivicHouseInfillContract.gd | civic-house-infill-18 | CITADEL_CIVIC_INFILL_OUTPUT | 45 | 196/196; six explicit producer-failure controls |
| CivicRecipeGeometryContract.gd | civic-recipe-controls-10 | VOXEL_CITADEL_CIVIC_RECIPE_REPORT | 30 | 23/23 |
| CitadelStreetKeepBoundaryContract.gd | street-keep-boundary-04 | CITADEL_STREET_KEEP_BOUNDARY_REPORT | 45 | 52/52 |
| CitadelWindowSpacingPreservationContract.gd | window-spacing-preservation-05 | CITADEL_SPACING_PRESERVATION_REPORT | 30 | 10 outer, eight policy, nine tamper checks |
| CitadelStructuralInputCapture.gd | facade-input-capture-03 | FACADE_STRUCTURAL_INPUT_REPORT | 120 | 9/9; 47.407693 s; capture only |
| CitadelFacadeEligibilityDiagnostic.gd | facade-eligibility-02 | FACADE_ELIGIBILITY_REPORT | 120 | 10/10; post-opening capture only |
| res://artifacts/citadel-runtime-integration/facade-proposal-source-02/Probe.gd | facade-proposal-02 | FACADE_PROPOSAL_REPORT | 60 | Three actual target proposals ready |

Every passing run above exited naturally with clean engine logs and proven zero
owned processes. The three targets were `urban_row_00_left_upper_facade_002`,
`urban_row_00_right_upper_facade_001` and `_002`; each independently proved its
panel, sill and two rooted corbels under the actual captured policy. Proposal
times were 1.355569 / 1.879293 / 1.949412 seconds. These three dry proposals are
not sequential completion of the whole facade stage or all 24 prior failures.

## Rejected experiments retained

- Eligibility01 disproved the suspected exact-bottom comparison bug: all twelve
  remaining bottom panels were correctly eligible; the other twelve failures
  were higher dependent panels. Eligibility rules were not changed.
- The first spacing formula considered access and socket padding but omitted
  the door frame and the gravity-seat inset. Full facade-spacing-candidate01
  rejected the first finite panel assembly after 82.849873 s. No threshold was
  relaxed. Capture02 and proposal evidence remain available.
- Considering every door sweep at every height was too conservative: low brace
  geometry is below the sill. Height filtering now consumes the actual swept
  bounds in the shared producer frame; it does not remove final sweep admission.
- Facade-spacing-candidate02 hit its declared 180 s internal deadline after
  180.178849 s and returned cancelled; natural exit 1, clean logs, owned-zero.
  No final facade proof was obtained. The original 512-event cap was exhausted
  by early physical-grid callbacks; the diagnostic now retains semantic stage
  events and the final stage separately. Its deadline was not raised.
- Initial unit01 incorrectly used an unbuilt physical lookup; the fixture was
  fixed to search actual producer parts. Unit03 assumed an accepted depth while
  the over-conservative formula rejected it. Both script errors triggered
  immediate owned cleanup with zero remaining members, not success.
- Unit04 checked an extra construction-padding equality using reordered doubles;
  the corrected test checks the actual existing 0.05 m seat requirement strictly.
- Preservation01/02 wrongly required total policy byte equality, including
  window furniture that should move. The replacement relational proof and nine
  negative controls make the allowed changes explicit. Preservation04's
  unrelated-item selector assumed non-window furniture existed; it now selects
  furniture belonging to an unchanged window. All failed artifacts are retained.
- Reusing the already existing `civic-house-infill-17` directory was refused
  before launch; run18 used a fresh directory.

## Full source checkpoint

The independent critic approved Recipe14 headless only, using unchanged
450-second source, 60-second independent-proof and 540-second outer ceilings:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-14 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

Recipe14 completed source preparation in **301.082941 seconds**, within the
unchanged 450-second deadline. The complete terminal failed-ID inventory contains
only `urban_bunting_rope_01`: **37 failures reduced to one**. The 24 facade panels,
four lintels and eight brackets no longer fail the ordinary terminal proof.
Threshold completion made no additions and performed two full proofs against
the same source digest:
`1125e588066d4fefeede8185f1964e93e5d8a5b6ea005d81f4727e164dd2cd11`.
Detailed failure evidence is complete (one failing part), not truncated.

All **774** launch-pinned GDScript/tool hashes stayed unchanged; there were no
hash-read errors or changed sources. The recipe failure BIN digest is
`42e3a569a82ac24feb6c29d8765b4c2b2abcc6760c6519999a260ccd4dab4f92`.
The engine emitted one structured `structural_completion_unresolved` error. The
watchdog immediately stopped its owned job: `forcedCleanup=true`,
`functionalExitCode=null`, `timedOut=false`, `authoritativeZeroProven=true`,
`finalJobMemberPids=[]`. This is not a natural exit or a green recipe run.

The remaining bunting failure means Recipe14 returns no ready source and does
not run the additional independent success proof. There is no new terrain
admission, rendering, player/gate traversal, streaming, save or performance
acceptance. No headed approval has been granted. The separate bunting helper has
a passing 61-check synthetic contract but is deliberately not wired into
production and earns no credit for this rope failure.

The independent read-only critic returned **PASS for the 13-file focused
spacing/callback commit**, excluding the unwired bunting helper and its contract.
The verdict accepts resolution of the 36 targeted failures, not full-source
success, performance ceilings, spawning or headed acceptance. The larger
goal—correct ordinary citadel spawning—remains incomplete.
