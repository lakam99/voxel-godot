# Incremental paving and scene publication

Starting commit `4ad2ebb`, branch `codex/citadel-visuals-clean`. This is an
implementation follow-up to the real scene-construction job, not ordinary-world
activation or headed acceptance. The NPC baseline exception remains unchanged.

## Changes

- SettledCobbleGeometry now has a row/stone cursor. Its synchronous APIs drain
  that identical implementation. Traversal, arithmetic, history queries, IDs,
  transforms and regular/worn grouping remain unchanged.
- Paving publication retains one unfinished part until its geometry and existing
  mesh groups have completed. It never recreates collision while retrying.
- Mesh uploads allocate once, submit individual instances, and attach only when
  complete. The compatibility add_mesh_batch drains the same upload path.
- Static flushes retain the existing part boundary, material groups and ordering.
  Instance upload and recursive metadata cloning are resumable. Typed containers
  are shallow-copied before their child containers are replaced incrementally;
  an entire large nested part record is no longer an atomic deep-copy unit.
- Previously published metadata remains unchanged until source validation and
  replacement in one non-yielding commit. Retired snapshots/arrays are retained
  for the existing worker disposal after all scene nodes are removed.
- Resumes bind blueprint, parent and part identity. Paving uses private part
  data and one private immutable history snapshot per publication session.
  Small part bindings are checked on resume; original history is validated at
  first visible paving publication, paving completion and metadata/readiness
  commits. Public history changes invalidate rather than update a running job.
- Compatibility finish drains only an actual active flush. Pending masonry or
  parts cannot cause a finish loop that makes no progress.

All costs, including snapshot preparation, shallow container allocation and
commit validation, remain measurable. This does not yet meet the full frame
budget: wall construction and masonry preparation remain separate offenders.

## Evidence

Artifacts are under `artifacts/citadel-runtime-integration/`. Actual source is
the unchanged `actual-site-source-05/result.bin`: world `atlas-1492`, region
`(1,-3)`, recipe `1298433643`, scale `1.25`.

- `scene-publication-cobble-02`: 910/910, all 138 actual paving parts plus synthetic
  boundary, cancellation, query-order, packing and small-budget controls. The
  frozen original geometry script is independently hashed, not merely compared
  with the rewritten synchronous drain. Actual maximum stone unit 590 us;
  actual maximum 2,500-us-requested slice 2,750 us. This is CPU descriptor evidence.
- `scene-publication-flush-09`: 62/62, exact deep snapshot isolation, unchanged
  old metadata until commit, stale rejection before replacement, nonspinning
  finish, blueprint/parent/part/history rejection and CPU submission parity.
  Failed preparation additionally proves detached source/parent aliases and
  source release when the returned retirement payload is released.
  Runs have clean logs, natural exit and authoritative owned-process zero.
- The CPU submission oracle is the exact publisher at `4ad2ebb`, frozen with
  SHA256 `9db413eae5c45ab4ec65d3c310255c032850fb87bcf781c276d9304b07c37cc4`.
  Test-only instrumentation removes duplicate global class registration,
  substitutes the mesh constructor and redirects the adjacent native setter
  pair to a recorder that still calls each native setter once. Original loop
  ordering, transforms, arguments and custom data remain untouched. Controls
  require nonempty recordings and detect a deliberately altered submission.
- `scene-publication-job-03`: 117/117, including cancellation during paving
  geometry, upload and pending static flush, no later publication after cancel,
  and pending-part completion without duplicate collision.
- `scene-publication-incremental-paving-01`: existing paving publisher 139/139;
  `scene-publication-incremental-masonry-01`: existing masonry publication 158/158.
- `scene-publication-incremental-05`: final full construction 61/61, empty stderr,
  natural exit 0, frozen source hashes and authoritative owned-process zero.
  Every available render/metadata fact matches the pre-change actual05 baseline;
  4,703 building parts, 210 furnishings, 3,179 blocking shapes, 20 site-specific
  door IDs and four shared-system trees remain. Unique mesh/material references
  are released after teardown and worker retirement. The renderer limitations
  below still apply; these are not 20 registered gameplay doors.
