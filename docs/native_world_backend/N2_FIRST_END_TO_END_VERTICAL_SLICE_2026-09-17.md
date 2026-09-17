# N2 First End-To-End Vertical Slice

Date: 2026-09-17

Migration authority: `CODEX_NATIVE_WORLD_BACKEND_MIGRATION_HANDOFF_2026-09-17.md`

Status: N2 complete; no production world-generation or collision-authority cutover

## Outcome

N2 adds one bounded native terrain-source path for the frozen `atlas-1492`
lattice. A single immutable native snapshot now produces the fixture's
collision triangle soup, declared blocker, and typed Voxel Tools render
channels. The headed fixture installs exactly one project-owned
`StaticBody3D`, disables Voxel Tools collision, hydrates the render consumer,
and proves source parity, publication acknowledgement, seam edits, ordinary
physics queries, and `CharacterBody3D` movement.

This is a fixture-only activation. Production `VoxelTerrainGenerator.gd`,
terrain-volume storage, collision generation, viewer collision demand,
navigation, NPC routing, saves, and gameplay remain unchanged for their later
N3-N8 cutover gates.

## Implementation boundary

- `terrain_source` reproduces the current lattice-origin generator for the
  frozen bounded region, including explicit material/biome/fluid/provenance
  columns and typed serialized edits.
- `terrain_snapshot` validates the complete ordered cell set, owns the declared
  blocker, and provides canonical snapshot identity.
- `terrain_meshing` consumes only immutable snapshots and emits deterministic
  world-space tile collision with half-open XZ ownership and explicit artifact
  identity.
- The GDExtension adapter performs typed Variant marshalling and render/collision
  packing. It remains a thin boundary over the Godot-free core.
- The fixture oracle independently reproduces current GDScript rules and checks
  all 33,915 ordered samples rather than trusting a digest or screenshot.

The synchronous adapter has no worker or queue. The fixture serializes its two
admissions, retains at most one prepared result, rejects stale results before
install and before acknowledgement, and records peak in-flight, prepared,
payload, and retired-set ownership. No asynchronous N2 queue is required by the
frozen contract.

## Translation corrections found by full parity

The full headed denominator caught several issues that small anchor tests did
not. These were corrected at the owning translation boundary:

| Translation | Correct behavior |
|---|---|
| Integer lattice vs section-center sampling | N2 follows the real `VoxelTerrainGenerator` lattice origin and does not use the section payload's center-sampled contract |
| Negative-coordinate surface reporting | The generator's float-rounded world position is mapped back through `floor(position / cell_size)`; both frozen negative-coordinate surface anchors therefore report `17.901000000000003` |
| FastNoiseLite defaults | Every current terrain channel explicitly uses the Godot-compatible FBM configuration rather than raw FastNoiseLite's no-fractal default |
| Underground transition | The current transition depth is five cells, not three |
| JSON integer transport | Exact, in-range integral JSON floats are accepted for delta coordinates, IDs, and revisions because Godot JSON decodes numbers as floats |
| Collision winding | The pure core keeps conventional outward CCW winding; the adapter reverses the final two vertices for Godot's clockwise front-face convention |

The prior `18.819000000000003` second surface anchor was therefore a
pre-implementation direct-cell mistranslation, not a value to preserve. The
frozen contract records the corrected headed-oracle evidence.

## Verification

### Native build, tests, and coverage

Command:

```powershell
node tools/run-native-world-backend-tests.mjs --run-name n2-native-build-07
```

Evidence: `artifacts/native-world-backend/n2-native-build-07/report.json`

- debug: 51/51 tests;
- release: 51/51 tests;
- strict MSVC `/W4 /WX /fp:strict` build and adapter smoke passed;
- first-party core coverage: 1,716/1,716 lines, 209/209 functions, and
  802/802 branches;
- coverage denominator and deliberate coverage canary passed; and
- debug/release DLLs and PDBs are bound to exact source/build manifests.

### Runner contracts

Command:

```powershell
node --test tools/tests/n2-native-world-vertical-slice.test.mjs tools/tests/native-world-backend-runner.test.mjs tools/tests/native-world-identity-reference.test.mjs
```

Result: 14/14 passed.

### Headed vertical slice

Command:

```powershell
node tools/run-n2-native-world-vertical-slice.mjs --run-name n2-vertical-slice-11-final --native-build-report artifacts/native-world-backend/n2-native-build-07/report.json
```

Evidence:

- receipt: `artifacts/native-world-backend/n2-vertical-slice-11-final/receipt.json`;
- fixture report: `artifacts/native-world-backend/n2-vertical-slice-11-final/fixture-report.json`;
- screenshot: `artifacts/native-world-backend/n2-vertical-slice-11-final/fixture.png`;
- status passed, empty stderr, functional exit 0, and natural owned-process zero;
- 33,915 baseline and edited samples matched ordered typed oracle data;
- both seam tile geometry hashes changed after the four serialized edits;
- exactly one project-owned terrain body and three installed shapes remained;
- stale-before-install and stale-before-acknowledgement were both rejected;
- edited prepared payload was independently recomputed as 1,445,071 bytes;
- peak in-flight builds and prepared results were both one;
- Voxel Tools generated real blocks from the native render payload; and
- live ray, cave-wall, seam, blocker, capsule, floor, slope-traversal, and
  blocker-contact checks passed with exact snapshot/artifact provenance.

The visual capture was inspected and shows a continuous smooth terrain slice
without a visible tile-seam tear or duplicate collision surface. This remains
N2 fixture evidence, not production terrain, NPC, or Gate-5 acceptance.

## Consumer and deletion audit

`rg` finds `n2_prepare_vertical_slice` only in its adapter declaration,
registration/forwarder, dedicated fixture, and runner contracts. No production
scene or gameplay caller uses the method. Production Voxel Tools collision and
viewer demand remain enabled in `VoxelTerrainRuntime.gd`; the N2 fixture alone
sets both collision controls false.

Accordingly N2 deletes no production sampler, terrain-volume, mesher,
collision, navigation, save, NPC, or fallback authority. The script generator
remains the independent fixture oracle and production source until N3. The
production collision cutover and deletion audit remain N5 work.

## Review and inherited scope

Independent review found that the contract permits the synchronous adapter and
does not require an asynchronous queue. Its concrete lifecycle findings were
resolved by serializing preparation, exercising both stale rejection points,
independently recomputing payload bytes, recording exact resource peaks, and
binding headed evidence to the passing native build inputs and installed
binaries. The final read-only review found no blocking N2 implementation or
evidence defect. It left three non-blocking hardening ideas for later runner or
fixture maintenance: compare provenance digests directly as well as by bound
artifact, exercise stale-before-ack rollback with a previously installed set,
and assert the final body child count directly in addition to the existing
shape/lifecycle proof.

The inherited Mira departure delay is still reserved for N6 route/query work.
The rescue targeting/scenario mismatch remains reserved for N7/N8. Neither was
changed or reclassified by N2, and each must first be checked as a possible
migration translation defect when its owning stage begins.
