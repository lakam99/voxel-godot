# N4 underground generated-prop ordered-source shadow

Date: 2026-09-24
Stage: N4 bounded diagnostic candidate; no production cutover

## Authority and parity boundary

Production remains in `MainPlaytestTools.gd`:

```text
begin_chunk_prop_spawn_state
  -> scan_underground_prop_candidates_from_volume_service
  -> TerrainVolumeService exposed-floor scan
  -> process_underground_chunk_prop_spawn_state
  -> spawn_underground_prop_attempt
  -> make_ore_cluster(count = 1) | make_rock | make_forage("swamp")
```

The native candidate consumes one immutable `WorldSourcePin` through
`NativeEffectiveTerrainSource`. It does not sample terrain independently. Its
floor scan is the exact 28 by 28 x-fastest source order, accepts only the first
36 exposed-floor cells whose stable candidate hash is at most `0.18`, and binds
the terrain-delta and shaping-registry revisions and identities into the scan
receipt.

The shadow performs that immutable 28 by 28 scan eagerly. This matches the
unbudgeted production `underground_prop_candidate_cells` oracle used by the
differential, whose single large volume-service advance traverses the whole
chunk before Main retains the first 36 rows. It does not claim parity with the
incremental runtime scan's work counters: a small-budget production scan may
stop requesting more volume work as soon as its retained list reaches 36.
`scannedCells` and `scannedColumns` are diagnostic native-work receipts, not a
production scheduling or performance contract.

`NativeUndergroundPropStream` uses the separate
`seed:underground-props:cx,cz` PCG stream. Each attempt preserves the production
root removedProps gate before any draw, the stable
`seed:underground:x,y,z` ID, direct iron/copper material selection, deep-stone
ore selection, six-draw rock recipe, swamp forage recipe, and the one-child ore
cluster draw stream. The ore child helper is shared with the existing native
two-child surface cluster; cardinality is an input, not a copied recipe.

The adapter endpoint `compose_underground_prop_ordered_shadow(page, chunk)` is
read-only. Its response declares all of these as false:

- `publishable`
- `channelFootprintsComplete`
- `removedPropsMutated`
- `collidersInstalled`
- `routingInfluenced`

No result is cached into a production owner, installed into the scene, passed
to navigation, or used to alter production spawning.

## Rejection boundary audit

The public surface accepts already-admitted native values rather than raw
metadata. Raw seed validation is centralized in `hash_key`; malformed or
forged admission receipts become `NativeUndergroundPropRejected`. Chunk bounds,
seed/source mismatch, scan/source identity drift, catalog/environment mismatch,
and incompatible transitions reject locally with the same domain type.
Cancellation is checked before work, at each scan column and cell, at each
attempt, and after each batch, and remains the distinct
`NativeUndergroundPropCancelled` type.

After those guards, the scan only invokes page-bounded queries on a ready
`WorldSourcePin`. The stream consumes immutable values already admitted by
`NativeFeatureDeltaSnapshot`, `NativeBiomeEnvironmentCatalog`, and
`NativeSurfaceRockAssetCatalog`; recipe inputs are derived from bounded PCG
draws, validated terrain enums, stable nonempty IDs, and the admitted fixed
swamp profile. Consequently there is no raw caller-controlled
`std::invalid_argument` path to translate inside the typed scan/stream body.
Focused tests pass forged seeds and mismatched pins/catalogs through every
public entry point and require the underground domain rejection type. This is
why exception translation exists at raw seed admission, while redundant broad
catches around already-admitted dependencies are intentionally absent.

## Evidence

The candidate is not complete until all of the following are recorded here:

1. focused MSVC debug and release tests for the shared ore helper and complete
   underground source stream;
2. focused LLVM tests and exact line/function/branch coverage for every added
   pure-core line;
3. the source-manifest inventory gate;
4. `tools/run-n4-underground-prop-source-differential.mjs`, with Godot's Dummy
   audio driver and `VOXEL_DISABLE_AUDIO_PLAYBACK=1`, comparing the exact
   production scan/spawn methods to the native diagnostic;
5. independent review of source parity, corruption/rejection boundaries, and
   proof that no publication or routing authority was introduced.

Current source freeze:

- `native_underground_prop_stream.cpp` SHA-256:
  `705847514b00a648f122e82fc84b34eb9975a10a3639ab8bb38bb60c469a3328`;
- `native_underground_prop_stream_tests.cpp` SHA-256:
  `87ff76fedb485cc544ec67144eb6fa7965ed8db6ab66eb337551eedbfa64002e`.

