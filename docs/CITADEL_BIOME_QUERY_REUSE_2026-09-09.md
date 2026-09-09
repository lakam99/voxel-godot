# Deterministic biome query reuse

BiomeRegionField memoizes site positions and climate channels in two per-instance
maps bounded at 4096 entries each. Exact raw seed, region and channel inputs bind
values. Mutex-protected lookup/storage permits shared callers; calculation occurs
outside the lock. Sampling, nearest-site order, climate math and biome authority
are unchanged. No generated world or save data is cached here.

## Evidence

Paths below are under artifacts/citadel-runtime-integration.

- biome-sampling-01: production survey observation, 87009 columns. 945780
  site calls used nine unique inputs; 171960 climate calls used two inputs.
  Instrumented field time 8.990s; survey work 11.617s.
- biome-sampling-02: same biome counts and height extrema; field time 1.046s,
  survey work 3.327s. Its archived scope string incorrectly says no cache;
  this run uses the cache. The observer source now describes scope correctly.
  These checks compare summaries, not every column.
- biome-memo-03: 20000 complete byte-equal field outputs across multiple seeds,
  clustered/distant points and eviction; 8000 additional comparisons across four
  concurrent callers sharing one field instance. Both maps remain bounded.
  Frozen original source differs only by removal of its global class name;
  its SHA is pinned in the differential.
- Existing biome contract runner: 5/5 passed.
- candidate-recipe-35: 100.741s total, all 4555 physical checks, zero violations.
  source-diff-27-35 differs only in civicClearance/elapsedUsec.
- candidate-continuation-35: 24 checks passed. Terrain admission 7.826s versus
  26.111s in continuation34. Publication preparation remains 16.843s.
  Focused/source/continuation runs exited cleanly with owned-process zero.

## Runtime findings and limits

`node tools/run-playtest.mjs` used atlas-1492. Its partial report reached 97
checks with a tutorial guard/home failure before the engine-log safeguard stopped
the job on dummy-renderer mesh/RID errors. Archived report/watchdog are in
biome-runtime-35. This was not a passing broad run.

Replaying the same command/seed with the original HEAD-equivalent field reached
82 passing checks before dummy-renderer RID initialization/mesh errors also
triggered the safeguard. See baseline-playtest.json, baseline-stderr.log and
baseline-watchdog.json. This establishes renderer failure without the memo; it
does not prove identical timing, clear the defect or attribute the NPC failure.
Both jobs proved zero remaining owned processes, but cleanupPassed was false.

Normal-runtime launch exposed a runner defect: playtest/seed overrides and fixed
FPS conflicted with the fixture's ordinary-startup contract. Commit c480fef fixes
that launcher only. Failed preflight attempts 01/02 remain recorded.

Normal-runtime-03 then exercised New Game and 75s traversal in atlas-76968016:
33.613s to gameplay, 609.456m travelled, 2320 collision samples, minimum collision
clearance -0.0701m. P95 14.469ms, P99 17.089ms, worst frame 159.75ms. The worst
spike was chunk/terrain_meshing_job_queue (157.005/156.062ms, nested timings).
It failed the 33ms frame limit and reported shutdown resource leaks. Owned zero
was proven; exit was not clean. These performance/shutdown defects remain
unattributed. A window capture was obscured and supplies no visual acceptance.

No 90-second citadel-arrival or completed gameplay acceptance is claimed.
