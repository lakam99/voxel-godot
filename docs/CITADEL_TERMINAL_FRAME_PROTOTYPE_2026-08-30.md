# Terminal shop frame: isolated prototype, not integrated

Latest validation follow-up: `dependency-terminal-corrected-01` now passes the
construction and synthetic post-construction contract after generic required-
dependency failure propagation and explicit correction of the three invalid
base-fixture preconditions. Earlier red results below remain historical evidence.
See `CITADEL_REQUIRED_SUPPORT_VALIDATION_2026-08-30.md` for scope and regressions.
This does not approve geometry, integration or headed testing; the integrated
gate remains 253.

## Status

Branch `codex/citadel-visuals-clean`, HEAD
`fcda6762c1923015e27cf622a63e87f6209118c0` with accumulated uncommitted
visual repair work preserved. Integrated physical gate remains **253 failures**.
The prototype observes **237**, but that is not an accepted repair count.
No commit or headed launch was performed for this prototype.

`TerminalShopFrameBuilder.gd` is not called by the composer. It connects the
existing three terminal-shop frames to their supplied retaining support, adds
awning rails and a three-piece sign standoff per shop, and gives brackets
explicit finite joints. Existing jamb/header nominal transforms are retained;
their collision and exact timber profile change. Brackets change shape and
position. These are real visual/collision changes still requiring review.
The existing cloth, signs, furniture planner output, rooms and blueprint
identity remain unchanged in the source contract.

## Fixed baseline

Known seed `208159`, scale `1.25`. Input is the framed 253-failure
`output.sourceSnapshot` in
`artifacts/citadel-visual-reset/roof-prototype-freeze-01/prototype.bin`.
SHA-256:
`7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5`.
The older unframed snapshot is not used as this prototype's baseline.

## Evidence

Every run below is under `artifacts/citadel-visual-reset/`, uses fresh isolated
application-data paths, and is launched through
`tools/run-godot-scene-watchdog.ps1` with `-Headless -TimeoutSeconds 100`.
Each directory contains `report.json`, `stdout.log`, `stderr.log`, and
`watchdog.json`; the latter records the complete command and owned-process
cleanup. These script fixtures have no separate progress file or screenshots.

| Run | Script supplied to Godot `--script` | Expected / actual |
| --- | --- | --- |
| `terminal-frame-contract-01` | `res://scripts/testing/buildings/CitadelTerminalFrameContract.gd` | Source preservation, valid target joints and mutation rejection: 16 checks and 45 negative controls PASS; exit 0 |
| `terminal-frame-payload-02` | `res://scripts/testing/buildings/CitadelTerminalFrameVisualProbe.gd` | Actual published joints and collider/visual agreement: 33 affected physical checks and 24 box matches PASS; strict contact FAIL; exit 1 |
| `terminal-frame-payload-03` | Same probe, with incidental-rooting measurements | Same bounded results, plus market/terminal pair evidence below; exit 1 |

Contract report elapsed work is 23.456 seconds. The contract has zero unexpected
source changes or added physical violations. Furniture snapshots match.
Reservation arrays match but are empty: this does not prove occupied-reservation
clearance. All three runs have authoritative owned-process zero and no cleanup
errors. Global Godot process count was also checked as zero after payload03.

The payload probe uses actual publisher box transforms, not GPU readback or
live traversal. Six jamb/retaining strict-contact separations are
`+1.19209289550781e-7 m`. They remain reported failures; no tolerance changes or
geometry offsets were introduced to erase them. The critic distinguishes these
arithmetic-scale diagnostics from the architectural blockers.

## Why the apparent 16-failure reduction is not accepted

Twelve removed failures concern the terminal shops. Four concern unchanged
nearby market timbers that infer new anchors from the prototype frames.
Payload03 checks those actual visible pairs separately:

- Three market knees overlap terminal timbers. Signed separations range from
  about `-0.0051 m` to `-0.1646 m`; overlap alone does not establish intended
  joinery rather than intersecting independently generated structures.
- `urban_market_canopy_ridge_-1_1` does **not** actually touch either inferred
  rail. Signed visible separations are `+0.0144110818 m` to
  `urban_terminal_00_awning_rail_1` and `+0.0035340743 m` to
  `urban_terminal_01_awning_rail_-1`. Its source-gate improvement is not a
  demonstrated physical repair.

The three sign-standoff bases intersect the existing recess panels by a nominal
0.035 m. The standoff avoids the cloth, but panel embedding and actual approach
clearance remain unadjudicated. Existing obstruction-candidate coverage excludes
beam targets; payload03's specific collateral-pair checks do not constitute a
complete interference audit.

