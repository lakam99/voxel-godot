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

## Staged terrace reconciliation implementation (not yet full-source acceptance)

`ResidentialTerraceCarvingRecipe` now stages explicit replacement-house/access
cutouts in verified retained Castle terrace records. Provisional placement
permission is not clearance acceptance: the existing strict planner repeats
against the actual represented fragments and requires identical house poses.
Composer commits only the complete checked replacement list, then emits the
ordinary houses. Sampled dimensions, roof design, materials and heights remain
unchanged. Existing holes are retained; the carver never regenerates a solid
uncarved courtyard or fills retired residence cutouts.

The Castle subtraction helper has an opt-in construction-plane-preserving mode;
old callers keep their original arithmetic and minimum-fragment policy. New
replacement carving verifies exact retained occupancy outside the requested
cuts. Failed runs01-04 exposed represented endpoint/intersection errors. The
repair constructs exact stored endpoints, using at most two same-material
solids per axis where one centre/size pair cannot represent both endpoints.
Their overlap is internal to the retained volume: no new exterior material,
moved cut plane, lost outside cell or clearance tolerance is permitted.

`terrace-reconciliation-05` passed its initial10 source checks in1.508781s:
two actual houses,19 changed terrace records, strict realized-source placement
and unchanged caller. This predates expanded dependency guards and Composer
integration and is not current acceptance. The critic correctly held the next
gate for uncut/embedded surviving dependencies and inherited fragment references.
The implementation now checks actual staged survivors, delegates affected
support/anchor comparisons to the existing physical resolver on private copies,
and checks final fragment references while exempting only historical provenance.
Expanded controls and a new current-source run are required before acceptance.

Parallel `terrace-dependencies-02` records155 retained terrace records,
539 contact candidates and2,272 exact ID references in1.357325s. It is an
explicitly read-only AABB/reference inventory, not fresh physical proof.
Its initial parse01 failure was repaired and retained. Run02 and source05
both have clean logs, natural exits, no timeouts and authoritative owned zero.

The existing `civic-recipe-controls-05` passed23/23 and
`civic-house-infill-12` passed189/189 in4.974138s, including standalone design
and archived recipe identity checks. These also predate the final dependency
guard revisions. No full public Recipe or headed test has been run for the
new terrace reconciliation yet; the runtime-spawn goal remains incomplete.

### Current dependency and production-entry controls

The critic also identified the physical owner's supported-gap reach as larger
than contact tolerance. The existing0.26m limit is now named
`BuildingBlueprint.STRUCTURAL_SUPPORT_MAX_GAP` without changing its comparison.
The carving broad phase conservatively includes its closed endpoints, while
the existing resolver alone decides actual support/anchor preservation.
Controls include a0.10m sole-support gap, an embedded anchor, an uncut eligible
terrace, and a reference inherited between two replaced records.

Run06 was a repaired type-inference parse failure;07 stopped immediately on an
invalid mixed-type classification exposed by a forged-tag control. Both owned
jobs were cleared. The repaired combined08 run passed70 checks but cancelled
its third full preparation at the unchanged30s aggregate fixture deadline.
It remains failed. Coverage was split into explicit `controls` and `composer`
phases, each retaining30s internally and45s outer cleanup protection, rather
than changing the production or fixture deadline.

```powershell
./tools/run-building-contract.ps1 -Contract CitadelTerraceReconciliationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/terrace-reconciliation-09 -ReportEnvironment CITADEL_TERRACE_RECONCILIATION_REPORT -TimeoutSeconds 45
$env:CITADEL_TERRACE_RECONCILIATION_PHASE='composer'
try {
    ./tools/run-building-contract.ps1 -Contract CitadelTerraceReconciliationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/terrace-reconciliation-10 -ReportEnvironment CITADEL_TERRACE_RECONCILIATION_REPORT -TimeoutSeconds 45
} finally { Remove-Item Env:CITADEL_TERRACE_RECONCILIATION_PHASE }
```

- Controls09: **71/71**,28.521573s. Deterministic complete result, actual outside-
  cut occupancy, stored-plane construction, legacy subtraction equivalence,
  unchanged unrelated records, reference/contact/gap rejection, stale commit
  and cancellation controls.
- Composer10: **20/20**,29.526934s. Actual `add_civic_quarter` applies the exact
  retained-part replacement prefix and emits the resolved actual house records;
  old rooms and unrelated recipe facts remain unchanged, with expected new
  house declarations produced by the existing house producer.
