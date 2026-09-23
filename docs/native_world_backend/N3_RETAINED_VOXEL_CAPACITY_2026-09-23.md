# N3 retained voxel demand capacity

This is a capacity contract for the native *retained data-block* queue, not a
claim that Voxel Tools' viewer has been replaced or that production streaming
passes. `NativeVoxelBlockDemandFootprint` continues to limit each incremental
mesh-demand call to 64 mesh keys / 128 halo data keys. That batch bound must
not be confused with the queue's simultaneous resident-key bound.

## Current runtime dimensions

`VoxelTerrainRuntime` has 16-cell mesh blocks, an 80-distance startup primary
viewer and 96-distance final primary. Its startup vertical cell bounds are
-16..48, or five mesh Y layers and seven data layers with a one-block halo.
`WorldGenerationSystem` declares a -64 bottom and, with the production
`MainInterface.MAX_HEIGHT=120` and cell size 1.35, a top of 93. Runtime's
four-cell margin therefore makes full bounds -68..97: 12 mesh Y layers and
14 data layers with halo.

Voxel Tools' exact resident set is dynamic and must be measured from the
engine during cutover. The following deliberately conservative *rectangular*
bounds treat the view distance as cells (the site gate does likewise), permit
an unfavorable center/grid alignment, and add one data block on each XZ side
for Transvoxel input. They are upper bounds for a single viewer, not observed
exact residency:

| Viewer | XZ mesh span bound | Halo data span | Vertical data layers | Data-key rectangular bound |
| --- | ---: | ---: | ---: | ---: |
| Startup primary (80) | 11 × 11 | 13 × 13 | 7 | 1,183 |
| Final primary (96) | 13 × 13 | 15 × 15 | 14 | 3,150 |
| Maximum admitted auxiliary (128) | 17 × 17 | 19 × 19 | 14 | 5,054 |

The default 16,384 retained-entry cap covers a final primary and two
nonoverlapping maximum-distance auxiliaries (13,258 keys), leaving 3,126
entries for overlap transitions or other demand. It does not guarantee all
possible auxiliary configurations: the current runtime has no fixed global
secondary-viewer count. The adapter permits an explicit measured-union
capacity from 128 through a hard 32,768 entries. Entry capacity does not
increase the separate one-worker limit or 4 MiB prepared-byte limit.

If a request would exceed the entry cap, the adapter returns retryable
`pending/queue_capacity` with retained/max-entry and cumulative rejection
telemetry; it does not register that request. The caller must keep that demand
in its desired set and retry after a release/retirement, or configure a larger
bounded cap for an intentionally admitted viewer union. A released request
becomes reclaimable through native retirement; an active request is never
evicted to make room for a new one. At the hard cap, production admission must
defer additional viewer attachment or reduce the demanded union by normal
viewer retirement; merely raising the cap again or losing the rejected
request is not a solution.

Focused pure-core tests cover resize without changing retained consumers,
rejection without insertion, and retry after release/retirement. The adapter
exposes current and peak entries, cap, prepared bytes, in-flight count, and
rejection count in `status()`. The remaining integration work is to measure live exact
viewer unions (including movement handoff and secondary viewers), configure
before admitting each union, and prove retained retry under a capacity-full
headed fixture.
