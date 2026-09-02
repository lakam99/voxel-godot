# Retained paving support: standalone source recipe

The subsequent composer hookup is recorded separately in
[the composition evidence](CITADEL_RETAINED_PAVING_COMPOSITION_2026-09-02.md).

Branch `codex/citadel-visuals-clean`, starting production source `a560d2a`.
This is a source-preparation helper and contract, **not composer wiring or live
citadel acceptance**. The independent critic approved standalone promotion only.

## Root cause and repair domain

Actual candidate `atlas-1492`, region `(1,-3)`, recipe `1298433643`, scale `1.25`:
urban composition removes courtyard buildings and their egress foundations but
keeps paving pieces `02`, `04` and `80` which depended on those real foundations.
Their ordinary structural proof passes before pruning and fails afterward.

`RetainedSurfaceBearingRecipe.prepare` privately stages a subset of retired real
foundation volume below retained surfaces. It does not extrude an arbitrary
footprint from zero, retain obsolete tall courtyard walls, alter surviving
geometry/furniture, waive a physical check, or introduce a seed-specific repair.

- Candidate bounds come from actual retired grounded parts and the retained
  paving underside. Candidate shape admission is bounded; every emitted box is
  proved inside the actual retired oriented solid using all eight vertices.
- Strict final containment uses no expanded source or target bounds. New stone
  has a tiny inward horizontal margin to avoid float-roundtrip expansion.
  Unrepresentable fragments fail rather than growing to the part constructor's
  minimum size. Protected volumes must remain strictly empty.
- Existing supports only remove work when they reach the required height.
  Canonical allocations prevent duplicate work for overlapping retained targets;
  every selected target still must pass the final ordinary physical proof.
- Inputs are unchanged on success or failure. Duplicate IDs, invalid volumes,
  unsupported shapes and excessive fragment/grid work reject atomically. No
  partial snapshot is returned. Before/after validation uses the existing grid
  work guard, including newly constructed geometry in the final proof.
- All previously passing parts and every emitted part must pass the final proof.
  Only original source records plus new geometry are returned; transient proof
  annotations do not rewrite surviving records. Already valid sources are exact
  no-ops. This synchronous source compiler is **not** a gameplay-frame budget API.

## Evidence

Committed synthetic source contract:

```powershell
./tools/run-retained-surface-bearing-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/retained-bearing-contract-02
```

Use fresh output directories. This runner records `report.json`, `stdout.log`,
`stderr.log`, `watchdog.json`, and accepts a `stop-request.txt` through the owned
watchdog. Expected: 21/21 synthetic checks, including shared/reversed targets,
rotated-root containment, EPS-expansion rejection, full protected voids,
insufficient height, constructor limits, duplicate inputs and unchanged source.

Actual and reference source replay artifacts are under
`artifacts/citadel-runtime-integration/paving-retirement-prototype-03/`:

| Run | Result | Measured source work |
| --- | --- | --- |
| `synthetic-07` | 21/21 synthetic controls | 0.020 s |
| `actual-strict-04` | 8/8, 18 bearings for exactly three failed surfaces | 17.454 s |
| `actual-strict-reverse-01` | 10/10, identical emitted records after reversing source and inputs | 18.241 s |
| `reference-03` | Frozen approved blueprint byte-exact no-op | 8.824 s |

The actual replay uses the post-shop snapshot, 414 furniture/access/room/door
primitive reservations, and the original pre-urban snapshot for retired source
provenance. All surviving records are byte-exact. Checks independently inspect
constructed containment, oriented-solid containment, reservation/duplicate
volume exclusion and ordinary physical proof. Original paving coverage was
19/25, 22/25 and 19/25 samples; these are ordinary structural-mass requirements,
not a claim of complete 25/25 walkable-subfloor coverage.

Reference seed `237207443` uses the SHA-bound source-reference artifact already
documented by the shared-source preparation work. The promoted helper body is
byte-exact to the critic-reviewed prototype except its introductory comment.
The committed synthetic contract runs against the promoted helper.

These passing runs have empty stderr, natural functional exit 0, clean watchdog
cleanup and authoritative zero owned processes. Earlier rejected iterations
remain archived, including permissive containment, minimum-size risks, mixed
door-descriptor input and unsupported zero-rotation-only attempts. They are not
acceptance evidence. No headed test was launched.

## Remaining integration boundary

Composer integration must capture retired provenance during the actual prune,
derive complete current post-shop reservations, stage the helper atomically,
and retain the existing final structural completion gate. Full composed source
and reference parity require separate critic review. The actual candidate's sign
placement still fails; this helper does not solve it. Normal-world activation,
terrain admission, streaming/unload, saves, player traversal and runtime budgets
remain incomplete. Invalid-site skipping has not been authorized or implemented.
