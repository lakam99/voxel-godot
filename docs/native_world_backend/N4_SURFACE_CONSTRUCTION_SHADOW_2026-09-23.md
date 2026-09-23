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
19/19 at `artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json`.
The bundle declares `complete=false`: it does not contain a native effective
terrain pin, StructureSystem tree halos, an all-28-attempt manifest or an
atomic publication lease. The capture's scene inspection is not a per-chunk
hot-path operation; future integration must cache by owner generation and
recheck freshness before publication without turning scene import inspection
into a gameplay-frame stall.
The same direct fixture now records measurement-only timings: roughly 39 ms
for a full owner bundle capture and 18 ms for a full freshness recheck on this
headless host, with visual rows (~10.5 ms) and biome profiles (~5.4 ms)
dominating that recheck. These are not gameplay-frame benchmarks or acceptance
thresholds, but they rule out a naive per-chunk full recapture. The eventual
native catalog must own immutable copied values after setup, with a cheap
same-owner/revision check adjacent to the no-yield publication swap; content
audits belong in loading/diagnostic work unless an owner-controlled mutation
requires a new catalog generation.

`NativeWorldBackend.admit_removed_props_tombstones` is the first narrow Godot
adapter conversion for that bundle. Its focused Godot contract passed after
the debug native build at
`artifacts/native-world-backend/n4-removed-props-adapter-contract.json`.
It validates strict sorted UTF-8 IDs, bounds, seed, capture content hash and
the FD1 tombstone grammar, but returns only a shadow, incomplete typed
receipt. A forged internally consistent capture cannot establish current
Main ownership: the caller must run `ActiveRemovedPropsSnapshot.is_current`
immediately before any eventual native feature publication. The adapter now
retains the typed set under its native owner and clears it on rejected
replacement. The focused direct retention contract passed against the rebuilt
debug extension. It still does not produce feature footprints or prove current
Main ownership at publication.
`NativeWorldBackend.admit_biome_environment_catalog` now similarly converts
the active 13-profile capture into the pure-core catalog and returns its typed
identity, with exact numeric byte lanes and content-hash checks. Its focused
Godot adapter contract at
`artifacts/native-world-backend/n4-biome-catalog-adapter-contract.json`
passed with no failures after a debug/release build. A later N4 checkpoint
retains that typed biome catalog in the native adapter and invalidates it on
rejected replacement. The adapter also now retains an effective visual rock
selection catalog from the active owner bundle; see
`N4_ORDERED_ROCK_VISUAL_SHADOW_2026-09-22.md` and the passing
`n4-visual-fallback-01` report. These remain partial shadow admissions, not
an all-28-attempt job or production publication.
The attempted aggregate `n4-removed-adapter-01` at
`artifacts/native-world-backend/n4-removed-adapter-01/report.json` failed its
debug extension source-inventory comparison because these adapter edits began
after its pre-build inventory. It is a reproducibility rejection, not a native
test assertion or a passing gate. The settled-source aggregate
`n4-wildlife-presentation-adapter-01` passed 446/446 debug and release tests,
editor and release adapter smoke, and strict 100% pure-core line, function and
branch coverage (9,988/9,988; 1,369/1,369; 5,940/5,940). Report:
`artifacts/native-world-backend/n4-wildlife-presentation-adapter-01/report.json`.
`NativeWorldBackend.admit_wildlife_presentation_catalog` now binds the active
animated capture to the same owner bundle and retained biome, visual and
removed generations. It retains three typed canonical variant capabilities,
using the procedural fallback for an absent active variant, and invalidates
them on any replacement of those admitted inputs. The direct Godot contracts
`artifacts/native-world-backend/n4-wildlife-presentation-adapter-contract.json`
and `artifacts/native-world-backend/n4-removed-props-adapter-contract.json`
both passed against that build. These are captured-value adapter contracts,
not proof of live freshness at publication, complete 28-attempt construction,
wildlife motion, or Gate 5 gameplay.

The subsequent Citadel source-admission review found a semantic mismatch:
`CitadelTerrainAdmission.source_state` returns `status=absent` with
`reason=source_not_requested` before a region has been decided, and
`StructureSystem.capture_surface_tree_exclusion_halo` initially treated that
as not ready. The native exclusion query had treated it as a complete clear
decision. The first correction left it unresolved. The source-ordered chunk
preflight and post-draw tree-halo evaluator required every crossed Citadel
region to be decided even when natural/terrain exclusion would short-circuit
individual cells. The original two-suite C++ focused executable
passed 16/16 after direct compilation; the additional tree-halo correction
passed 7/7 in its focused suite. The `n4-exclusion-source-admission-02`
aggregate passed all 446 debug/release assertions but was blocked solely by
one strict coverage branch: the old per-cell completeness check could no
longer fail after exact bounds and all-region decided preflight. That
redundant 28x28 scan has been removed; an integrated rebuild/coverage rerun
then passed as `artifacts/native-world-backend/n4-exclusion-source-admission-03/report.json`:
446/446 debug and 446/446 release assertions, with 10,014/10,014 pure-core
lines, 1,371/1,371 functions, and 5,964/5,964 branches covered. This changes
only the N4 shadow source, not production prop spawning or protected NPC
routing.

