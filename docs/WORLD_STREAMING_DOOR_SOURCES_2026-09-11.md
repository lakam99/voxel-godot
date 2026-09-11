# Citadel entrance source progress

Branch `codex/world-streaming-architecture`, parent `d7d077d`. Regional
navigation preparation and adapter work remains an uncommitted candidate.

The shared gatehouse producer now rotates its complete stair assembly toward the
courtyard entrance, placing the base/full-height landing at the door rather than
the first half-height turn. The source retains each stair part's identity and
rotates the real geometry, seats and piers together. Gatehouse roof panels and
entry steps, the market plaza and upper lane explicitly declare their walking
surfaces. Perimeter alley paving now publishes its actual slab collision and
walking surface, supported by the existing terrace and outer bearing. No general
reclassification of structural foundation masses or route/motor change.

```text
node tools/run-building-contract.mjs -Contract CitadelStairClearanceContract.gd -ReportEnvironment CITADEL_STAIR_REPORT -OutputDirectory artifacts/citadel-runtime-integration/door-source-clearance-02 -TimeoutSeconds 120
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-door-source-01
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/door-source-nav-01/report.json -ProgressPath artifacts/citadel-runtime-integration/door-source-nav-01/progress.txt -TraceDir artifacts/citadel-runtime-integration/door-source-nav-01/traces -ScreenshotDir artifacts/citadel-runtime-integration/door-source-nav-01/screenshots -WatchdogSeconds 120
node tools/run-playtest.mjs -Visible -Seed atlas-338921745 -ReportPath artifacts/citadel-runtime-integration/door-source-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/door-source-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/door-source-broad-01/playtest.png -TimeoutSeconds 600
```

The existing stair producer/physics contract passes 51 checks. It does not cover
live traversal or the complete enclosing gatehouse; the production candidate
separately validates its generated source and scene. The first focused attempt,
`door-source-clearance-01`, failed parsing on an inferred variable type; the
explicit integer declaration fixes that error. No assertions were weakened.

The full headed diagnostic passes scene publication in `Main.tscn`, with zero
setup relocations. Startup 84.403s, total diagnostic 143.897s. The verification
receipt records natural exit 0, clean engine logs, unchanged launch-frozen sources
and zero owned processes. Existing caches were present; this is not cold-load or
five-minute traversal acceptance. Source collider count increases from 3,255 to
3,261, exactly the six alley slabs. Scene audits report no collision mismatches
or source binding failures. Inspected the gatehouse base landing and upper-row
door captures: the stair is visible ahead and the door frontage is visible, but
interior lighting remains dark. These are diagnostic cameras, not movement proof.

The accepted-source inspection in the same folder (`navigation-source.json`,
`inspect-source.gd`, `source-inspect-watchdog.json`) shows **16/20 door portals
certified**, up from 6/20. All 12 stair endpoint certifications remain resolved.
The inspector restores the captured source and calls the existing manifest
builder; it does not invent runtime readiness or regenerate the candidate.

The navigation world suite passes 86 cases with natural exit 0 and owned zero:
`artifacts/node-tools/process-runs/godot-dyXbqy/watchdog.json`. This is service and
contract evidence, not NPC movement through the citadel.

Broad regression finishes **162/163**. The sole failure is
`character_asset_pack_ready`, with the exact independently recorded baseline
detail: `npc ready true, hostile ready true, assets 40, families 11`. The two
baseline tree checks pass this time; no tree code changed, so do not attribute
that variation to an ecology fix. Inspected the final capture: terrain, Mira and
a fuller tree crown are visible. The fixture internally uses `atlas-1492` despite
the runner seed. Owned watchdog `artifacts/node-tools/process-runs/godot-snFzpK/watchdog.json`
records natural exit 1, no forced cleanup, clean engine logs and owned zero.
The suite remains non-green due to the existing asset failure.

Four remaining source dependencies:

1. The gate's exterior approach has only 0.57m-deep treads. None offers the full
   standing footprint required for a door staging point. Declare/build a real
   landing and preserve the collision-backed transition to terrain.
2. The gatehouse base landing is 1.04m deep, exactly twice the navigation staging
   margin (0.52m). The current 0.108m stepped search misses its narrow valid centre:
   source centre Z is approximately -3855.204, requested Z -3855.320. An analytic
   footprint interval is needed instead of accepting a nearby lower surface that
   intersects the bearing shoe. The exterior candidate also reaches into an
   adjacent house; corridor clearance must remain required.
3. The civic-house approach intersects a retained terrace fragment. Existing
   infill planning reserves an interior-biased furnishing access box; the actual
   exterior door staging footprint must be included in placement/carving.
4. The keep's rear secondary door is mounted on a solid cross-wing mass. It needs
   a real source-derived interior, opening and supported approach while retaining
   roof bearing and the door identity. A navigation label cannot repair it.

The current scene still reports `gameplayReady: false` with
`door_activation_pending`. Source certification is not regional navigation
acknowledgement or whole-citadel acceptance. The architectural cutover, bounded
publication, live crossings, distance tiers and full performance campaign remain
unfinished.
