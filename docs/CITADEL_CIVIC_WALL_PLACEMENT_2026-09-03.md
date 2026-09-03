# Civic house / curtain-wall source failure

Starting checkpoint: clean `codex/citadel-visuals-clean` at `b9c3ed8`.
The previous goal turn made progress: committed source repair and teleport
selection, then isolated a second candidate's source failure in ordinary Main.
The goal remains correct ordinary-game citadel spawning; it is not achieved.

## Exact failure capture

The existing headless public-recipe diagnostic now accepts an explicit world
seed, region and expected recipe seed. Defaults preserve its original candidate.
The production field must agree with the expected recipe before construction.
`CaptureFailure` is separate from `ExpectReady` and caller-blueprint capture.
It uses the existing 450-second source ceiling and 540-second owned watchdog,
with no independent proof. This is a bounded inventoried-failure capture, not
a production or headed timeout change and never recipe success.

The watcher permits one exact inventoried facade-error header across both logs.
It stops on a second header, any unexpected error or warning. Counts reset on
each complete log scan rather than accumulating rereads. Five controls execute
the actual wrapper watcher extracted from its syntax tree, including repeated
polls of one header, duplicate same/other-log headers and unexpected errors.

```powershell
./tools/test-candidate-recipe-error-watcher.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-watcher-01
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-identity-01 -CaptureFailure -CandidateRegion '-1,0' -ExpectedRecipeSeed 1
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-06 -CaptureFailure -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

The identity negative control correctly rejects with `candidate_identity_mismatch`,
zero callbacks, natural exit1 and owned zero. The five synthetic watcher cases
pass; they do not launch Godot or prove source construction.

Critic-approved `candidate-recipe-06` faithfully reproduces the failure in
176.099514s using forest context, scale1.25, site
`citadel-site-v1:14:atlas-30895044:-1,0`. One exact expected engine error, natural
exit0, zero owned processes and unchanged context. All750 measured sources
remained unchanged during this capture. Exit0 means diagnostic reproduction;
both `passed` and `recipePassed` remain false.

Read the full `failure.json` / typed `failure.bin`, not only the compact reason
chain. Also inspect `input.json`, `report.json`, `timings.json`, verification,
source-hash audit, parse/runtime logs and watchdogs under the run directory.
Failure BIN SHA256:
`6d3751c3e08b963dc7f068d5ca00e1524bcfefc73444e99eaa05d2491333bd3c`.

- Failed house: `urban_civic_house_wall`, after one completed house.
- Rule: `no_clear_connection_in_socket_domain` in opening-head completion.
- Gable: `urban_civic_house_wall_upper_shell_side_-1`.
- Nine attempted connection positions, all blocked by `castle_right_wall_wall`.
- Each reports greatest-axis gap `-0.399995595216751m`; this is real overlap,
  not precision noise. It is not the required displacement of the whole house.
- Direct masonry-seat alternative reports `no_direct_masonry_geometry`.

Static producer inspection finds fixed civic-house center X56 while the curtain
position derives from seeded courtyard width. A correction must use actual
transformed geometry and complete house extents, preserve already-clear layouts,
and avoid neighbours/access/civic props before dependent rooms, doors and
furniture are generated. Connection admission and terminal physical validation
must remain unchanged. No production placement change or successful spawn is
claimed by this diagnostic checkpoint. No headed retry is approved.

## Bounded placement work (not source acceptance)

Diagnostic checkpoint committed as `fdbb46a`. The reusable fixed-X infill helper
and its contract were independently reviewed and committed as `dfc5a27`.

```powershell
./tools/run-building-contract.ps1 -Contract BoundaryInfillPlacementContract.gd -OutputDirectory artifacts/citadel-runtime-integration/boundary-infill-02 -ReportEnvironment BOUNDARY_INFILL_REPORT -TimeoutSeconds 30
./tools/run-building-contract.ps1 -Contract CivicRecipeGeometryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/candidate-civic-infill-controls-02 -ReportEnvironment VOXEL_CITADEL_CIVIC_RECIPE_REPORT -TimeoutSeconds 30
./tools/run-building-contract.ps1 -Contract CivicHouseInfillContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-house-infill-01 -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -TimeoutSeconds 30
```

- Helper:361/361, clean logs, natural0, owned zero. Critic found a float32
  endpoint-rounding defect in the initial326-pass version. The regression now
  selects the adjacent legal Z0.2999999821 rather than the distant0.6 placement,
  retaining strict domain and obstacle checks. This is bounded fixed-X search,
  not a global two-dimensional packing proof.
- Existing standalone civic producer:23/23, clean logs, natural0, owned zero.
  Its unchanged geometry does not prove the new enclosure-aware placement.
- Candidate B actual-producer subset:12/13,187899us, natural1, empty stderr,
  unchanged measured sources, owned zero. The first civic house fails
  `civic_infill_search_failed -> no_clear_fixed_x_placement` after5 candidates.
  This is an honest geometric rejection, not a crash or successful source.
  The sampled compound and curtain exactly match diagnostic03. Full castle,
  structural completion, terminal clearance and gameplay are not proven.

The uncommitted integration preserves each complete house's producer, rebuilding
its room/door/structural declarations at the resolved position. Independent
later producers are previewed as obstacles; trees, roof frames and furnishings
still run from the actual resolved source. A terminal external-envelope audit
includes actual later parts, own furnishing extents, foreign furnishings,
access and tree footprints. Ownerless protected reservations receive no
own-house exemption. This intentionally conservative audit does not replace
physical proof or claim correctness of same-house furniture arrangements.
The integration is not accepted while the actual candidate fit is rejected.

## Actual producer fit recovered

The fixed-X rejection was real for that column, but not a global impossibility.
`civic-house-infill-02` identified two roughly7m Z windows versus a13.2m house.
The full source-derived X endpoint diagnostic (`civic-house-infill-2d-03`)
found a two-house arrangement in the same domain, without moving the service
yard, removing objects, changing dimensions or enlarging paving. Earlier
64-endpoint sampling did not prove that no placement existed.

The generic column search is committed as `1ede03a`, after independent critic
approval and `boundary-infill-columns-03`:550/550, clean natural0/owned zero.
It orders finite geometry-derived columns by X displacement, then X; each
column selects nearest Z. It is not global 2D distance minimization. The initial
actual WALL search reached its work cap. Conservative whole-domain/fixed-Y
obstacle filtering eliminated irrelevant repeated work without raising the
cap; every original obstacle is still validated and checked at final output.

Actual rebuilding then exposed a distinct recipe issue: roof rise depended on
the relocated center, altering height by8.37cm in `civic-house-infill-05`.
Civic design now samples the original roof-rise formula once at the seeded
design center and carries that finite sample through placement. Other street
and perimeter callers retain the original default formula. No clearance,
connection-admission or physical-proof threshold was weakened.

```powershell
./tools/run-building-contract.ps1 -Contract BoundaryInfillPlacementContract.gd -OutputDirectory artifacts/citadel-runtime-integration/boundary-infill-columns-03 -ReportEnvironment BOUNDARY_INFILL_REPORT -TimeoutSeconds 30
./tools/run-building-contract.ps1 -Contract CivicHouseInfillContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-house-infill-07 -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -TimeoutSeconds 30
./tools/run-building-contract.ps1 -Contract CivicRecipeGeometryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/candidate-civic-infill-controls-04 -ReportEnvironment VOXEL_CITADEL_CIVIC_RECIPE_REPORT -TimeoutSeconds 30
```

`civic-house-infill-07`:102/102 in3.390247s, clean logs, natural0, owned zero,
unchanged measured sources. Both actual regenerated houses fit, with roof and
chimney dimensions, rotations and Y positions exactly matching the frozen
original. Cancellation and negative late foreign-part, furniture, access,
protected-volume, canopy and root controls pass. The terminal subset contains
2,016 parts,114 real furnishings and1 tree from the ordinary shared recipe path.
Standalone civic controls04 also pass23/23 after roof-design extraction.

This subset still excludes the complete castle source and later shop/structural
completion. It is not full-recipe, physical-proof, runtime/performance, or live
spawn acceptance. The complete public Recipe gate and any later headed run
still require separate critic readiness review. Run06's fixture property-name
error was immediately stopped with owned-zero cleanup; it is not pass evidence.

## Full-source gate07 and real courtyard-floor correction

Expanded guards in `civic-house-infill-08` passed161/161 in3.916636s,
including byte-exact comparison of all139 standalone civic part records and
all rooms against diagnostic03. The critic then approved the bounded public
Recipe run below; that permission was not a success or headed acceptance.

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-07 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

Gate07 **failed**, cleanly and within its unchanged deadline. Recipe elapsed
160.287827s; context and all measured sources unchanged; no engine error,
timeout or cancellation; natural1 and authoritative owned zero. No independent
physical proof ran. EAST hit `column_work_limit_exceeded` after239 columns,
717 candidates, with3,878 source obstacles and460 relevant obstacles. Failure
BIN SHA256: `b21cb74bddcfe12278d7119e6acaaac407882e2fe9a5d3ddcd38e444a3767b5a`.

The new collector was wrong about the existing floor producer. It recognized
the old unsplit courtyard IDs, but the real castle emits canonical indexed
`castle_compound_foundation_segment_*` and `castle_compound_paving_segment_*`
records after carving entry/egress exclusions. Compatible floor slabs were
therefore treated as blocking structures. This was a collector defect, not a
reason to change the shared floor generator or increase the work budget.

The correction recognizes canonical indexed producer IDs together with exact
semantics, material, collision, egress/root/family/navigation-role tags, rotation,
height and thickness. Other foundations/decorations remain obstacles; room and
protected access handling is unchanged. No broad semantic-name exemption.

`civic-house-infill-11` now calls the actual segmented-base producer:4 foundation
and4 paving records with1 actual keep-entry exclusion. Residence cuts remain
explicitly omitted in this subset.189/189 checks pass in4.782275s, including
forged-ID/missing-egress/wrong-height controls, synthetic carving, the terminal
subset with4 actual tree records, and139-record archive parity. Clean logs,
natural0, unchanged sources and owned zero. The initial fixture09 and production
typing10 parse failures were repaired; they are retained as failures, not passes.

The complete public source still requires another critic-approved run; no
successful spawn, full physical proof or headed acceptance follows from11.

## Full-source gate08: still rejected

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-08 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

The separately critic-approved repeat also **failed** before physical proof.
Recipe202.697158s; natural1, forced cleanup false, no engine errors, no timeout
or cancellation, owned zero and unchanged source hashes/context. Failure BIN:
`dc45aad8c6305b2a3c08f24cc53b0dc213a69fd26115ffd7aa9af2801eb91164`.
EAST hit the unchanged work limit after264 columns/792 candidates. The corrected
collector sees3,729 source/416 relevant obstacles, versus3,878/460 in07. The
real floor mismatch is repaired, but that does not establish feasibility
against the rest of the complete castle.

Do not keep repeating long success-gate runs based on the smaller fixture or
raise the work cap to call this green. The next bounded chunk needs exact failed
caller/obstacle input capture, then cheap replay that names the remaining
geometric blockers and measures the finite search. The existing failed-caller
capture is diagnostic-only and must remain distinct from public-source success.
No headed run or integration-completion commit is approved. The committed
teleport runner remains available; the unfinished production integration and
its expanded source tests remain uncommitted pending this gate.

## Exact failed-caller capture and replay boundary

The critic approved one headless `candidate-recipe-09 -CaptureBlueprint` run
for B, using the existing450s source/540s outer measurement ceilings. This
does not change production limits, the placement work cap, or headed approval.
The capture path retains the typed Builder/Composer caller after failure and
the exact candidate input; it does not invoke independent physical validation.
`captureCompleted` is independent of `passed=false` and `recipePassed=false`.
All engine warnings/errors stop this capture immediately. The wrapper's five
synthetic watcher controls passed in `candidate-recipe-watcher-02`; these are
process-watcher tests, not recipe or live-gameplay evidence.

The next replay must reconstruct the exact failed East preparation inputs from
that caller through the unchanged production preparation path. It must first
reproduce08's failure/counts before testing any solver change. Capturing the
upstream blueprint alone is not proof of exact placement-call equivalence.

Capture09 completed in157.055108s, with false recipe/pass claims, unchanged
context and755 audited source files, empty engine errors, natural0, no timeout
or forced cleanup, and authoritative owned zero. The full failure BIN is
byte-identical to08 (`dc45aad8c6305b2a3c08f24cc53b0dc213a69fd26115ffd7aa9af2801eb91164`),
including264 columns/792 candidates and the same seven search fields. The typed
caller SHA256 is `57ab941d9e714bb91415ee28b59efcbe8fde1b5c65699401c9df9178a561db12`.
Command:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-09 -CaptureBlueprint -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

Artifacts: `candidate-recipe-09/report.json`, `progress.json`, `timings.json`,
`input.bin`, `caller-blueprint.bin`, `failure.bin`, `source-hash-audit.json`,
and `watchdog.json`. No screenshots or gameplay claims apply to this capture.

## Cheap exact preparation replay

`CitadelCivicInfillReplayDiagnostic.gd` restores the typed failed caller,
reconstructs the unchanged Composer environment and calls ordinary civic
preparation without rebuilding the compound. It separately produces the real
standalone East design, resolves domain and ordered named obstacles through
the production helpers, and passes those exported inputs directly to the
unchanged placement solver. Both paths must reproduce08's exact failure.
The direct result is byte-identical to the civic call's failure detail.

```powershell
$env:CITADEL_CIVIC_REPLAY_INPUT=Join-Path $PWD 'artifacts/citadel-runtime-integration/candidate-recipe-09'
try {
    ./tools/run-building-contract.ps1 -Contract CitadelCivicInfillReplayDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-infill-replay-02 -ReportEnvironment CITADEL_CIVIC_REPLAY_REPORT -TimeoutSeconds 45
} finally { Remove-Item Env:CITADEL_CIVIC_REPLAY_INPUT }
```

Replay01 passed29 diagnostic checks in1.574427s; expanded replay02 passed35
in2.203100s, including direct-input equivalence. Both exited naturally0 with
clean engine logs, unchanged sources and owned zero. Recipe success remains
false. Capture binds384 production script hashes; the fixture also compares
all script hashes before/after. The416 relevant rows are an inventory only:
both solvers receive all3,729 obstacles in their original order.

Reports and typed inputs are under `civic-infill-replay-02`: `report.json`,
`replay-inputs.bin`, `replay-inputs.json`, `relevant-obstacles.json`, and
`watchdog.json`. No new geometry, source injection, live collision, successful
recipe, rendering or gameplay is proved. This reproduces the failing placement
without the157-203s compound rebuild, so further diagnosis can be inexpensive.

Independent critic analysis confirms retained `castle_inhabited_terrace_block`
geometry is sufficient to block the whole East domain, not merely exhaust the
search budget. Eight actual records suffice: `castle_terrace_block_00_right_00`,
`00_right_05`, and `01_right_00/02/03/05/06/11` with the same full prefix.
The critic's independent double-precision open-forbidden-rectangle sweep
examined19 critical-X endpoint/midpoint cases for this subset, including domain
boundary points, and found no gap. This is exported-geometry evidence, not
engine or represented-coordinate proof. Broader selection counts differed
between the two analyses; the shared eight-record sufficient obstruction is
the supported conclusion, not equality of those filters.

The owning producer `CastleCompoundBlueprintBuilder.add_citadel_terraces`
carves the original residence/access footprints. Composer retires those
residences and rooms, but retains their dependent terrace masses before
introducing the ground-level replacement residences. The next bounded recipe
repair must reconcile those masses with explicit replacement-house/access
footprints through existing Castle geometry production. Preserve elevations,
unrelated terraces, surviving support dependencies and keep-entry exclusions;
do not fill old cuts blindly, merely omit blockers, or raise the work budget.
Require actual deterministic rebuilt geometry, unchanged unrelated records,
remaining-obstacle clearance and terminal physical proof before full-source
acceptance. No terrace mutation or headed approval follows from this diagnosis.
