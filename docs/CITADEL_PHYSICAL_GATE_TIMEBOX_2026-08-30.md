# Citadel physical gate: bounded repair attempt

User timebox: 2026-08-30 13:10:47 through 13:25:47 America/Toronto.
Starting branch `codex/citadel-visuals-clean`, HEAD `fcda676`, clean worktree.
Original and donor worktrees were not edited. No headed tests were launched.

## Outcome

The full physical publication gate remains **REJECTED**. No threshold, physical
intent classification, support requirement, collision flag, or publication
admission rule was relaxed. This is a partial contact-inference repair, not
visual/gameplay acceptance. The patch remains uncommitted for review.

Seed `208159`, scale `1.25`, actual castle builder followed by urban composer:

| Check | Baseline | Contact repair |
| --- | ---: | ---: |
| Structural support failures | 208 | 208 |
| Attachment anchor failures | 151 | 140 |
| Total violations | 359 | 348 |

There were eleven removed violations and no added violations in runs 02/03.
Shape digests (IDs, kinds, materials, transforms, dimensions, collision flags,
semantics) and full furnishing snapshots matched the baseline exactly. This
does not prove rendered appearance; it excludes inference bookkeeping and does
not hash all building material-recipe fields. The production diff changes only
BuildingBlueprint contact inference, not composer/material/furniture sources.

## Narrow repair

- Replace incomplete corner-containment overlap with all fifteen separating
  axes for oriented boxes. Preserve the existing margin by expanding either
  box locally, never both simultaneously.
- Query the entire attachment extent, not just its center, so long pieces can
  discover endpoint anchors. Spatial insertion now includes all eight corners.
- Use sqrt(3) times the margin only for conservative world-axis candidate
  lookup; exact contact testing retains the original margin.
- Critic requested explicit rejection of nonfinite transforms/dimensions and
  invalid sizes/margins. Guards and negative controls were added for run 04.

## Evidence and reproduction

Evidence root: `artifacts/citadel-visual-reset/` (local, ignored by Git).
Each run directory contains `stdout.log`, `stderr.log`, `watchdog.json`, and,
when completed, `report.json`. The watchdog records the exact engine command
and owned-process cleanup proof. Diagnostic progress is recorded in stdout.

All runs used `tools/run-godot-scene-watchdog.ps1` with:

```powershell
-ProjectPath <clean-worktree>
-GodotExe 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe'
-Scene '--script'
-SceneArguments @('res://scripts/testing/buildings/CitadelPhysicalGateDiagnostic.gd')
-Headless
-StdoutPath <fresh-run>/stdout.log -StderrPath <fresh-run>/stderr.log
-SummaryPath <fresh-run>/watchdog.json -StopRequestPath <fresh-run>/stop-request.txt
```

`APPDATA` and `LOCALAPPDATA` were isolated beneath each fresh run directory.
`VOXEL_PHYSICAL_DIAGNOSTIC_REPORT` pointed at that run's report.json.
Timeout was 90 seconds for baseline/01/02/03 and 60 seconds for final run 04.

- `physical-timebox-baseline`: unchanged production baseline; 359 failures.
- `physical-timebox-contact-fix`: parse error in new local variable typing;
  stopped immediately upon inspection through owned stop marker. Not evidence
  of product correctness. Cleanup proved no owned processes remained.
- `physical-timebox-contact-fix-02`: 348 failures; seven synthetic contact
  controls pass; shape and furnishing parity pass.
- `physical-timebox-contact-fix-03`: broad-phase margin correction and selected
  real-part contact diagnostics; same 348 failures and parity results.
- `physical-timebox-contact-fix-04`: final finite-input safeguards and expanded
  negative controls; 348 failures remain, all 13 synthetic controls pass,
  shape/furnishing digests match baseline, empty stderr, 24.117 seconds of
  measured diagnostic work. Functional exit 1 correctly reports gate failure.
  Watchdog proves zero owned processes, no cleanup errors; global Godot count 0.

Final tested source SHA256:

- `BuildingBlueprint.gd`: `D84E99BD9E134009B9CEE88D3D3AAA91498DAA0D744B6B548815761FE3180790`
- `CitadelPhysicalGateDiagnostic.gd`: `92DF819CD6649DC02355AA2AFAA2C4FB64FDE5DC69741BF2DF5D6711BFAD4C3B`

Protected NPC/navigation files still match `90e89cf433edacbeed26c40916719e7a7d4b55e3`
by source diff. No runtime NPC regression claim is made.

Independent critic final verdict: **bounded partial-fix evidence PASS; full
physical gate REJECT**. Independently verified final counts, all 13 controls,
both matching digests, expected exit 1, empty stderr, no timeout/forced cleanup,
and zero owned/global Godot processes. Report SHA256:
`51706C36C0041AA7EA7A59399682477DBA7B5A37738C8C24111ED2B4816C8637`.
The critic did not independently establish every remaining assembly-cause
assertion below. No further implementation or headed launch is authorized by
this partial verdict. Work stopped within the user's 15-minute limit.

The runner exits nonzero while the real gate is false. Its synthetic contact
checks are reported separately and cannot overrule the real gate. No meshes,
live collision, actors, movement, doors, or navigation are instantiated.

## Remaining cause and boundary

The shared house recipe widens the upper storey by 0.62 and shifts it by 0.31.
Its upper facade inner face is 0.32 beyond the lower stone facade outer face.
Independent collision-enabled facade panels have no declared lateral assembly
load path. Bottom sampling cannot prove bearing on the inset lower wall.

Run 03 confirms some rejected panels contact rooted side shells, and both roof
halves in the representative house contact rooted members despite their sampled
support graph resolving only to each other. Contact alone is not an approved
load-bearing assembly. Other brackets/studs have no structural contact within
the existing tolerance. These facts must not be flattened into "all geometry
is broken" or "just attach everything to its nearest wall."

Next bounded work, if requested: establish explicit, geometrically certified
load paths for one shared overhanging facade/roof assembly. Preserve geometry
and furniture, keep absent contacts rejected, then measure remaining failures.
Do not increase tolerances, exempt parts, label them grounded, resume the old
navigation campaign, or launch a headed test to hide this gate.
