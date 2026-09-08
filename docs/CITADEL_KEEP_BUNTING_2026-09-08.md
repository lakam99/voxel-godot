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

## Exploratory frozen-source proposal

```text
node tools/run-building-contract.mjs -Contract CitadelKeepBuntingProposalDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/candidate22-keep-bunting-proposal-01 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 120
```

Read-only review approved one trial. All 12 checks passed in 26.834 seconds,
with clean engine logs, natural exit 0 and authoritative owned zero. The trial
uses the captured tower/pavilion IDs as explicitly diagnostic setup, derives
the common face envelope, verifies courtyard XZ containment, retains every
captured protected volume and adds all non-courtyard room bounds.

Actual anchor preparation tested four candidates with 58,036 clearance
comparisons and proposed endpoints `(-9.823,9.619762,-10.9584)` and
`(13.741,9.619762,-10.9584)`. Both sockets are independently rooted. All 14
selected assembly members passed physical validation after applying the
proposal privately. Stored-placement verification passed with 50,658 further
comparisons. The original 13 pennants retain their sizes, material, rotation,
collision setting, semantics and IDs; their positions spread along the new
rope span. Other source geometry is not changed by the proposal.

The full physical validator ran, but this diagnostic accepts only the selected
14 members; it does not certify the whole source. The trial does not establish
a production owner relationship or reusable placement domain. Those must be
published by the owning structure producers, consumed generically and tested
for stale/foreign/swapped ownership, impossible geometry and clearance failure
before another full candidate run. No production placement or headed change
has been made.

## Production ownership implementation

The builder now records exact geometry receipts on its two forecourt pavilions;
the civic landmark producer records its own receipt. The composer resolves the
actual owner IDs and courtyard ID and declares exterior mounting independently
in the third assembly's membership record. Deleting the rope's owners payload
therefore fails validation rather than restoring the unbound path.

`CitadelExteriorBuntingDomain.gd` recognizes pavilion side/geometry against the
existing hashed forecourt layout and recognizes the landmark and courtyard
against their compound-grammar producer contracts. Receipts bind ID, kind,
semantic, position, size, rotation and collision, excluding mutable physical
caches. They do not authorize rootedness. The helper derives an opposing-face
domain, retains captured protection and adds non-courtyard rooms.

Structural completion validates associations before physical selection and
includes every associated assembly in terminal verification. Already-passing
associated geometry may receive anchor facts but may not be relocated. The
anchor search, rooting, socket, pennant clearance and terminal proof remain
unchanged. No NPC/navigation or tree implementation is modified.

Verification commands (each output directory is fresh under
`artifacts/citadel-runtime-integration/`):

```text
node tools/run-building-contract.mjs -Contract CitadelExteriorBuntingDomainContract.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-domain-04 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 60
node tools/run-building-contract.mjs -Contract CitadelExteriorBuntingRecognitionDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-recognition-03 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 30
node tools/run-citadel-structural-policy-capture.mjs -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-producer-capture-02
node tools/run-building-contract.mjs -Contract CitadelExteriorBuntingIntegrationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-integration-01 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 120
node tools/run-building-contract.mjs -Contract CitadelBuntingAnchorRecipeContract.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-anchor-regression-01 -ReportEnvironment CITADEL_BUNTING_ANCHOR_REPORT -TimeoutSeconds 60
node tools/run-building-contract.mjs -Contract CitadelBuntingAssemblyManifestContract.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-manifest-regression-01 -ReportEnvironment CITADEL_BUNTING_MANIFEST_REPORT -TimeoutSeconds 60
node tools/run-building-contract.mjs -Contract CitadelMarketBuntingDomainContract.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-market-regression-01 -ReportEnvironment CITADEL_MARKET_BUNTING_DOMAIN_REPORT -TimeoutSeconds 60
node tools/run-building-contract.mjs -Contract CitadelExteriorBuntingCompletionContract.gd -OutputDirectory artifacts/citadel-runtime-integration/exterior-bunting-completion-02 -ReportEnvironment CITADEL_ORDERED_OPENING_REPORT -TimeoutSeconds 60
```

All listed runs passed with clean engine logs, natural exit 0 and authoritative
owned zero. Evidence levels and counts:

- Domain04: 83 synthetic checks for strict receipt/producer recognition,
  numeric-side types, foreign/stale/duplicate ownership, exact rejection
  branches, immutability, ordering and cache sanitation.
- Recognition03: three diagnostic checks; all actual frozen pavilion,
  landmark, courtyard and layout-hash predicates are true. Receipt stamping
  here is synthetic and does not prove producer emission.
- Producer capture02: eight checks, 43.387 seconds, 4,440 parts and 178
  furniture parts. Actual builder/composer emission, intentionally cancelled
  before structural completion. Full source and file-inventory audits pass.
  Input SHA-256:
  `c9054b1aac1bbd08f77a41fd6f70480650dc7a82f2d73aa083eeffc483192e83`.
- Integration01: 16 checks, 54.304 seconds. Removing exactly three mount
  receipts, one rope owners field and one manifest marker restores byte-exact
  old pre-structural blueprint and furnishing policy. Only these identified
  fields are transferred to the frozen late source after exact geometry
  comparison. Actual structural bunting completion, selected 14-member
  physical proof and stored clearance pass. Nonselected records and all
  protected volumes remain intact; repeated completion is byte-exact and
  deleting owners from a passing assembly rejects before physical selection.
  This is a hybrid offline contract, not current whole-candidate acceptance.
- Existing anchor/manifest/market suites: 91/83/83 checks. They retain forged
  root-cache, crowded-pennant, protected-volume, roof, cancellation and
  membership negative coverage.
- Completion02: ten synthetic checks. Explicit physical roots establish a
  passing assembly; an independently successful alternative placement proves
  that production refuses relocation rather than merely lacking a solution.
  The caller remains unchanged. A union of 4,096 input protections and an
  interior room is rejected without truncation or caller/input mutation.

Earlier failures are retained. Producer capture01 naturally exited 1 after
9.273 seconds with no engine error or forced cleanup and unchanged sources.
Recognition01/02 isolated a numeric-type mistake: the real layout uses float
sides, while the first predicate used integer Array membership. The fix uses
the builder's finite float-side handling. Domain03 assertions passed but its
test serialized NaN and emitted an engine warning; it is rejected evidence.
Domain04 rejects bounded nonfinite descriptors before JSON hashing and avoids
warning-producing fixture serialization.

Completion01 naturally exited 1 with owned zero because its initial synthetic
domain produced no fitted candidate. Its non-exact X interval can round inward
at the right face; Completion02 explicitly uses an exactly represented
15-unit fixture gap and verifies both endpoint planes. This isolates the
preservation/overflow branches; it does not resolve general domain-rounding
behavior or justify widening production geometry.

Full current-source construction, independent physical proof, actual terrain
admission, publication preparation and critic-approved headed inspection are
still required. No broad gameplay playtest or headed run has been performed
for this change yet.
