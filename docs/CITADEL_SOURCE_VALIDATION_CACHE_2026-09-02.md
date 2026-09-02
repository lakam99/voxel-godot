# Citadel source-validation cache

Scope: transient geometry reuse inside one synchronous physical resolve or
validation pass. This is not a source recipe, geometry, furniture, navigation,
save or publication change. Part object identity keys transforms, inverse
transforms and bounds. Neighbour-grid results preserve original ordering and
ID deduplication. All caches are released when the owning pass returns; nested
resolve preserves the enclosing validation cache. Rooted-chain verdicts and
mutable physical proof facts are not cached.

Starting branch `codex/citadel-visuals-clean`, HEAD `62333f6`. Other terrain and
site-integration edits were in progress separately and are not part of this
cache change. Scope of the focused cache commit: `BuildingBlueprint.gd`, the
synthetic `BuildingValidationCacheContract.gd` and this evidence note.

## Verification

All runs used `tools/run-godot-scene-watchdog.ps1 -Headless -Scene '--script'`
from this worktree with the bundled Godot 4.6.1 console executable. Complete
commands, arguments, timestamps and owned-process results are in each
`watchdog.json`; reports and stdout/stderr sit beside it under
`artifacts/citadel-runtime-integration/` (ignored generated artifacts).

- `cache-check-small-01`: 75/75 synthetic cache checks, including direct part
  mutation between passes, nested ownership, negative grid coordinates,
  duplicate IDs, collision changes and cleanup. Scene argument:
  `res://scripts/testing/buildings/BuildingValidationCacheContract.gd`.
- `cache-check-differential-02`: 17/17 independent old/new checks on the exact
  frozen reviewed 4,649-part source. Original script was fetched from Git blob
  `eef5d5ee92a913454226ab71f26bad077fab3a73` at `62333f6`, with only its global
  class declaration removed to compile beside the current class. Old/new direct
  resolve and full validation produce byte-identical complete reports and
  post-proof snapshots; no physical violations. Scene argument:
  `res://artifacts/citadel-runtime-integration/cache-check-differential-02/differential.gd`.
  Resolve: 10.847226 -> 7.956362 seconds. Validation: 12.470659 -> 9.106843 seconds.
- `source-profile-03/run-02`: 8/8 gates on the actual shared preparation API,
  seed `237207443`, forest / river-citadel context, scale `1.25`. Entire
  6,748,364-byte typed handoff is exact, including 4,649 building parts, 146
  furnishings, access reservations and diagnostics. All 82 dependency hashes
  are stable across the build; the loaded API resource also matches disk.
  Scene argument:
  `res://artifacts/citadel-runtime-integration/source-profile-03/run-02/profile.gd`.
  Preparation took 234.666797 seconds versus the earlier diagnostic 268.342760
  seconds: 12.55% less. This is a single-seed diagnostic, not an isolated
  benchmark or a runtime-loading performance pass.

Successful runs have empty stderr, natural exit 0, clean watchdog cleanup and
authoritative zero owned processes. No screenshots are claimed for these
headless source contracts. Reference envelope SHA256:
`f949a4bcacdaf0c5e5fec060979f16eac1012493fe3a30e1a62b2a5a172f8aa2`.

Failed attempts remain recorded, not relabeled: `source-profile-01` collected
timings then failed on an incorrect binary-envelope reader and was promptly
stopped with owned zero; `cache-check-differential-01` and the root
`source-profile-03` attempt exited at diagnostic-script parse errors;
`source-profile-02` matched the complete handoff but failed its source-stability
gate because the main agent edited the preparation API during the run. The
fresh `source-profile-03/run-02` supersedes that failed run. Source dependencies
were frozen for the successful rerun.

The tested preparation API contains a new optional stage callback; its default
path is covered by the full equality run. Cancellation behavior is not part of
this cache acceptance, nor is that separate API edit part of this cache commit.

## Limits

Cold preparation still takes minutes. These results do not prove acceptable
streaming latency, worker cancellation/exit latency, incremental publication,
player collision, trees, door operation, NPC behavior, native navigation,
main-menu spawning, unload/re-entry or save/Continue. The existing physical
publication bypass remains explicit and is not resolved by a physical source
report passing. The active goal remains **continue until citadel spawns correctly**.

Independent critic approved the cache-only commit after the small contract,
old/new differential and successful current-tree source rebuild. The callback
API and terrain work remain separate reviews.
