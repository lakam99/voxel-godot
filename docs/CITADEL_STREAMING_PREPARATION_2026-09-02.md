# Ordinary streaming dispatch for citadel preparation

Branch `codex/citadel-visuals-clean`, starting at `a75990a`. This is checkpoint 3
implementation, not a spawned-city or headed acceptance report. The prior
source/preparation commits and user-approved NPC baseline exception remain.

## Implemented boundary

StructureSystem owns one CitadelPublicationService and one background worker.
Native runtime maintenance supplies the current player's ordinary terrain-view
footprint. The service consumes admitted immutable source snapshots, dispatches
the existing background BuildingPublicationPreparation, and retains an opaque
prepared holder plus its frozen terrain profile. It publishes no scene nodes,
doors, generated-building records or city-ready markers yet.

Admission's non-enqueuing source_state exposes the admitted site/source/generation
identity even after its reconstructible geometry cache is evicted. Active,
completed and retained prepared consumers do not request another recipe build.
A genuine subsequent approach after both source and prepared ownership are gone
requests reconstruction through the existing admission queue. Repeated demands
retain one request; failure-debounced preparation does not trigger reconstruction.
Unavailable, failed, shutdown or unfinalized admission cannot authorize new work
or acceptance. Acceptance rechecks source identity and profile signature after
joining the worker. This does not add a new terrain or navigation authority.

The worker owns both preparation and payload retirement, with one completion
slot and retirement-first backpressure. Cancelled/obsolete results cannot leave
an abandoned slot blocking later sites. Queued/start-failure residence is not
counted against the 60-second preparation timeout. Large input/prepared payloads
are relinquished on the worker, not through last-reference destruction on main.
The controller and worker survive ordinary seed resets. Loading yields and
native early-return paths continue draining; MainCore quit awaits both source
and publication workers. No raw process-name cleanup is introduced.

## Focused evidence

Commands below run from this worktree and require fresh artifact directories.
All directories are under `artifacts/citadel-runtime-integration/`, with
`report.json`, `stdout.log`, `stderr.log`, `launch.json` and `watchdog.json`.
Source hashes are frozen before/after the focused wrappers. These are headless
service/contract checks, not screenshots or live gameplay acceptance.

```powershell
./tools/run-building-publication-worker-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-worker-01
./tools/run-citadel-publication-service-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-service-05
./tools/run-citadel-terrain-admission-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/terrain-admission-publication-01
./tools/run-citadel-terrain-bootstrap-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/terrain-bootstrap-publication-01
./tools/run-citadel-town-inputs-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/town-inputs-publication-01
./tools/run-citadel-native-admission-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/native-admission-publication-02
```

- Worker: 62/62. Real empty-source preparation plus explicitly synthetic
  cancellation, failed starts, late results, completed-slot backpressure,
  profile lifetime and off-main input/result retirement.
- Admission: 124/124; bootstrap ordering: 28/28; finalized town inputs: 52/52;
  native admission/player-collision controls: 42/42. All finish naturally with
  empty engine logs and owned-process zero.
- Service: 69/69, empty engine logs, natural exit 0 and owned-process zero.
  Actual source is the
  frozen complete `actual-site-source-05/result.bin`, SHA256
  `7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.
  Seed `atlas-1492`, region `(1,-3)`, recipe `1298433643`, scale `1.25`.
  It is injected through real Admission._accept, then prepared by the real
  worker through StructureSystem. Identity/profile and 4,703 building/210
  furnishing counts are checked; this is not another complete typed-output
  equality comparison. Prior exact-output evidence remains in the background
  preparation report. Other lifecycle cases use explicitly synthetic small
  sources and gated execution, not a full Site regeneration.

The final actual-source case records 18.147 seconds of background preparation,
with a 0.308 ms maximum service advance, 0.015 ms dispatch and 0.005 ms terminal
join through its recorded preparation/departure interval. The metric snapshot
is taken while retirement is still running; separate shutdown assertions and
watchdog evidence establish terminal cleanup. These figures exclude scene
publication and do not establish a whole-frame or cold-generation latency pass.

The runtime-hook test executes the real _process and generation-context check
with an in-tree player, a real StructureSystem and a native terrain object kept
off-tree. Unrelated native maintenance and gate advancement are stubbed. It
proves current-player footprint dispatch and stale-generation drain, not ordinary
world loading or terrain rendering. MainCore loading-yield and quit methods are
exercised on a fixture that suppresses gameplay boot.

Earlier service runs remain visible: `-01` rejected a fixture WeakRef inference
parse error; `-02` emitted a runtime dependency compile error despite exiting
zero, and was rejected. The explicit runtime Boolean annotation fixes it.
`-03` passed 61/61 before the extra hook/deduplication controls. `-04` passed
68/69: the hook fixture placed a float32 player exactly on a cell boundary,
invalidating its expected footprint. The fixture now uses the cell interior;
production footprint code is unchanged. No failed run is relabeled green.

Additional native-admission run `-01` exposed an outdated explicit Structures
test double: it lacked the newly required publication maintenance method,
causing runtime script errors before the existing native gate could advance.
The test double now explicitly stubs building publication (the fixture has no
building sources); no production fallback or terrain assertion was changed.
Native `-02` passes all original 42 checks, including failed-source loading stop.

## NPC regression boundary

The unchanged NpcAutonomyTest scene was run through the existing owned-process
watchdog, seed `atlas-1492`, time `both`, fixed FPS 60, 45-second external cap.
Each full command is in its watchdog.json; suite/seed are in report.json.
Paths: `publication-service-npc-{contract,motor,nav_world,route}-01`, each with
report, progress, traces, logs, isolated user data and cleanup proof.

Assertions are 84/84, 48/48, 84/84 and 130/132. Engine error headers are 0, 4, 4
and 250. Route stderr is byte-identical to the previously accepted final
`publication-preparation-npc-route-02` log. The two diagnostic home collision-
lattice detour failures remain, not new regressions and not repaired here.
All four jobs exit naturally with authoritative zero owned processes.
No protected route/door implementation or NPC test has been modified.

## Still required

Incremental visible scene publication, remaining history/masonry/part/finish
costs, preserved furniture and shared production trees, door registration and
symmetric cleanup. Explicit protected shared-door cleanup permission remains
pending. Main/New Game physical approach, gate use, visual preservation,
departure/re-entry, save/Continue with durable edits and traversal performance
remain unverified. The temporary physical-publication bypass remains explicit.
No headed run or final completion is approved by this report.
