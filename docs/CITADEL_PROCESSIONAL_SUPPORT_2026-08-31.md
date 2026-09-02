# Processional stair support correction

Branch: `codex/citadel-visuals-clean`, base HEAD
`fcda6762c1923015e27cf622a63e87f6209118c0`; uncommitted recipe work preserved.
Known fixture: seed 208159, scale 1.25, forest / river-citadel.

## Owner and change

`CastleCompoundBlueprintBuilder.add_citadel_processional_steps` directly authored
elevated masonry as `structural_root`, with `physicalRoot=true` and a self-root
route declaration. Its lower face is above ground. Clearing derived root flags
therefore exposed seven failures hidden in the earlier 226-count reports: the
honest pre-repair physical baseline was 233.

The producer now declares elevated steps as structural mass with the existing
25-sample walkable-subfloor obligation. It selects actual, collision-backed,
geometrically grounded foundation supports contacting the lower face, records
their sorted IDs as mandatory seats and route-source roots, and leaves all tread
positions, sizes, rotations, materials, collision flags and visual variation
unchanged. No validator or navigation implementation was changed. No fallback
foundation geometry or authored seed-specific correction was added.

## Evidence

All run folders are under `artifacts/citadel-visual-reset/`. Their `watchdog.json`
records the exact command, executable, ownership and cleanup evidence; output is
`report.json`, with separate stdout/stderr. These are headless source/service
contracts, not gameplay acceptance. Standard outer timeout is 100 seconds.

Command entry point: the existing watchdog with `-Headless -Scene '--script'
-SceneArguments 'res://scripts/testing/buildings/CitadelProcessionalSupportContract.gd'`.
`VOXEL_PROCESSIONAL_SUPPORT_REPORT` selects each fresh report.

- `processional-support-01`: rejected. Physical, geometry and negative checks
  passed, but route-query tests sampled the exact outer edge despite that query's
  existing 0.015m rim exclusion. No production tolerance changed.
- `processional-support-02`: PASS, 223 checks. Actual producer variations,
  unchanged tread geometry, fresh/repeated/cleared-cache agreement, explicit
  non-self roots, missing-foundation and invalid-elevation rejection. Route-query
  checks use a 3x3 interior grid; physical bearing still tests its full 5x5 grid
  including boundaries.
- `processional-full-01`, with `VOXEL_PROCESSIONAL_FULL_CITADEL=1`: all seven
  stairs pass; physical results are 226 on fresh, repeated and cleared-cache
  validation; all 152 furnishings remain exact. Full test is RED because the
  existing raised-route coverage contract reports two failures.
- `processional-route-baseline-01`: repeats that full contract and evaluates the
  same route consumer on immutable reviewed source via
  `VOXEL_PROCESSIONAL_REVIEWED_BASELINE`. Both route failures pre-exist unchanged.
  Independent recursive comparison, also checked by the critic, finds exactly
  17 changed leaves: false stair self-root IDs become
  `castle_compound_foundation_segment_03`. No position, gap, height, coverage,
  pass flag or failure identity changes.

The immutable reviewed source is `market-reviewed-freeze-01/reviewed.bin`, SHA256
`e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038`.
All four runs have clean stderr and authoritative zero owned processes. The full
runs deliberately exit 1; their failed route assertion was not removed.

## Remaining failures and verdict

The reproduced route failures are:

1. The civic-approach and final-turn roadbed collision partitions overlap.
2. `processional_04a_palace_approach` lacks a collision-continuous declared
   roadbed-to-transition seam.

Critic verdict: **scoped stair-source correction and preservation PASS**.
The two pre-existing route failures remain RED. No headed authorization, NPC
navigation acceptance, material/GPU comparison, or zero-gate acceptance follows.
Unrelated recipe work may continue separately; the active physical-gate goal
remains incomplete at 226 integrated fresh-validation failures.
