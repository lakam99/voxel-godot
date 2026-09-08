# Candidate 22: keep-approach bunting

Branch `codex/citadel-visuals-clean`, production HEAD `99c655c`.
Candidate identity remains `atlas-3376622889`, region `(-2,-2)`, recipe
`1393179273`. No headed acceptance is available.

## Terminal source evidence

Command:

```text
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-22 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady
```

The source advanced beyond opening-head completion, then failed after
271.521 seconds: `citadel_structural_completion_failed` ->
`bunting_completion_failed` -> `no_rooted_bunting_endpoint_pair`.
Assembly `urban_bunting_rope_02` had zero left/right faces, zero tested pairs
and zero clearance comparisons. This is not an infeasibility proof.

Input SHA-256:
`fa347fa0724686e5f1dd07124417615387bb0cfe461fd58b02baf35e898dc688`.
Failure SHA-256:
`986472ce1f739ce419acedd47f15a3532614bdf27a629774a770e1cced369076`.

The source audit reports unchanged inputs. Functional exit was 1, without
timeout; the watchdog used forced cleanup, overall exit 126, and proved
authoritative zero remaining job members. Do not call this a clean exit.

## Raw geometry isolation

```text
node tools/run-building-contract.mjs -Contract CitadelBuntingFaceDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/candidate22-bunting-raw-faces-01 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 30
```

Four diagnostic checks passed with clean owned exit and engine logs. The
diagnostic pins `candidate21-policy-capture-01/input.bin`, SHA-256
`d6df2eeff4044d85d41cd46e1dc9b200740a01b3abd36455b6536ceb3514a903`.
It checks raw axis-aligned collision wall/foundation geometry before filtering
physical intent, validation results or rootedness. Assembly 02 at
`(11.5,9.619762,-13.6)`, width 17, has zero qualifying raw faces on either
side. At this Z, the recorded X-eligible faces belong to low foundations and
terraces; none reaches the rope. Assemblies 00 and 01 do have raw faces.

This proves only the pinned pre-structural geometry fact. It does not reproduce
the later stage, prove that no nearby valid placement exists, or certify
rootedness, clearance, rendering or gameplay. Detailed rows show Z-aligned
faces only. The diagnostic's passing status means the audit completed.

The producer uses a keep-relative fixed pose for assembly 02; only assembly 01
currently carries a producer-owned market domain. A repair must derive real
owning structures and shared exterior space from the generated layout. It must
not borrow the market association, invent a search radius, lower the rope onto
terraces, or shrink/remove the 13 pennants.

Read-only review accepted the raw diagnostic and required the exact later-stage
source, whole selected assembly set and protected volumes before repair
acceptance. A dedicated offline capture resumes the pinned structural source
and actual policy through the real structural stages, replacing only the
anchor dependency with a capture-and-cancel stub. Full source reconstruction
and headed testing remain deferred.

## Exact structural-stage capture

```text
node tools/run-citadel-bunting-stage-capture.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate22-bunting-stage-01
```

Read-only review approved this one offline capture. It completed in 211.375
seconds with nine checks passing, natural exit 0, no forced cleanup and
authoritative zero remaining job members. Both the frozen-source audit and
the added/deleted-file inventory passed. The original generic-runner proposal
was rejected in review because its 240-second ceiling could not accept the
330-second budget; no launch occurred for that proposal. The dedicated wrapper
uses existing owned-runner primitives with a 30-second parse gate, 300-second
structural deadline and 330-second watchdog, without changing generic limits.

Captured `candidate22-bunting-stage-01/input.bin`, SHA-256:
`58885c0e75414db4c4c3e16c764c6b7a522e1c9bd46618dd171101bccc8f9bbd`.
It contains 4,696 source parts, 338 protected volumes, and the exact selected
assembly list: rope02 with its 13 pennants. The other two assemblies were not
selected and remain in the source as obstacles. This is the actual input at
`BuntingAnchors.prepare`, reached through preceding production structural
stages. The interception deliberately cancels; capture success does not mean
the recipe passed.

## Focused exact failure replay

```text
node tools/run-building-contract.mjs -Contract CitadelBuntingStageDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/candidate22-bunting-stage-replay-01 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 120
```

Read-only review approved this replay. It completed in 9.501 seconds with six
checks passing, clean engine logs and natural owned exit 0. Actual
`Anchor.prepare` reproduced the same reason, rope ID, zero left/right faces,
zero candidate pairs and zero clearance comparisons. This passing diagnostic
proves reproduction of a failure, not a successful recipe.

`geometry.json` exports numeric bounds for all captured parts, rooms and
protected volumes. These are raw geometry; the inventory does not expose the
anchor helper's private recomputed rooting proof. Exploratory AABB screening
(`space-screen.json`) suggests a 23.518-unit span from the civic tower's east
face to the east keep-forecourt pavilion's west face. That screen included all
rooms and therefore reports `castle_courtyard` as a blocker. Its producer
declares that room with role `courtyard`, not an interior. This needs a proper
owner/domain and exact rotated/socket/clearance trial, not a blanket room
exemption or a production placement inferred from the exploratory rectangle.

No production bunting geometry, acceptance rule, ownership or placement has
changed. The next step is to verify the shared exterior relationship and test
the complete unchanged assembly against independently rooted sockets and all
actual protected geometry on the frozen stage source.
