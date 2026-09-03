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

Run results and inspected captures will be appended after execution.
