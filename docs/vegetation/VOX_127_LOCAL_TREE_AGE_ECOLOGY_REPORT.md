# VOX-127 Local Tree-Age Ecology Report

## Outcome

Tree age is now a deterministic biome ecology fact, independent of chunk ownership and independent of the shared placement RNG. The implementation is the composed `TreeEcologySampler`; no `Main*.gd` inheritance layer or biome-specific procedural branch was added.

## Implementation

- `BiomeEnvironmentProfile` declares validated architecture, age range, maturity-field, age-band, and growth-curve data.
- `BiomeEnvironmentCatalog` rejects invalid architectures, unordered ages, too-small correlation scales, and unordered/non-normalized band thresholds.
- `TreeEcologySampler` evaluates a continuous two-octave maturity field from seed, biome, and world coordinates.
- Stable tree identity selects exact age and genetics inside the local range. Neighboring trees share ecological history but are not clones.
- Five age bands map to finite phenotype choices. Height, girth, and crown growth are independently derived.
- Missing/unknown biomes use the explicit default profile.

The sampler consumes no placement RNG and changes neither the 28 surface-prop attempts nor their draw order. Repeating the sample after chunk reload or Continue returns the same values. Removed trees remain governed by the existing stable prop-ID save set.

## Focused evidence

`tools/run-biome-environment-catalog-contract-tests.ps1 -ReportPath artifacts/vegetation/vox131-biome-catalog-final.json`

- 14/14 passed.
- Includes complete ecological profiles, explicit fallback, no duplicate hardcoded tables, shared catalog ownership, and zero placement-RNG consumption.

`tools/run-canopy-runtime-contract-tests.ps1 -ReportPath artifacts/vegetation/vox131-canopy-runtime-final.json`

- 9/9 passed.
- Same seed/cell/prop reproduces maturity/range/age/genetics/band.
- Different seed and biome vary.
- Sibling cells remain coherent and the chunk-boundary sample is continuous.
- Removed-tree state round-trips and prevents respawn.

Two fresh `atlas-1492` signatures are byte-identical. All 628 stable prop records in the old/new loaded-window overlap are byte-identical, which proves the shared prop RNG was not reordered. The intentional signature-window delta is discussed in VOX-131.

`manifesto.md` and `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` boundaries remain intact: this sampler has no navigation, town-readiness, NPC, or story authority.
