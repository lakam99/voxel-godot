# VOX-122 Mature Canopy Integration Report

## Outcome

VOX-122 integrates the generated mature-canopy asset family into normal procedural chunk publication without adding a parallel placement, save, collision, or navigation system. Forest, swamp, taiga, snow, tundra, alpine, and savanna profiles select biome-appropriate mature trees; plains retains the existing open profile. Stable seed, biome, and prop ID select visual variation and rare old growth without consuming placement RNG.

The final leaf-card counts are exactly twice the preceding reviewed canopy generation: broadleaf variants contain 1,206–1,668 leaf cards, old-growth variants 1,400–1,636, conifers 760–1,046, and savanna variants 884–1,332. Leaves and branches are decorative/non-colliding; one manifest-sized cylinder represents each trunk.

## Architecture and boundaries

- `BiomeEnvironmentCatalog` remains the single profile authority for procedural vegetation behavior.
- `VisualAssetRegistry` resolves and caches the generated GLBs and derives old-growth selection from stable identifiers.
- Existing prop IDs, removed-prop state, drops, targeting, falling-tree presentation, and chunk attempt budgets remain authoritative.
- `StructureSystem` now publishes separate natural-corridor and structure-footprint margins. This permits controlled crown overhang over paths while keeping trunks clear and rejecting crowns that clip buildings, gates, doors, or required authored corridors.
- Prop publication uses the existing generic world/navigation notification. No file under `scripts/npc_ai/` and no `NpcPathing.gd` code changed.
- In accordance with `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`, canopy integration consumes already-published town/structure facts. It does not generate or repair tutorial records, issue named movement, or reinterpret startup readiness.

## Determinism and save evidence

The old world-signature runner sampled an incompletely drained prop queue at a fixed frame count. Its schema-v2 fixture now waits for stable chunk publication and completes only the already-seeded surface-prop attempts for those loaded chunks. This is deterministic fixture evidence, not live gameplay acceptance.

- Commands: `tools/run-world-signature.ps1 -Seed atlas-1492` and two pre-commit comparison captures.
- Official result: tracked baseline matches `artifacts/world-signature/latest/atlas-1492.json`.
- Repeated SHA-256: `BEDD39F33317321C6294C5C980AE887340E62867FD28821284021F7E27F22BC6`.
- Signature scope: 49 loaded chunks, 896 props including 338 trees, 1,300 blocks, 12 terrain samples, 11 structure kinds, and one town-home group.
- Runtime save contract: `artifacts/vegetation/canopy-runtime-contract.json`, 7/7. It round-trips removed tree IDs and proves they gate chunk respawn.
- NPC streaming/save contract: `artifacts/npc/reports/vox122-streaming-save-postsignature.json`, 40/40 across day and night; baseline and latest are both 446,216 bytes.

No migration was added because no concrete save incompatibility was reproduced.

## Focused verification

- `tools/run-project-compile-smoke.ps1`: passed; menu and main scenes load.
- `tools/run-biome-environment-catalog-contract-tests.ps1`: 13/13.
- `tools/run-canopy-asset-import-contract-tests.ps1`: 6/6 across 13 imported canopy GLBs.
- `tools/run-canopy-runtime-contract-tests.ps1`: 7/7, including trunk/collision agreement, exclusions, save removal, generic notification, and RNG parity.
- `tools/run-environment-wind-contract-tests.ps1`: 11/11; five shared shader-global writes, cached materials, deterministic smoothed field, and sub-1 ms CPU p99 contract.
- `tools/npc/run-npc-contract-tests.ps1 -TimeMode Both -Seed atlas-1492`: 82/82.

## Live NPC and town evidence

The initial full NPC aggregate ran 17 suites. Fifteen passed directly, including the real tutorial playthrough, tutorial morning, final rescue, and town job-cycle visual runner. Its two failures were audited rather than attributed to production routing:

1. `streaming_save` compared the newly reviewed tracked signature with the old `latest` artifact. The official post-commit signature and focused 40/40 rerun resolved it without test weakening.
2. `go_home_visual` completed the real route, door opening, strict interior entry, clearance, and closure but found 11 NPCs because the fixture claimed population ownership before its chunks finished publishing. Moving that fixture-only claim after chunk settlement kept the exact-one-NPC assertion strict.

The corrected headed command was:

```powershell
.\tools\npc\run-npc-go-home-visual-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts\npc\reports\vox122-go-home-visual-fixed.json -ProgressPath artifacts\npc\progress\vox122-go-home-visual-fixed.txt -ScreenshotDir artifacts\npc\screenshots\vox122-go-home-visual-fixed
```

It passed 13/13 with the wrapper's forbidden-call self-scan green. Captures are `spawn_behind_home.png`, `at_home_door.png`, `door_open.png`, and `inside_closed_door.png` under `artifacts/npc/screenshots/vox122-go-home-visual-fixed/`. They are dark nighttime images, but manual inspection confirms the visible sequence. This proves the one-house production NPC fixture uses real physics, route authority, and door traversal. It does not by itself prove every generated town seed or damage balance. The real tutorial and job-cycle suites provide the broader protected baseline, consistent with the live-evidence rules in `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`.

## Visual verification

Nine headed captures and metric sidecars are under `artifacts/vegetation/vox122-canopy-v5e/` and were manually inspected:

- forest midday: 7 trees, 6 mature broadleaf plus 1 old growth, average height 14.394 m;
- forest traversal: 12 trees, 11 mature broadleaf plus 1 old growth, average height 14.825 m;
- forest night/torch and storm: dense overhead silhouettes remain visible;
- taiga: 7/7 mature conifers, average height 15.781 m;
- swamp and savanna: profile-appropriate mature families;
- plains: zero requested trees in the open-biome fixture;
- town edge: clear outside sightline with no building-wall crown clipping.

The render demonstrates substantially denser individual leaves rather than one continuous crown mesh. Ecology density was not increased; larger crowns achieved the visual target while preserving placement decisions.

## Performance

`tools/run-normal-runtime-performance-pass.ps1` ran through the visible Main Menu New Game input and `startup_loading_completed`, then performed normal sprint traversal with NPCs and autosave enabled.

Report: `artifacts/performance/vox122-normal-sprint.json`; screenshot: `artifacts/performance/vox122-normal-sprint.png`.

- generated seed: `atlas-30234053` (the runner correctly requires the normal path to have no forced seed);
- 1,945 measured frames, 673.94 m travel, 140 chunks created;
- frame p50 13.238 ms, p95 19.188 ms, p99 21.449 ms, max 28.377 ms;
- chunk prop spawn max 16.022 ms;
- terrain meshing job max 4.809 ms;
- NPC max 4.930 ms;
- no report threshold failures.

The max frame improved substantially from the VOX-118 baseline's 100.991 ms. Median and tail times are higher than that older run, so VOX-123 should retain the full runtime observation gate rather than claiming universal zero-cost rendering from one machine/run.

## Residual limits

- The Godot process still reports known navigation/resource leak warnings at test exit. No functional failure accompanied them.
- The headed door evidence is unusually dark.
- VOX-123 remains responsible for final New Game/Continue, multi-seed traversal, live harvesting/removal/reload, weather/night/torch, full performance observation, stale-setting removal, and the complete protected NPC matrix.

Next phase allowed: yes.