Completed standalone evidence:

- MSVC debug build command: pinned BuildTools 14.44.35207 through
  `tools/lib/native-compiler-owned-wrapper.mjs`, invoking `scons.exe -Q -j2
  platform=windows target=template_debug arch=x86_64 api_version=4.6
  custom_tools=<worktree>/native/terrain_meshing/scons_tools`, with
  `VWB_CONFIGURATION=debug` and `GODOT_CPP_DIR` bound to the clean primary
  godot-cpp checkout at revision
  `ba0edfed90512ec64aba51d4295a3e7e30112f86`;
- debug build and test watchdogs:
  `artifacts/native-world-backend/n4-underground-props-msvc-debug-20260924-3/build-debug.watchdog.json`
  and `test-debug.watchdog.json`; both record functional/overall exit `0`,
  `cleanupPassed=true`, and `authoritativeZeroProven=true`;
- debug test result: `634/634`, failed `0`, stderr empty; executable SHA-256
  `8c8f4bc3b1923cb26f0c44b7201905b3eae47080d1fc45b887aa0574f787e235`;
- LLVM command: repository `runLlvmCoverage` with the pinned LLVM `23.1.1`
  lock, `fetchLlvm=true`, and the validated per-run execution timeout
  `coverageExecuteTimeoutMs=300000`;
- LLVM report:
  `artifacts/native-world-backend/n4-underground-props-llvm-20260924-4/coverage-report.json`
  (SHA-256
  `64e2060fefa63c45048818538e908dc082c7d55236327fbc7276daec8d3de63b`);
  test result `634/634`; line `16068/16068`, function `1944/1944`, and branch
  `8618/8618`; all coverage build/execute/merge/export/report watchdogs record
  zero exits, cleanup, and authoritative-zero proof; the source freeze records
  all 77 manifested source/test files unchanged with zero changed paths;
- MSVC release build used the same command and dependency pin with
  `target=template_release` and `VWB_CONFIGURATION=release`;
- release build and test watchdogs:
  `artifacts/native-world-backend/n4-underground-props-msvc-release-20260924-1/build-release.watchdog.json`
  and `test-release.watchdog.json`; both record functional/overall exit `0`,
  `cleanupPassed=true`, and `authoritativeZeroProven=true`;
- release test result: `634/634`, failed `0`, stderr empty; executable SHA-256
  `488dbb92321e413db033bb75b9dade7d9671b927ab50dec02d0993f6c39413fb`.

Completed manifest and source-bound evidence:

- the explicit inventory audit found `222` declared, `222` discovered and
  `222` unique core/test `.cpp`, `.hpp` and `.h` paths, with zero missing or
  extra paths; `native/world_backend/source-manifest.json` SHA-256 is
  `8de0fcb8f24f3188ce18df29cee976fc9de1cf0628ec3627b276e64dcbe0aedb`;
- Godot command: `node tools/run-n4-underground-prop-source-differential.mjs`;
  the runner launches Godot 4.6.1 headless with `--audio-driver Dummy` and
  `VOXEL_DISABLE_AUDIO_PLAYBACK=1`. Its `360` second process and `300` second
  work deadlines are fixture evidence capacity for four complete 28x28 scans,
  not gameplay or production scheduling budgets;
- passing report:
  `artifacts/native-world-backend/n4-underground-prop-source-differential/report-9700850b-d804-4f75-855e-920007dd5691.json`
  (SHA-256
  `a0fc8ee774355c667631ec25e0493ca80f957e2949a7c73ca0699d6c7b0b6442`);
  probe SHA-256
  `1dcba139f6e835a51d766a99503e12237bf873984152a4cd848d20b7c95901be`;
  watchdog
  `artifacts/node-tools/process-runs/godot-470vWu/watchdog.json` (SHA-256
  `22c435a24303f16e0a99b0500f031e091be781999c89e11eb052915fa24ef5b4`);
  functional/overall exit `0`, natural exit, `cleanupPassed=true`,
  `authoritativeZeroProven=true`, and stderr empty;
