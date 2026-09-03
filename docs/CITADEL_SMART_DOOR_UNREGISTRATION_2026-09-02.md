# Preserve shared interaction ownership during door unload

## Scope

Follow-up to `0ac13ba` on `codex/citadel-visuals-clean`, under the user's explicit
permission for narrow shared-door cleanup. Only a new SmartObjectService wrapper
and exact signal-disconnect helper affect production. Existing registration,
interaction, routing and movement bodies are unchanged. Main owns production,
the worker owns the new synthetic fixture, and the independent critic is read-only.

The wrapper delegates leaf identity to DoorPortalService.unregister_door.
Successful removal disconnects only the removed leaf's bound service callback,
even if the smart registration has since disappeared or become a non-door object.
Unrelated signal listeners are preserved. Failed/absent removal does not mutate
smart state.

For grouped doors, the same smart registration and its metadata, slots and
reservations survive. Removing the representative rebinds to a remaining leaf,
advances its revision, clears query cache and connects the new representative's
normal exit handler. Removing a non-representative leaves that registration
unchanged. Rebinding deliberately does not revive stale/depleted flags or
reservations previously released by a real node exit.

Final removal uses ordinary unbinding to release that object's reservations and
index membership, then erases its registration and transient release record.
It does not mark depletion, erase unrelated registrations, or clear completed
effect replay protection. Existing register_door still replaces registrations;
this wrapper never uses re-registration to repair a survivor. Repeated active
registration semantics are not changed or claimed fixed here.

The critic initially rejected a stale-callback bug: returning early for a
missing/non-door registration left the old leaf callback connected. The repair
moves exact callback disconnection before that guard. Acceptance must include
actually freeing the old leaf after a replacement registration is present.

## Regression evidence

Artifact paths below are relative to `artifacts/citadel-runtime-integration/`.
Before edits, `smart-door-unregister-baseline-interaction-01` passed 45/45 with
empty stderr, natural exit 0 and zero owned processes. Prior six-suite baseline
is `door-unregister-final-<suite>-01` from the preceding committed API checkpoint.

Final runs: `smart-door-unregister-final-{contract,motor,nav_world,route,door,traffic,interaction}-01`.
All used the existing process-owning scene watchdog, Godot 4.6.1 official
`14d19694e`, headless `res://scenes/testing/npc/NpcAutonomyTest.tscn`, seed
`atlas-1492`, both time modes, empty case filter, fixed 60 fps, 45-second cap,
VOXEL_PLAYTEST=1, matching seed variables and fresh report/progress/trace/
screenshot/userdata paths and run tokens. Exact Godot commands are in watchdogs.

Results: 84/84 contract, 48/48 motor, 84/84 nav-world, 130/132 route, 48/48 door,
38/38 traffic and 45/45 interaction. Six stderr files are byte-exact to baseline.
Route is not byte-exact: 173259 bytes and 247 error headers versus 170166 bytes
and 244 headers. It retains the same day/night exact-detour assertion failures;
day visited four cells and night five, versus four/four previously, against the
same 32000-microsecond budget. The independent critic classified all 3093 extra
bytes as three more copies of one existing off-tree transform stack, with no
new unique lines/stack types and unchanged outcomes/assertion lists. The new
wrapper is not called by these suites. This is accepted baseline timing
variation, not a repaired or green route result. Route naturally exits 1;
all others exit 0. Every watchdog proves zero owned processes without forced
cleanup. The pre-existing motor/nav/route errors and 124-byte traffic ObjectDB
warning remain disclosed, not repaired or represented as green acceptance.

## Focused evidence and acceptance

```powershell
./tools/run-building-contract.ps1 -Contract SmartDoorUnregistrationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/smart-door-unregistration-contract-03 -ReportEnvironment SMART_DOOR_UNREGISTRATION_OUTPUT
```

The independent synthetic fixture passes **116/116**. All five recorded source
hashes match the final files. Parse/run logs are empty of errors and warnings;
both exit naturally 0, prove zero owned processes and need no forced cleanup.
Progress is stdout; no gameplay screenshots/traces are claimed. Real SmartObject
reservation calls and actual Node exit signals test both leaf-removal orders,
registration/metadata/slots/reservations preservation, surviving callbacks,
unrelated listeners, final occupants/index/release cleanup, harmless duplicate
calls, stale/depleted non-revival, freed unsignalled representatives, missing or
non-door registration replacement, and same-ID reuse before the old leaf exits.
Explicit metadata positions are retained in the indexed control; this does not
prove moving/reindexing a generic spatial object. Completed-effect records are
synthetically seeded; replay uses the real service's idempotency path.

Run `smart-door-unregistration-contract-01` is rejected evidence: two fixture
variables used unsupported inferred types. Parse failed and the error watchdog
forced cleanup (126), proving zero owned processes. Only fixture declarations
were corrected. Run `-02` passed 110 checks; `-03` adds explicit final slot
occupants and duplicate-call invariance. The failed run remains recorded.

The independent critic approved the focused four-file commit after inspecting
the final wrapper, full contract, source hashes, process evidence, seven NPC
suites and both documents. No complete
production door lifecycle, ordinary scene activation, visual/gate traversal,
save/re-entry, NPC movement or frame-budget acceptance is claimed. No headed
test was launched. Building/furniture recipes and the production tree pipeline
are untouched. The next integration boundary is balanced scene door/tree hooks;
player-safe publication and previously measured timing overruns remain open.

Read-only next-boundary mapping identified two integration requirements: retirement
callbacks must run before a registered body's children are freed, and tree unload
must not use a destructive/depleting prop-removal path. Shared registration also
publishes a navigation door state; final unload must retire that state without
unloading shared terrain regions or leaving stale node references. These are
remaining hooks, not acceptance claims or permission for topology replacement.
