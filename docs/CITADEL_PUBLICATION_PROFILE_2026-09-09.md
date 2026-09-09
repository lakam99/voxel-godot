# Citadel publication profile

The existing headed runner now retains bounded publication job status,
publisher stage timing and aperture-preparation counters once at scene audit,
after checking the source binding. No acceptance conditions or runtime
publication behavior changed.

Run: the command in CITADEL_HEADED_STREAMING_2026-09-09.md with output directory
artifacts/citadel-runtime-integration/candidate-teleport-31-02. Production code
is unchanged from f357986. Report/verification/watchdog prove23 checks, natural
exit0, zero engine warnings/errors, frozen sources and owned-process zero.

Milestones: original spawn19.262s, remote setup19.398s, accepted source capture
177.327s, ready279.352s. This reproduces the previous280s result. Inspected
ready.png: terrain, citadel and trees visible. Other captures from this repeat
were not inspected; prior31-01 inspection remains the broader visual evidence.

Scene job:3728 advance calls,11.027461s CPU inside advance and49.546164s between
advances. Between-advance time includes caller work, rendering and frame waits;
it is not purely sleep. Largest atomic operation25.736ms at building finish.

Existing stage counters (nested totals must not be summed):
- part publication:2.657s across4555 calls.
- masonry authority validation:1.495s, including aperture guards1.274s.
- paving geometry:1.032s.
- prepared masonry lookup:0.639s.
- masonry instance collection:0.500s across187250 instances.
- static instance upload:0.203s across211105 instances.
- static flush commit:0.181s across18 flushes.

Aperture preparation:1.973s CPU across617 slices,112 parts,4445 bricks,
only4 changed bricks,106872 verified vertices,1111773 work units. Unit box
readback occurred once. The maximum slice24.981ms includes the initial unit
readback19.823ms. These are real measured stalls, not passing performance
acceptance. Door-registration units1550 include scanning non-door published
nodes; they must not be described as1550 door retries.

Conclusion: all-aperture preparation does delay first building publication,
but removing that dependency alone cannot meet90s. Elapsed time from remote
setup to source acceptance remains about158s, then preparation/publication adds
about102s. Prioritize repeated source proofs, and retain this profile when
designing progressive publication. Do not increase frame budgets or weaken
source/physical checks to manufacture a pass.

An attempted cardinal-overlap shortcut was discarded: it preserved full
physical reports and12002 synthetic comparisons, but current-HEAD comparison
cardinal-overlap-head-01 measured2.510s baseline and3.089s candidate. Earlier
comparison to1298e34 included already-committed improvements and could not
attribute benefit to this attempt. No shortcut or new test logic remains.
