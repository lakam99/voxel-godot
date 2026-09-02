# Shared upper-wall trim: bounded producer repair

Branch: `codex/citadel-visuals-clean`; starting HEAD `fcda676` with the previous
uncommitted contact-inference repair and explicitly authorized gate bypass.
Those existing changes were retained. Original/donor worktrees were untouched.

## Finding and implementation

`add_street_house` uses a presentation coordinate 0.14 units outside the actual
upper wall face. Upper studs and floor beams added more outward offset, leaving
their nearest edges 0.09 and 0.08 units from the wall respectively.

The production change adds the actual upper-wall coordinate and uses it only
for those two noncolliding trim families. Studs and beams shift inward by 0.14,
leaving 0.05/0.06 embedment in the existing wall. Walls, roof geometry, doors,
room bounds, collision records, furniture generation, RNG and navigation code
were not changed. Trim placement intentionally changes; this is not a claim of
identical pixels or identical positions for every visible piece.

This is not a replacement structural solver. No support declarations were
invented, no physical tolerance was increased, and no failures were suppressed.
The user-authorized publication bypass remains in place.

## Source/geometry contract

Seed 208159, scale 1.25. `scripts/testing/buildings/CitadelUpperTrimContract.gd`
builds the actual castle/urban recipe and reconstructs only the previous two
placement expressions in a separate source-level control. This is explicitly
not an independent historical executable or a gameplay fixture. The current
producer diff and prior actual baseline report support that limited comparison.

Evidence directory: `artifacts/citadel-visual-reset/upper-trim-contract-01/`.
Files: `report.json`, `stdout.log`, `stderr.log`, `watchdog.json`.

| Measurement | Previous placement | Repaired placement |
| --- | ---: | ---: |
| Trim pieces contacting their own facade, zero contact margin | 0 | 56 |
| Trim pieces with a rooted anchor chain | 30 | 50 |
| Total physical violations | 348 | 328 |

The 56 moved pieces cover 16 houses. There are no added physical violations.
All eight contract checks pass, including room/furniture/reservation equality,
unchanged non-position fields, noncolliding-only 0.14 moves, exact own-wall
contact, and negative controls for moved, removed and ungrounded anchors.
The representative `urban_row_00_left` gains rooted support for both upper
studs; its floor beam now contacts the facade but remains unrooted. That
failure is retained rather than pretending contact establishes a load path.

Headless invocation uses the owned-process watchdog, 100-second timeout,
isolated APPDATA/LOCALAPPDATA, and `VOXEL_UPPER_TRIM_REPORT=<run>/report.json`:

```powershell
./tools/run-godot-scene-watchdog.ps1 -ProjectPath <this-worktree> -GodotExe 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelUpperTrimContract.gd') -Headless -TimeoutSeconds 100 -StdoutPath <run>/stdout.log -StderrPath <run>/stderr.log -SummaryPath <run>/watchdog.json -StopRequestPath <run>/stop-request.txt
```

Measured diagnostic duration: 31.410 seconds. Exit 0, empty stderr, and zero
remaining owned processes. This proves the limited source/geometry contract,
not full structural, collision-backed movement or NPC acceptance.

## Deliberately not folded into this fix

- Upper-facade overhangs need genuine bearing/assembly evidence; touching a side
  shell is not itself a demonstrated load path.
- Roofs require proven bearing joints or real framing, not bare IDs whose only
  justification is an overlap test.
- Lower-level brackets need tier-aware placement and actual joinery; blindly
  replacing every facade coordinate would move doors and other unrelated parts.
- Market-stall awnings use a separate recipe, not this house mounting coordinate.
- Camera coverage and the window/interior mismatch remain separate failures.

The experiment identifies a reusable repair, but does not establish that one
large patch can satisfy most remaining gates. Further work should stay bounded.

## Critic-approved headed comparison

After the contract passed and the critic explicitly approved the frozen input,
one run used:

```powershell
./tools/run-citadel-visual-preservation.ps1 -Mode Capture -OutputDirectory "$PWD/artifacts/citadel-visual-reset/upper-trim-capture-01"
```

Same seed 208159, scale 1.25, 1280x720, Godot 4.6.1 Forward+. Output includes
`report.json`, `stdout.log`, empty `stderr.log`, `watchdog.json`, and nine
`screenshots/*.png`. There is no separate progress file for this fixture.

All 4,045 building parts loaded; 20 doors registered. Capture readiness is true
and the loading overlay is hidden. Headed elapsed time was about 54 seconds;
exit 1 correctly preserves the existing non-passing full report. Both the
owned-process watchdog and a global check confirmed no Godot processes remain.

Main agent inspected all nine images against the prior
`physical-bypass-capture-01` views. Gate masonry, roofscape, building massing,
paving, market goods and tree layout remain present; the wall trim changes
position as intended. No broad visual degradation was identified in these
views. This is a qualitative comparison, not pixel identity or proof that all
56 moved members are visible in these cameras.

Known limitations remain unchanged: `green_market_square` is missing after all
64 support-pose candidates fail; `perimeter_lane` is fully occluded despite a
green camera check; the window/interior audit rejects
`urban_row_03_left_window_02_-1`; separate market canopy/bracket pieces still
look disjoint. Physical diagnostics retain all 328 violations and report
`physicalIntegrityRequiredForPublication=false`.

This is a bounded trim repair, not full visual, structural, collision-backed,
night-time, normal-world, interior-furniture or NPC acceptance. No retry or
additional scope was undertaken. Changes remain uncommitted.

Tested production composer SHA256:
`F036B220BF7D09B647B0D9C8B947E15763F5A3968410E5B8E201901D5AD7C0DF`.
Tested contract SHA256:
`50E2A0D358AAB49C98BCF589948967DA20EFF6574CEF10ED292DB64D3172EF61`.

Independent critic final verdict: **PASS for the bounded upper-trim repair;
full physical/visual gate REJECT**. Confirmed the contract evidence, completed
publication and cleanup, and no evident building-silhouette regression in the
representative before/after images. This does not certify complete visual
preservation or gameplay. Final headed report SHA256:
`7520BC8B0301ED614A075AD9A11323CA71C1BEF68E688FE2B894E697FADCD5DD`.
