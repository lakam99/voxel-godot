# Corner-frame and lintel mounting repair

## Objective and checkpoint

The active user goal is zero genuine physical-gate failures, preserving the
Citadel appearance and furniture logic. This is a partial repair, not completion.
Worktree `voxel-biome-world-godot-citadel-visuals`, branch
`codex/citadel-visuals-clean`, HEAD `fcda6762c1923015e27cf622a63e87f6209118c0`.
Earlier uncommitted contact, upper-trim and publication-bypass changes were
preserved. Original/donor worktrees and protected NPC/navigation files were not
changed. No commit was made.

## Producer correction

In `CitadelUrbanPocComposer.add_street_house`, corner frames and door lintels
now use the actual `upper_facade_x`, rather than the presentation coordinate
0.14 units outside that wall. Both families move inward by 0.14 only.

For seed 208159 at scale 1.25 this changes 48 noncolliding pieces across
16 houses. Corner-frame upper-wall embedment becomes 0.07; lintel embedment
becomes 0.09. Lintel bottoms remain 0.03 above the authored door opening.
All dimensions, rotations, materials, rooms, doors, collision and furniture
records are unchanged. Corner-frame lower sections still project beyond the
inset stone base: these are attached trim, not newly proven bearing posts.
No support declarations, classifications, thresholds or validator rules changed.

## Measured source evidence

All evidence directories below are under `artifacts/citadel-visual-reset/`.

| Run | Result | Limit |
| --- | --- | --- |
| `facade-mount-diagnostic-01` | Actual builder: 317 violations, 208 structural + 109 attachment; 13 existing contact controls pass | Source geometry, not gameplay |
| `facade-mount-contract-01` | Script parse failure; engine exited in under one second; zero owned processes | No contract evidence; retained failed run |
| `facade-mount-contract-02` | Seed 208159: all 18 checks pass; 328 to 317, no additions | Before state reconstructs only the two previous X expressions, not an independent historical executable |
| `facade-mount-contract-fresh-783601` | Castle layout infeasible; builder returns null before composer invocation | No trim or fresh-seed acceptance |
| `facade-mount-contract-208158` | Same pre-composer construction rejection | No trim or historical-seed acceptance |

Fresh seed 783601 was selected and recorded before execution. It was not replaced
with a successful random seed. 208158 is separately reported additional coverage.
The call order and unchanged castle builder show these two failures do not exercise
the modified coordinates; this is not a historical-baseline execution claim.

The passing contract moves exactly 32 corner frames and 16 lintels. Own-façade
contacts at zero margin increase from 0 to 48; rooted anchor chains from 31 to
42. Ten corner-frame failures and one lintel failure disappear. Six adjusted
pieces remain unrooted and are retained as failures. Full recipe, room,
unrelated-part, previous stud/floor-beam, furniture and reservation comparisons
pass. Independent synthetic valid/moved/removed/ungrounded/cyclic anchor fixtures
exercise the real integrity validator; the invalid fixtures all reject.

Diagnostic duration: 23.838 seconds. Passing A/B contract duration: 41.343 seconds.
These are synchronous offline source diagnostics, not runtime performance claims.
Successful diagnostic/contract stderr is empty. Every run's watchdog records
`authoritativeZeroProven=true`, no unresolved cleanup and no cleanup errors.

Each run has `stdout.log`, `stderr.log`, `watchdog.json` and, except the parse
failure, `report.json`. There is no separate progress file for these scripts;
stdout records phases. The watchdog records exact arguments and UTC times.

Invocation from the clean worktree, with fresh run directory and isolated
APPDATA/LOCALAPPDATA:

```powershell
# Diagnostic: VOXEL_PHYSICAL_DIAGNOSTIC_REPORT=<run>/report.json
./tools/run-godot-scene-watchdog.ps1 -ProjectPath <clean-worktree> -GodotExe <Godot-4.6.1-console> -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelPhysicalGateDiagnostic.gd') -Headless -TimeoutSeconds 100 -StdoutPath <run>/stdout.log -StderrPath <run>/stderr.log -SummaryPath <run>/watchdog.json -StopRequestPath <run>/stop-request.txt
# Contract: VOXEL_FACADE_MOUNT_SEED=208159 (or recorded seed), VOXEL_FACADE_MOUNT_REPORT=<run>/report.json
./tools/run-godot-scene-watchdog.ps1 -ProjectPath <clean-worktree> -GodotExe <Godot-4.6.1-console> -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelFacadeMountContract.gd') -Headless -TimeoutSeconds 100 -StdoutPath <run>/stdout.log -StderrPath <run>/stderr.log -SummaryPath <run>/watchdog.json -StopRequestPath <run>/stop-request.txt
```

Godot executable: `C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe`.

Production composer SHA256:
`688E8D00AF1E9134B78332B2DC9F3264CCE7EFF4E0ADF25BAAC8D621B81BB573`.
Passing contract SHA256:
`B2275B789E7DB544F77C5DDE6E29B7116E0BB62012ED66E8602EC0A9A2550F89`.

## Visual review and remaining work

After source review, the independent critic granted exactly one unchanged
headed capture on seed 208159:

```powershell
./tools/run-citadel-visual-preservation.ps1 -Mode Capture -OutputDirectory "$PWD/artifacts/citadel-visual-reset/facade-mount-capture-01"
```

Godot 4.6.1 Forward+, 1280x720, scale 1.25. The run completed in 53 seconds,
published all 4045 building parts and registered 20 doors. Readiness is true
and the loading overlay is hidden. Exit 1 correctly records the known overall
visual rejection, not a crash. The report retains all 317 physical violations.
Stderr is empty, owned-process cleanup is proven, and the global Godot count is
zero. No retry was launched.

The main agent inspected all nine saved images. `inner_lane` and
`market_ground` were compared directly with `upper-trim-capture-01`: corner
trim sits closer to the wall, while building masses, roofs, windows, shop goods,
trees and paving remain present. This is qualitative preservation evidence,
not pixel parity or inspection of every changed member. The lower-frame
projection remains visible; no claim of full-length or ground bearing is made.

Known limitations remain: no `green_market_square` image after camera-support
rejections; `perimeter_lane` is fully occluded despite its green camera check;
`urban_row_03_left_window_02_-1` fails the interior-window audit. Separate
market awnings/brackets still look disjoint. No night or interior walkthrough
was run. These defects were not hidden or repaired incidentally.

Evidence: `facade-mount-capture-01/report.json`, `stdout.log`, empty
`stderr.log`, `watchdog.json`, and nine `screenshots/*.png`. No independent
progress file is emitted by this fixture.

Independent critic final verdict: **PASS for the bounded corner-frame/lintel
mounting repair on seed 208159; full gate REJECT**. The critic independently
compared `inner_lane`, `market_ground` and `civic_overview`, confirmed unchanged
producer hash and complete publication/cleanup, and found no evident building
silhouette regression. No further launch was authorized. Headed report SHA256:
`4343ADC93A35EA4E039FF275FBD1FC29B5199524057477AD2252D36AC38EBFF2`.

The full physical gate remains false; the user-authorized publication bypass
remains enabled. Zero failures must be genuinely validated, not inferred from
rendering. The 163 upper-façade failures are the largest remaining family;
see `CITADEL_REMAINING_PHYSICAL_GATE_2026-08-30.md` for the complete original
inventory and real bearing-geometry requirements. Broader gameplay, normal-world
NPC, runtime performance, day/night and interior usability acceptance are not
established by these source contracts.