- Both retain typed `report.bin`, full-precision `report.json`, unchanged bound
  source hashes, clean engine logs, natural0, no timeout/forced cleanup and
  authoritative owned zero. Each includes two complete preparations; their
  elapsed times are source-test totals, not runtime frame ceilings.

These prove the captured caller's civic preparation and commit, not the later
furnishing/shop/structural-completion stages, independent full physical proof,
ordinary site admission, scene publication, visuals or gameplay. Full public
Recipe and headed acceptance remain separate critic-gated steps.

### Public Recipe10 and remaining street/keep overlap

Following critic approval for headless source verification only:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-10 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

The public recipe failed after233.316819s, now **after civic infill succeeded**
with both resolved houses and19 actual terrace replacements. The subsequent
structural facade stage failed at `urban_row_03_right_upper_shell_side_1`;
all12 attempted connections were blocked by `castle_keep_front_tower_1`.
The earlier15 completed houses do not imply final structural acceptance.
Failure BIN SHA256:
`56156dba3ea0f3fd456944a8cd70d6b7cf6abf5cb1437698f343b15d57ec67e0`.

The engine emitted the inventoried facade error and the watchdog stopped its
owned job immediately. Wrapper exit1, **forced cleanup true**, natural engine
exit unavailable, no timeout, authoritative owned zero.759 bound source hashes
and launch context remained unchanged. No independent final physical pass,
ordinary site admission, rendered city or gameplay acceptance follows.

```powershell
./tools/run-building-contract.ps1 -Contract CitadelKeepStreetOverlapDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/keep-street-overlap-03 -ReportEnvironment CITADEL_KEEP_STREET_OVERLAP_REPORT -TimeoutSeconds 30
```

Overlap03 passed13/13: typed caller09 and current Composer10 retain byte-identical
records for the failing house member and tower, neither appears in the terrace
replacement set, and the shared zero-margin transformed-part overlap test rejects
their intersection both before and after civic reconciliation. Composer evidence
BIN SHA256 is `d74cb0dce3c103911dbc4a7da7dc19f225e5196e9257c6b866f1ac766f9874ab`.
This attributes the existing geometric overlap, **not equivalence of every
historical facade candidate or an historical full-recipe run**.

Overlap01/02 remain failed experiments: regenerating only the street producer
on an empty blueprint did not expose the expected member through its lookup.
Overlap03 retains that incomplete experiment as an explicit false observation;
acceptance instead compares the actual captured before/after Composer records.
All three exited naturally, without engine errors, timeout or forced cleanup,
and proved their owned jobs empty. No headed launch was attempted.

The empty-producer lookup discrepancy is now explained: `find_part` reads the
physical resolver's ID index, which a bare producer has not populated. Run04
uses the unchanged emitted `parts` array instead and adds an exact typed-record
comparison. **14/14 pass**, including the current street producer's byte-identical
gable and both actual Composer comparisons. Same command as03 with output
`keep-street-overlap-04`; natural0, clean logs, no timeout/forced cleanup,
authoritative owned zero. This repairs only the diagnostic's lookup, not any
production behavior or expected geometry.

Hash caveat for reconciliation09/10:89 nonempty source hashes were bound;
three shader paths ending in `.gd` produced empty hashes instead of binding
their actual `.gdshader` files. They are not claimed as verified source bindings.
Recipe10 independently bound759 actual source files.

The civic placement/terrace repair is a focused source checkpoint, not completed
citadel integration. The next owning problem is street-house placement against
the retained keep geometry. Preserve full-source failure and all visual,
physical, runtime-performance and ordinary-world acceptance gates.

### Focused checkpoint review

Hooke independently returned **PASS for the focused civic-placement/terrace
repair commit**, including overlap04; no further attribution evidence was
requested. Approval covers staged actual carving, strict unchanged-pose recheck,
outside-cut occupancy, dependency preservation and atomic commit controls only.
It explicitly excludes final integrity, integration, headed/gameplay acceptance
and performance budgets. Recipe10 remains failed.

Current-source regression refreshes also completed:

```powershell
./tools/run-building-contract.ps1 -Contract CivicHouseInfillContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-house-infill-13 -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract CivicRecipeGeometryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-recipe-controls-06 -ReportEnvironment VOXEL_CITADEL_CIVIC_RECIPE_REPORT -TimeoutSeconds 30
```

Infill13 passes189/189 in5.014798s; civic geometry06 passes its aggregate
contract. Both have natural0, clean engine logs, no timeout or forced cleanup,
and authoritative owned zero. Broad gameplay/visual runners remain unrun for
this checkpoint because full-source readiness still fails before headed approval.
