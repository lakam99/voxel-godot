# Entrance approach source milestone

Parent `8af69f8`, branch `codex/world-streaming-architecture`. Source fixes are
verified through the production diagnostic and broad regression below. This is
not promotion of full regional streaming or live citadel traversal acceptance.
The separate regional publication/adapter candidate is still uncommitted.

## Changes

- Navigation manifest schema 9 replaces fixed-step door staging with the valid
  interval inside the actual convex support. Candidates at real obstacle bounds
  retain the existing footprint/headroom checks and must connect back to their
  doorway without crossing static geometry. This is source publication; route
  planning, movement, door execution and traffic are unchanged.
- Civic infill includes the same exterior/interior staging envelope in its
  placement and terrace carving bounds. The previous furnishing access box alone
  allowed a retained terrace to obstruct the exterior approach.
- Gate and rear-wing approaches have full-depth flat landings followed by rooted
  stone steps. The rear secondary door retains its identity and faces outward
  from a real hollow shell, supported floor and approach. The roof still uses the
  existing gabled-roof producer, with its two actual side-wall bearers. Door jamb
  and lintel attachments bind to the real shell panels.
- The gatehouse entrance floor continues through the threshold, with grounded
  underfill, instead of dropping to lower paving beside the carriage bearing shoe.
- Existing diagnostic cameras include the affected doors and stay outside an
  opposing wall using real scene ray queries. Stair-standing probes select floor
  samples explicitly. No player placement, movement or lighting override is added.

## Recorded verification so far

```text
node tools/run-building-contract.mjs -Contract CitadelStairClearanceContract.gd -ReportEnvironment CITADEL_STAIR_REPORT -OutputDirectory artifacts/citadel-runtime-integration/door-approach-clearance-05 -TimeoutSeconds 120
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/door-approach-nav-03/report.json -ProgressPath artifacts/citadel-runtime-integration/door-approach-nav-03/progress.txt -TraceDir artifacts/citadel-runtime-integration/door-approach-nav-03/traces -ScreenshotDir artifacts/citadel-runtime-integration/door-approach-nav-03/screenshots -WatchdogSeconds 120
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-door-approach-05
```

The existing focused stair contract passes 60 checks, including three narrow
landing staging cases and synthetic obstacle/fully-covered negative controls on
the producer's real landing geometry. Existing published physics, source endpoint
and physical support assertions remain intact. This does not cover live movement
through the enclosing gatehouse. The navigation world suite passes 86 cases;
watchdog `godot-lHqaXS` records exit 0, cleanup passed, no forced cleanup and
authoritative zero owned members.

The first full candidate (`candidate-teleport-door-approach-01`) generated and
rendered successfully: startup 88.018s, diagnostic 149.814s, natural exit 0, clean
logs, unchanged launch-frozen sources, zero owned processes, no scene binding or
collider correspondence mismatches. Eighteen of twenty source door certifications
were resolved, with all twelve stair endpoint certifications resolved. Its source
snapshot exposed the rear-floor threshold gap and gatehouse staging through an
adjacent house. Inspected an overview and the gatehouse base landing. This was
diagnostic camera evidence, not live traversal or cold-load performance acceptance.

`candidate-teleport-door-approach-02` reached scene readiness and ordinary input
approach, but failed the expanded structural probe. The new door capture samples
had been mistakenly treated as standing surfaces: all nine failing probes stood
on top of three doors beneath their headers. Existing stair samples passed. This
fixture classification error is distinct from the remaining real source doorway
dependency. The run exited naturally with code 1, clean logs and owned zero;
retain its failure. Inspected the rear door and gatehouse door captures; the latter
showed the nominal observer inside the opposite wall. `revised-navigation-source.json`
in this folder is a later manifest replay against its immutable accepted source,
not the launch-time manifest. Its `revised-manifest-*` logs identify that replay.

Attempt 03 failed parsing a newly added inspection-camera variable type. Attempt
04 then exposed a genuine generation error: the new base floor was queried from
the blueprint's not-yet-built lookup table. The producer now retains the actual
generated part directly during assembly orientation. Both failed attempts remain
archived; neither is a passed generation or gameplay run.