- Final NPC quartet `scene-publication-incremental-npc-{contract,motor,nav_world,route}-01`:
  seed `atlas-1492`, both modes, fixed 60 FPS, isolated userdata, 45-second owned
  watchdog. Counts 84/84, 48/48, 84/84, 130/132. First three stderr files are exact
  to the preceding scene checkpoint; route stderr is exact to the previously
  accepted service checkpoint (250 headers, five visits per mode in the same
  32,000-us diagnostic). Same two known failed IDs, no new assertion failures.
  All four owned jobs emptied. No protected routing change or NPC repair claimed.

Actual headless reproduction:

```powershell
./tools/run-building-scene-publication-contract.ps1 -Phase actual -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-incremental-05
```

Focused scripts run through `tools/run-godot-scene-watchdog.ps1`, headless,
with isolated userdata and fresh report paths. The geometry script reads
`SETTLED_COBBLE_CURSOR_OUTPUT`; the flush script reads `BUILDING_STATIC_FLUSH_REPORT`.
The scene job contract reads `BUILDING_SCENE_PUBLICATION_JOB_OUTPUT`. Exact
engine argv and owned cleanup evidence are retained in each `watchdog.json`.

## Failed experiments and evidence limits

The first geometry-contract launch failed on two inferred Variant declarations;
the corrected contract is the successful `-02`. Flush `-01`/`-02` exposed that
headless Godot returns empty MultiMesh buffers and placeholder getters. They
remain failed native-readback evidence. Actual04/05 fingerprints from the prior
checkpoint never proved per-instance GPU fidelity; the earlier report has been
corrected. Native setter overrides also did not intercept static native dispatch
(`flush-03`), so the test uses the explicit writer adapter, not empty-trace parity.
Flush `-06` is invalid despite its Boolean because its synthetic pending-masonry
double lacked a metrics field. `-07` repairs that test error with clean logs.
Flush `-08` failed to parse an inferred WeakRef; `-09` supplies the explicit type.
Integrated `-03` failed its two resource-release checks because the added memory
observer retained its iteration inputs across later awaits. The isolated-call
observer in `-04` and `-05` releases those aliases; both release checks now pass.

CPU submissions are not rendered equivalence. Existing mesh-resource, scene-node,
material, count and metadata fingerprints remain useful but cannot replace the
later critic-approved headed visual run. No screenshots or ordinary Main/New Game
city spawning, gate traversal, save/reload or runtime smoothness are claimed here.

## Measured tradeoffs and next work

Final actual05 requested slices are 2,500 us, capped at 4,000. Observed maxima:

| Work | Maximum |
| --- | ---: |
| Paving geometry advance | 2.82 ms |
| Paving mesh upload advance | 2.50 ms |
| One-time private history snapshot | 3.25 ms |
| Recursive metadata initial shallow copy | 1.03 ms |
| Recursive metadata unit | 0.48 ms |
| Static flush validation/commit | 21.22 ms |
| Masonry setup | 11.48 ms |
| Remaining ordinary wall/part publication | 39.43 ms |

The original 235.782-ms paving part and 102.508-ms metadata replacement no
longer run as indivisible copies. However, full scene publication now takes
**49.994 seconds**, compared with 16.676 seconds before this scheduling change.
The recursive metadata loop consumes 6.466 seconds cumulatively and creates
additional scheduler turns. This is explicitly NOT a throughput or complete
smoothness win. `measuredBudgetsMet` remains false.

There are 16 retained metadata prefixes, totaling 24,305 repeated records and
108,796,452 serialized bytes. This is an encoded footprint, not measured heap or
GPU memory. Repeated prefix copying/retention needs improvement before ordinary
activation. Prefer bounded batches of provably cheap copy work or safely reused
immutable artifacts over simply adding more yields. Preserve independent source
isolation and old-snapshot stability. Wall descriptors, masonry setup and final
validation still need their own measured bounded work.

The independent critic approved this focused implementation checkpoint after
verifying final actual05, all 13 recorded source hashes, exact available fact
comparisons, resource release and the ownership/cancellation/NPC closeouts.
This is not performance completion, ordinary activation or headed approval.
