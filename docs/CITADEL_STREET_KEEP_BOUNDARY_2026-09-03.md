# Street layout respects the retained keep

Branch `codex/citadel-visuals-clean`, baseline `861ba73`, clean before edits.
World `atlas-30895044`, region(-1,0), recipe541151883, forest, scale1.25.
This is source construction work, not routing/movement/navigation work.

## Cause and repair

Public Recipe10 failed at the upper-right street house against the keep-front
tower. The earlier typed caller09 already contained the identical intersection;
overlap04 established that the civic repair did not introduce it.

Both street geometry and market-tree sampling forced a minimum42m street span.
This candidate has only33.908m between the front boundary and the existing5m
keep approach reservation. Expanding that span pushed the rows into the keep.
Removing that floor preserves actual available space; the existing row packer
still rejects houses below their minimum depth rather than expanding the site.

Source inventory street-keep-boundary01 reduced historical200 positive
street/keep intersections to2. The remaining row03left foundation overlaps the
keep's entrance forecourt root and walking slab by1.867837m in Z. It extends
above the slab, so these are not compatible underlay exemptions. Run01 remains
failed: natural1, clean engine logs, no timeout/forced cleanup, owned zero.

The production composer now measures the actual retained colliding keep parts
before sampling urban rows. The shared rear plane is the more restrictive of
the existing nominal5m approach and the foremost transformed keep bound minus
the existing0.25m building clearance. The sampled layout carries that plane to
street rows, market/tree sampling and civic consumers. No seed-specific offset,
new placement solver, ignored blocker, actor movement or navigation change.

Eight houses and their width/height/material choices are retained. Depth and Z
placement, along with dependent details and paving extents, intentionally adapt
to the actual available space. Visual preservation still requires headed review.

## Verification and failed-experiment accounting

All following commands use `tools/run-building-contract.ps1`, a fresh
`artifacts/citadel-runtime-integration/<directory>` and the owned-job watchdog.
Reports are `report.json`, with `report.bin` where the fixture emits typed data;
stdout/stderr and `watchdog.json` retain termination/cleanup evidence.

| Contract | Directory | ReportEnvironment | TimeoutSeconds | Result |
|---|---|---|---|---|
| CivicRecipeGeometryContract.gd | civic-recipe-controls-07 | VOXEL_CITADEL_CIVIC_RECIPE_REPORT |30|22/23; old narrow synthetic legacy parity fails|
| CivicRecipeGeometryContract.gd | civic-recipe-controls-08 | VOXEL_CITADEL_CIVIC_RECIPE_REPORT |30|23/23 after explicit spacious parity fixture|
| CivicHouseInfillContract.gd | civic-house-infill-14 | CITADEL_CIVIC_INFILL_OUTPUT |45|188/189; archived paving position/size intentionally differ|
| CivicHouseInfillContract.gd | civic-house-infill-15 | CITADEL_CIVIC_INFILL_OUTPUT |45|190/190; actual commons-derived paving plus unchanged other records|
| StreetRowDepthPackingContract.gd | street-depth-controls-01 | STREET_ROW_DEPTH_PACKING_OUTPUT |30|123/123|
| CitadelStreetKeepBoundaryContract.gd | street-keep-boundary-01 | CITADEL_STREET_KEEP_BOUNDARY_REPORT |45|fails2 remaining forecourt intersections|

The unchanged legacy street oracle is still exercised for an explicitly
sufficient49.982m span (front-60, keep-5.018). Critic agreed that wide X spacing
alone did not establish longitudinal room in the original31.982m fixture.
The original failed result is retained; narrow-span correction gets its own
source-bound and42m boundary controls instead of asserting historical identity.

The civic archive stays unchanged.138 nonpaving records and all rooms remain
typed-byte identical. Only paving position/depth are reconstructed from the
actual14 emitted commons parts and existing0.25m edge margin, with all other
paving fields unchanged. Whole-archive inequality remains an explicit observation.

These are source-level geometry and rule checks, not final structural integrity,
normal-world site admission, rendering, continuous travel, save lifecycle or
performance acceptance. Full public Recipe and headed tests remain critic-gated.

