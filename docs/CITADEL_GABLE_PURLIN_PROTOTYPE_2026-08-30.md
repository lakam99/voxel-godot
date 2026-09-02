# Gable-supported roof-frame prototype

Current status: the later shared-composer integration is complete and
critic-accepted in its bounded scope, with **253 remaining physical failures**.
See `CITADEL_ROOF_FRAME_INTEGRATION_2026-08-30.md` for immutable prototype parity,
regressions and late-failure containment. The full gate and strict exact-contact
checks still fail. The chronology below describes the earlier unwired prototype
and its one-use diagnostic; those historical 298/current-versus-253/candidate
distinctions are not the latest branch status.

Branch `codex/citadel-visuals-clean`, HEAD
`fcda6762c1923015e27cf622a63e87f6209118c0`; existing uncommitted work preserved.
The original and donor worktrees were not edited. No commits were made.

## Repair at the owning geometry

The existing urban roof halves have mutually circular inferred support. Their
actual underside differs from the nominal rise: representative house
`urban_row_00_left`, seed 208159, scale 1.25, has width 9.268304, depth 9.45,
wall top Y6.820 and roof rise 3.745632. At the house centre the roof underside
is Y10.148794, not the nominal wall-top-plus-rise Y10.565632.

The frame-only builder consumes the two unchanged roof parts and two existing
gable side-wall IDs. It adds four longitudinal purlins and eight uprights,
all above the wall tops. It neither moves roof skins nor adds low cross-room
beams, ground-level facade posts, or new furniture placement logic.

Each roof half requires two purlins bracketing its centre; each purlin requires
two end uprights; each upright has a finite downward seat on an existing gable
wall. Both wall paths must reach existing grounded masonry independently of
the roof/frame. Geometry, full declared obligations and compatible physical
intent/collision are checked, not merely any reachable graph edge.

New files: `GablePurlinFrameBuilder.gd`, `GablePurlinFrameValidator.gd`, and
three focused scripts under `scripts/testing/buildings/`. The standard roof
grammar is not replaced. `BuildingBlueprint` adds scoped preflight rejection
and second-pass validation for the new explicitly declared frame grammar.

The builder stages finite gravity and housed-joint geometry before mutating
records. Invalid thin bearers, invalid dimensions, unsupported roof joints and
malformed member IDs leave the input snapshot unchanged. Root validity remains
the independent validator's responsibility; builder `ready` is not acceptance.

## Evidence so far

All runs use Godot 4.6.1 console, headless, through
`tools/run-godot-scene-watchdog.ps1`, isolated run-local APPDATA/LOCALAPPDATA,
fresh stdout/stderr/report/watchdog paths, and an owned stop-request marker.
Run directories below are under `artifacts/citadel-visual-reset/`.
Exact engine command/arguments and cleanup evidence are in each watchdog file.

| Run | Script / report environment | Result |
| --- | --- | --- |
| `roof-grammar-baseline-01` | `LandmarkBuildingGrammarContractRunner.gd` / `VOXEL_LANDMARK_BUILDING_GRAMMAR_REPORT` | Pre-existing gable-cap, courtyard-door and layout failures; exit 1 |
| `roof-grammar-after-01` | Same | Identical non-timing report content and failure list; 14 publication timing fields differ; exit 1 |
| `existing-roof-frame-baseline-01` | `ExistingRoofFrameContract.gd` / `VOXEL_EXISTING_ROOF_REPORT` | 18 synthetic standard-roof cases PASS |
| `existing-roof-frame-after-01` | Same | 18 PASS after the first validator extension; 243 ms test time |
| `gable-purlin-contract-01` | `CitadelGablePurlinContract.gd` / `VOXEL_GABLE_PURLIN_REPORT` | 12 positive checks and 35 negative controls PASS |
| `gable-purlin-contract-02` | Same | 12 positive and 37 negatives PASS; 5.544 s test time |
| `gable-purlin-contract-03` | Same, final source | 12 positive and 40 negatives PASS; 5.720 s test time |
| `existing-roof-frame-after-02` | `ExistingRoofFrameContract.gd` | All 18 standard-roof cases PASS on final source |
| `gable-purlin-probe-01` | `CitadelGablePurlinVisualProbe.gd` / `VOXEL_GABLE_VISUAL_REPORT` | Obsolete validator; invalid visual readback, not acceptance |
| `gable-purlin-probe-02` | Same, corrected source payload capture | 16 frames ready; observed 298 -> 253, zero new-frame failures; existing roof transforms match; all 192 purlin segments overlap shingles; no tested corner above nominal roof upper plane |
| `gable-purlin-probe-03` | Expanded preservation script | Parse failure from an untyped local; process exited immediately, cleanup zero; no acceptance |
| `gable-purlin-probe-04` | Expanded script with explicit bool type | FAIL: 36 upright-to-purlin render gaps and 320 timber corners below wall-top clipping plane; full furniture/material/original-record checks PASS |

These are source/service/synthetic tests, not live gameplay or headed imagery.
The broad grammar uses seed 208154; urban probes use 208159/1.25. The focused
house reproduces representative dimensions through the actual street-house
composer, not an alternative roof generator.

