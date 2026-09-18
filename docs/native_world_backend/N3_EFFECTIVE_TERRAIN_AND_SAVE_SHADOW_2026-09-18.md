# N3 Effective Terrain And Save Shadow Milestone — 2026-09-18

Status: **shadow milestone complete; N3 production cutover incomplete**.

The commit range `15c43b146847719e927df9b911fef2bc158e9706` through
`a31068dfe340035f79f32fe117e3285510d9aa16` establishes a native shadow
implementation for effective terrain queries and the current v2
`terrainVolume` checkpoint. It does not switch a production caller, delete a
Godot authority, replace `SaveSystem` file/envelope I/O, or complete N3.

## Committed slice

| Commit | Bounded contribution |
|---|---|
| `15c43b146847719e927df9b911fef2bc158e9706` | Added native volume-surface facts to the effective-terrain result. |
| `ad26e585267bd1bb25acdd2f911804e258797e69` | Replaced the hand-authored candidate oracle with a production-derived Citadel candidate/profile fixture. |
| `babc6ffd14f723365ba58c38ab44c509e24b4921` | Added the `NativeWorldBackend` shadow Godot adapter and page contract. |
| `fc5581d8fac08bc15ef742df5e1caf604d04dba2` | Separated world-position sample material semantics from generated cell-state/lattice material semantics. |
| `c820f89d0c39d80ba3d75f84e1a17b0d126c9151` | Validated typed, production-sized terrain checkpoints without routing them through the small generic value algebra. |
| `46e740a22550ee901c327eaaf4d1798555de4b31` | Admitted only verified production terrain profiles at the Godot boundary. |
| `1ed4d1703fef3168f8664f8b6443e42487e18d33` | Added the independent Godot/native effective-terrain differential. |
| `f581dc23bb39c1f856aba6dab188cf5a06333800` | Preserved canonical v2 section/cell ordering, persisted revisions, and exact `saveDelta` truthiness. |
| `96b1a937a91c10da0ff8242d6684d026b0e74022` | Added shadow-only v2 `terrainVolume` import/export and mutation bindings. |
| `a31068dfe340035f79f32fe117e3285510d9aa16` | Added the isolated Windows release-export save-adapter gate. |

## Migration translations corrected before evidence was accepted

These were semantic corrections, not cosmetic test changes:

- The candidate-site oracle now obtains a real `CitadelSiteField` candidate and
  rebuilds the production manifest/terrain profile. A convenient hand-authored
  profile was not accepted as a production-semantics oracle.
- Direct surface-column sampling, cell-center sampling, lattice-origin numeric
  sampling, arbitrary world-position sampling, and surface projection remain
  distinct contracts. Float32 world remapping can change the source cell; the
  oracle and native path retain requested and source coordinates separately.
- Volume surface height follows `TerrainVolumeService`'s bounded top-down solid
  scan and includes effective durable/scene-overlay cell precedence. It is not
  interchangeable with the shaped reference height.
- World-position sample material follows
  `WorldGenerationSystem.material_from_sample_components`: it does not inherit
  the generated cell-state bedrock or deep-stone substitutions. Lattice and
  cell-state queries retain those substitutions.
- A production-sized typed terrain checkpoint is admitted against the
  65,536-record/4,096-cells-per-section limits. It is not first squeezed
  through `NativeValue`'s 1,024-container-entry/4,096-node convenience limits.
- Canonical v2 durable cells are ordered by section z/y/x and then cell z/y/x,
  including negative section decomposition. Native lookup and mutation use
  that same order instead of a flat cell-only ordering.
- `terrainVolume.revision` and per-section revisions are persisted metadata;
  they are not aliases for the native aggregate store revision. Durable native
  commits advance the persisted terrain revision while old pins stay immutable.
- `metadata.saveDelta` matches Godot 4.6.1 `bool(Variant)` behavior: Boolean
  `true` and finite nonzero numbers persist; Boolean `false`, numeric zero, and
  non-convertible values do not become canonical durable cells. Scene overlays
  remain effective at runtime but are excluded from v2 export.

## Evidence and immutable hashes

