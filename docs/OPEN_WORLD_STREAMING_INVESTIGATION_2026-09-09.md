# Open-world streaming: first investigation, 2026-09-09

Baseline: codex/citadel-visuals-clean, 438d6cd; clean working tree before investigation.
Product target: initial playable area within 90 seconds, then uninterrupted movement with progressive nearby world publication. This is a target, not achieved acceptance.

## Recorded timing evidence

Read existing evidence rather than launch another expensive replay. Seed atlas-3376622889, region (-2,-2), recipe 1393179273.

User manual run: artifacts/citadel-runtime-integration/candidate-teleport-manual-20260909-101103/report.json:
- First remote discovery phase: 18.404 seconds after launch.
- Accepted source / terrain clearance phase: 269.029 seconds.
- Ordinary scene publication phase: 272.052 seconds.
- Publishing status observed: 325.170 seconds.
- Scene ready observed: 376.272 seconds, still door_activation_pending.
These are sampled milestones, not exact stage CPU durations. Approximately 251 seconds elapse between discovery and source acceptance. Another 107 seconds elapse before scene-ready observation. Initial ordinary startup is already below 90 seconds on this case; remote arrival is the large delay. Startup completion does not prove the screenshot's remote terrain is complete.

The same manual run's verification.json records native exit 3221225477, ObjectDB leak warning, unchanged sources and successful owned-process cleanup. It reached manual inspection but is not a clean passing run; crash cause remains undiagnosed.

Source-only candidate26 timings.json records 212.550 seconds source preparation and 4.574 seconds independent final physical validation. Its callback-interval accounting assigns:
- physical_resolve_support: 74.259 seconds, 118544 callbacks;
- lower_facade_panel: 54.210 seconds, 70 callbacks;
- opening_head_house: 14.075 seconds, 16 callbacks;
- lower_facade_panel_completed: 10.303 seconds;
- landscape_tree_candidate: 9.510 seconds, 4753 callbacks.
These intervals are charged to the previous checkpoint, not exclusive function CPU profiles. They identify investigation targets, not guaranteed optimization savings. In particular, removing final validation would save little and weaken correctness.

## Source boundaries found

BuildingPublicationPreparation.prepare_source restores and validates the source, then compiles history and masonry before returning the prepared holder. BuildingScenePublicationJob subsequently completes its masonry phase before publishing construction parts, then completes building, door registration, furniture and trees. It already uses incremental operations; total latency and dependencies remain the problem.

LowerFacadeBearingRecipe performs physical validation of before/after candidate contexts and support proofs. Repeated support resolution is a concrete target for tracing immutable shared input versus changed candidate input. A cache or narrower proof is justified only after proving identical dependencies and invalidation; do not skip validations or cache by seed alone.

## Implementation order

1. Attribute repeated lower-facade/support work to exact candidate contexts using bounded existing diagnostic hooks. Determine how much source planning can be reused without changing accepted geometry, deterministic output, cancellation or rejection behavior.
2. Reduce that measured repeated work first. Verify unchanged full source geometry/semantics and negative controls, then one full source run. This can shorten both normal discovery and any later progressive-shell path.
3. Separate accepted structural data from optional visual preparation. Publish a coarse shell from the same source, retaining exact near-player collision and openings. Detailed masonry must not gate first useful geometry. Preserve one source revision and retirement ownership across replacement.
4. Define independently usable spatial sections with explicit support and doorway dependencies before exposing partial interiors. Do not equate scene-ready, registered doors and gameplay-ready.
5. Measure initial safe terrain, first visible shell, first usable section and detail completion separately, including cold start, Continue, sprinting and teleport arrival. Use <=90 seconds as the initial loading ceiling; do not permit holes or invisible collision to meet it.

No runtime code changed in this investigation. No new Godot run or gameplay acceptance claim. Existing NPC/navigation authority remains protected. Prior NPC baseline deferral does not authorize routing changes. Before geometry/publication implementation, reconcile applicable existing baseline evidence and verification requirements with the task scope.

