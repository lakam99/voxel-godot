# Citadel landscape preparation cancellation

Baseline: `codex/citadel-visuals-clean`, `f81799d`. Production scope is only
`CitadelUrbanPocComposer.gd`; no route, terrain, rendering, furniture or tree
grammar edits. Main owns the production patch; Hypatia owns the source contract
and wrapper. Bernoulli independently reviews the combined evidence.

## Change

The existing perimeter-house, tree-candidate and shared tree-recipe loops accept
an optional continuation. Omitted/empty continuations preserve their old calls.
The composer owns a terminal per-call cancellation latch: a rejected callback
discards the private source and returns `cancelled`, rather than interpreting an
empty tree selection as success. The void house helper may mutate its private
input before cancellation; rollback/reuse of that partial input is not promised.
Selection and tree-record helpers never return partial arrays on cancellation.
The normal biome catalog, tree request builder and TreeSpawnService remain the
tree authorities.

## Historical phase evidence

All directories below are under `artifacts/citadel-runtime-integration/`.
Commands use `tools/run-citadel-landscape-cancellation-contract.ps1`:

```powershell
./tools/run-citadel-landscape-cancellation-contract.ps1 -Phase baseline -OutputDirectory artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01
./tools/run-citadel-landscape-cancellation-contract.ps1 -Phase parity -Mode omitted -AuthorizeCurrent -BaselineDirectory artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/landscape-cancellation-omitted-02
./tools/run-citadel-landscape-cancellation-contract.ps1 -Phase parity -Mode empty -AuthorizeCurrent -BaselineDirectory artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/landscape-cancellation-empty-01
./tools/run-citadel-landscape-cancellation-contract.ps1 -Phase parity -Mode true -AuthorizeCurrent -BaselineDirectory artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/landscape-cancellation-true-01
./tools/run-citadel-landscape-cancellation-contract.ps1 -Phase cancellation -AuthorizeCurrent -BaselineDirectory artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/landscape-cancellation-stages-01
```

Baseline 14/14, each parity mode 26/26, cancellation/empty controls 102/102:
**194/194**. All five selected runs exited naturally with code 0, no engine
errors/warnings and clean owned-process cleanup. Reports and checkpoint traces
are in `report.json`; `launch.json` binds dependencies and archived source;
`watchdog.json` records process ownership and exit. No screenshots are claimed.

The archived `f81799d` composer runs its original prefix against the existing
typed actual compound (recipe seed `1298433643`, 5,204 input parts). Its capture
variant observes house input/output and stops immediately before tree selection;
the unmodified archived helpers compute the comparison outputs. Inputs contain
3,604 pre-house parts, 4,111 post-house parts, 4,205 pre-tree parts and four tree
sites. Baseline SHA256:
`89afc07894548b0541cdc6919be0825c8c2c4e1b1929846839cbf0e1b9640ee1`.

Complete typed house snapshots, tree positions and tree records match old output
without exemptions, including omitted, empty and always-true callbacks. Tests
also verify unchanged global RNG, dependency/input immutability, twelve rejection
positions, no callback/mutation after rejection, partial-house prefix provenance,
and legitimate empty selection versus cancelled selection. This is historical
source-contract evidence, not a complete rebuilt source or a live game.

The first `landscape-cancellation-omitted-01` launch failed to parse a test-local
untyped boolean. Its logs are retained. The explicit boolean correction passed
in `omitted-02`; the failed run is not acceptance evidence.

## Actual owned Source cancellation

`site-landscape-cancel-01/run.gd` runs real Queue -> Site -> Source for world
`atlas-1492`, region `(1,-3)`, scale `1.25`. It observes tree selection and requests
cancellation from the owner while candidate work is active. The recorded command
is the headless `--script` invocation in `watchdog.json`, using the existing
`run-godot-scene-watchdog.ps1`, a 120-second deadline and owned stop-request file.

**10/10**: cancellation caller 5 us, rejection 7.850 ms, actual Site return
25.149 ms and queue result 27.730 ms. External owner polling maximum 148 us.
No publishable blueprint/furniture, no callback after rejection, no subsequent
roof-frame stage; result consumed once and shutdown/retirement drained. Natural
exit 0, empty stderr and clean owned-process cleanup. `report.json` includes the
actual source-return observation; this is not a mock construction or timed delay.

The unchanged retained-paving adapter also passes 17/17 at
`landscape-adapter-parse-01`. It parses the modified composer but does not prove
landscape behavior.

## Complete Site preservation and remaining timing limits

`site-build-queue-real-04/run.gd`, through the same headless watchdog with the
unchanged 450-second deadline, completes in **393.227095 seconds total runner
elapsed (including artifact comparison)**, **8/8**. This is not isolated Source
preparation time.
World/region/scale are as above. The complete result matches
`actual-site-source-05/result.bin`, excluding only root `preparationUsec` and
survey `slices`, `maxSliceUsec`, `maxColumnUsec`, `sliceOverruns`, `preparationUsec`,
`workUsec`. Geometry, furniture, profile, manifest and all other fields are exact.
Result SHA256: `a92648f926a1ad142c21d24c92a29edc93ade01c8986d1910eaa50eb718746ba`.
Natural exit 0, empty stderr, clean owned-process cleanup. The observation-only
queue subclass records bounded per-stage aggregates and 1 Hz progress snapshots;
those measurements are not added to the production payload.

There were 1,313,321 source callbacks. The largest measured interval was shop
preparation, **2.555484 s**. Some structural house/panel intervals remain around
1.1-1.2 s. Geometry-manifest construction was 709.321 ms. Landscape intervals:
manifest 328.905 ms, house 28.116 ms, candidate 22.483 ms, tree recipe 177.998 ms.
External whole owner poll maximum was 4.251 ms; source-return tail was 171.318 ms.
These are observations, not universal cancellation or frame-budget guarantees.
Source work remains off the gameplay thread. No claim of zero atomic work above
8 ms, faster generation, live streaming or visible freeze-free behavior is made.

## Review and next boundary

Bernoulli independently approved this source-only patch and evidence. No headed
launch is approved by this report.
The next integration boundary is native terrain admission followed by ordinary
building/tree/door publication. The remaining shop/manifest intervals are known
shutdown-latency limitations, not a reason to reopen an unlimited source-only
optimization campaign. Actual New Game spawning, approach, collision, re-entry,
saves and visual/performance acceptance remain unproven.
