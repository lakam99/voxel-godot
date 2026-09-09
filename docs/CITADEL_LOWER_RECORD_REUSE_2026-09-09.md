# Lower-facade record reuse

The private completion loop reuses its constructor-validated prepared parts for
support-delta queries. After an accepted proposal it replaces the changed panel
and appends three beams, including the ID map, instead of reconstructing every
part. Obstacle and duplicate-ID validation precede mutation. Unchanged metadata,
part order, raw-ID exclusions, support predicates and cancellation remain intact.

Evidence under artifacts/citadel-runtime-integration:

- lower-input-differential-04: 50 checks, including existing whole-completion
  baseline comparisons, cancellation, and five generated-record component
  replays. Old delta/advance totals 252330/198266us; new 141765/5264us. The
  component fixture moves three generated records to an appended delta; it is
  not an accepted composition or gameplay test.
- candidate-recipe-36: 91.717s total; source preparation 88.363s, independent
  physical validation 2.745s. All 4555 parts checked, zero physical violations.
  Source35 was 100.741s total. Single-run observations, not statistical timing.
- The lower_facade_panel_completed callback intervals fell from 7.530s to
  2.958s. These intervals include delta/advance/propagation work; they are not
  exclusive function CPU profiles.
- source-diff-27-36: only civicClearance/elapsedUsec differs.
- candidate-continuation-36: 24 checks passed.
- All above runs exited cleanly with zero owned processes.

Commands:
```
node tools/run-building-contract.mjs -Contract LowerFacadeInputReuseContract.gd -OutputDirectory artifacts/citadel-runtime-integration/lower-input-differential-04 -ReportEnvironment LOWER_INPUT_REPORT -TimeoutSeconds 60
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-36 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-36 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-36
```

Source preparation below 90 seconds does not establish usable arrival below 90
seconds. A headed run remains required; existing broader runtime failures are
recorded in CITADEL_BIOME_QUERY_REUSE_2026-09-09.md.
