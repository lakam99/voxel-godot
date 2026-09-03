# Citadel street-row packing correction

Baseline: `codex/citadel-visuals-clean`, clean commit `ea1757a`. The preceding
goal turn was progress: its owned teleport diagnostic reproduced a real source
failure and shut down the failed game. No citadel spawning acceptance exists.

## Reproduced cause

World `atlas-30895044`, region `(0,-1)`, recipe `1747969299`, scale `1.25`.
The production center survey selects `plains` and site key
`citadel-site-v1:14:atlas-30895044:0,-1`.

`candidate-recipe-01` replays the public `CitadelRecipePreparation.prepare`
entry point. Its full `failure.json`/typed `failure.bin` show this chain:

```text
citadel_structural_completion_failed
  facade_completion_failed
    opening_head_completion_failed
      no_clear_connection_in_socket_domain
```

House `urban_row_03_left` fails after fourteen completed houses. All nine
connection placements into its near gable are blocked by the neighboring
`urban_row_02_left_upper_shell_side_1`. The direct-masonry alternative also
correctly rejects: there is no eligible direct socket geometry.

`candidate-recipe-02 -CaptureBlueprint` runs the former equivalent
Builder-to-Composer sequence and preserves the failed caller's blueprint in
`caller-blueprint.bin`. This is diagnostic source state, not a publishable
result. No furnishing pass was repeated. The two row centers are approximately
`-20.56099` and `-10.22929`, each house depth is `10.827`, and each foundation
depth is `11.107`. Their foundations overlap in Z by approximately **0.7753 m**;
the gables also intersect in positive volume. This is not precision noise or
a routing/publication problem.

Both diagnostic runs preserve the known Composer error explicitly, report
`recipePassed=false`, complete naturally, and prove owned-process zero.

## Correction being verified

Independent center jitter previously coexisted with fixed depth fractions.
The source now constrains row depths before generating any houses, apertures,
rooms, civic-edge geometry or furniture. It keeps sampled centers and widths.
Pairs with overlapping represented structural X sections share only the depth
reduction required to remove their overlap. Each row uses the maximum of its
simultaneously computed pair reductions, making the result order-independent.

Foundation overhang and shell sections derive from the existing house producer;
decorative roof overhang is not used to spread the dense roofline apart. This
is conservative XZ source packing, not a new collision authority. A minimum
depth derives from window width and the room inset; actual furnishing and
complete physical validity still require the full recipe checks.

The correction intentionally changes affected house depths, dependent part
positions, some coordinate-derived IDs, and their subsequently generated
furniture layout. It does not promise whole-source byte parity. Already-clear
rows must remain exact, all house/furniture recipes remain in use, and no
physical validator or protected navigation code is changed.

## Evidence in progress

- `street-row-depth-packing-01`: 82/82 pure geometry/control checks pass,
  including order independence, both-neighbor constraints, unchanged clear
  rows, malformed inputs, bounded work and represented floating-point faces.
- `street-row-packing-producer-01`: generated actual foundation/shell overlaps
  are removed, all eight houses retain part/room counts, original geometry
  matches the captured failing source, and unchanged rows are byte-exact.
  An envelope-containment accounting check remains unresolved; the overall
  contract fails until that is understood and repaired.
- `street-row-packing-civic-01`: 16/17. Neither current seed has a commons
  overlap; both preserve 0.5000019 m edge clearance, paving containment and
  the fourteen-member local geometry signature. The obsolete pre-packing
  whole-street byte comparison and one historical fixed-offset control fail.
  The critic approved adapting those tests while retaining historical controls
  on legacy geometry, exact current civic non-mutation, clear-layout legacy
  parity, and the current geometry-derived negative boundary test.

No headed rerun, visual preservation, successful spawning or performance
acceptance is claimed by these source checks. Current diagnostic artifacts are
under `artifacts/citadel-runtime-integration/`; failed evidence is retained.

## Follow-up verification

- `street-row-packing-producer-02/03` isolated the containment failure to
  separately rounded gable centers in unchanged rows. The whole-depth box alone
  did not enclose their final scalar faces. No collision tolerance was relaxed.
- The packer now accepts an explicit end-slab thickness and includes the actual
  represented end centers, scalar faces and vector/AABB faces in its bounds.
  Only the gable envelope supplies this dimension; it comes from the same wall
  thickness formula as the house producer. This is not a cosmetic gap margin.
