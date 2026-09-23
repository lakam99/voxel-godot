# N4 source-ordered surface construction shadow checkpoint

Status: **verified shadow slice; not an N4 or N3 production cutover**. The
integrated native gate `n4-surface-definitions-02` passed against the
combined pure-core candidate at
`artifacts/native-world-backend/n4-surface-definitions-02/report.json`. The earlier
`n4-surface-definitions-01` failed during Windows compilation because a test
object path reached the platform path limit; shortening the wildlife test
source name corrected the build input. That report is not test evidence.

## Candidate and direct source evidence

The pure-core candidate adds source-ordered typed construction for ore
clusters, four forage forms, wildlife forms, and tree recipes/presence. It
consumes the existing 28-attempt source-ordered stream and ordered placement
receipt, rather than reconstructing an independent RNG order. The direct
Godot construction oracles are:

| Feature | Direct report | Passing cases | Boundary |
|---|---|---:|---|
| Ore | `artifacts/native-world-backend/n4-ore-construction-oracle.json` | 4/4 | Both child geometry plans, transforms, seams/glints, and tombstone-shifted input; no live dig/harvest claim. |
| Forage | `artifacts/native-world-backend/n4-forage-construction-oracle.json` | 4/4 | Four constructed forms, material roles and physical colliders; NPC navigation occupancy is a separate channel. |
| Wildlife | `artifacts/native-world-backend/n4-wildlife-construction-oracle.json` | 6/6 | Constructed procedural/animated-root geometry and registry/clip admission; imported GLB internal hierarchy and live movement are outside. |
| Tree | `artifacts/native-world-backend/n4-tree-direct-exclusions-02.json` | 7/7 | Post-draw recipe/request state, body metadata, natural and terrain-footprint rejection, ready/prepared Citadel reservations, and a true negative-to-zero Citadel region crossing with distinct source states; no live ecological publication claim. |

The checked-in forage and wildlife geometry-golden derivation scripts translate
those Godot outputs to native fixed-width comparison hashes. These are
direct-service construction and deterministic-rule evidence, **not headed
gameplay acceptance**. The tree source binds a separate, adapter-owned
exclusion-halo receipt: its records must include sources originating outside
the prop chunk and all crossed Citadel region states. A missing/incomplete
capture rejects instead of treating a tree as present. An absent tree retains
its recipe/draw identity; a captured Citadel source outside Godot's queried
region range cannot falsely block it. The live adapter does not yet produce
this halo receipt.

Independent tree-halo review found no clear mismatch in the pure-core
expanded-margin arithmetic, but the capture's completeness is still a
caller assertion. A caller could supply an empty record set and get a false
`present` without a StructureSystem revision/coverage admission. The expanded
direct Godot fixture now exercises terrain footprints, ready/prepared Citadel
sources, and a true negative-to-zero region crossing. It uses a fixture
admission stub and does not itself prove production adapter completeness.
`StructureSystem` now advances a dedicated exclusion-record revision on
owner-API natural/terrain changes and setup/reset. The focused direct oracle
passed 47/47 checks at
`artifacts/node-tools/run-surface-structure-exclusion-oracle.json`, including
unchanged 28-cell decisions and unchanged regional revision semantics.
GDScript's publicly mutable maps can still be edited without this counter;
the future adapter must copy/hash captured contents and revalidate them, not
trust the counter alone. Citadel admission remains a separate source receipt.

## Translation corrections and limits

Direct Godot comparison caught two genuine C++ translation errors before
cutover. Godot `randi_range(a, a)` does not advance the RNG; the shared native
PCG compatibility primitive initially did, changing hare drops and later
shared-stream outcomes. The fix is in that shared primitive, not a wildlife
exception. The forage cylinder's top/bottom radius arguments were initially
reversed; the full geometry-bit oracle exposed and corrected it. Source biome
for forage/wildlife remains the original spawn sample, while rock visual
biome is separately queried at its transformed/rounded anchor. Tree physical
presence also requires a dimension-dependent structure halo after recipe
draws, not just the existing center-cell exclusion query.

