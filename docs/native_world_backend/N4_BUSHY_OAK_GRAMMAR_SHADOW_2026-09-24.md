# N4 bushy-oak grammar shadow precursor

Status: **shadow-only precursor; no broadleaf artifact or production cutover**.

The live broadleaf owner is not a small shape recipe. `TreeSpawnService.gd`
normalizes broadleaf and legacy `rounded_broadleaf` requests onto `bushy_oak`,
derives maturity/density/LOD growth budgets, invokes the v21 grammar, reduces
the source graph, adapts coordinates and radii, reduces again for rendering,
then attaches signatures, interaction facts and trunk-only collision. The
3,081-line bushy-oak builder inherits the shared mathematical-tree base and
constructs its graph through Godot PCG crown initialization, trunk/scaffold
growth, local-grid space colonization, pipe-model solves, as many as four
continuous derived-axis growth seasons, full-axis foliage and root buttresses.
Both the review PoC and runtime worker enter through the same service path.

`NativeBushyOakShadowRecipeBuilder` and
`NativeBushyOakWorkerShadowBuilder` intentionally port only facts that can be
cross-attested before the topology migration:

- bounded UTF-8 request admission, presence-aware request normalization and
  stable identities, including architecture fallback/repair and omitted canopy
  density fallback to the normalized biome profile;
- the v21 scalar envelope and first Godot-PCG crown-phase draw;
- near/mid/far render budgets and runtime grammar growth profiles;
- runtime versus review and impostor field semantics;
- v10 topology-dependent signature finalization; and
- definition-owned trunk collision, including the normalized architecture's
  production height fraction, with a strict five-dimension
  equality gate for any future artifact binding.

Every non-impostor result is explicitly `topology_pending`, reports zero source
branch/foliage counts, has empty topology/signature fields and keeps
`artifact_publishable == false`. Runtime and review impostors are represented
exactly because the live service invokes no grammar and emits zero topology for
that tier; they also remain non-publishable. `NativeTreeArtifactBuilder` is not
referenced or changed. No Godot adapter, publication callback, routing code or
GDScript owner changed.

## Source-bound oracle design

The precursor reuses `tools/compare-native-tree-oracles.mjs`, the same owned,
clean-source differential authority used by Savanna. Its Broadleaf config is
`native_bushy_oak_shadow_oracle_attestation.json`.

The raw GDScript oracle runs the actual live v21 grammar for three bounded
near/mid/far profiles, but publishes an explicitly topology-free projection:
scalar dimensions, crown vector/phase, growth profile and render budgets are
compared, while signature, counts, selection hashes and checkpoints are
deliberately empty/zero on both sides. The worker oracle compares seven
impostor cases: runtime, review, omitted architecture/canopy density, explicitly
empty architecture, an admitted UTF-8 unknown architecture, and explicit oak grammar under the
two recognized non-broadleaf architecture labels. These are the cases for
which the shadow owns exact complete facts without a topology compiler, and
they bind the production fallback and collision-policy order instead of
assuming every caller supplies
already-normalized values. This distinction prevents scalar evidence
from being reported as branch/foliage parity. The config also carries an
impostor-only evidence contract enforced by the shared runner: a pending tier,
nonzero topology, empty signature or non-impostor topology identity is rejected
before row comparison. `tools/test-native-tree-oracle-evidence.mjs` verifies
those fail-closed cases without launching Godot or native code.

The shared runner records and freezes both GDScript authority sources and all
native sources, uses Dummy audio plus `VOXEL_DISABLE_AUDIO_PLAYBACK=1`, records
Godot/native executable hashes, compares exact integer/text facts and bounded
floating values, and requires authoritative zero owned processes.

The native compiler also has one deliberate safety precondition that the live
dynamically typed GDScript service does not enforce: every canonical numeric
input, including biome parameters, must be finite. NaN and infinity are rejected
before identity or collision construction. The seven differential cases are
finite production-parity cases only; they do not claim that GDScript rejects
the same invalid numerics. The worker evidence contract requires finite
normalized values and exact nonempty `recipeIdentityKey`/`requestKey` values,
including their production field order and render-tier suffix.

## Promotion blockers

Production promotion requires a separate typed, exact port of ordered branch
segments, foliage anchors, root-buttress footprints, pipe/occupancy diagnostics
and both graph reductions across the admitted seed/maturity/LOD/review domain.
That stage must preserve every topology-affecting Godot RNG draw and float
evaluation, then differentially prove signatures, checkpoint hashes and ordered
geometry—not merely counts. Only after that review may Broadleaf be connected
to the shared tree artifact, Godot publication and live visual/collision tests.

The precursor verification is complete. The production verdict remains
**NO-GO**.

The reported `crownPhase` is only the first exact Godot-PCG draw; it is not a
claim about the unported topology RNG sequence. The final build and
source-frozen executable evidence below verifies this bounded precursor, not
the missing topology sequence. All precursor rows, including exact impostors,
remain `artifact_publishable == false`.

## Final precursor evidence

The complete native aggregate passed from the clean isolated branch at exact
commit `42d19b8d8685f4b2d1d75ef16cdeacb18693b3a5`:

- Debug, Release and LLVM-instrumented runs each passed `642/642` tests;
- strict first-party coverage was `16,445/16,445` lines,
  `1,980/1,980` functions and `8,732/8,732` branches, with no uncovered
  line/function/branch entries;
- the deliberately incomplete coverage canary reported `8/12` lines,
  `2/3` functions and `2/4` branches, proving that the evidence parser still
  detects misses;
- the explicit Debug adapter load and installed Release-export adapter smoke
  both passed; and
- every inspected watchdog terminated naturally with authoritative zero owned
  processes.

Aggregate report:
`artifacts/native-world-backend/4-bushy-oak-shadow-42d19b8d/report.json`
with SHA-256
`3ebca324d43249197657230cf5c950406ecd8debbc53c3d7b82b37d3c0047f95`.

The separate source-bound differential then passed from that same clean exact
commit. It compared three direct recipe projections and seven worker cases.
All declared integer/text/identity facts matched exactly; finite floating
values matched within the declared `1e-12` tolerance. Its four watchdogs all
exited naturally, cleanup proved zero owned processes, all stderr outputs were
empty, and the 25-input source freeze remained unchanged.

Differential report:
`artifacts/native-world-backend/n4-bushy-oak-shadow-oracle-42d19b8d/report.json`
with SHA-256
`adfc12593956df330cfbd8ec2c724cdcc0c4958db9ef0c317c0d398294a00d35`.
The bound Debug native executable SHA-256 was
`9f7273b6ee31e7d16a915c6cec0305943937c511de79500c77834267d379d01b`;
the Godot 4.6.1 console SHA-256 was
`bd9e27c6994a128aaab45cdda4d372de87b91900618ba2de55c6aa29248d5b56`.

The six verified commits were cherry-picked without content changes onto the
primary migration branch as `614b98c6`, `c4c33f5b`, `c2aa1697`, `f3ba4c12`,
`2f56e23f` and `85fca07e`. A Git object comparison between the isolated exact
head and the integrated head found no differences in the native world-backend,
tree authority, oracle, process-runner or evidence inputs. Working-tree byte
hashes are not reused across the two Windows checkouts because their checkout
line-ending representations differ; the attestation remains bound to the
clean isolated checkout and the identical committed blobs.

This evidence verifies only the bounded non-publishable Broadleaf precursor.
It does not port ordered branches or foliage, make a native tree artifact
publishable, connect production publication, delete the GDScript grammar, or
close N4.