- `street-row-packing-producer-05`: **11/11**, natural exit 0, clean engine logs,
  authoritative owned-process zero. Includes actual generated envelope
  containment, no inter-row foundation/shell overlap, complete house counts,
  unchanged clear rows and matching civic/house depths. The report records
  composer, helper, contract and captured-input hashes.
- `candidate-recipe-03`: the public recipe progressed beyond the old opening
  failure but was cooperatively cancelled at 150.090 seconds during
  `physical_resolve_support`. It did not return a ready source. Empty stderr,
  natural exit 1, cleanup passed, zero owned members. This is retained as a
  failed diagnostic, not a successful structural or gameplay result.
- The existing ordinary `CitadelTerrainAdmission` source worker allows 450
  seconds. The original 150-second diagnostic was sized to reproduce the early
  failure; a readiness replay may use that existing 450-second source ceiling
  while recording independent post-source validation separately. No production
  deadline or the 600-second headed-run ceiling is changed.

## Reproduction commands and evidence limits

Commands run from this worktree, using fresh output directories on repeats:

```powershell
# Exact rejected candidate source replay; does not instantiate Main.
./tools/run-citadel-candidate-recipe-diagnostic.ps1 `
  -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-04 -ExpectReady

# Pure packing contract, including separately represented end slabs.
./tools/run-building-contract.ps1 -Contract StreetRowDepthPackingContract.gd `
  -OutputDirectory artifacts/citadel-runtime-integration/street-row-depth-packing-02 `
  -ReportEnvironment STREET_ROW_DEPTH_PACKING_OUTPUT -TimeoutSeconds 60

# Actual house producer against the retained, typed failed-source snapshot.
$env:CITADEL_PACKING_SOURCE = Join-Path $PWD 'artifacts/citadel-runtime-integration/candidate-recipe-02/caller-blueprint.bin'
$env:CITADEL_PACKING_SOURCE_SHA = '114a393279c1ae7676fca8f3ca9a9d7688c86c8cb0d587dbe203ab2a8d0a66b3'
./tools/run-building-contract.ps1 -Contract CitadelStreetRowPackingContract.gd `
  -OutputDirectory artifacts/citadel-runtime-integration/street-row-packing-producer-05 `
  -ReportEnvironment CITADEL_PACKING_REPORT -TimeoutSeconds 60
