# Street-brace mounting correction

Active objective: zero genuine physical-gate failures while preserving Citadel
visuals and furniture. This is partial progress: **317 to 315**, no added
violations. Branch `codex/citadel-visuals-clean`, HEAD `fcda676`, with prior
uncommitted repairs preserved. No commit or protected navigation edit.

## Change and evidence

Only the `add_street_house` street-brace X expression changes from
`facade_x + street_side * 0.07` to `upper_facade_x + street_side * 0.07`.
All 32 noncolliding braces move inward 0.14. Rotation about X leaves their
X thickness unchanged: the upper-wall gap 0.12 becomes embedment 0.02.
Dimensions, rotations, collision flags, other parts, rooms and furniture remain
unchanged. The lower sections still project beyond the inset stone base;
this does not establish two-ended structural bracing or bottom bearing.

Source evidence under `artifacts/citadel-visual-reset/`:

- `street-brace-diagnostic-01`: actual whole blueprint, 315 failures =
  208 structural-mass plus 107 attachment. Exit 1 retains the failed full gate.
- `street-brace-contract-01`: all 13 checks pass, exit 0, duration 32.362 s.
  Seed 208159, scale 1.25. Current actual source is compared with a reconstruction
  of only the previous brace X expressions, not a historical executable.
  Zero-margin own-façade contacts increase 0 to 32; rooted anchors 19 to 21.
  Full unrelated source, recipe, rooms, furniture and reservation comparisons
  pass. Synthetic moved/removed/ungrounded/cyclic anchor controls reject.

Exactly two violations were removed:

- `urban_row_01_left_street_brace_1`
- `urban_civic_house_wall_street_brace_1`

Eleven braces remain unrooted, even though they contact actual panels. No
anchor IDs, thresholds, physical classifications or validator rules changed.
This is contact improvement, not full structural acceptance.

Both directories contain `report.json`, `stdout.log`, empty `stderr.log`, and
`watchdog.json`. Both watchdogs prove zero remaining owned processes, no
unresolved cleanup or cleanup errors. No independent progress file is emitted;
stdout records diagnostic phases. No fresh-seed success is claimed.

Invocation from the clean worktree, with fresh run directory and isolated
APPDATA/LOCALAPPDATA:

```powershell
# VOXEL_STREET_BRACE_REPORT=<run>/report.json
./tools/run-godot-scene-watchdog.ps1 -ProjectPath <clean-worktree> -GodotExe 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelStreetBraceContract.gd') -Headless -TimeoutSeconds 100 -StdoutPath <run>/stdout.log -StderrPath <run>/stderr.log -SummaryPath <run>/watchdog.json -StopRequestPath <run>/stop-request.txt
```

Diagnostic uses the same watchdog and timeout with
`res://scripts/testing/buildings/CitadelPhysicalGateDiagnostic.gd` and
`VOXEL_PHYSICAL_DIAGNOSTIC_REPORT=<run>/report.json`. Exact commands and UTC
times are in the watchdog reports.

Composer SHA256:
`A43C7B8C079827613C9C58E96DB5AAFC2A6788A2DC10194851EB3E85672E7013`.
Contract SHA256:
`240C69F15AA43D3C424E19EBC3442EFE32EBE2D4E9AE3A20468291D3506AE771`.

## Review status

After reviewing the passing contract, the critic authorized exactly one headed
capture through the unchanged wrapper:

```powershell
./tools/run-citadel-visual-preservation.ps1 -Mode Capture -OutputDirectory "$PWD/artifacts/citadel-visual-reset/street-brace-capture-01"
```

Seed 208159, scale 1.25, Godot 4.6.1 Forward+, 1280x720. Completed in 50.2 s,
all 4045 parts published, 20 doors registered, readiness true, loading hidden.
Exit 1 preserves the known overall visual rejection, not a crash. Stderr is
empty; watchdog proves owned zero, no unresolved cleanup or cleanup errors;
global Godot count is zero. No retry was launched.

Main inspected all nine images and compared `inner_lane`, `market_ground` and
`civic_overview` to `facade-mount-capture-01`. Braces move closer to their upper
wall while massing, roofscape, shop goods and landscaping remain present.
This is qualitative visual evidence, not pixel parity or complete inspection
of all 32 braces. Lower-brace separation and other market-attachment issues
remain visible. The full report still rejects 315 physical facts, misses the
green-market image, retains the occluded perimeter image and rejects window
`urban_row_03_left_window_02_-1` for interior coverage. No night/interior or
normal-world gameplay acceptance is claimed.

Evidence: `street-brace-capture-01/report.json`, stdout/stderr/watchdog, and
nine screenshots. The fixture emits no independent progress file. Report SHA256:
`07161B5E3F2BEC7C99D7841F8A466E3D56BD8FBA484303EE0939DEB148C8D11A`.
Independent critic final verdict: **PASS for the bounded street-brace mounting
repair on seed 208159; full gate REJECT**. The critic compared all three
requested before/after views, confirmed unchanged visual character/furniture
layout within those views, source-contract scope, publication and cleanup.
All capture grants are consumed. Publication bypass remains active; the full
gate is false and the zero-failure goal remains unfinished.

The larger upper-façade repair remains a separate visual decision. See
`CITADEL_UPPER_FACADE_BEARING_STUDY_2026-08-30.md`: low interior beams fail
standing clearance, and visible exterior supports require user agreement.
No posts, footings, sills, furniture movement or new collision were added here.
