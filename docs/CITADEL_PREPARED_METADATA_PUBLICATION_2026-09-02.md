# Prepared metadata publication

Starting commit `bb226ef`, branch `codex/citadel-visuals-clean`. This is a
throughput improvement to the real scene publisher, not ordinary-world activation.
Recipe geometry, furniture, shared trees and protected NPC/door code are unchanged.
The independent critic approved this focused implementation, tests and report
after verifying the final source hashes, comparisons, logs and owned cleanup.
This approval does not cover ordinary activation, headed testing or frame budgets.

## Change and ownership

The existing background preparation worker now compiles collision-enabled,
non-door part snapshots after the existing diagnostic sequence. Eligible nested
Arrays/Dictionaries are copied once and deeply frozen. Their exact bindings and
records travel in the existing revision-bound, one-shot prepared holder; no new
worker, generator, save format or publication authority is introduced.

Before making a part's collision, the publisher compares its current snapshot
with that prepared binding. Each static flush creates a fresh outer dictionary
but shares the exact frozen record values. Commit checks ordered membership and
every selected reference before replacing metadata. Failed preparation detaches
both maps into the existing retirement payload. Scene teardown frees Nodes on
main before handing the retained publisher/resources/metadata to its owned worker.

Mutable compatibility inputs use an exact-bound record cache. Changed records
are copied again; removed records leave the cache. Packed arrays, handles,
Resources and Object-typed containers retain ordinary unfrozen-copy semantics
and are never reused. Cycles and excessive nesting fail explicitly before
encoding; late mutations fail before cache/metadata replacement. Compatibility
copy/validation costs are measured, not claimed to meet the runtime budget.

Godot 4.6.1 leaves NodePath component padding unwritten when encoding Variants.
Bindings initialize storage then use native `encode_var`, preserving all
represented values, types and ordering without comparing allocator padding.
The contract verifies explicit golden bytes, poisoned-buffer padding positions,
stable replay, and distinctions between NodePath/String/StringName, typed/untyped
containers, and dictionary order. This does not relax geometry equality.

## Evidence

All directories below are under `artifacts/citadel-runtime-integration/`.
The actual source is the previously accepted `actual-site-source-05/result.bin`,
SHA256 `7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`:
world `atlas-1492`, region `(1,-3)`, recipe `1298433643`, scale `1.25`.
This replay avoids rebuilding a source irrelevant to the publication change;
it is not known-seed runtime prewarming or cold-generation acceptance.

- `scene-publication-cache-types-01`: inventory of all 3,159 post-diagnostic
  records, 801,581 value occurrences; no packed arrays, Objects, Resources,
  cycles or unhandled types. Maximum encoded record 6,316 bytes; total encoded
  records 14,401,452 bytes. This historical inventory preceded the compiler.
- `scene-publication-prepared-metadata-02`: 69/69, actual ordered typed records
  and bindings exact, deeply frozen and isolated; unsupported omission,
  cancellation and one-shot ownership controls. 20.334 s total, 959.684 ms
  metadata preparation. Current preparation and contract hashes are recorded.
- `scene-publication-cache-07`: 122/122, prior CPU submission oracle retained;
  exact cache reuse, type/order changes, removals, unfrozen fallback,
  late-selected mutation rejection, cycle/depth rejection, prepared mutation
  before collision, prepared identity replacement rejection, and failed-begin
  ownership. This is synthetic publication evidence, not live gameplay.
- `scene-publication-cache-final-job-01`: 117/117 cancellation/lifecycle controls.
  Existing publisher suites: `scene-publication-cache-final-paving-01` 139/139,
  `scene-publication-cache-final-masonry-01` 158/158.
- `scene-publication-cache-actual-03`: final-code full construction 62/62.
  Its entire `render-baseline.json` is byte-identical to committed checkpoint
  `scene-publication-incremental-05`, not merely a passing Boolean. 4,703
  building parts, 210 furnishings, 3,179 blocking shapes, 20 site-specific door
  IDs and four shared-system trees remain. Door IDs are not gameplay registration.
  Cleanup releases the observed unique mesh/material resources and drains the
  worker/tree queue. Every selected non-NPC final run has clean logs, natural
  exit 0 and authoritative owned-process zero.
