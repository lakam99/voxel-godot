# Existing sign socket domain: source-level exclusion

Branch `codex/citadel-visuals-clean`; production source at `a560d2a`.
World `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`, scale `1.25`.

The actual completed source build still fails structural completion. Its east
civic sign intersects a terrace. A wider search within the existing mounting
domain cannot fix this specific failure: at the declared facade plane, the rigid
board intersects that terrace throughout the entire allowed radius-1.25 domain.

The nearest board-only exit face is 1.68000031 metres away. This is a lower bound
on escaping one obstruction, **not a valid proposed placement**. The arm, actual
finite socket, rooted anchor and other protected volumes remain requirements.
The 29 final rejected candidates are covered: 22 have nearest socket distances
outside the cap; seven are excluded by the continuous board/terrace interval
certificate. No production geometry or search bound has changed.

## Replay and evidence

From the project root, choose a fresh output directory:

```powershell
./tools/run-citadel-sign-socket-bounds-contract.ps1 -OutputDirectory artifacts/sign-socket-investigation/contract-03
```

This diagnostic requires the existing ignored evidence inputs:

- `artifacts/citadel-runtime-integration/actual-site-shop-02/result.bin`
- `artifacts/citadel-runtime-integration/actual-site-source-03/report.json`
- `artifacts/citadel-runtime-integration/actual-site-source-03/launch.json`

The contract binds these inputs by SHA-256 and compares the current geometry
authorities with the completed failure run. It reads a post-shop source snapshot;
the completed failure report supplies the final rejected-anchor inventory. The
opening-head fitting service is used only to check the facade-plane invariant,
not to invent a post-completion rooted head or certify a repair.

`contract-03/report.json`: 16/16 source/service checks; watchdog functional exit 0,
empty stderr, cleanup passed and authoritative zero owned processes. Earlier
`contract-02` has the same passing checks. Negative controls reject reachable
exit faces, boundary contact, separated X intervals and invalid bounds.

The independent critic approved the contract as **source-only infeasibility
evidence**. It does not approve removing the sign, enlarging the mounting bound,
skipping invalid sites, or launching headed acceptance. A source recipe placement
decision remains necessary. Normal-game citadel spawning is not complete.

Earlier snapshot-preparation attempts are retained under
`artifacts/sign-socket-investigation/`: one argument-order failure and one
90-second facade-preparation timeout were cleaned up by the process-owning
watchdog. Neither is a successful source build or gameplay test.