All listed runs exited with authoritative owned-job zero; no cleanup errors
or unresolved cleanup. Broad grammar runs retain their expected nonzero exit.
Its first stop marker was written after the run had already exited, so it does
not prove cancellation coverage. Final Godot count at this checkpoint was zero.

## Critic findings repaired

The critic rejected intent-dependent enforcement, missing finite/schema
guards, committing records before joint feasibility, and using only any-edge
rooting below gable bearers. Tests now cover those failures.

Two further exact regressions are also covered in contract02:

- A malformed `physicalRequiredSupportPartIds` is rejected before resolution
  consumes it, without script errors.
- A frame member cannot silently add a second set of mandatory support IDs;
  this closed grammar uses seat declarations exclusively. A missing extra
  support rejects the post, purlin and dependent panel despite valid seats.

After contract02, additional guards reject empty part IDs, a non-string gable
bearer ID, wrong part kinds, and attempts to overwrite an existing roof assembly.
Contract03 and standard-roof after02 complete the final source rerun. The critic
accepted the implemented **unwired source prototype**, not its integration or
visual acceptance. Reviewed source hashes:

- Builder: `F75F66A892281C9220AA80941504B08EB4EA00C6C15FD1DC9740AAB82C013600`
- Validator: `F1A2012216F2F581075D522D3B5C92C9DD40CDD39D1713DBBD248E83B36006B0`
- Blueprint: `555FA79DE931898757FDC67A6D2CF10DBE4AE364B3E69A8D19C5BC167176BF8B`

## Evidence limitations and next gate

Probe01 read MultiMesh transforms back from the headless renderer and obtained
identity instances. Its apparent gaps/protrusions were invalid observations.
Probe02 instead captures the actual static-publication transform payload before
that backend and uses affine-box SAT, preserving shear rather than reducing
matrices to Euler angles and scale. It still proves no rendered image.

Probe02's zero upper-plane protrusions do not establish full XYZ containment,
concealment, upright fit, chimney clearance, material/custom-data preservation,
or full furniture/reservation equality. Those checks are being extended before
promotion. Its exit 0 means measurement completed, not full acceptance.

Probe04 strengthens the evidence and rejects the visual candidate before any
headed launch. All 16 setups and 224 frame/roof physical checks pass, with no
added failures; observed count remains 253. All 4,045 original part records are
preserved except explicitly named frame declarations, rooms/blueprint recipes
match, and all 152 furnishings plus protected reservations match. Existing roof
publication payloads (transforms, material/shader exposed state and custom data)
match. Finite/degenerate/sheared SAT controls pass. No nominal new-frame/chimney
intersection candidates were found. This is not live or rendered acceptance.

Actual aged timber payloads explain the two failed checks: independently bent
purlin segments no longer meet 36 short uprights, and bent/scaled long upright
segments dip roughly 2-3 cm into the gable wall. No upright corner is outside
the finite projected roof footprint. The clip-at-wall-top check alone does not
classify embedding into an existing bearer as a gameplay defect, but real
upright-to-purlin gaps still prevent promotion. A generic joint-preserving timber
profile for only the new frame members was conditionally approved by the critic
and is now implemented. Existing aged timbers remain on their original path.

## Joint-preserving publication follow-up

`preserveBearingFaces` is a strict boolean opt-in on the new frame members.
The publisher emits one continuous member using the existing material and
facade custom-data pipeline. Missing, false and non-boolean values retain the
existing aged-beam formula. Neither nominal collision nor physical thresholds
changed. This is not yet composer integration or headed acceptance.

- `timber-bearing-profile-01`: test-oracle Array inference caused a script
  error; the owned stop marker terminated the process and cleanup proved zero.
- `timber-bearing-profile-02`: all 60 direct/static synthetic cases and payload
  parity PASS after correcting the oracle type. Six sizes, legacy formula,
  strict-boolean opt-in, material/custom data and collision are covered.
- `gable-purlin-probe-05`: local bool inference parse failure; immediate exit,
  no acceptance.
- `gable-purlin-probe-06`: all source/material/furniture and full finite XYZ
  envelope checks PASS; strict-zero contact checks still reject tiny gaps.
- `gable-purlin-probe-07`: scalar-double separation measurement retains the
  authored float32 matrix components without extra Vector3 subtraction/dot
  rounding. Maximum post/purlin separation is 7.74860382080078e-7 world units;
  maximum post/wall separation is 4.17232513427734e-7. The two strict-zero
  contact checks remain FAIL. No tolerance or geometry offset was added.
  All other explicit probe checks PASS, with candidate count 253 and no added
  failed part IDs. Exact gaps remain in each upright report row. Numerical
  classification is under independent review, not accepted as real contact.
- `gable-purlin-contract-04`: after the publication opt-in, all 12 positive
  checks and 40 negative controls still PASS; exit 0, empty stderr.

