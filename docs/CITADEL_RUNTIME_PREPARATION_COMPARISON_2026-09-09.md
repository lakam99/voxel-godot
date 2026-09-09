# Runtime publication preparation comparison

No production behavior or budgets changed in this investigation.

The offline continuation now copies and recursively freezes the blueprint and
furnishing input using CitadelSiteBuildQueue._freeze before calling the existing
publication preparation. It checks unchanged values and rejects freeze failure.
This reproduces input immutability, not the full queue envelope or live contention.

`candidate-continuation-36-frozen` passed 26 checks, clean exit and owned zero.
Copy/freeze took 0.123s over 174857 values. Preparation took 14.977s, including
5.216s route geometry and 2.760s physical validation. The preceding unfrozen
continuation took 15.025s. Freezing does not explain the live slowdown.

The headed runner now captures four retained preparation timings from the job's
buildingBegin result and checks that all are nonnegative integers. History and
masonry preparation times are explicitly unavailable there. It also writes one
accepted-source.bin after scene publication for complete value comparison; this
does not inject source into runtime. Capture time is separate from scene readiness.

`candidate-teleport-36-02` passed 24 checks, clean exit and owned zero, with
unchanged 120s startup/600s terminal budgets and the same seed atlas-3376622889,
region -2,-2. Source acceptance was 135.459s, scene-ready 250.653s. The source
write/hash cost 0.038s. Live preparation retained:

- route geometry: 22.065s;
- physical validation: 14.426s;
- combined route/physical preparation: 36.491s;
- metadata: 3.397s.

`runtime-source-diff-36` verifies the captured source hash against the headed
receipt and the offline artifact hash against source36. Complete blueprint and
furnishing values, including access reservations, are byte-identical. No
differences were found. This rules out different generated inputs as the cause
of these timings; it does not isolate CPU scheduling, lock contention, cache
behavior or other live execution costs.

Read-only OS observations showed multiple CPU-heavy Godot threads on a 16-logical
processor host. These snapshots did not identify their functions and are not a
thread-level causal profile. Avoid attributing the slowdown to voxel workers
without stronger evidence.

Ready.png was inspected and shows the same citadel/terrain/tree view as 36-01;
other captures from 36-02 are not newly claimed as inspected. Scene-ready still
does not prove door interaction or gameplay-ready state. The 90-second usable
arrival target remains unmet. Next investigate overlapping runtime work and
publication scheduling while preserving near-player collision and retryable jobs.
