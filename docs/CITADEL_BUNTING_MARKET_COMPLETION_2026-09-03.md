# Citadel market bunting completion

## Scope and baseline

Branch `codex/citadel-visuals-clean`, baseline `bc4cfaf`.
Ordinary candidate: world seed `atlas-30895044`, region `(-1,0)`,
recipe seed `541151883`, center `(-796,659)`.

The prior complete recipe diagnostic (`candidate-recipe-14`) finished its
structural stages in 301.083 seconds with one failure: `urban_bunting_rope_01`.
It was not a ready source or successful spawn. Its engine failure was followed
by owned-job termination and proven zero remaining job members.

The candidate teleport runner already exists in `20dffac` (initial runner
`ea1757a`). It skips the travel to an exterior candidate while retaining real
world generation/admission/streaming. Teleports are setup, not evidence of
continuous traversal, NPC movement, gate interaction or save/load acceptance.

## Recipe change

- The street producer declares the two actual market house owners and plaza.
  The bunting producer declares complete rope/pennant membership and gives its
  market assembly that association. The tree recipe refresh preserves it.
- The completion stage selects failed assemblies from a fresh ordinary physical
  proof bound to the exact source bytes. Passing assemblies are not repaired.
- Market placement is limited to the actual opposing facade pieces and the
  common plaza/facade envelope. It is not a castle-wide nearest-wall search.
- Independent rooted socket proof is required at both rope ends. Only finite,
  explicitly bounded rope endcaps enter the masonry; no flag gets an exemption.
- The whole assembly clears buildings, roof geometry, other bunting, furnishings,
  door sweeps and declared room interiors. Flag count, dimensions, material,
  rotation and relative sag remain unchanged. The rope length and the assembly's
  position may change to fit the real market.
- Proposals replace only existing selected records in a private snapshot. The
  ordinary threshold/final physical proof remains. Stored placements are then
  checked read-only; a later obstacle cannot trigger a hidden second relocation.
- Exhausted bounded samples mean tested placements were rejected, not that all
  geometrically possible placements have been proved impossible.

No protected navigation, movement, routing, doors, tree generation or furniture
recipe code was edited. No authored seed-specific placement, extra posts,
reduced flag count or relaxed physical threshold was introduced.

## Focused evidence

All paths below are under `artifacts/citadel-runtime-integration/` and contain
`report.json`, parse/run logs and watchdog records. These are source-only tests,
not headed gameplay acceptance. Runs use `tools/run-building-contract.ps1` with
the named contract, a fresh output directory and the report environment below.

| Run | Contract | Checks | Report environment | Outer limit |
| --- | --- | ---: | --- | ---: |
| `bunting-anchor-contract-09` | `CitadelBuntingAnchorRecipeContract.gd` | 91/91 | `CITADEL_BUNTING_ANCHOR_REPORT` | 45 s |
| `bunting-completion-06` | `CitadelBuntingCompletionContract.gd` | 33/33 | `CITADEL_BUNTING_ANCHOR_REPORT` | 45 s |
| `bunting-domain-03` | `CitadelMarketBuntingDomainContract.gd` | 83/83 | `CITADEL_MARKET_BUNTING_DOMAIN_REPORT` | 45 s |
| `bunting-manifest-01` | `CitadelBuntingAssemblyManifestContract.gd` | 83/83 | `CITADEL_BUNTING_MANIFEST_REPORT` | 30 s |

All four exited naturally with code 0, clean engine logs, no forced cleanup,
and authoritative zero owned processes. Contracts pin their source dependencies
and enforce their internal deadlines. Source-only runners do not produce visual
captures or claim production frame-time ceilings.

Example exact invocation:

```powershell
./tools/run-building-contract.ps1 -Contract CitadelBuntingCompletionContract.gd -OutputDirectory artifacts/citadel-runtime-integration/bunting-completion-06 -ReportEnvironment CITADEL_BUNTING_ANCHOR_REPORT -TimeoutSeconds 45
```

