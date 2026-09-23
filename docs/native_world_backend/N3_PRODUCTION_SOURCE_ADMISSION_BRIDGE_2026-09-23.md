# N3 production-input source admission bridge

Status: shadow-only bridge checkpoint. The production `VoxelTerrainRuntime`
still assigns `VoxelTerrainGenerator` and uses Voxel Tools as its collision
owner. This is neither the N3 terrain cutover nor Gate 5 acceptance.

`NativeWorldSourceRequest.from_main` constructs the native initialization
envelope from the same seed, finalized town records, ordinary structure
policy and world constants held by production owners. It does not sample
terrain or create a fallback generator. It checks seed/profile-store binding,
the admission policy against Main constants, and canonicalized town inputs
before returning a request. `CitadelTerrainAdmission.source_policy_snapshot`
is the narrow read-only policy boundary used by that builder.
For Continue, `from_main_with_current_volume` takes the current
`TerrainVolumeService.save_all_section_deltas()` durable v2 snapshot and
builds the one-shot native save-v2 initialization envelope. It does not
serialize Voxel Tools generated blocks or infer missing volume as empty.

`NativeShapingPageAdmission` then translates native page requests through
the production Citadel source admission. Pending remains pending across calls;
only an authoritative prepared profile or genuine absent decision can be
submitted to the native registry. Candidate identity and prepared source
signature are checked before submission. Its 16-resolution call cap is
conservative; callers must retry a page until the native registry reports
ready. The production source owner must be advanced independently by its
existing scheduler.

Focused evidence:

- `node tools/run-n3-native-world-source-request.mjs` passed with installed
  Godot and native adapter, including one finalized town, one explicit
  no-town region, seed-mismatch failure, and exact native save-v2
  import/export of a current negative-cell durable edit. Report:
  `artifacts/native-world-backend/n3-world-source-request-1790165382026-0a933981/report.json`.
- `node tools/run-n3-native-shaping-page-admission.mjs` passed repeated
  pending retention for a real Citadel admission and ready-page passthrough.
  Report:
  `artifacts/native-world-backend/n3-shaping-page-admission-1790165259066-387445e0/report.json`.

The focused `--advance` path now proves pending-to-authoritative-absent for
seed `atlas-1492`, region `(-1,-1)`, native page `(-3,-3)`. The source
decision is `town_reservation_overlap`; the native page then reports ready
with no outstanding requests. Report:
`artifacts/native-world-backend/n3-shaping-page-admission-1790165939263-3660175c/report.json`.
This is a real source decision, not a prepared-site or headed gameplay proof.
The complementary `node tools/run-n3-prepared-shaping-bridge.mjs` contract
injects a synthetic prepared profile at the site-worker boundary, then proves
the bridge admits canonical candidate/signature data into the real native
shaping registry and rejects a mismatched signature without publication.
Report:
`artifacts/native-world-backend/n3-prepared-shaping-bridge-1790166297483-13afbfee/report.json`.
It does not prove a real site can finish preparation.
The first retry's 30-second fixture deadline was too short for this source;
the focused advance budget is now 90 seconds, below the production owner's
450-second source watchdog.

An earlier focused real-source advance hit a GDScript null-instance call
at `FacadePartitionGeometry.gd:22` inside the existing Citadel source worker;
the run's pending report is not an acceptance result. Diagnostic stderr:
`artifacts/node-tools/process-runs/godot-LsTk7f/stderr.log`. This requires
classification before claiming the bridge's pending-to-ready lifecycle.
Another bounded `--advance` retry reached a terminal source failure after about
24 seconds: `canopy_recipe_failed` in the generated Citadel shop. The bridge
returned that failure rather than converting it to absent or publishing bytes.
Its failed diagnostic report is
`artifacts/native-world-backend/n3-shaping-page-admission-1790165183978-91692fd3/report.json`;
it is not acceptance evidence. The earlier null-instance call did not recur
in this retry, so its cause is still unproven. Owner-level diagnosis found
~11 microns of float32 transform drift in mirrored canopy depth at a
translated/yawed site. The rectangular symmetry comparison now permits 20
microns while the physical seat/socket/collision checks remain unchanged.
`MarketCanopyFrameContract.gd` passes 506 checks, including translated/yawed
positive geometry and a deliberate 50-micron warp rejected as
`nonrectangular_canopy`. Its report is
`artifacts/native-world-backend/canopy-n4-boundary-20260923.json`.
The direct generated recipe diagnostic for this seed also reaches `ready`.
Durable save-v2 delta synchronization, page-demand planning, current receipt
publication, runtime reset/shutdown and all other N3 consumer cutovers remain
open. No script generation or collision authority was deleted here.

A later shadow-only `NativeDurableEditMirror` bridge binds only when the
current native export exactly matches `TerrainVolumeService`'s durable v2
snapshot. It mirrors explicit set/replace/clear deltas through bounded native
typed transactions, verifies the resulting native durable records, and fails
closed on an external native revision or mismatched initial owners. The
focused service contract is `node tools/run-n3-native-durable-edit-mirror.mjs`
with report
`artifacts/native-world-backend/n3-durable-edit-mirror-1790166319655-cf167007/report.json`.
The mirror is not connected to the production edit path. Its explicit sync
currently scans all durable records and has a 4,096-operation transaction cap;
bounded incremental scheduling and native edit/mesh/physics publication
receipts are still required for live cutover.
