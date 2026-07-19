# VOX-126 Tree Ecology Baseline and Frozen Schema

Date: 2026-07-15

Branch: `codex/vox-125-age-driven-trees`

Entry commit: `959f98c4`

Godot: 4.6.1 stable

Blender: 5.1.2

Fixed seed: `atlas-1492`

## Outcome

The age/phenotype/bark contract is frozen and implementable through composition. Per the user's explicit instruction, this phase began without rerunning the unchanged baseline. The current checked-in VOX-123 release evidence was used as the entry baseline: 17/17 protected NPC suites, byte-identical world signatures, live tree harvest/Continue, and a green normal sprint pass. No old migration or obsolete synthetic test was revived.

`manifesto.md` remains the hard firewall. `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` remains controlling: vegetation may consume published biome, structure, corridor, and town-exclusion facts, but may not generate/repair town facts, change startup readiness, or issue NPC commands.

## Frozen authoritative flow

`world seed + biome + continuous local maturity -> local age range -> exact age/genetics -> age-band phenotype -> reusable generated visual`

- Existing surface-prop attempts remain the sole authority for whether a tree exists.
- A pure composed sampler answers only maturity, age range, exact age, genetics, growth stage, and age band.
- The sampler uses stable world coordinates and does not consume shared terrain/town/structure/prop RNG.
- Derived ages are recomputed, not saved. Existing removed-prop state remains save authority.
- There is no canopy/stand planner and no placement target solver.
- Runtime uses a finite cached library; no per-tree mesh, texture, or material is created.

## Age and growth schema

- Architectures: `broadleaf`, `conifer`, and `savanna`.
- Bands: `young`, `established`, `mature`, `old`, and `ancient`.
- Each biome declares minimum/typical/maximum age, maturity correlation scale, influence, local span, skew, four ordered band thresholds, and height/girth/crown growth exponents.
- Maturity is a continuous two-octave stable value field. Exact age and genetic seed additionally include stable prop identity.
- Height, girth, and crown use independent slowing growth curves; age is not represented by uniform scale alone.

## Phenotype and fullness schema

The bounded build library is keyed by architecture, age band, and architecture variant. The manifest publishes:

- architecture, growth class, band, and nominal age;
- grounded dimensions, trunk and crown metrics;
- primary branches, branch generations, terminal tips, and leaf-card count;
- crown-sector occupancy/fullness proof;
- wind channel ranges and fixed-root proof;
- bark UV/repeat metadata;
- triangle count and per-asset triangle limit.

Every phenotype must meet deterministic minimum branch, terminal, leaf, attachment, sector, grounding, wind-root, and triangle contracts. Under-filled assets fail the build instead of entering the runtime library.

## Bark coordinate schema

- UV0 is authored on every trunk/branch before transform and mesh joining.
- U wraps circumference; V advances at 0.72 repeats per physical metre of segment length.
- Runtime instance scale is supplied as an instance shader value so elongation adds apparent repeats without material duplication.
- Bark uses the shared tree wind material, so it deforms with the mesh and does not swim in world space.

## Entry comparison

The prior generated tree library was 4.87-21.63 m tall, with mature forest trees generally 10-16 m. VOX-118 measured the original sparse assets at 3.0-6.0 m and recorded the pre-existing terrain-meshing hitch separately. The release target therefore requires ordinary mature forest/taiga trees to exceed house height without changing placement ownership.

The pre-change protected baseline is documented in `VOX_123_CANOPY_RELEASE_REPORT.md`. The final post-change firewall is recorded in the VOX-131 report.
