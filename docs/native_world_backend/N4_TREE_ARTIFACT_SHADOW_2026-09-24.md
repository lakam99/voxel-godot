# N4 tree-artifact shadow checkpoint

Status: **verified pure-core Norway-spruce artifact; no production cutover**.

`NativeTreeArtifactBuilder` binds an immutable `NativeTreeDefinition` to a
revisioned render/collision artifact without changing the shared 28-attempt
surface-prop RNG sequence. For the native `norway_spruce` worker recipe, the
artifact carries tier-specific branch, foliage or impostor render input,
source/recipe identity, conservative bounds, and the definition-owned trunk
cylinder. Completion fails closed unless the worker consumes the definition's
visual height, trunk radius, canopy radius, collision radius and collision
height exactly. Broadleaf/oak and savanna definitions remain explicit
`broadleaf_recipe_pending` and `savanna_recipe_pending` results with
provisional render bounds rather than being reported complete.

## Provenance and focused evidence

- Original isolated commits: `539224ca0ac30fd9ad5fbb13b4b4893c484194fa`
  (artifact/schema/tests) and `d9c7af047ee4684669d4eb96b7deaf20dcdf0f28`
  (source-manifest registration).
- Primary integration equivalents: `9fa513d` and `4f7250d`.
- Focused MSVC `/W4 /WX`: 5/5 passed. Focused LLVM: 5/5 passed.
- Changed component coverage: 301/301 lines, 52/52 functions and 62/62
  branches.
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
- Broadleaf/oak and savanna render recipes remain pending.
- Live tree visual publication and physics installation are unproven.
- Durable tree removal/tombstone publication and save/reload are unproven.

Accordingly, this is an N4 shadow artifact boundary, not acceptance of the
complete tree family, live gameplay collision, or N4 completion.