- `scene-publication-cache-npc-{contract,motor,nav_world,route}-01`: same
  `atlas-1492`, both time modes, fixed 60 FPS, isolated userdata, 45 s owned
  watchdog. Counts 84/84, 48/48, 84/84, 130/132. First three stderr files exactly
  match the preceding committed checkpoint, including known engine errors in
  motor/nav-world. Route stderr exactly matches the original accepted
  `baseline-2026-09-02/route-both` (244 headers). The same diagnostic detour
  fails in day/night after four visits at 32,000 us; its ID is
  `npc_route_diagnostic_home_collision_lattice_exact_detour`. No new assertion
  failure, protected code edit or NPC repair is claimed. All four jobs emptied;
  route naturally exits 1 and remains a failure under the user's baseline exception.

Reproduction (choose fresh output directories):

```powershell
./tools/run-building-scene-publication-contract.ps1 -Phase actual -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-cache-actual-03
```

Focused scripts use `tools/run-godot-scene-watchdog.ps1 -Headless -Scene '--script'`
with `-SceneArguments @('res://scripts/testing/buildings/<contract>.gd')`,
fresh stdout/stderr/report paths and isolated APPDATA/LOCALAPPDATA. Exact engine
commands and cleanup are in each `watchdog.json`. Compiler contract reads
`BUILDING_PREPARED_METADATA_OUTPUT` (directory; 90 s cap); flush reads
`BUILDING_STATIC_FLUSH_REPORT` (JSON path; 30 s); job reads
`BUILDING_SCENE_PUBLICATION_JOB_OUTPUT` (directory; 30 s). Paving/masonry use
`VOXEL_PAVING_FOOTING_PUBLISHER_REPORT` / `VOXEL_MASONRY_PUBLICATION_REPORT`.
The actual wrapper records source hashes, seed and 240 s cap in `launch.json`;
`progress.txt` records stages. No screenshots were taken or claimed.

## Measurements and limits

| Measurement | Committed incremental baseline | Final prepared-record run |
| --- | ---: | ---: |
| Scene construction elapsed | 49.994 s | 21.134 s |
| Main recursive metadata copy CPU | 6.466 s | 0 (not executed) |
| Prepared record selection CPU | not applicable | 78.862 ms total |
| Background metadata compilation | not applicable | 936.345 ms |

Final flushes reuse prepared records 27,464 times with zero main metadata-copy
entries. Ordinary per-part snapshots still occur for source validation: zero
cache-copy entries does not mean all main-thread snapshot allocation is gone.
Retired outer prefixes still serialize to 108,796,452 bytes, but now share their
nested records. That figure is encoded duplication, NOT measured heap memory.
Compiled dictionary reclamation has ownership inspection, not a heap measurement;
mesh/material weak-reference checks do not prove dictionary reclamation.

Requested slices remain 2,500 us, maximum declared 4,000 us. Final measured
metadata selection max is 220 us, but ordinary part publication still reaches
40.533 ms (`urban_civic_tower`), static validation/commit 22.533 ms and masonry
setup 11.358 ms. **The full frame/atomic budget still fails.** The next construction
work is those wall/masonry/validation operations, not more metadata micro-tuning.

Scene timing excludes cold recipe generation and preceding diagnostic preparation.
Headless MultiMesh getters do not provide reliable per-instance GPU readback.
The available scene/mesh/material/collision facts and CPU submissions do not
prove rendered fidelity. Ordinary service activation, player access and shared
door lifecycle, Main/New Game approach/traversal, unload/re-entry, save/Continue,
and headed visual/performance acceptance remain unfinished. No headed launch
is approved by this report, and the active goal is not complete.

## Failed intermediate evidence retained

Prepared-metadata-01 passed 57/60: actual records were exact, but three synthetic
comparisons exposed NodePath padding. It is not a passing run. Synthetic-only
diagnostics isolated that native encoding behavior before the final -02 replay.
Earlier cache actual-01 (26.700 s) and actual-02 (22.029 s) precede final code;
the final timing and acceptance evidence above use actual-03. No failed report
was overwritten, no timeout increased and no headed run launched.
