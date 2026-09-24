# N4 tree-artifact shadow checkpoint

Status: **verified pure-core Norway-spruce and umbrella-thorn artifacts; no production cutover**.

`NativeTreeArtifactBuilder` binds an immutable `NativeTreeDefinition` to a
revisioned render/collision artifact without changing the shared 28-attempt
surface-prop RNG sequence. For the native `norway_spruce` worker recipe, the
artifact carries tier-specific branch, foliage or impostor render input,
source/recipe identity, bounds, and the definition-owned trunk cylinder.
Completion fails closed unless the worker consumes the definition's visual
height, trunk radius, canopy radius, collision radius and collision height
exactly. Norway spruce and umbrella thorn now compile complete pure-core
artifacts; broadleaf/oak remains `broadleaf_recipe_pending` with provisional
render bounds.

## Provenance and focused evidence

- Original isolated commits: `539224ca0ac30fd9ad5fbb13b4b4893c484194fa`
  (artifact/schema/tests) and `d9c7af047ee4684669d4eb96b7deaf20dcdf0f28`
  (source-manifest registration).
- Primary integration equivalents: `9fa513d` and `4f7250d`.
- Focused MSVC `/W4 /WX`: 5/5 passed. Focused LLVM: 5/5 passed.
- Changed component coverage: 301/301 lines, 52/52 functions and 62/62
  branches.
- Savanna integration: worker commit
  `5fe8cb04d436ba97a80ce2abdaad5e064e5c15ca`, primary integration `75fbd73`.
  Its focused MSVC and LLVM test executables each report 11/11 passed when run
  against the reviewed candidate checkout. The tests cover the umbrella-thorn
  worker recipe and all four artifact render tiers; this is focused candidate
  evidence, not a fresh complete primary-manifest build receipt.
- Source-manifest inventory: 213 discovered files equal 213 declared files;
  the artifact source, header and test source are registered.
- Independent review: ignored evidence at
  `C:\Users\arkam\.codex\worktrees\n4-tree-artifact\artifacts\native-world-backend\n4-tree-artifact-focused-01\independent-review.md`,
  SHA-256
  `F1EBE15BA31A219368437388EBFD463EF98623EBD21060AC094A0C5BD8538295`.
  This checked-in report is the durable summary; the ignored review file is
  not repository history.

The independent review's dimension-normalization finding was corrected before
the final commits. Regression coverage includes admitted low-trunk,
narrow-canopy and low-height definitions, retained collision-height mismatch,
and an independent analytic +90-degree XZ/yaw fixture for owner-local versus
world render bounds and translation.

## Explicit limits

- There is no Godot consumer or adapter for this artifact.
- There is no production authority cutover or deprecated-code deletion.
- Broadleaf/oak render recipe remains pending.
- The earlier Savanna-specific NO-GO findings were closed for this shadow
  boundary by the 2026-09-24 repair receipt below. Independent review permits
  shadow integration only; it is not a production cutover approval.
- Live tree visual publication and physics installation are unproven.
- Durable tree removal/tombstone publication and save/reload are unproven.

Accordingly, this is an N4 shadow artifact boundary, not acceptance of the
complete tree family, live gameplay collision, or N4 completion.

## 2026-09-24 savanna repair receipt

The post-integration review findings are repaired on the shadow boundary. A
complete conifer or savanna artifact now fails closed before canonicalization
unless every definition, trunk cylinder, impostor dimension, branch/foliage
record and final collision/render bound is finite and contract-valid. The
branch graph must have unique positive child IDs and source-ordered ancestry
rooted at implicit node zero; this rejects orphans, duplicates and cycles after
the graph-preserving LOD reducer. Foliage `source_segment` remains a nonnegative
ID in the unreduced grammar graph: foliage LOD is intentionally reduced
independently, so it is not required to name retained wood.

The validation covers both complete grammars and rejects exact `FLT_MAX` plus
near-overflow canopy inputs for Norway spruce and umbrella thorn. The direct
savanna worker remains an internal pure-core API. It intentionally does not own
a serialized-text byte limit; a future engine adapter must enter through the
bounded `NativeTreeDefinition` contract.

Focused frozen-source evidence:

- MSVC `/std:c++17 /EHsc /Od /Z7 /fp:strict`: 14/14 passed.
- LLVM `/std:c++17 /EHsc /Od /fp:strict` with profile instrumentation: 14/14
  passed.
- Changed implementation/observation coverage: 689/689 lines, 77/77
  functions, 172/172 branches and 347/347 regions (100% each).
- Source manifest: 220 discovered = 220 declared = 220 unique, zero
  differences; the native savanna observation is registered.
- The registered config-driven runner executed both live GDScript oracle
  sources headlessly with `--audio-driver Dummy` and
  `VOXEL_DISABLE_AUDIO_PLAYBACK=1`, then executed the exact native binary. It
  compared four raw grammar cases, all 132 branch checkpoints, all 170 foliage
  checkpoints, both selection hashes, and all seven worker cases. Integer
  identity/checkpoint values are exact; serialized floating facts use the
  stated `1e-12 * max(1, |Godot|, |native|)` tolerance.
- Godot: `4.6.1.stable.official.14d19694e`, console SHA-256
  `bd9e27c6994a128aaab45cdda4d372de87b91900618ba2de55c6aa29248d5b56`.
- Final MSVC focused executable SHA-256:
  `5771d241c863487b0be5a01f5d58c9d86cae8b689a098b59fb4cfe80912c4a14`.
- Final LLVM focused executable SHA-256:
  `7839ef05323d7a5ac925ca9e5b10434141763e9731ba769d70f3d4851e350631`.

Machine evidence is intentionally ignored at
`artifacts/native-world-backend/n4-savanna-repair-final/`. The source-bound
runner receipt is `registered-run-final5/report.json`; focused coverage is
`final5-coverage-report.txt`; the complete source/tool/binary inventory is
`final5-hashes.json`; and manifest evidence is `final5-inventory.json`.

This repair does not add a Godot adapter, change production routing, or promote
the shadow artifact. Broadleaf remains pending, and live publication/physics
acceptance is still deferred to the later cutover stage.