```

The captured-source contract deliberately requires its historical input and
SHA256; it fails closed if unavailable or altered. The standalone pure packing
and civic contracts do not require that artifact. Every wrapper uses an owned
process job, separate parse/runtime logs and cleanup proof. Source-only checks
do not produce or claim gameplay screenshots. The replay records recipe timing
separately from independent validation; its 450-second recipe budget alone
does not prove the complete site worker fits the existing 450-second ceiling.

## Complete replay 04: original failure removed, next defect exposed

`candidate-recipe-04` returned a real recipe failure after **203.994 seconds**,
inside the unchanged production-source ceiling. It completed facade preparation
and then rejected `urban_row_03_left_door_threshold` with
`threshold_completion_failed -> threshold_housing_footprint_outside_seat`.
It did not return a ready blueprint or reach the independent post-source
physical validator. Full nested failure, input, timings and report are retained.

An immediate manual post-run comparison against `launch.json.sourceHashes`
reported no changed sources (worker tool output `2dcbe8`); this check is retained
in task tool history, not a run04 hash-audit file. The engine error triggered immediate owned
cleanup; watchdog exit 126 records forced termination and authoritative zero
owned processes. This is not a clean functional exit or gameplay acceptance.

The bounded callback-family wall intervals identify 108.46 seconds attributed
to physical support resolution and 42.28 seconds to lower-facade panel work.
These are not exclusive CPU timings. The aggregate facade phase took about
122.79 seconds. No performance threshold is claimed passed.

The original row-overlap/opening-head blocker is no longer the terminal failure;
the new threshold-seat failure remains mandatory unfinished work before a
headed retry. Its relationship to the packing change must be checked against
actual geometry; it is not automatically classified as pre-existing.

Final focused checks so far:

- `street-row-depth-packing-02`: **123/123**, including a positive end-slab
  overlap witness, independent represented-box clearance, clear-row and
  ordering parity, and malformed thickness rejection.
- `street-row-packing-producer-06`: **12/12**. Adds byte-exact preservation of
  every door and threshold record before/after packing. This alone does not
  establish parity of their surrounding support geometry.
- `street-row-packing-civic-03`: **23/23**. Both generated layouts have zero
  commons overlaps and 0.5000019 m edge clearance. Current street parts,
  rooms and existing recipe declarations are byte-exact across civic insertion;
  only the two expected civic houses and their four facade declarations are
  appended. Mutated existing declarations and unexpected additions reject.
  Historical offset negatives use legacy geometry, and an independently clear
  layout retains full legacy street parity. The fourteen-piece commons local
  signature remains unchanged.
- All three final focused runs: clean parse and runtime logs, natural exit 0,
  no forced cleanup, authoritative zero owned processes.

The Civic correction is limited to test accounting; it does not weaken the
production physical validator, change collision tolerances, or authorize a
headed launch. The failed earlier Civic and producer runs remain on disk.

## Narrow threshold attribution

`candidate-threshold-02` runs one complete ordinary physical proof against the
locked **historical unpacked pre-completion source** (4326 parts), then supplies
its actual, source-matched successful seat records to `ThresholdBearingSeatRecipe`.
The physical proof itself has unrelated violations; no whole-blueprint pass is
claimed. No canned checks or inferred success are supplied. The selected roadbed
has a successful rooted physical check and reproduces
`threshold_housing_footprint_outside_seat` without the packing change.

Selected seat: `castle_district_processional_03_final_turn_roadbed_01`.
Candidate footprint: X `[8.1351824105, 9.0551824272]`,
Z `[-11.0192871690, -9.4392871261]`. Its Z footprint exceeds the seat's permitted
inset extent by **0.1477131295 m**. This is a real geometric overhang, not a
floating-point tolerance issue. The proof takes about 7.04 seconds; the bounded
diagnostic completes in about 7.47 seconds.

`candidate-threshold-04` is explicitly a **producer-delta diagnostic variant**,
not a replayed complete packed recipe. It overlays guarded old-to-new house
producer field deltas onto the retained pre-completion source, leaving unrelated
parts and derived declarations unchanged. That qualification matters: it cannot
prove complete new roof/declaration validity, furniture, rendering or gameplay.
Its independent ordinary proof again selects the same successfully rooted seat
and returns the same housing rejection. Threshold and selected-seat snapshots,
normalized threshold, candidate center/size/domain, and failure are identical
to the unpacked diagnostic. It completes in about 10.38 seconds.

Together with byte-exact door/threshold producer controls, this establishes a
latent threshold-footprint defect independent of the changed row depths. It is
not a declaration that all later recipe failures predate this patch. Both
diagnostics report `passed=false`; successful diagnostic extraction is not
successful recipe preparation. Their owned wrappers exit naturally with clean
engine logs and zero owned processes. The earlier incomplete threshold03
producer-delta identity attempt remains retained as failed evidence.

Final-source confirmation: `candidate-threshold-05` repeats the unpacked case
in 7.586498 seconds using the **same diagnostic SHA256 as delta04**:
`c864379e5606e06152829d2377664f09577dbce40307af74b718a11f3322364b`.
It reproduces the failure with unchanged input/threshold/seat records, clean
engine logs, natural exit 0 and owned-process zero. Commands:

```powershell
./tools/run-building-contract.ps1 -Contract CitadelCandidateThresholdDiagnostic.gd `
  -OutputDirectory artifacts/citadel-runtime-integration/candidate-threshold-05 `
  -ReportEnvironment CITADEL_CANDIDATE_THRESHOLD_OUTPUT -TimeoutSeconds 30
# For the explicitly partial producer-delta variant, set
# CITADEL_THRESHOLD_PACKED=1 and use a fresh output directory.
```

The recipe diagnostic wrapper now writes a separate final source-hash audit
even on failed runs. That wrapper-only addition was syntax checked, not used
retroactively to rewrite run04 evidence or to claim a new full source replay.

## Critic decision

Independent read-only critic: **PASS for this focused ten-file packing,
diagnostic and documentation commit**, after verifying 123/123, 12/12, 23/23,
source hash bindings and qualified threshold attribution. No blocking issue
remains for this scope. Validators and routing code are unchanged.

Explicitly **not approved**: headed retry, ready-candidate/spawning, gameplay,
full packed-source parity, or performance-budget acceptance. Next work is the
bounded threshold-footprint defect; keep the ordinary seat/root and clearance
proofs, preserve the door and visible recipe, and use the isolated diagnostic
before another complete source replay.