Lifecycle evidence includes a mixed failed/passing assembly batch, exact
preservation of the passing members, fresh failure selection, stale-input and
cancellation rejection, complete manifest coverage, ordinary terminal proof,
and rejection of a later column or changed/missing stored anchors without
relocation. Synthetic failures use real invalid socket geometry, not a mocked
failure report. Entry callbacks cannot redefine the pinned source or obstacle
policy. Both terminal-verification cancellation points remain cancellation through
the actual production wrapper, rather than being mislabeled invalid geometry.
Preparation and terminal verification both accept actual ordinary door-sweep
records through one normalizer; a real overlapping sweep and malformed record
remain rejected.

## Diagnostic limits and retained failures

`bunting-market-01` inventories actual archived market geometry: the facade gap
is about 14.76 m, versus a conservative 10.1031 m projection span for all 13
unchanged flags. This establishes a useful geometric domain, not clearance or
rootedness acceptance.

`bunting-candidate-01` attempted placement on the pinned **pre-structural** archive
`facade-input-capture-03/input.bin` (SHA256
`1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c`).
The domain and manifests passed; the proposal was rejected in 7.738 seconds.
Only two facade candidates on each side were independently rooted in that early
archive; their tested original-span sockets failed. The run exited naturally
with code 1, clean logs and zero owned processes. `proposal.bin` is offline
diagnostic evidence and is never injected into gameplay. This does not establish
failure or success on the later fully supported source.

Earlier failed contract evidence is retained:

- Anchor04 expected overlapping assemblies to be rejected, but its wide mounting
  courses admitted distinct clear alternatives. The corrected control uses real
  narrow courses and first proves each lone assembly can fit.
- Domain01 used zero-height foundations, which the real house producer correctly
  rejected. Domain02 supplies a positive base and derives plaza height from the
  emitted foundations. Domain03 additionally covers post-completion timber heads
  in sealed facade declarations without treating timber as masonry anchors.
- Completion01 had a test type-inference parse error. Completion02 used a rope
  that the ordinary generic support proof accepted, so no repair was selected.
  Completion03/04 use genuinely invalid mandatory endpoint sockets; 04 adds a
  simultaneously passing assembly and checks its exact preservation.

## Remaining acceptance

The critic-approved full-source run `candidate-recipe-15` reached the terminal
bunting verifier after the ordinary terminal physical gate and final sign checks,
then failed at 349.146 seconds with `terminal_bunting_invalid` /
`invalid_bunting_protected_volume`. All 780 launch-pinned sources were unchanged,
with no read errors. The structured engine failure triggered forced owned-job
cleanup; functional exit was unavailable, no timeout occurred, and zero remaining
members was proven. This was not a ready source or successful spawn.

Cause: preparation accepted AABB or `{bounds:AABB}` obstacles, but the new stored
verifier accepted only raw AABBs. Production door sweeps are dictionaries carrying
name/moving fields and their authoritative bounds. Both phases now use the same
normalizer; completion06 exercises real door-sweep records in both phases and
keeps blocking/malformed records fail-closed. No door or geometry rules changed.

The critic approved one further headless diagnostic at the unchanged limits:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-16 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

Recipe16 ran the completed structural pipeline, including ordinary terminal
physical validation, final signs and stored bunting verification. It reached
`structural_later_completed`, committed that private blueprint and checked exact
furnishing/reservation preservation. The **later** final civic clearance gate
then rejected `urban_civic_house_east`: `composed_civic_clearance_failed` /
`no_clear_fixed_x_placement`, three tested candidates. Its envelope is
`AABB((37.76284,0,-26.76097),(12.60383,14.82176,13.2))`.

Source preparation took 361.621 seconds. The process exited naturally with code
1, clean engine logs, no timeout or forced cleanup, and proven zero job members.
All 780 source hashes remained unchanged with no read errors. The failure BIN
SHA256 is `d29a3150a9d5f79b022b3ab00a5988d32952b9a1c9f2775cc2d3102d2580d792`.
Report, progress, timings, hash audit and watchdog evidence are retained under
`candidate-recipe-16/`.

This completes the bunting stage, **not the full recipe or game integration**.
The civic gate was not reached in Recipe14; its cause is previously masked and
unverified, not declared unrelated or waived. Its owning clearance/ownership
contract is the next investigation. There is still no ready source export or
extra independent final-source proof. Limits remain 450-second source,
60-second independent proof and 540-second outer diagnostic.

Headed work requires a subsequent explicit critic GO. Screenshots, actual
candidate terrain admission, publication and visible citadel preservation
remain unproven here. No headed test was launched in this repair chunk.