Follow-up source-admission audit found a subtler boundary in that correction:
`request_bounds` deliberately leaves an irrelevant Citadel candidate
unrequested, yet returns `ready` for the exact footprint. Thus
`absent:source_not_requested` cannot decide coverage alone, but is a complete
clear result *under that ready bounds receipt*. The native chunk query now
accepts it only after the exact 28-cell admission preflight, while still
requiring every crossed region row and rejecting pending, failed, or missing
rows. The post-draw tree-halo capture now requests its own expanded bounds
before reading region states; pending/failed admission remains unready. The
direct StructureSystem oracle passed 66/66 checks at
`artifacts/native-world-backend/n4-surface-structure-exclusion-context-02/report.json`,
including a real `CitadelTerrainAdmission` case where an unrequested region
is irrelevant to ready bounds. The integrated command
`node tools/run-native-world-backend-tests.mjs --run-name
n4-citadel-bounds-context-01` passed at
`artifacts/native-world-backend/n4-citadel-bounds-context-01/report.json`:
446/446 debug and 446/446 release assertions, with 10,008/10,008 pure-core
lines, 1,371/1,371 functions, and 5,954/5,954 branches covered. These are
source-contract and shadow-adapter results, not live publication evidence.

A further direct admission case showed that a region may retain a failed site
whose declared influence is outside the requested chunk. The exact bounds
request still returns ready, so the failure is not a blocker for that chunk;
`source_state` alone cannot decide this either. The native center and tree
queries now accept that failed-but-irrelevant state only under their respective
ready bounds contracts, while a failed relevant source makes the bounds
request fail. A composed `ActiveStructureExclusionChunkSnapshot` now captures
one 28-cell StructureSystem source value with that admission, validated local
natural/terrain rectangles, every crossed Citadel row, reset/revision identity,
and a content hash. The focused Godot oracle passed 74/74 at
`artifacts/native-world-backend/n4-structure-exclusion-chunk-capture-03/report.json`,
including real irrelevant-failed admission, pending-bounds rejection, negative
chunks, tamper and owner-generation freshness. This capture has no production
caller and does not yet enter the native adapter or generate a live prop.
The first integrated run, `n4-structure-chunk-capture-01`, exposed one stale
native test expectation: it still expected every failed Citadel row to reject
a tree halo. The corrected contract accepts a failed row only under exact
ready-bounds admission and rejects a malformed failed row that carries
physical source fields. `node tools/run-native-world-backend-tests.mjs
--run-name n4-structure-chunk-capture-02` then passed 446/446 debug and
446/446 release tests, both adapter smokes, and strict pure-core coverage of
10,012/10,012 lines, 1,371/1,371 functions and 5,968/5,968 branches.
Its report is `artifacts/native-world-backend/n4-structure-chunk-capture-02/report.json`.

The owner-local N4 bundle now has an optional `capture_chunk`/`chunk_is_current`
boundary that binds the catalog/removal receipt to one admitted
StructureSystem exclusion chunk under the same Main owner. It rechecks both
sources after capture and rejects nested tampering, owner replacement and
structure-generation changes. The direct headless contract at
`artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json`
passes 26/26 checks. This remains explicitly incomplete: it does not bind an
effective terrain pin, capture dimension-dependent tree halos, produce an
all-family native manifest or change the live prop loop.

The next focused freshness check found a concrete reset alias: Citadel
admission could be reconfigured under the same StructureSystem generation and
produce identical empty chunk content. The chunk capture now records and
rechecks the admission's world seed and own generation; the owner bundle also
rejects an admission seed different from Main's. Direct Godot contracts pass
76/76 structure-oracle checks at
`artifacts/native-world-backend/n4-structure-exclusion-seed-generation-01.json`
and the owner-bundle contract's reset, mismatched-seed and recapture checks.
This closes receipt freshness only, not terrain or feature cutover.

