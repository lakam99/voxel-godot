# Ordinary-menu diagnostic

Runtime parent: `dd60df2`, `codex/citadel-visuals-clean`.
Independent critic approved a bounded headed diagnostic after runtime-binding
acceptance and window-tool safety review. This is not completed gameplay or
performance acceptance. The known ~20.6ms atomic publication step remains open.

Launch `tools/run-citadel-main-menu-diagnostic.ps1 -OutputDirectory
artifacts/citadel-runtime-integration/ordinary-main-01` from this worktree.
The wrapper uses ordinary MainMenu, no gameplay fixture flags, isolated user
data, a 600-second Job Object watchdog and immediate engine-error stopping.
It validates final process cleanup and scans late shutdown errors as well.

Window controls require current run/project, live exact job membership, process
creation identity, an inspected HWND, unchanged client size/position and
foreground focus. Input holds are at most two seconds and release in finally.
Use only during an exclusive desktop-input interval; SendInput is global and
cannot eliminate races with another person/desktop driver. Other project Godot
processes are never targets. Capture only the unobscured owned client.

Tool evidence: `owned-ui-policy-02/report.json` 12/12 explicitly synthetic
policy checks (zero real input calls); `owned-ui-watchdog-smoke-02/default`
and `/live` natural0/owned-zero; `owned-ui-watchdog-live-03` natural0/owned-zero,
four running membership heartbeats and stopping sequence6. Running rows were
overwritten by the final snapshot; this limits archival evidence, not hidden.
All three PowerShell scripts parse cleanly. Critic found no remaining launch
blocker after the pre-input changed-bounds repair and terminal-report checks.

Select New Game through the visible UI; record its final random seed and loading
state. Observe normal spawn/control/collision before approaching a naturally
generated candidate. Minimum possible candidate center is about a kilometre
from the tutorial spawn; no nearby city is not itself a generation failure.
Do not teleport, inject a source, force a seed or skip tutorial readiness.
Stop and preserve evidence on errors, unsafe collision or failed cleanup.

## Run 01 result

`ordinary-main-01`, committed launcher `d7d2c3e`. The real menu was captured,
New Game was selected by an exact-owned-window click and ordinary startup reached
the visible world in about 43 seconds. Final seed `atlas-30895044`; ordinary
tutorial spawn `(360,-13.5)`. Short backward input visibly changed the camera
position until room collision stopped it. The production performance overlay
reported 49 loaded chunks, frame maxima around 49–51ms and several ordinary NPC
task sections near 4–7ms. A route-stall trace was produced for the deferred NPC
baseline; it is not a citadel regression or a clean NPC result.

Nearest raw candidate in a bounded `[-2,2]` region scan is region `(0,-1)`, cell
`(1216,-679)`, world XZ `(1641.6,-916.65)`, recipe seed `1747969299`, about
1.566km from observed spawn. This pure candidate is not proof of site admission.
The user subsequently chose a dedicated teleport playtest rather than spending
minutes walking that distance.

The first MouseLook call rejected before attempting or sending input when a
non-Godot window took foreground focus. The agent did not refocus or retry. The
helper gained its separately reviewed MouseLook operation after the earlier
menu/keyboard/capture actions; therefore that failed no-input action is not
treated as source-frozen evidence for them or for gameplay. Game/runtime sources
remained at `dd60df2` throughout. Final MouseLook policy controls are 20/20 in
`owned-ui-policy-06/report.json`, explicitly synthetic, with no real input calls.
The run was stopped deliberately through its own stop path; the Job Object performed
forced cleanup and proved authoritative zero. This is expected non-clean
diagnostic termination, not a natural-exit pass. No Godot process from the run
remains. Empty stderr and inspected captures:

- `screenshots/menu-01.png`
- `screenshots/loading-01.png`
- `screenshots/loading-02.png`
- `screenshots/spawn-performance.png`
- `screenshots/after-backward.png`
- `screenshots/room-movement-02.png`

Run 01 proves ordinary menu/New Game reaches a controllable visible world under
the integration commit. It does not prove a citadel spawned, continuous approach,
city visuals, gate interaction, save/Continue or clean natural quit.
