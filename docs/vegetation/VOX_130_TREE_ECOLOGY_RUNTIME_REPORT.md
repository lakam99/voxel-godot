# VOX-130 Tree Ecology Runtime Integration Report

## Outcome

Ordinary production tree props now resolve a deterministic ecology sample and select a matching cached age-band phenotype through `VisualAssetRegistry`. Existing prop placement, stable IDs, targeting, damage, drops, falling visuals, chunk budgets, and removed-prop save authority remain unchanged.

## Runtime path

1. The existing tree constructor supplies authoritative biome, world cell, stable prop ID, and seed.
2. The registry samples local ecology and selects one matching architecture/age-band asset from the finite library.
3. Profile growth curves and stable genetics produce bounded continuous target dimensions.
4. The cached PackedScene is instanced with shared materials, per-instance wind phase, and bark-scale compensation.
5. One static cylinder uses manifest/runtime trunk metrics. Leaves and upper branches remain decorative/non-colliding.
6. Existing generic prop-created notification publishes the prop; no tutorial or NPC-specific path exists.

Tree metadata now exposes architecture, age band, exact age/range, maturity, genetics, height, crown, and trunk metrics for bounded diagnostics and visual captures. It is derived state, not a new save payload.

## Preserved boundaries

- No unique runtime mesh or material.
- No synchronous phenotype generation during chunk publication.
- No extra `Main*.gd` inheritance layer.
- No placement RNG draw or order change.
- Existing structure, natural-corridor, road, gate, door, and town exclusions remain authoritative.
- Crown checks consume published structure facts; vegetation never repairs a town manifest.
- The generic navigation prop notification remains the only integration seam.
- No file under `scripts/npc_ai/` and no `NpcPathing.gd` implementation changed.

## Evidence

`artifacts/vegetation/vox131-canopy-runtime-final.json`: 9/9, covering ecological selection, biome dimensions, stable/continuous age facts, scale-safe bark, one coherent collider, exclusion/RNG parity, removed-tree saves, and the tutorial-authority firewall.

`artifacts/vegetation/vox131-canopy-release-rerun/` is a headed production Main Menu -> New Game -> forest harvest -> chunk reload -> save -> Main Menu -> Continue run on fresh seed `atlas-72617936`:

- live viewport targeting hit the coherent trunk;
- five real clicks produced the falling tree and three logs;
- destruction completed in 2.352 ms;
- `atlas-72617936:244,-41:4` stayed removed after stream-out/reload;
- Continue restored the forest pose, 12 nearby mature trees, and the same removed state.

The night portion uses the project-approved player-only playtest survival policy while preserving real night, NPC, and hostile behavior.

`CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` remains controlling throughout: startup readiness, town facts, actor registration, and commands are untouched.