Independent read-only source investigation (James) identifies the third market
stall and terminal row as independently placed, overlapping households rather
than an authored shared frame. Relative to the plaza, the stall is centred at
approximately X -2.506, Z +2.823; terminals 00/01 at X -4.6/0, Z +3.570.
Rear stall knees at Z +3.543 nearly coincide with the terminal frame line.
`CitadelUrbanPocComposer.sample_urban_layout` owns this placement conflict.
A future correction must reserve the terminal envelope and place the entire
stall household coherently, retaining its storage/seating grammar. No placement
change was made in this evidence step. The worker considers the sign-base/recess
contact legitimate embedding in its own non-colliding backing; that is source
interpretation, not visual or clearance acceptance.

## Independent critic decision and next bounded work

Cicero: **PASS bounded evidence; REJECT integration readiness. No launch
authorized.** Remaining work:

1. Resolve market/terminal contacts and sign-base panel embedding at the owning
   geometry layer; do not credit incidental anchors as repairs.
2. Stage builder changes and reject duplicate, wrong-kind and incompatible
   inputs without mutating the source. Validate all mandatory joints before
   returning ready.
3. Extend negative controls to base/top sign mounts and failed mandatory
   upstream seats despite incidental rooting; positively precheck dependents.
4. Obtain critic readiness approval before any headed visual/clearance run.

Production NPC/navigation files still match protected baseline
`90e89cf433edacbeed26c40916719e7a7d4b55e3`. This work proves neither live NPC
behavior nor normal-world loading, player traversal, general seeds or a green
whole-citadel physical gate. The temporary physical-publication bypass remains
explicit. Exterior facade posts/footings remain a separate unapproved proposal.

## Transactional construction follow-up

The builder now stages seven source records and five new members privately,
checks all twelve records and their mandatory joints, and only then commits
authored changes. It preserves original part objects/order, the supplied
foundation and caller-held original recipe objects. Derived validation caches
are cleared/recomputed in the staging copy and are not committed.

The API explicitly requires an actual colliding foundation grounded at blueprint
y=0 according to the existing `is_grounded_structural_root` rule (sampled
bottoms within 0.06 m). This is not arbitrary terrain-contact or elevated-frame
support. Duplicate IDs, invalid geometry, wrong member kinds/materials, existing
external requirements, forged roots, addition conflicts and invalid final joints
fail without changing source content. Attachment sockets must also fit inside
their own member's body, not merely inside the named anchor.

- `terminal-frame-payload-04`: initial transaction version; actual joint,
  collision and violation report arrays exactly match payload03.
- `terminal-frame-payload-05`: final hardening version; the same exact array
  equality holds. Existing strict contact failures remain; exit 1.
- `terminal-frame-contract-02`: 21 construction checks PASS, including all
  180 invalid-input/retry controls, all 45 original support controls and all
  18 base/top mount controls. Foundation identity/content, original aliases,
  furniture output and permitted-change preservation pass. Reported elapsed
  work: 36.858 seconds.

All use the same scripts/watchdog pattern and per-run evidence files above.
All three runs completed with authoritative owned-process zero, no cleanup
errors, and empty stderr; global Godot zero was verified after contract02.

The expanded contract is deliberately **overall FAIL / exit 1**: all 18
post-construction diagnostic controls are false. Fifteen exercise incidental
rooting after a member's required seat fails, exposing incomplete downstream
invalidation. The three base-mount cases do not retain incidental rooting and
therefore do not establish that diagnostic's required scenario; do not count
them as three additional demonstrated defects. `constructionChecksPassed` is true;
`postconstructionDiagnosticsPassed` and overall `passed` are false. No shared
validator or navigation changes were made to conceal that result.

The critic accepted contract02's construction evidence but withheld constructor
acceptance: sign/bracket inputs mislabeled as visual details or portals could
bypass intent-dispatched anchor checking. The builder now rejects incompatible
attachment intent/collision and explicitly checks every generated seat and
anchor, independent of intent dispatch. Thirty-six wrong-intent input cases
extend the rejection matrix to 216. `terminal-frame-contract-03` completed in
40.260 seconds of reported work: all 21 construction checks and all 216 input,
45 original support and 18 base/top controls pass. Overall status remains FAIL
because the separate post-construction diagnostics are unchanged. Exit 1,
authoritative owned-process zero, no cleanup errors and empty stderr were
verified. Cicero independently accepted the bounded constructor change after
contract03: no further constructor fixes required. This is not a headed-launch,
integration or whole-gate grant; overall contract status remains RED.
This closes neither the market layout conflict nor visual/integration acceptance.
The user subsequently approved a whole-stall relocation. Source-only checks
found that the proposed move intersects an existing solid terrace, and no
complete-household rectangular fit exists under the unchanged-plaza policy.
No relocation has been applied. See `CITADEL_MARKET_RELOCATION_CHECK_2026-08-30.md`.
