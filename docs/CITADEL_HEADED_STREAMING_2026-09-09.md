# Headed streaming measurement, candidate31

Worktree voxel-biome-world-godot-citadel-visuals, branch codex/citadel-visuals-clean,
runtime commit f357986. Critic approved the existing diagnostic after source31
and continuation31 gates. No runtime edits during the run.

Command:
```
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion '-2,-2' -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-31-01
```

Report, verification, watchdog and 29 PNG captures are in that directory.
All 23 diagnostic checks passed; natural exit0, zero engine warnings/errors,
unchanged sources, cleanup passed and owned-process zero.

## Milestones from launch

- Original spawn capture:19.239s.
- Remote setup capture:19.379s.
- Accepted source / second setup capture:178.580s.
- Collision-cleared scene publication phase:182.719s.
- First sampled publishing status:219.808s.
- First sampled scene_ready:280.056s; ready capture280.277s.
- Input approach close capture293.459s; final capture298.692s.

These are sampled milestones, not exclusive CPU timings. Compared with the
previous manual run's376.272s scene-ready observation, appearance is about96s
earlier. The90-second usable-arrival target remains unmet. Source acceptance
still takes about159s after remote placement; scene preparation/publication
adds about101s. Initial ordinary startup is below90s on this flagged replay.

## Inspected observations and limitations

Inspected preteleport, pending, pending_publication, ready, close,
courtyard_overview, all four urban house-door views, urban_upper_lane,
castle_keep_stair_exit_01, castle_gatehouse_wall_stair_exit_03 and furniture_22.
Original terrain is visible. Both immediate remote setup captures show an
empty horizon. These captures precede clearance and do not establish how long
terrain remained absent. Final terrain, citadel and trees are visible. Four
sampled doorways have no market stall across the threshold; sampled lane and
stair landings connect visibly. Dark/grainy shading remains conspicuous at noon.
Other captured viewpoints were not inspected in this pass.

All3253 source colliders matched publication;36 sampled capsule/support probes
passed. The scene contained20 doors,178 furniture bodies and4 owned trees.
This is collision/scene evidence, not a walked interior or door-interaction
test. Two setup teleports and diagnostic cameras remain explicitly fixtures.
The approach used ordinary input, but does not establish continuous travel
from the original spawn or broad sprinting performance.

The scene service always reports gameplayReady=false and labels scene_ready
as door_activation_pending (CitadelPublicationService.scene_state). This is a
hard-coded status, not an observed failed door interaction. Do not claim actual
door failure from it, or relabel it ready without checking the real contract.

Retained performance samples:404, max13.107ms, p958.889ms, no last spike reason.
Observed section maxima include chunk5.427ms, autosave JSON/write3.601ms and
terrain meshing queue3.455ms. Publication maximum step24.821ms and maximum
advance24.889ms exceed those retained frame observations; the window does not
prove full-run smoothness. No performance acceptance claim.

A desktop AVG prompt obscured part of the early computer-use capture; no
security settings were changed. Inspection used direct game viewport PNGs.

## Next implementation boundary

Prioritize safe nearby terrain and useful structural publication over optional
detail completion, using the same authoritative accepted source and collision.
BuildingPublicationPreparation currently finishes all masonry before returning
its payload; BuildingScenePublicationJob then finishes masonry preparation
before building publication. Measure and separate these dependencies without
creating a second geometry authority or weakening physical validation. Source
generation also remains above budget. Batch the resulting changes before the
next full run. Preserve the protected NPC/navigation stack.