All follow-up jobs have authoritative zero-process cleanup. Reports and exact
commands are in the correspondingly named directories above; each uses its
existing report environment variable. The timber contract uses
`VOXEL_TIMBER_BEARING_REPORT`. None of these runs supplies a headed screenshot.
The source hashes above predate the builder's publication opt-in.

`gable-purlin-probe-08` completes scalar-double cross products and axis
normalization too (probe07 still used Vector3 for those operations). All 14 SAT
controls pass, including represented submicrometre and millimetre separations,
large-coordinate contact/separation and operand reversal. Exact gaps above are
unchanged. Both strict contact checks remain FAIL, all other explicit checks
PASS; 40.318 s, exit 1, empty stderr and owned zero. No uncertainty allowance
was introduced. The critic accepted diagnostic visual inspection as a possible
next step without converting these strict failures to contact or acceptance.

An isolated `CitadelGablePurlinDiagnostic.tscn` inherits the existing empty-world
urban capture fixture, adding frames only to its own blueprint. It writes
`prototype-setup.json` with the strict-contact failure and evidence limitations.
`gable-diagnostic-parse-01` parses cleanly with `--check-only`; no scene execution
or image is implied. The parent fixture's review-door service call is explicitly
not player/NPC door acceptance.

The critic granted exactly one diagnostic invocation for
`res://scenes/testing/buildings/CitadelGablePurlinDiagnostic.tscn -- --seed 208159
--citadel-scale 1.25`, through the unchanged watchdog with 210 s timeout and
fresh `gable-diagnostic-capture-01`. Isolated APPDATA/LOCALAPPDATA, cleared
inherited VOXEL settings, explicit report/screenshot/stop-marker paths and zero
Godot processes were checked before launch. Fixture SHA256:
`034A5D1B8A4E58ACA28F8C976EB4B37DE620B38193F0BC44BB2E58A265FBB9A3`.
No retry is authorized. The grant is now consumed by that invocation.
`existing-roof-frame-after-03` also retains all 18 standard-roof cases PASS.

### Consumed headed diagnostic result

`gable-diagnostic-capture-01` completed in 55.021 s, exit 1 with the known
visual-contract failures, empty stderr, authoritative owned-job zero, no cleanup
errors and global Godot count zero. Fixture, scene, builder and publisher hashes
matched the frozen packet after execution. `prototype-setup.json` records all
16 successful frame setups and the unresolved strict-contact failure.

All 4,237 building parts published (4,045 originals + 192 frame members), with
20 doors, 152 furnishings and 456 furnishing visual pieces. The run retained
one non-interior window out of 76 and the missing `green_market_square` capture
after 64 unsupported camera candidates. Nine screenshots were saved. The
`structuralSupport.passed` summary checks only its named foundation/street/terrace
families; it does not overrule the full 253-failure candidate diagnostic.

Main-agent inspection covered all nine images and compared `civic_overview`,
`inner_lane` and `market_ground` directly against `street-brace-capture-01`.
The overview visibly adds vertical timber supports beneath the gables while
retaining roof silhouettes, masonry, openings, chimneys and market arrangement.
Street and market comparisons retain the original appearance; no new gross
roof protrusion or street obstruction was apparent in these views. This is
limited-view observation, not proof of every member's concealment or clearance.
The `perimeter_lane` image is still fully occluded despite its camera boolean;
awning/bracket discontinuities remain visible. No night/interior or live
player/NPC interaction acceptance is supplied by these images.

Exact command, run ownership and paths: `gable-diagnostic-capture-01/watchdog.json`.
Setup: `prototype-setup.json`; main report: `report.json`; captures: `screenshots/`;
logs: `stdout.log` and `stderr.log`. A progress path was supplied, but this
inherited runner did not create a progress file; no progress evidence is claimed.
The critic inspected all nine candidate images and three baseline comparisons:
**bounded appearance-diagnostic PASS; full visual/physical acceptance REJECT**.
No second headed invocation is authorized.

The headed publisher's actual physical diagnostic also reports 253 failures,
with no additions relative to the 298-failure stored-firewood checkpoint. Its
45 removed failures comprise 28 roof halves, 14 eaves, one facade frame and two
bunting ropes. This is observed downstream rooting, not 45 independently proven
architectural repairs. The source probe still preserves both strict-contact
FAIL results. No accepted production reduction is claimed.

Critic-approved next implementation conditions: call the existing builder once
through the owning composition path, without seed-specific repairs, duplicate
diagnostic injection or silent setup failure; retain geometry/furniture and
new-member-only rendering opt-in; prove integrated output matches this reviewed
prototype and rerun structural negatives/standard-roof contracts. Preserve all
physical thresholds, temporary bypass status, exact-contact limitations and
incomplete attic coverage. Submit the integration diff and parity results to
the critic. These images may be reused if output parity holds; another identical
capture is not automatically required.

Subsequent result: integration under those conditions passed independent critic
review; the separate integration ledger supplies the evidence. The production
composition cutover is complete, with strict-contact failures retained.
The visible exterior-post proposal for the separate upper-facade problem still
awaits user agreement. Do not count this prototype as satisfying that decision,
the full physical gate, normal-world integration, NPC behavior or performance.