The candidate still has no normal-gameplay caller. `MainPlaytestTools.gd`
owns the production 28-attempt surface loop and all five feature-family
publication paths. The environment catalog, visual registries, terrain and
shaping revisions, removed-prop IDs, wildlife presentation, and
StructureSystem source states must be captured in one immutable,
same-generation adapter bundle. Catalog and registry setup now expose
owner/revision/ready lifecycle receipts. The registry receipt nests the
shared catalog receipt, so setup failure, reload and replacement invalidate
an older candidate. Focused catalog contracts passed 18/18 at
`artifacts/vegetation/biome-environment-contract.json`. These lifecycle
receipts do **not** freeze publicly mutable Resource or Dictionary payloads;
the adapter must deep-copy/hash/revalidate the actual profile and asset rows.
`ActiveBiomeEnvironmentSnapshot.gd` now provides a capture-only value copy
of the active 13 resolved profiles, bound to that lifecycle receipt and
re-read for content stability. Its focused direct contract passed 18/18 at
`artifacts/native-world-backend/n4-active-biome-snapshot-contract.json`,
including equality with the independent resolved-catalog oracle digest,
mutable-Resource staleness, and rejection of a post-capture tampered value
payload. This is not yet a native adapter invocation or
production source substitution. `ActiveVisualAssetSnapshot.gd` now separately
captures the active ordered family lists (including duplicate IDs), ID-map
overwrite values, disabled IDs, and import-cache identities. Its focused
direct contract passed 27/27 at
`artifacts/native-world-backend/n4-active-visual-snapshot-contract.json`.
Independent review found and corrected a false-ready cached-scene case: the
snapshot now checks the manifest path and 3D scene-root type, and rejects a
missing import without hydrating GLB meshes in the headless fixture. It does
not instantiate a substitute for a missing asset and does not cover
the separate `AnimatedAssetRegistry` used for wildlife presentation. That
registry now exposes an explicit capture-only presentation receipt bound to
its instance/reload lifecycle, active row and scene identities, and actual
AnimationPlayer/expected-clip availability. It double-reads copied values
and rejects partial imports or a tampered receipt. Its focused direct Godot
contract passed 23/23 at
`artifacts/native-world-backend/n4-animated-presentation-capture-contract.json`.
This is import/presentation admission, not wildlife movement or headed play.
The later `NativeSurfaceRockAssetCatalog` admission must derive candidate
membership from the captured ordered family lists, not just the sorted
ID-map rows: live selection retains duplicate family membership while
resolving each chosen ID through the map's last value.
Tree-halo completeness remains an explicit future adapter admission
responsibility. `StructureSystem.capture_surface_tree_exclusion_halo` now
copies both record families across the full post-draw expanded square and
every crossed Citadel source state, rejecting unrequested, pending, failed or
malformed inputs. Its focused direct oracle passed 63/63 at
`artifacts/node-tools/run-surface-structure-exclusion-oracle.json`; the
capture still must be bound to current native terrain/world and center
exclusion receipts and driven through expanded Citadel admission/retry before
production use. No production generator,
prop publication, save, collision, navigation, or presentation authority has
been replaced or deleted. The underground rock stream is a distinct source.

The next cutover proof must compare the complete 28-attempt manifest and
before/after feature footprints with active Godot inputs, reject stale
results, then publish all families atomically with visual/physical and
save/reload evidence. Per-family shadow oracles cannot justify a partial
production substitution because each attempt shares the later RNG stream.

The capture-only `ActiveSurfacePropOwnerBundle` now binds the live Main owner
and seed to four existing value captures: resolved biome profiles, ordered
visual registry/imports, animated wildlife presentation, and durable removed
IDs. It rejects a tampered completeness claim, same-content restore,
cross-Main reuse and registry replacement. Its direct Godot contract is
15/15 at `artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json`.
The bundle declares `complete=false`: it does not contain a native effective
terrain pin, StructureSystem tree halos, an all-28-attempt manifest or an
atomic publication lease. The capture's scene inspection is not a per-chunk
hot-path operation; future integration must cache by owner generation and
recheck freshness before publication without turning scene import inspection
into a gameplay-frame stall.

`NativeWorldBackend.admit_removed_props_tombstones` is the first narrow Godot
adapter conversion for that bundle. Its focused Godot contract passed after
the debug native build at
`artifacts/native-world-backend/n4-removed-props-adapter-contract.json`.
It validates strict sorted UTF-8 IDs, bounds, seed, capture content hash and
the FD1 tombstone grammar, but returns only a shadow, incomplete typed
receipt. A forged internally consistent capture cannot establish current
Main ownership: the caller must run `ActiveRemovedPropsSnapshot.is_current`
immediately before any eventual native feature publication. The adapter does
not retain the typed set or produce feature footprints yet.

## Integrated result and deletion review

Command: `node tools/run-native-world-backend-tests.mjs --run-name
n4-surface-definitions-02`. The terminal report passed 442/442 debug and
442/442 release standalone tests, editor adapter smoke, and isolated release
export/save-v2 adapter smoke with empty runtime stderr. Strict pure-core
coverage is 9,937/9,937 lines, 1,368/1,368 functions, and 5,892/5,892
branches. Its complete native source inventory digest is
`4ea1b344dc4b13843a715b60318cc5d05fc421bc17f0efa7b0faa7d9aa53aa58`;
all 168 listed native source/header/test file hashes were rechecked against
the present worktree with zero mismatches. The project's bound build-input
digest was identical before and after the run. The gate completed before the
subsequent capture-only Godot scripts and owner lifecycle methods above were
added; it does **not** test those additions. Their individual focused direct
contracts are the evidence named in this report.

The independent N4 construction review found and prompted the post-draw
tree-presence/halo correction. A later read-only capture review found and
prompted the active visual scene-path/root readiness correction. Neither
review nor the integrated gate proves a production surface caller, all-family
publication, headed visual/collision behavior, save/reload/no-resurrection,
or original Gate 5 acceptance. No production deletion is authorized by this
checkpoint.
