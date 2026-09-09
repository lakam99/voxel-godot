# Headed candidate 36

Production commit: 66ac7d8. Run:
```
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion '-2,-2' -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-36-01
```

Run passed 23 checks, exited cleanly and proved owned-process zero. It remains
teleport-driven setup/inspection evidence, not ordinary traversal to a citadel
or successful walked door/interior interaction.

Timeline from report.json (seconds from fixture start):

- 17.117: original startup complete, remote source discovery.
- 132.404: accepted source available; native clearance stage.
- 135.428: scene publication wait.
- 186.565: scene construction visible in telemetry.
- 247.712: scene_ready observation; ready screenshot at 248.535.
- 261.724: close screenshot after ordinary-input approach.
- 266.729: terminal scene_ready.

Previous headed31-02 ready observation was 279.352s. New source-only36 preparation
was 88.363s, but real arrival remains far above 90 seconds. The remote discovery
interval includes terrain admission; it is not pure source-generation CPU.

Scene publication retained 3893 advances, 11.177s advance CPU and 50.466s between
advances. Between-advance time includes caller/render/frame waits. The maximum
atomic step was 26.002ms. Do not sum nested publicationTiming sections. Mid-run
worker telemetry at 156.505s reported 21.729s in route_geometry; that is a partial
phase observation, not its final duration. Investigate the runtime preparation
interval before assuming the offline continuation represents its full cost.

Scene audit matches all 3253 source colliders, registers 20 doors, 178 furniture
parts and four owned trees. The scene status intentionally still reports
gameplayReady=false/door_activation_pending; scene_ready is not a door test.

Inspected pending, pending_publication, ready, close, overview_0,
urban_row_03_right_door, castle_keep_stair_exit_01,
castle_gatehouse_wall_stair_exit_03 and furniture_22. Ready shows terrain, trees
and the citadel. The sampled doorway has no stall across its threshold and the
sampled stair views show landings. Dark/grainy rendering persists. These samples
do not clear every structure, furniture placement, doorway or lighting defect.

The two pending captures show empty horizons at their capture instants; they
do not establish continuous absence of terrain between captures. Remaining
captures are retained but not claimed visually inspected. The 90-second goal
remains open.
