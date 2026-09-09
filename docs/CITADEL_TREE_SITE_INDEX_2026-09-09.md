# Citadel tree-site query acceleration

Tree selection now builds a private spatial index once per selection, retaining
the existing source-space AABBs, distinct site/sample filters, paving order,
candidate order, scoring and cancellation callbacks. Oversized bounds use the
original intersection scan. A snapshot comparison rejects persistent source
mutation during selection with `tree_selection_source_changed`.

## Evidence

Artifacts are under `artifacts/citadel-runtime-integration`.

- `tree-site-index-01`: historical selection 10.096473s, indexed selection
  0.117125s, identical selected sites. Single-run timing, not a statistical benchmark.
- `tree-site-index-02`: 14 checks, including 135 positions with four queries
  compared against pinned historical helpers, paving order and boundaries,
  oversized/out-of-domain fallback, mutation rejection and five cancellation
  stages. Nonfinite and negative boxes were not explicitly tested.
- `candidate-recipe-34`: 99.637s total; 96.031888s source preparation and
  2.964754s independent physical validation. All 4555 parts checked, zero
  physical violations. Previous source33 total was 114.527s.
- `source-diff-27-34`: only `/civicClearance/elapsedUsec` differs. Generated
  content remains identical to the canonical structural-repair baseline.
- All these runs exited cleanly with owned-process zero.

Commands:
```
node tools/run-building-contract.mjs -Contract CitadelTreeSiteIndexContract.gd -OutputDirectory artifacts/citadel-runtime-integration/tree-site-index-02 -ReportEnvironment TREE_SITE_INDEX_REPORT -TimeoutSeconds 60
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-34 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady
```

The old frozen landscape runner rejected the changed dependency graph before
launching Godot. This was a fixture provenance rejection, not a production
failure; the focused comparison instead pins the historical input and composer.

This proves source parity and physical integrity, not live gameplay. The
90-second playable-arrival target remains unmet. No new headed acceptance is
claimed; the last observed headed arrival was approximately 279 seconds.