- the first exact-commit rerun at
  `8d60de5694a28d0cb5ce0286f13e1ae2eb75caf4` also passed:
  `report-c8935c9d-c5f6-4d93-8545-ee7e3ce3ffe5.json` (SHA-256
  `4b0ef15b0e07cc2921c6f91aceb949bb5b40ce81a7cfba9be03a28a403bc4e26`),
  with the same probe SHA-256 and 28 launch-relevant inputs unchanged. Its
  exact receipt is `artifacts/node-tools/process-runs/godot-tFJUYl/watchdog.json`
  (run ID `f3cf1cfc4962416ca0136d32cf9df4c0`, root PID `48700`, launch
  `2026-09-24T09:42:48.982Z`, completion `2026-09-24T09:46:07.985Z`, zero
  proof `job_membership_zero`). Job membership observed child `28896` and
  then zero before that receipt was published;
- a separate invocation began 48 seconds later at
  `2026-09-24T09:46:55.852Z`. Its distinct receipt is
  `artifacts/node-tools/process-runs/godot-6ZqwII/watchdog.json` (run ID
  `db4bd41ee8bc4d40961681a4c30822c6`, root PID `36340`) and its distinct
  `report-dde03899-0508-4122-9ad9-cecbcce86061.json` is failed after an
  external stop, with no probe. This later run is not parity evidence and does
  not contradict the earlier Job Object zero proof. That proof is explicitly
  scoped to one Windows Job Object; command line and worktree alone are not a
  process identity;
- four cases compared `36`, `36`, `3` and `36` ordered attempts for chunks
  `(0,0)`, `(0,0)` with the root tombstoned, `(-1,-1)` and `(5,3)`.
  Candidate cells, stable IDs, source material, all PCG states, final state,
  exact ore/rock/forage geometry, production process replay and publication
  counts matched. The compared families were `none`, `rock`, `forage`,
  `copperOre` and `ironOre`;
- the staged debug adapter DLL used by the differential has SHA-256
  `1b15eb9223a59ff000ce3f982f6ba3414439d2f564fa1a415b14b4970e5f2134`.
  The isolated worktree required the clean primary Voxel Tools editor DLL
  (SHA-256
  `b24cc4eb8d22c27ce5babf1cf23190571d4acca9b2d215cf9c9adf00614bfc97`)
  and an ignored build-output `.gdignore`; the final import bootstrap receipt
  is `artifacts/node-tools/process-runs/godot-nvmosb/watchdog.json`, exit `0`,
  cleanup/zero proven, stderr empty. Earlier missing-binary, missing-cache,
  interrupted-import and 90-second noncompletion receipts are retained as
  setup evidence and are not cited as parity evidence.

The follow-up runner hardening freezes the complete direct oracle/capture graph,
including `MainInteractionFlow.gd`, `WorldGenerationSystem.gd`, the relevant
Main owners, terrain/biome generation, owner snapshots, structure admission,
catalog resources, generated scene inputs, and owned-process implementation.
It also copies the exact watchdog run ID, root PID, launch/completion timestamps,
zero-proof source, authority and receipt path into every report, rejecting a
missing or cross-receipt identity. This static hardening requires a newly
coordinated differential before it can replace the exact-commit evidence above.

Independent review is diagnostic-only **GO**, with no P0/P1 finding, and
production/cutover **NO-GO**. Its four P2 limits remain explicit:

1. eager scan counters are diagnostic-only and do not match production cursor
   or budget behavior;
2. removedProps live freshness is caller-owned
   (`liveCaptureFreshnessProven=false`);
3. the immutable-pin architecture still needs stale/retry integration for a
   mid-scan edit before cutover; and
4. this four-case fixed-seed differential is not the N4 known-seed plus two
   fresh-seed acceptance suite.

No promotion, deletion or production claim follows from this evidence.

## Deletion ledger

Nothing is deletable in this slice. Specifically retain:

- `process_underground_chunk_prop_spawn_state`;
- `scan_underground_prop_candidates_from_volume_service`;
- `spawn_underground_prop_attempt`;
- the TerrainVolumeService exposed-floor scan;
- `make_ore_cluster`, `make_rock`, and `make_forage` production publication;
- GDScript removedProps/save ownership; and
- all collision, navigation, and routing consumers.

Deletion can be reconsidered only after a later complete all-channel feature
manifest owns visual, physical, interaction, save, and navigation consequences,
live owner-fresh publication passes, save/reload proves no resurrection, and
named production caller search reaches zero. The shared-RNG root tombstone can
shift every later attempt, so an eventual durable transition must compare the
full before/after ordered chunk artifact rather than delete by one static ID.

## Explicit limits

This is not headed gameplay evidence, visual acceptance, collision publication,
save/reload proof, performance proof, or an N4 production cutover. The typed
transition reports changed source rows only and intentionally refuses the
complete feature-footprint contract.