The next chunk bundle can retain one native `NativeEffectiveTerrainPage`
against the same Main seed, source identity, terrain-delta revision and shaping
registry revision/identity as the backend owner. The adapter status now exposes
its immutable raw source seed for this admission. The wrapper maps ten 28-cell
prop chunks to each 280-cell native page (including negative page keys) and
rejects a replaced backend, seed change, tampered pin or later terrain delta.
The native gate `n4-terrain-seed-status-01` passed 446/446 debug and release
core tests, both adapter smokes and strict pure-core coverage at
`artifacts/native-world-backend/n4-terrain-seed-status-01/report.json`.
The focused N3 differential at
`artifacts/native-world-backend/n3-chunk-pin-differential-02.json` passed
goldens, source parity, delta mutation and pin lifetime; the combined owner
bundle contract passed 39/39 checks at
`artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json`.
This is still a capture-only receipt, not a native prop decision, live terrain
cutover or gameplay acceptance.

The structure-exclusion chunk now crosses a native adapter boundary as an
immutable `NativeStructureExclusionChunk` value. Admission validates the
Godot capture's seed, owner/revision, exact 28-cell bounds, row limits, copied
content identity and complete decided Citadel region set before constructing
the typed core snapshot. Native queries remain shadow-only and retain no live
StructureSystem reference; freshness still belongs to the owning bundle.
The first rebuilt adapter gate, `n4-structure-adapter-01`, passed 446/446
debug and release core tests and both adapter smokes at
`artifacts/native-world-backend/n4-structure-adapter-01/report.json`.
Focused Godot contracts passed 45/45 owner-bundle checks and 90/90 direct
structure-oracle checks at
`artifacts/native-world-backend/n4-structure-adapter-differential-01.json`,
including terrain/Citadel inclusive-versus-half-open boundaries, negative
natural exclusion, seed/content tampering and a missing region. The native
parser was subsequently tightened to bound rows before serializing their
identity. The final rebuilt-DLL gate, `n4-structure-adapter-bounded-02`, passed
446/446 debug and release core tests, both adapter smokes and validated strict
pure-core coverage at
`artifacts/native-world-backend/n4-structure-adapter-bounded-02/report.json`.
Both focused Godot contracts passed again against that installed DLL: 45/45
owner-bundle checks and 90/90 direct source/native decisions at
`artifacts/native-world-backend/n4-structure-adapter-differential-02.json`.

The adapter now composes the native source-ordered stream and SPO1 placement
witness for all 28 attempts from one effective terrain page, admitted
structure chunk, and retained biome/removal/visual/wildlife admissions. It
returns a shadow receipt with every ordinal, durable ID, cell, outcome, RNG
boundary and anchor; it does not construct or publish a complete feature
manifest. `n4-ordered-adapter-01` passed 446/446 debug and release core tests,
adapter smokes and validated pure-core coverage at
`artifacts/native-world-backend/n4-ordered-adapter-01/report.json`.
The first focused Godot invocation exposed a receipt translation error: the
terrain-pin wrapper compared the entire backend status, so unrelated catalog
admissions falsely staled an unchanged terrain page. It now compares only the
seed, source identity, terrain delta and shaping revision/identity. The
combined owner-bundle contract passes 52/52 checks at
`artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json`;
the focused N3 differential at
`artifacts/native-world-backend/n3-terrain-owner-identity-01.json` still
rejects the genuinely stale pre-edit pin. This establishes adapter execution,
not an independent full Godot source-order differential, complete geometry,
live freshness proof or production cutover.

A repeatable direct production-method differential now invokes the real
`Main.spawn_chunk_prop_attempt` loop and independently composes the native
ordered shadow from a captured terrain/structure bundle. Command:
`node tools/run-n4-direct-source-order-differential.mjs`. The first fresh
report passed at
`artifacts/native-world-backend/n4-direct-source-order-differential/report-7f64d69d-11ed-4d97-9854-66c538629e6e.json`:
all 28 atlas-1492 chunk-(0,0) attempt ordinals, durable IDs, sampled cells,
biomes, source heights, per-attempt 64-bit RNG states and final RNG state
matched. The runner uses a unique probe path and treats engine warnings or
failed owned-process cleanup as failures. This is direct-service evidence
under an empty Citadel/town policy, not headed gameplay, feature geometry,
live-capture freshness or N4 production cutover acceptance.

The differential was then extended to replay the same chunk with its first
durable prop ID tombstoned and a negative-coordinate chunk. Its fresh report
passed all 84 attempts across the three cases at
`artifacts/native-world-backend/n4-direct-source-order-differential/report-69ac3929-6a3a-4724-9aee-8e15df706d67.json`.
The tombstoned attempt preserves its coordinate and RNG boundary but correctly
does not consume a terrain sample; the probe compares only source values
actually used by production. This remains direct-service evidence, not a
headed game-flow or feature-geometry acceptance claim.

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
