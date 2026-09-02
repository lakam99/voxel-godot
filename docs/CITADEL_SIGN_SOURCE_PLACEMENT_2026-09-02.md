# Household sign source placement

## Scope

Source recipe construction only, on `codex/citadel-visuals-clean` after
`316768d`. Preserve the citadel's architecture, furniture, shared trees and
rigid sign design. No NPC/navigation, ordinary-town or tutorial changes.
This is not evidence of ordinary-game spawning or visual acceptance.

The actual `atlas-1492` landmark candidate in region `(1,-3)` uses recipe seed
`1298433643`, plains context and scale `1.25`. After retained paving was fixed,
its full source build still rejected `urban_civic_house_east_sign_arm`.
The previous capped mounting domain was analytically obstructed; see
`CITADEL_SIGN_SOCKET_BOUNDS_2026-09-02.md`. Merely increasing the old planner's
cap or rebasing its template and retrying was not the adopted policy.

## Reviewed construction policy

Every declared sign is checked, including signs that pass generic physical
attachment validation. Preserve an existing sign exactly only when its finite
socket is rooted in its own household and its complete assembly is clear.
Otherwise first try the unchanged capped planner on the original template,
then a bounded deterministic search of the actual declared household facade.
Commit one proven arm/board pose and required socket. No new collision mass,
authored coordinates, seed exception or foreign-house attachment is introduced.

The whole sign must stay within frontage width, above the greater of facade
bottom and door bottom, and below facade top. Actual facade openings, ordinary
door sweeps, furniture/access reservations and other source geometry remain
protected. Search limits are explicit failures, not permission to omit a sign.
Malformed and nonfinite door swing inputs fail closed.

Rigid construction uses exactly the existing mount recipe's arithmetic:
`newBoard = newArm + (oldBoard - oldArm)`. Requiring inverse subtraction to
recover identical float32 offset bits was an invalid prototype constraint;
removing it does not relax constructed geometry, socket or clearance checks.

After all later structural stages, the existing final physical proof is reused
to check every sign again. A proposed further relocation is a final-state
failure, not verification. No extra whole-blueprint validation is hidden here.

## Reference preservation is explicit, not claimed whole-output parity

The frozen reviewed reference (seed `237207443`) has 14 signs. Thirteen are
already valid; one old sign intersects a foreign terrace while generic physical
attachment still reports success. The critic approved repairing that sign
through the same source rule. The historical failed exact comparison remains
under `artifacts/sign-initial-placement/contract-06/`; subsequent reports retain
`whole_reference_signs_exact = false` rather than presenting the change as parity.

The fresh full-source comparison now passes 51/51 checks in
`artifacts/citadel-runtime-integration/sign-reference-preservation-02/`.
All 4,621 non-sign part records and the 26 parts of thirteen valid signs are
byte-exact even before derived-cache cleanup. Furniture/access reservations,
interior program, rooms, complete blueprint recipe and ordered part inventory
remain exact. Only the civic east arm and board change authoritative records.

The repaired reference arm moves from approximately `(36.76,3.32,5.943029)` to
`(37.27,5.121,5.92)` and the board from `(36.74,2.9,6.363029)` to
`(37.25,4.701,6.34)`, attached to its existing `upper_facade_012` panel.
These coordinates are measured evidence, never production constants. Exact
typed bytes and values are retained in `differences.json` and the full handoff.

All 39 full-handoff difference rows and 16 authoritative-part rows were
enumerated without truncation. Beyond the pair's pose/socket records, actual
differences are sign-stage accounting and four aggregate threshold proof
fields (source byte count, source hash and two validation-event hashes).
No unrelated diagnostic subtree or arbitrary hash waiver was used.
`full_handoff_byte_exact=false` remains explicit. The run took 277.372 seconds
(273.874 seconds preparing source), with stable dependency/reference hashes,
empty stderr, natural exit 0 and owned process zero.

Reference attempt 01 failed immediately on a test-script type inference error;
it exited naturally with code 1 and owned process zero. Attempt 02 fixes only
that explicit variable type and uses fresh paths. Both artifacts are retained.

## Source evidence and remaining acceptance limits

- `artifacts/sign-initial-placement/contract-11/`: 17/17 direct proposal checks,
  including deterministic result, immutable inputs, actual finite socket and
  clearance, malformed door rejection, thirteen unchanged reference signs and
  one explicit reference repair. Empty stderr, natural exit 0, owned process zero.
- `artifacts/citadel-runtime-integration/final-structural-source-01/`: 6/6 checks
  against the exact cached post-facade source; all later structural stages and
  final sign verification succeed with zero physical failures. 80.906 seconds,
  immutable source/policy/input and stable dependencies, empty stderr, natural
  exit 0, owned process zero. This does not rerun facade construction.
- `artifacts/citadel-runtime-integration/actual-site-source-05/`: fresh full
  `CitadelSitePreparation.prepare` now returns `prepared`, with 4,703 building
  parts and 210 furnishings. 367.589 seconds, stable source hashes, empty stderr,
  natural exit 0 and owned process zero. Includes actual recipe, manifest and
  terrain profile preparation; no live terrain/structure publication. The profile
  has 81 apron cells, level 37.8 and source signature
  `f958f320411e9d2069549671488a82b9204f25e49ed48b0104d228cdc5bada47`.
  This cold cost is not acceptable evidence for gameplay-frame or streaming
  latency. The preceding failed full builds remain recorded, not relabeled.

The first combined orchestration negative-control run,
`sign-completion-contract-01`, exceeded its 60-second cap with no terminal
report. It is failed evidence. The watchdog terminated its owned process group
and proved zero remaining members; `cleanupPassed=false` is retained. Its
original script is archived there. Four independently bounded phases replace
that redundant combined execution, each with a 45-second cap, not a longer wait.

All four phases passed with empty stderr, natural exit 0 and owned process zero:

| Artifact directory (under `artifacts/citadel-runtime-integration/`) | Checks | Seconds | Evidence |
| --- | ---: | ---: | --- |
| `sign-final-old-01` | 4 | 12.353 | Old generic physical pass is rejected by final sign guard; no relocation committed. |
| `sign-final-new-01` | 5 | 13.818 | Completed source passes unchanged; added protected obstruction is rejected. |
| `sign-initial-stage-01` | 2 | 9.795 | All 14 signs checked; exactly 13 preserved and one repaired. |
| `sign-blocked-stage-01` | 3 | 12.583 | Blocking every sign returns explicit unresolved failure without mutation. |

Reproduction uses `tools/run-citadel-sign-completion-contract.ps1` with
`-Phase final_old`, `final_new`, `initial`, or `blocked`, and a fresh
`-OutputDirectory` for each phase. All four are required. Snapshot paths are
explicit optional parameters and hash-bound for the run. The proposal wrapper
also passed 17/17 in `sign-placement-wrapper-01`.

Reproduce the proposal contract with a fresh directory:

```powershell
./tools/run-household-sign-placement-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/sign-placement-FRESH
```

It requires the hash-bound frozen source/reference artifacts named by the
wrapper; optional explicit snapshot paths are supported. This is service-level
evidence only; full source was checked separately above. Rendered clearance,
normal-world lifecycle, player traversal and performance remain open. No headed launch
has been approved for this chunk.

The independent read-only critic approved the focused source commit after
reviewing code, wrappers, negative controls, the actual candidate, full reference
differences and process cleanup. This approval does not cover headed readiness,
live spawning, runtime performance or goal completion.