## Actual keep-boundary verification

```powershell
./tools/run-building-contract.ps1 -Contract CitadelStreetKeepBoundaryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/street-keep-boundary-02 -ReportEnvironment CITADEL_STREET_KEEP_BOUNDARY_REPORT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract CivicRecipeGeometryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-recipe-controls-09 -ReportEnvironment VOXEL_CITADEL_CIVIC_RECIPE_REPORT -TimeoutSeconds 30
./tools/run-building-contract.ps1 -Contract CivicHouseInfillContract.gd -OutputDirectory artifacts/citadel-runtime-integration/civic-house-infill-16 -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -TimeoutSeconds 45
```

Boundary02 passes48/48 in1.022025s: historical200/current0 exact positive
street/keep intersections, all pairs visited, actual retained-source rear plane,
order independence, invalid-bound rejection, sampled-input immutability,
41.75/42/42.25m controls, too-short atomic rejection, shared market/tree/civic
consumers and actual represented clearance. Available depth30.85599975585938m;
furthest colliding row faceZ=-13.33408260345459, nominal keep frontZ=-4.892,
remaining approach8.44208260345459m. All eight house identities retain their
material sets, foundation widths/heights and X positions. This is not a claim
of identical roof shape, all part counts, depth or Z positions.

Its hash closure binds actual `.gdshader` paths as well as `.gd` and rejects
missing/empty hashes. Civic09 passes23/23; infill16 passes190/190. All three
have clean engine logs, natural0, no timeout/forced cleanup, authoritative
owned zero. No public full-source, headed or performance acceptance yet.

The critic rejected launch readiness for one missing-authority case: an empty
source or source without any colliding keep record must not silently return the
nominal boundary. The production helper now returnsNAN and the existing
composition guard rejects it. Standalone sampling without a keep remains a
clearly limited producer API, not the production composition path. Additional
negative controls and a fresh boundary run are required before Recipe11.

Boundary03 then passed52/52 in1.021980s, including empty-source and
no-qualifying-keep rejection with no emitted street records.92 complete hashes,
clean logs, natural0 and owned-zero. The critic approved exactly the following
headless source run; no headed or completion approval was given.

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-11 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

## Recipe11: geometry progressed; later support work exceeded source limit

Recipe11 **failed** by cooperative source cancellation at450.745808s, with
the unchanged450s internal source limit (60s independent-proof allowance and
540s outer limit unchanged). It passed the previous opening-head/upper-right
house failure and reached later party-wall completion, stopping after
`party_wall_item_completed:urban_row_01_right_upper_facade`.

The authoritative report records cancellation; the last on-disk progress
snapshot precedes that final cancellation and must not override the report.
Engine stderr is empty; natural exit1, no forced cleanup, no outer-watchdog
timeout, authoritative owned zero and empty final job membership.761 source
hashes unchanged, source context unchanged. Failure BIN SHA256:
`0e2e56469ada79fd10ac87b45addfbc04b2434439788c40bfc6c4b7caf624bda`.
There is no finished blueprint or independent final physical proof.

Callback-interval attribution (not exclusive function profiling or frame time):
base compound structure proof156.331s; physical support resolution118.820s;
party-wall items75.876s before cancellation; lower facade panels42.868s.
Maximum callback gap19.077390s. Timing JSON states its attribution semantics.

Read-only inspection locates redundant full-source work:
`_complete_party_walls` already obtains a source-bound physical report, but
each `MasonryPartyWallBearingRecipe.plan` copies and fully validates the source
again before even identifying its failed bottom cohort. It can then validate
another copy with that facade removed to prove independent seats. Reusing the
first proof requires exact source-revision validation and invalidation after
any successful mutation; independent removed-facade proof must not be bypassed.
This is the next implementation candidate, not a measured speedup or approved
replacement yet. No support rule, timeout or acceptance gate was relaxed.

Hooke independently returned **PASS for this focused five-file street-boundary
commit** after verifying boundary03, Recipe11's failed cancellation accounting,
the failure hash and761-source audit. That verdict does not approve completed
integration, final physical/headed/performance acceptance or the proposed
party-wall optimization. No headed test ran during this checkpoint.
