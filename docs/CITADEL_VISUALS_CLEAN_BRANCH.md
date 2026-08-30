# Citadel visuals on the pre-integration production baseline

**Checkpoint status: source preservation verified; visual publication blocked.**
This branch is not yet a verified runnable urban visual PoC.

## Product boundary

This branch preserves the current Golden Alley / Solitude-inspired citadel
appearance and the blueprint and furniture-placement rules that generate it.
Citadel residents, their life-playtest fixture, and the later normal-world
citadel/NPC/navigation integration are deliberately absent. This is not a claim
that citadel NPC integration has been completed.

The ordinary production NPC, pathfinding, terrain, streaming and save systems
start from commit `90e89cf433edacbeed26c40916719e7a7d4b55e3`.
No current `scripts/npc_ai`, `NpcSystem.gd`, or `NpcPathing.gd` changes are
ported. The existing player-door system remains, including raising gates.

## Preservation source

Visual source: the working tree of `codex/unified-nav-gate0-baseline` at
`f010830ac75b45982dc2f4657d3cad17c7fef596`, including its current uncommitted
furniture/residence-planning changes. Both that working tree and the original
`codex/citadel-texture-poc` working tree are left untouched.

The retained source includes architecture, courtyard/residence placement,
interiors, furnishings and protected access reservations, masonry/weathering
materials, procedural trees, urban composition and its review scene.

Some source-level clearance/connectivity calculations influence furniture
selection. Those calculations are retained under `scripts/buildings/layout/`
with the donor's dimensions, separate from restored runtime NPC policy.
They analyze immutable building/furniture records; they do not register
navigation, schedule actors or provide a runtime route service.

Building and furnishing publishers no longer publish navigation manifests.
Their visual, collision and player-door construction methods are retained.
Layout-only manifest builders remain dependencies of furniture generation.
The later Citadel route-admission check is diagnostic-only on this branch;
its failures remain visible in publication summaries. The separate physical
integrity admission check remains enforced.

## Verification and reproduction

Use `tools/run-citadel-visual-preservation.ps1` with a fresh absolute
`-OutputDirectory`. It requires no preexisting Godot processes and launches
through a bounded, process-tree-owning watchdog with isolated user-data paths.

- `-Mode Import`: headless project import/parse preparation.
- `-Mode Contract`: seed 208159, scale 1.25 source-artifact capture. Pass
  `-ProjectPath` to run the identical external script against the donor.
  Run both `-Variant urban` and `-Variant compound`; the former alone does
  not exercise courtyard residence furnishings.
- `-Mode Capture`: headed empty-environment citadel appearance captures.
  Obtain the requested independent readiness review before launching.

Contract reports must be compared across projects. A complete report alone
does not prove parity. Compare all five stage records, full snapshot and part
hashes, including furnishing access reservations. This is not live NPC,
normal-world, door-input or performance acceptance.

Visual reports require inspection of the actual images. The review fixture
stages a door through its service for photography; it does not prove real
player-operated door traversal. Do not cite that action as gameplay evidence.

Run evidence and the original 84-file donor hash inventory are under
`artifacts/citadel-visual-reset/` (locally generated, ignored by Git).
Final verification results are recorded below after review.

### Verified so far

- Import/parse: `import-01`, exit 0, empty stderr, no detected errors/warnings,
  empty owned process job and no remaining Godot processes.
- Urban source parity: `donor-contract-02` versus `clean-contract-02`,
  seed 208159 / scale 1.25. All five stage objects match, including 18 hashes
  and all counts/histograms. This covers 4,045 urban shell parts and 152
  urban furnishing parts. Independent critic accepted source parity.
- Earlier `donor-contract-01` and `donor-compound-01` are deliberately
  retained as incomplete captures: cumulative serializer safety ceilings were
  too low. Neither is acceptance evidence. Their production calls returned,
  and process cleanup succeeded; execution timeouts were not increased.
- Source-only checks confirm ordinary NPC/navigation files match the chosen
  baseline, and the copied publishers' mesh/material/collision/door methods
  match the visual donor. These are not runtime gameplay claims.

### Accepted source checkpoint and unresolved visual gate

- Compound source parity: `donor-compound-02` versus `clean-compound-02`,
  seed 208159 / scale 1.25. All five stage objects match exactly: 4,951
  building parts, 386 furnishings, including 10 beds, 23 other interior
  furniture pieces, and 51 protected access reservations. Independent critic
  accepted this and the urban source-parity result.
- `donor-capture-01` stopped at the later route-admission gate (overlapping
  roadbed collision records and an unresolved declared handoff). The donor
  was not edited. Its failure remains in stderr and watchdog evidence.
- After retiring only that route-admission prerequisite, `clean-capture-01`
  stopped at the independent physical-integrity gate: 208 structural
  support-chain failures and 151 attachment-anchor failures, 359 total.
  Details: `artifacts/citadel-visual-reset/physical-publication-blocker.json`.
- Both headed failures were stopped through their run-local stop markers.
  Both watchdog reports prove zero remaining owned processes, with no
  unresolved cleanup or cleanup errors. Final global Godot process count: 0.
- **No screenshots were obtained.** There is no rendered, player-collision,
  traversal, normal-world or NPC acceptance claim. The aggregate physical
  errors do not distinguish bad declarations from restrictive inference or
  unsupported geometry; live colliders had not been published.
- The critic accepted a source-preservation checkpoint, not visual acceptance.
  Further work needs a product decision: reconcile physical support/anchor
  contracts without changing the approved appearance, or explicitly retire
  that later admission policy. Do not bypass it silently or mark failures PASS.

### Stop control

The wrapper supplies a fresh `stop-request.txt` path inside each run directory.
Creating that marker requests termination of that watchdog's own Job Object;
it never selects processes by executable name or guessed PID ownership.
Checks occur during the bounded wait, after root exit, and after cleanup grace.
Normal completion, requested stop of a waiting root, and stop-during-exit were
tested in `stop-normal-01`, `stop-wait-01`, and `stop-exit-race-01`.
Both cancellation tests observed the marker before root exit; post-exit-check
coverage is static review only. Intentional cancellation returns nonzero.

Fresh import also changed line endings in 213 existing asset/icon import
descriptors. Those line-ending-only changes were restored; the five newly
generated script UID files were retained. No asset content was replaced.
