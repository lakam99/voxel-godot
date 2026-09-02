# Citadel terrain source boundary

Branch `codex/citadel-visuals-clean`; this source chunk began at `62333f6`.
Standalone preservation (`ddea9d6`) and physical-validation cache (`6357aa3`)
were committed separately while this terrain work was being verified.

This is not ordinary-world spawning acceptance. No runtime controller currently
installs these profiles for a live citadel. The active goal remains unfinished.

## Ownership

`BuildingSiteManifestBuilder` reads the existing prepared building and furniture
objects without changing them. The source signature includes all typed recipe
data, furniture/access reservations and tree semantics. Reservation bounds include
every transformed part box and declared canopy/buttress envelope. Grounded root
faces are separately taken from the existing Blueprint physical root contract.

`BuildingGroundMask` rasterizes source root faces and declared access clearance
with conservative one-cell-diagonal padding for terrain interpolation. It does
not treat the enclosing reservation rectangle as solid ground. A linear
two-pass Euclidean distance transform provides the apron distance field. Support
and grading masks have different meanings: clearing terrain for an access void
does not invent a foundation or eight-cell overburden beneath that void.

Ground-level trees use trunk/buttress footprints, never canopy bounds. The frozen
citadel's four trees have elevated local bases (0.81 or about 2.618 metres); those
are published structure/planter support responsibilities, not permission to raise
terrain. Their actual live support remains unverified. Clearance below the
source ground plane explicitly rejects until supported; it is not filled over.

`BuildingTerrainProfile` binds this source to a seed, one origin and ground level.
`WorldGenerationSystem` applies the height/overburden policy; its existing volume
service retains every saved cell edit. There is no ground slab, copied terrain
generator, save-version change or route/navigation patch. Native worker contexts
consume the same admitted source snapshot. Packed temporary rasters are converted
to enforceably read-only arrays before sharing; exported data is copied.

The profile configure API is generation-input admission, **not a live terrain
edit API**. A future runtime owner must install it before affected terrain requests,
prove old native jobs exclude the new influence, and guard every activation
frontier. Unloading a visible building must not discard its terrain source facts.

## Verification

All paths below are under ignored `artifacts/citadel-runtime-integration/`.
Each executed script used `tools/run-godot-scene-watchdog.ps1`, bundled Godot
4.6.1 console, `-Headless -Scene '--script'`. Full exact commands, timestamps,
logs and process ownership proof are retained in each `watchdog.json`.

- `site-manifest-contract-01`: 41 checks on synthetic and immutable real source.
  Actual manifest includes 4,649 building parts, 146 furnishings, 179 grounded
  roots; reservation bounds are approximately 126.81 x 137.241 metres in XZ.
  Manifest build was about 0.472 seconds, a worker operation, not a frame pass.
  Script: `res://artifacts/citadel-runtime-integration/site-manifest-contract-01/run.gd`.
- `terrain-profile-contract-08`: 33 checks, seed `atlas-1492`, explicit synthetic
  source origin `(1300,-1500)` plus the hash-verified frozen real citadel geometry.
  Script: `res://scripts/testing/buildings/BuildingTerrainProfileContract.gd`;
  report environment `VOXEL_BUILDING_TERRAIN_REPORT` points to the fresh absolute
  `report.json`. Main/worker equality covers 1,849 height samples; a native 4-cubed
  buffer matches density within declared 16-bit quantization tolerance and retains
  an explicit air edit. Root-corner interpolation, invalid admission, overflow,
  valid overlap rejection, retained source revision, input/export aliases and
  enforced raster immutability are covered. Visual-only extent enlargement does
  not alter terrain; disjoint supports do not fill their bounding rectangle;
  declared access voids stay clear. The distance field matches an independent
  brute-force oracle on 143 nodes.

Successful source runs have empty error logs, natural exit 0 and authoritative
owned-process zero. No screenshots or gameplay claims accompany them. The final
terrain contract reruns the real-source manifest checks including the later
trunk-radius field. Profile construction does not certify publisher geometry,
native mesh seam/collision support, smooth traversal or any runtime budget.

## Rejected attempts retained

The critic rejected the initial all-bounds plateau and a malformed overlap-test
input. Both were corrected rather than waived. The critic then rejected mutable
packed rasters inside a read-only outer dictionary; the final contract covers
the enforceably immutable replacement.

`terrain-profile-contract-02` rejected an overly exact float32/float64 origin
comparison; its early fixture return leaked a reference cycle. Both were fixed.
Contracts 04/05 rejected elevated trees incorrectly treated as ground-level;
the corrected model keeps their support with the published structures. All
failed artifacts remain, with natural process exit and owned-zero evidence.

NPC rerun `terrain-profile-npc-02` keeps the same `atlas-1492`/both conditions:
84/84 contract, 48/48 motor, 84/84 nav-world, 130/132 route. Baseline error
categories remain in motor/nav-world/route logs; no new assertion failure or
error category was observed. The user's explicit baseline exception remains in
force. This is neither a clean NPC matrix nor live NPC acceptance.

## Still in progress, outside this source boundary

`CitadelSitePreparation` joins recipe preparation, geometry-derived admission,
ordinary-structure exclusions and full-envelope terrain surveys. Its first
source-only sweep found no eligible site with a centre-cell ground level.
Balancing maximum cut/fill over the surveyed site yielded an accepted source
candidate `(1,-3)` in a subsequent run, but that run preceded the final support-mask
repair. Current-mask admission is being rerun; no final density claim is made.

Native request-frontier enforcement, actual StructureSystem activation,
incremental building/furniture/shared-tree publication, shared door lifecycle,
physical approach, inspected visuals, unload/re-entry and save/Continue remain
required. No headed launch has been approved or performed for this chunk.

The independent critic approved this focused terrain-source chunk after
inspecting contract-08 and the raster-ownership repair. This is not full
checkpoint 2, site-preparation, frontier-safety or spawning acceptance.