Attempt 05 passed every recorded check, including ordinary input approach,
scene/source binding and collision correspondence, and the retained stair-standing
probes. Startup was 85.522s and the full diagnostic 148.963s. Its verification
receipt records natural exit 0, no engine warnings/errors, unchanged launch-frozen
sources, cleanup passed and zero owned processes. Existing caches were present;
this is not cold-load or frame-pacing acceptance.

Replayed the unchanged manifest builder against attempt 05's accepted source with
its artifact-local `inspect-source.gd`, using the existing `runGodotProcess` owned
wrapper. `navigation-source.json` records **20/20 resolved door portals and 12/12
resolved stair endpoints**. Watchdog `godot-5uPHaZ` records clean natural exit and
zero owned processes. This is source certification, not live NPC traversal.

Inspected `pending_publication.png`, `overview_2.png`, and the gatehouse/rear
secondary door close-ups. Nearby terrain is visible while distant publication
continues, and the overview shows the rendered citadel. The door leaves and their
frames remain extremely dark; these close-ups do not prove readable clearance or
successful entry. Keep that visual limitation open rather than equating saved
captures with visual acceptance.

Also inspected the civic doorway, gatehouse base landing, courtyard overview and
ordinary player close-approach capture. The civic leaf/handle and approach floor
are visible, and the gatehouse base shows a continuous floor beside the stair
carriage. These observer views do not demonstrate opening or crossing the doors.
All **3,285** authoritative source colliders have matching published counterparts.
Measured publication operations still exceed the cooperative budget:
`static_flush_commit` reached 13.028ms and `flush_validate_apertures` 10.433ms.
These operation timings are not total frame times or performance acceptance.

## Independently attributed civic subset failures

```text
node tools/run-building-contract.mjs -Contract CivicHouseInfillContract.gd -ReportEnvironment CITADEL_CIVIC_INFILL_OUTPUT -OutputDirectory artifacts/citadel-runtime-integration/door-approach-civic-02 -TimeoutSeconds 120
```

The producer subset fails `actual_environment_ready` with
`citadel_bunting_declaration_failed`, and
`standalone_civic_exact_except_recipe_derived_paving` against its old archived
geometry. Repeated the same contract in the unchanged `d6314ed` reference checkout
at `../voxel-biome-world-godot-streaming-reference-20260911`, output
`artifacts/citadel-runtime-integration/door-approach-civic-baseline-01`. Copied only
its required archived `candidate-civic-wall-03/subset-541151883.bin` input; tracked
reference sources remain unchanged. Check dictionaries and complete evidence
objects are identical. The fixture stops at its bunting setup failure, so it does
not establish current infill correctness. Do not weaken it or cite it as a
production regression; the complete production candidate provides separate proof.
An earlier invocation (`door-approach-civic-01`) mistakenly passed a directory
where the contract requires a report file and produced no report.

## Broad regression

```text
node tools/run-playtest.mjs -Visible -Seed atlas-338921745 -ReportPath artifacts/citadel-runtime-integration/door-approach-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/door-approach-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/door-approach-broad-01/playtest.png -TimeoutSeconds 600
```

Final result: **162/163**, with only `character_asset_pack_ready` failing:
`npc ready true, hostile ready true, assets 40, families 11`. That exact failure
and detail match the independently executed unchanged `d6314ed` reference report
at `../voxel-biome-world-godot-streaming-reference-20260911/artifacts/citadel-runtime-integration/regional-crossings-baseline-broad-01/report.json`.
The two tree checks that failed in that baseline passed here; no tree fix is
claimed. The broad fixture internally exercises `atlas-1492` despite its wrapper
seed and uses fixed frame pacing, so it is not fresh-seed performance acceptance.

Watchdog `godot-rA2ZNY` records natural exit 1 for the retained functional failure,
clean engine logs, cleanup passed, no forced cleanup and authoritative zero owned
members. Inspected the final screenshot: terrain, trees, actor, held item and
dialogue are visible. The broad fixture's helper-driven checks do not substitute
for ordinary main-menu or live citadel crossing acceptance.

## Acceptance still required

No live citadel door/stair traversal acceptance, regional navigation acknowledgement, cold-cache
campaign or five-minute performance acceptance is claimed here. The full spatial
streaming architecture remains unfinished.
