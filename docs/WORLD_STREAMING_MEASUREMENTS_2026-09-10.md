# Spatial streaming measurement baseline

Implementation branch: `codex/world-streaming-architecture`, created from
`2c71199` in the existing citadel worktree. Generation, physical publication,
navigation and rendering output are unchanged in this measurement milestone.

## Observation contract

`RuntimeRenderObservation` is an opt-in, composed playtest observer. It records
bounded histograms of frame-post-draw cadence, root-viewport render CPU/GPU time,
frame setup CPU, visible/shadow draw and primitive counts, and callback overhead.
The existing Main-script monitor is explicitly labelled as script-only timing.
GPU observations may be delayed; do not add them to CPU values or infer exact
transition-frame attribution. Cadence is not OS presentation timing. Overall
cadence includes captures and phase transitions. Per-phase cadence excludes
transitions. Capture phases are diagnostic, often too short for inference.

Logical viewport dimensions differ from output dimensions under canvas stretch.
An eight-frame owned window probe (`render-size-probe-01`) independently observed
a 1920x1080 window and image, 1280x720 logical UI, but texture.get_size() returned
2880x1620. The final observer uses Window/SubViewport size and records 3D scale
and changes in render configuration. Probe cleanup exposed the existing
unparented metrics-helper leak; its result is diagnostic, not clean acceptance.

## Citadel baseline

Command:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-architecture-baseline-01
```

Source42 and continuation42 gates were reused: instrumentation did not change
their generation/physical source. Read-only critic approved the headed launch.
The run passed 25 diagnostic checks and exited naturally with clean logs and
zero owned processes. Fresh process and isolated user data; this is not the
final cold-cache acceptance campaign.

- Ordinary startup: 19.467s; accepted source: 97.652s; scene ready: 152.814s.
- Scene publication cadence: p99 21.7ms, max 81.124ms, six intervals >33ms.
- Short input approach: 779 cadence samples, p99 17.2ms, max 29.993ms.
  Render CPU p99 5.0ms, GPU p99 7.1ms; peak 2,393 visible and 3,933 shadow draws.
- Startup cadence contains a 10,786.111ms stall. Existing script-only timings
  cannot account for this interval.
- Inspected 1920x1080 ready, courtyard, home-door and stair-landing captures.
  Citadel, terrain and trees are visible. Dark close views and grainy shadows
  remain baseline visual issues. Inspection cameras/teleports do not establish
  ordinary traversal, NPC routes, all physical behavior, or performance acceptance.

## Ordinary menu and traversal baseline

Command (each invocation used fresh isolated APPDATA/LOCALAPPDATA and save path
under its named artifact directory):

```text
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 75 -TimeoutSeconds 300 -ReportPath artifacts/citadel-runtime-integration/architecture-normal-baseline-03/report.json -ProgressPath artifacts/citadel-runtime-integration/architecture-normal-baseline-03/progress.txt
```

- `architecture-normal-baseline-01`: failed fixture attempt. The stretched-menu
  click was not accepted; seed and loading observations remained empty. No world
  load took place. Corrected logical-coordinate input, explicit window sizing,
  and immediate input acknowledgement. Forced cleanup, zero owned processes.
- `architecture-normal-baseline-02`: fresh seed `atlas-71030935`, New Game ready
  in 36.806s, 595.08m traversed. Cadence p99 46.1ms, max 61.923ms, 504 intervals
  >33ms. Functional checks passed, but old direct teardown leaked resources and
  required forced cleanup. Zero owned processes. Its texture-size telemetry is
  superseded by the independent window probe; do not label it 2880p rendering.
- `architecture-normal-baseline-03`: fresh seed `atlas-83490937`, New Game ready
  in 35.821s, 310.80m traversed. Actual output 1920x1080, 3D scale 1.0, zero
  configuration changes. Cadence p99 63.2ms, max 79.949ms, 610 intervals >33ms;
  render CPU p99 13.0ms, GPU p99 19.1ms. Peak visible/shadow draws 688/5,449.
  Startup maximum 10,327.095ms. Functional checks passed; natural exit, empty
  stderr, clean cleanup and zero owned processes in
  `artifacts/node-tools/process-runs/godot-6dhjtO/watchdog.json`.

The runner now releases its unparented metrics helper and calls the existing
production graceful-quit path. Its survival observer and automated movement
remain explicitly fixture controls. A green legacy functional result does NOT
mean the new pacing contract passes: both measured traversal seeds exceed the
33ms p99 target and have recurring stalls. These are 75-second baseline samples,
not the required five-minute acceptance observations or Continue coverage.

## Verification and next cutover

- Candidate Node runner tests: 15/15.
- Owned Godot check-only: both modified runners parsed cleanly.
- `render-observer-contract-01`: 6/6 synthetic histogram/availability controls,
  clean owned exit. No gameplay claim.
- No broad gameplay suite was repeated for this observation-only milestone;
  broad and affected lifecycle/navigation coverage remain required at production
  cutovers. Prior broad42 baseline failures remain explicitly recorded in
  `CITADEL_NATIVE_SUPPORT_INTEGRATION_2026-09-10.md`.

Next: worker-prepared final masonry packets, shared material request rules,
bounded assembly/upload through the current publisher. Preserve aperture cuts,
part-completion flush boundaries (including batches above 12,000 instances),
material first-request order, exact close-up output, physical data and readiness.
Source compilation/publication and actual traversal pacing are distinct blockers.
The synchronous terrain scan in spawn selection is a plausible startup-stall
contributor to profile in the later generation cutover, not a proven timing yet.
