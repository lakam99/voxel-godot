# Stored firewood intent correction

## Result and scope

Independent critic: **PASS for this bounded classification correction; REJECT
for the full physical gate (298 failures remain).** Known seed 208159, scale
1.25: 315 -> 298, exactly 17 removed, none added. This is not support repair.

On `codex/citadel-visuals-clean`, checkpoint
`fcda6762c1923015e27cf622a63e87f6209118c0`, the two stored-firewood recipes in
`CitadelUrbanPocComposer.gd` now explicitly declare `physicalIntent: visual_detail`.
The rule applies to all 112 household/civic logs, not selected failing IDs.
Their `beam` kind selects the timber renderer; loose fuel is not facade joinery.
No positions, dimensions, rotations, materials, collision flags, furniture
rules, or random-number consumption changed. The validator was not relaxed.
The unrelated cottage recipe was not edited.

Full record signatures intentionally change because physical intent is part of
the record. Geometry equality must not be described as full snapshot parity.
The temporary, user-authorized publication bypass remains active.

## Evidence

Source/service contract: `scripts/testing/buildings/CitadelStoredFirewoodContract.gd`.
It builds the actual compound and urban composer, then reconstructs only the
former firewood intent for its control. This is not a historical executable.

Final run: `artifacts/citadel-visual-reset/stored-firewood-contract-02/`:

- `report.json`: all 11 checks pass; validation and observations took 48.928 s.
- `stdout.log`: phase evidence; there is no separate progress file.
- `stderr.log`: empty.
- `watchdog.json`: exit 0, no timeout, `authoritativeZeroProven=true`,
  `cleanupUnresolved=false`, no cleanup errors; final global Godot count 0.

Run01 also passed. Run02 extends placement observations only; production source
was unchanged. No new headed run was launched. The critic explicitly accepted
actual primitive equivalence as proportionate evidence for this intent-only
batch, without granting another headed launch.

Engine command recorded by the watchdog (launched under its owned Job Object,
100-second timeout, isolated run-local APPDATA and LOCALAPPDATA):

```powershell
& 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --headless --path 'C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot-citadel-visuals' --script res://scripts/testing/buildings/CitadelStoredFirewoodContract.gd
```

Set `VOXEL_STORED_FIREWOOD_REPORT` to the fresh run's absolute `report.json`
path and use `tools/run-godot-scene-watchdog.ps1`, not an uncontained launch.
Pass the fresh run-local stdout, stderr, summary and stop-request paths.

Verified facts:

- Every nonfuel physical-check record is identical before and after.
- Removing all logs entirely leaves every nonfuel check identical too: logs
  do not secretly support structures or anchor attached parts.
- Actual production-publisher mesh/material resources, transforms, child count
  and shadow settings match for every log's old/new input.
- Geometry/collision fields, rooms, furniture snapshots and protected access
  reservations match.
- Unsupported structural beam, unsupported wall, unanchored noncolliding brace
  and collision-enabled visual-detail negative controls all still reject.

Reviewed SHA256:

- Composer: `43AECBC8B24D9185320C4D97155C697BBA942E04FE9565B0DF6BC38EBE4CC4E3`
- Contract: `9C195BE0889A01E52AE40C232483F4710AC143EF1427524159AA1ABC1FCFB831`

## Placement remains unresolved

The report preserves center-sampled nearest-lower surfaces and overlapping
volumes independently of classification. These skip pitched/rolled candidates,
omit overlaps no deeper than 0.05 m, and do not cover the full footprint.
A lower-surface gap is not proof of floating: other volumes can cover/embed a
log. Conversely, an overlap is not proof of sound placement. For example,
`urban_row_03_left_firewood_00` reports an overlapping log, not proof of paving
embedding. Do not snap piles from these observations.

Require full-footprint support and penetration evidence before changing stored
prop placement. This batch does not establish grounding, live movement,
rendered-image acceptance, NPC behavior, normal-world performance, or the full
physical gate. The last headed visual evidence remains the separately reviewed
street-brace capture. No visible facade posts or new collision were introduced;
that proposed design change still awaits user agreement.
