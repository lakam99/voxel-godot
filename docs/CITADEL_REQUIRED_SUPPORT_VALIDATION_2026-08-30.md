# Required physical-support failure propagation

## Outcome and scope

The shared blueprint validator now rejects dependents of invalid **required**
supports, seats and anchors. It retains existing local geometry/root/assembly
checks and runs after the gable validation pass. This fixes the fifteen valid
terminal-frame post-construction counterexamples without changing geometry,
furniture, collision, navigation or the citadel's existing 253-failure baseline.
The terminal frame remains an unwired prototype; its observed 237 failures
are not an accepted integration count. No headed test or commit was performed.

Worktree: `voxel-biome-world-godot-citadel-visuals`.
Branch: `codex/citadel-visuals-clean`, HEAD
`fcda6762c1923015e27cf622a63e87f6209118c0`, existing dirty work preserved.
Main changes are a composed `MandatoryPhysicalDependencyValidator` and its
preload/call in `BuildingBlueprint.validate_physical_integrity`.

## Contract

Only these authored arrays create mandatory edges:

- `physicalRequiredSupportPartIds`
- `physicalRequiredSeatPartIds`
- `physicalRequiredAnchorPartIds`

Writer inventory found mandatory-AND semantics in the castle, landmark,
cottage, standard-roof, gable-purlin, urban and terminal builders. Inferred
supports/anchors and allowed alternatives are deliberately not mandatory edges.
Missing or ambiguous targets fail consumers. Malformed declarations fail the
owner in the helper. A cursor-based queue visits each failed target and each
required edge once. Existing check order, local facts and reasons are preserved;
only newly invalid dependents receive a false result and one deterministic
dependency-failure reason. The pass does not mutate source parts or recipes.

This is failure propagation, not a new grounding authority. An all-passing
cycle is not disproven by this pass; existing grounding/assembly checks remain
responsible. Malformed-array coverage is **direct synthetic helper coverage**:
earlier whole-validator casts remain outside this chunk's robustness claim.

## Commands and evidence

All run directories below are under `artifacts/citadel-visual-reset/` and contain
`report.json`, `stdout.log`, `stderr.log` and `watchdog.json`. The watchdog records
the complete command, timing and process cleanup. Each launch uses a fresh
directory, isolated APPDATA/LOCALAPPDATA and a run-owned `stop-request.txt` path.
No separate progress files or screenshots are produced by these script fixtures.

Launcher: `tools/run-godot-scene-watchdog.ps1`, with project path set to this
worktree, the bundled Godot 4.6.1 console executable, `-Headless`,
`-Scene '--script'`, the script below as `-SceneArguments`, and
`-TimeoutSeconds 100`. Each report environment variable names its run's fresh
absolute `report.json` path.

| Run | Script under `res://scripts/testing/buildings/` | Report variable | Result |
| --- | --- | --- | --- |
| `dependency-standard-roof-before-01` / `dependency-standard-roof-after-01` | `ExistingRoofFrameContract.gd` | `VOXEL_EXISTING_ROOF_REPORT` | 18 cases PASS before and after; exit 0 |
| `dependency-cottage-before-01` / `dependency-cottage-after-01` | `CottageConstructionContractRunner.gd` | `VOXEL_COTTAGE_CONSTRUCTION_CONTRACT_REPORT` | Existing RED unchanged; exit 1 |
| `dependency-terminal-after-01` | `CitadelTerminalFrameContract.gd` | `VOXEL_TERMINAL_FRAME_REPORT` | All 15 valid old counterexamples now PASS; original three precondition-invalid cases remain false; exit 1 |
| `dependency-roof-parity-after-01` | `CitadelRoofIntegrationContract.gd` | `VOXEL_ROOF_INTEGRATION_REPORT` | All 26 exact-parity checks PASS; 55.980 s reported work; exit 0 |
| `dependency-helper-contract-01` | `MandatoryPhysicalDependencyContract.gd` | `VOXEL_MANDATORY_DEPENDENCY_REPORT` | 170 direct synthetic cases PASS; 87 ms reported work; exit 0 |
| `dependency-terminal-corrected-01` | `CitadelTerminalFrameContract.gd` | `VOXEL_TERMINAL_FRAME_REPORT` | Entire contract PASS, including 18 valid mandatory-upstream cases; 39.142 s reported work; exit 0 |

Citadel seed `208159`, scale `1.25`. Frozen parity source:
`roof-prototype-freeze-01/prototype.bin`, SHA-256
`7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5`.
`VOXEL_ROOF_INTEGRATION_BASELINE` names this absolute binary path. Whole source,
resolved source, physical validation, furniture and reservation snapshots match
exactly; reservation arrays are empty and do not prove occupied clearance.

The unchanged cottage baseline uses seed `207154`, timber and masonry styles.
Its 42 failed assertions all concern missing mortar beds. Both styles also have
three physical failures: entry threshold coverage, entry paving support and
entry ramp coverage. Before/after physical-integrity report objects and failure
strings match exactly. Each run has the same 32 detached-node transform errors
from the publication benchmark, which creates its fixture outside the scene
tree. These are recorded baseline failures, not whole-cottage acceptance and not
evidence of live navigation behavior. No door, publisher or harness repair was
made to suppress them.

## Corrected synthetic base-mount cases

The original three base cases did not retain incidental rooting after their
mandatory seat was broken. Original results remain in
`terminal-frame-contract-03` and `dependency-terminal-after-01`.
The new `failed_mandatory_seat_with_alternate` cases add an explicit, finite,
colliding foundation from blueprint y=0 to the base's underside **before**
positive validation. No forced root or cached support flag is supplied.

Each corrected case proves normal resolution selects that foundation for the
base, that the dependent mount neither directly contacts it within the existing
contact margin nor lists it as a support, and that all relevant original checks
pass before mutation. Changing only the required header-seat reference then
fails both the base and dependent mount while incidental rooting remains true.
All three corrected cases pass. This is test-only geometry, not a production
layout change, an invisible runtime support, or gameplay evidence.

The terminal contract also retains all 21 construction checks, 216 invalid-input
and retry controls, 45 original support controls and 18 base/top mount controls.

## Review and remaining work

Cicero independently accepted the bounded mandatory-dependency validator
change after inspecting the final evidence. Acceptance is validation-time
failure propagation only, not a headed or integration grant. All eight run records prove authoritative
owned-process zero with no cleanup errors. Global Godot zero was also checked.
Protected NPC/navigation paths remain identical to baseline
`90e89cf433edacbeed26c40916719e7a7d4b55e3`.

This does not approve terminal integration, strict published-contact acceptance,
headed visuals, live destruction behavior, normal-world loading or the full
physical gate. The overlapping market-stall relocation and exterior facade
posts/footings still await user choices. No production layout has been moved.
