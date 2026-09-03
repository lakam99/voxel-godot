# Candidate-local residence obstacle validation

Baseline: clean `codex/citadel-visuals-clean` at `d093c89`.
Goal remains ordinary citadel spawning, not a source-only benchmark.
No protected routing, movement or navigation implementation changes.

Recipe12 stopped at the unchanged450s source limit after progressing beyond
party-wall work. Its initial compound placement structure-proof intervals cost
148.601s across663831 callbacks. Inspection found that the planner passed one
obstacle at a time to an API that revalidated every candidate collision part
before even checking whether that obstacle was distant.

The geometry authority now exposes a candidate-local batch: pin original inputs,
deep-copy descriptors, validate the candidate shape once, then run the same exact
overlap kernel for each obstacle. Every obstacle still has an individual callback,
validity check and comparison. Ordered overlapping indices produce the same
planner rejection records and counters. Cancellation or input mutation returns
no usable partial result. No cached view escapes the call or survives a pose.
The legacy boolean API retains invalid-input handling and first-hit early exit.

## Focused evidence

```powershell
./tools/run-building-contract.ps1 -Contract ResidenceObstacleBatchContract.gd -OutputDirectory artifacts/citadel-runtime-integration/residence-obstacle-batch-02 -ReportEnvironment RESIDENCE_OBSTACLE_BATCH_REPORT -TimeoutSeconds 45
```

117/117 checks;0.564033s;10 dependency hashes unchanged. Frozen-original,
current-singleton and batch results agree for ordinary, rotated, tangent,
clearance, malformed and empty cases. First/middle/last cancellation stops all
later callbacks. Nested candidate, obstacle and array mutations return cancelled
without partial indices. All five200-part/500-obstacle poses have exact results.
Old singleton measurements98.635–104.704ms; batch8.184–8.624ms including its
copying and binding. These synthetic timings are not a full-build speedup claim.

Natural exit0, clean logs, no forced cleanup and zero owned processes. The first
attempt (`residence-obstacle-batch-01`) failed at fixture parse because a loaded
script constant cannot expose `resource_path` as used there. Exact path-string
hashing fixed the fixture; that failed attempt remains preserved, natural1/zero.

Frozen original scripts are offline oracles only, extracted from `d093c89`:
LF normalization and removal of global `class_name`; the old planner's geometry
import points to its frozen counterpart. No production call loads these files.

- Geometry SHA: `fcd37306189d0f1bdf40608bf9e3ff11c57e9aaf61458fb709b60b56b6901fee`.
- Planner SHA: `d1005fb22ef2dd63b9f2839022574e441184e69893c2784bbd87d2f94bc8dfae`.

They reside in `artifacts/citadel-runtime-integration/residence-obstacle-original/`.
Actual candidate plan parity, full source readiness and critic approval remain
required. No headed launch or spawning acceptance is claimed.

## Actual candidate comparison

After critic approval:

```powershell
./tools/run-building-contract.ps1 -Contract ResidenceObstacleCandidateParity.gd -OutputDirectory artifacts/citadel-runtime-integration/residence-obstacle-candidate-01 -ReportEnvironment RESIDENCE_OBSTACLE_CANDIDATE_REPORT -TimeoutSeconds 240
```

12/12 checks. Recipe541151883, world `atlas-30895044`, forest, scale1.25, region
(-1,0). Reconstructs the same sampler/Builder pre-placement inputs: ten residence
intents,771 actual structure descriptors. The frozen original plan took
142.066198s; current12.217668s. Complete typed plan bytes (including placements,
signatures, validation and telemetry) are equal; callback sequence digest and
counts are equal. Inputs remain unchanged. This isolates placement; it does not
measure total preparation, runtime frames or final rendered geometry.

- Complete plan SHA: `d481b9231cd35f92afd00bfe3a5231163f2e1ea6f49458f4313f612ceef7f1df`.
- Input SHA: `c65df96ea4f6f4b3d7ef448f3bc9f0134aeba217e0820f6ef0f85f19b64558aa`.
- Callback sequence SHA: `53d30b8629b250a574ca474f24b8f14be70467e96682fa4c83198b1e1e9b8678`.

`report.bin` retains typed input and both complete plans. `report.json` contains
comparisons, timing and17 unchanged discovered source hashes. Natural exit0,
clean logs, no timeout/forced cleanup and authoritative zero owned processes.
The210s internal/240s outer diagnostic ceiling was not reached. The unchanged
450s public full-source test remains the next gate, not this isolated comparison.

## Full Recipe13: deadline cleared; structural failure exposed

Critic-approved, unchanged450/60/540-second limits:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-13 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

Source returned after276.600785s, within deadline, but **failed** with
`citadel_structural_completion_failed -> structural_completion_unresolved`.
The threshold stage completed, making zero changes; its initial/final physical
proof source hashes match. There are37 remaining failed IDs:24 street-house
facade panels, four dependent door lintels, eight door brackets and one bunting
rope. All eight party-wall proposals had no finite geometric contact and were
rejected. The gate was not weakened and no scene was published.

Reports: `report.json`, `timings.json`, `failure.json`/`failure.bin`,
`source-hash-audit.json`, `stderr.log`, `watchdog.json` in the named directory.
All765 source hashes and input context remained unchanged. Failure BIN SHA:
`0fa8293b8743a6bfcf2ac51ce6d6b7888c57135ace50bb27c7170659af17c04f`.
The bounded detailed evidence emits16 of37 failed parts, not a complete geometry
inventory; its overflow marker remains explicit.

The error watcher stopped the owned job on the structured engine error.
`forcedCleanup=true`, no functional exit recorded, no timeout, authoritative
zero owned processes and empty final membership. This is **not** a natural
clean exit or a successful full-source run. Reports were written before stopping.

The timing blocker is cleared for this run; the structural recipe defect is not.
No headed launch, final independent physical pass or successful spawning claim.

Hooke returned **PASS for the focused five-file batch commit**, independently
reviewing code,117/117 and12/12 parity evidence and failed Recipe13 accounting.
No headed or full-integration approval follows from that focused verdict.

Next owning evidence: the urban house upper storey is0.62m wider and shifted
0.31m streetward, projecting its front0.62m beyond the stone base. Failed bottom
panels have no discovered supports, and higher panels/lintels/brackets depend
on those unrooted piers. LowerFacadeBearingRecipe already attempts finite
sill/corbel construction, but its individual rejection details are dropped from
the later failure payload. Preserve those details before choosing the repair.
Do not remove the visual overhang or span a beam across the doorway as a shortcut.

The separate rope01 record spans X11.64569–27.64569 at Y8.873433,Z-10.3 and has
no discovered anchors. The layout-positioned bunting producer needs an actual
rooted endpoint mount, not metadata declaring unsupported endpoints valid.
These are read-only diagnoses, not implemented or accepted geometry changes.