| Evidence | Authoritative artifact and SHA-256 | What it proves | What it does not prove |
|---|---|---|---|
| Aggregate native build/test/coverage | `artifacts/native-world-backend/n3-release-export-save-gate-07/report.json` — `bc257d47c5e8a19fe442555232dd10644b4e96dfc96652967d09e492fb528eb1` | Debug and release each passed 259/259 pure-core tests; 26 pure-core translation units reached 5,972/5,972 lines, 774/774 functions, and 3,016/3,016 branches; the debug adapter smoke and release-export gate also passed. | Coverage is pure-core coverage, not Godot adapter line coverage. It is not gameplay, production-call, render, collision, navigation, or save-file journey evidence. |
| Effective-terrain differential | `artifacts/native-world-backend/n3-effective-terrain-bottom-projection-01/receipt.json` — `1d211a72643ffcd1f28e8a23efc44e3b1b775ac129286f053cb4d771002fbcb1`; fixture report `artifacts/native-world-backend/n3-effective-terrain-bottom-projection-01/fixture-report.json` — `443c35a4a77ebea633b49a04d6acbd343119d760f2b6e8619393843c036e29bf` | Independent Godot goldens and the native adapter matched with zero mismatches across the final 47-query denominator: 10 surface columns, 11 cell centers, 11 lattice queries, 6 world-position queries, and 9 surface projections, including bottom and bottom-plus-one. Durable edits, scene-overlay precedence, idempotent replay, conflict/stale rejection, affected-page identity, and old-pin lifetime were exercised without production mutation. | It is a bounded shadow fixture for seed `atlas-1492`, not broad live-world acceptance or a production source cutover. |
| Godot save-v2 contract | `artifacts/native-world-backend/n3-save-v2-adapter-contract-final-02/contract-report.json` — `bcf83d1bbdbb92f306065ea2996ed8d1c485b1bc2d1df3201d1fb8bef6afab13` | 149 checks passed for exact current `terrainVolume` v2 import/export, `SaveSystem` v2 envelope round-trip, negative sections, water/lava, metadata, one-shot initialization, durable mutation, overlay exclusion, ordering, 65,536-record admission, and 65,537/4,097 rejection. | It covers `terrainVolume`, not a complete `terrainVolume + removedProps + blocks` checkpoint. It does not replace `MainSaveState` or `SaveSystem`. |
| Exported release adapter | `artifacts/native-world-backend/n3-release-export-save-gate-07/release-adapter-smoke-report.json` — `c1362a5954d072c6e769d4b4eaecba1c9a5366b175e272b5f4aa800ef72fd705` | An artifact-staged Windows Godot 4.6.1 release export loaded the release DLL, registered `NativeWorldBackend`, performed exact terrain save-v2 restore/export, committed durable and overlay mutations, excluded the overlay from save output, and exited with empty stderr. | It is an isolated release-export probe, not the shipped main scene, a Continue journey, or proof that any production caller uses the adapter. |

The aggregate report was produced immediately before `a31068d`: its Git field
therefore records base commit `96b1a93` plus four dirty release-gate paths. The
report's bound hashes for those paths match their committed contents at
`a31068d`; the report does not pretend it was a post-commit clean run.

## Authority and cutover boundary

Production authority remains unchanged:

- `WorldGenerationSystem.gd`, `TerrainVolumeService.gd`,
  `VoxelTerrainGenerator.gd`, and `VoxelTerrainRuntime.gd` still serve live
  terrain generation, effective sampling, terrain publication, and edits.
- `MainSaveState.gd` still assembles gameplay snapshots, and `SaveSystem.gd`
  still owns the v2 envelope and file I/O.
- Repository caller search for `NativeWorldBackend` and its save methods finds
  only scripts under `scripts/testing/native_world/`. There is no production
  caller and no deletion candidate is yet authorized.
- No NPC route, motor, door, traffic, or navigation-production code was changed
  in this commit range. This evidence makes no NPC/pathfinding claim.

## Newly proven complete-checkpoint blocker

A complete current v2 world-delta checkpoint cannot yet be imported into
`NativeWorldBackendState` when `removedProps` is nonempty.

`MainSaveState.gd` legitimately writes nonempty `removedProps`, and the native
removed-prop/world-delta codecs can decode those stable IDs. However,
`WorldDeltaStore::validate_feature_admission` deliberately rejects every
nonempty tombstone snapshot. The tombstone contains only a generated feature
ID; no authoritative generated-feature footprint catalog currently resolves
that ID to every terrain/render/collision/navigation cell that must be
invalidated. Constructor-time `validate_initial_features` uses the same gate,
so accepting the codec payload would otherwise publish stale geometry with an
empty or incomplete affected-section receipt.

There is also an aggregate-capacity mismatch that must be redesigned rather
than hidden:

- `NativeWorldDeltasV2Payload.terrain_volume` is presently a `NativeValue`, so
  a complete aggregate decode inherits the generic 1,024-entry/4,096-node
  bounds even though the typed terrain codec correctly supports 65,536 cells.
- `WorldDeltaStore` defaults to one combined 65,536-record ceiling for durable
  terrain, overlays, tombstones, and player-created instances, while the
  current v2 domains expose independent production-sized limits.

The smallest mature next step is therefore not to approximate or drop
`removedProps`. It is to add an authoritative deterministic generated-feature
footprint catalog and catalog-backed invalidation, make aggregate terrain typed
instead of `NativeValue`, and define/test complete-checkpoint capacity across
terrain, tombstones, and player blocks. Only then can full checkpoint
import/export, production caller inventory, live save/reload evidence, cutover,
and deletion be reviewed.
