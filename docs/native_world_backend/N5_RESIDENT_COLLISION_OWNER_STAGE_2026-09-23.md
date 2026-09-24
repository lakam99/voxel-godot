# N5 resident collision owner mechanism stage — 2026-09-23

`NativeResidentCollisionOwner` is a composed project-owned physics publisher. It accepts only a complete source-declared resident mesh set with independently pinned demand membership, exact source epoch/revision/cancellation identity, and source-owned canonical triangle rows. It prepares at most one affected block per process frame and switches/physically probes each affected block across physics frames while an actor admission barrier covers the full changed region. Empty source blocks retain an artifact receipt and require a negative terrain-layer ray. Startup can stage more than 64 blocks in batches, but its readiness stays pending until every declared resident block has a physical receipt. An edit may reuse an unchanged live collider only when the current source artifact key matches its installed key.

The focused real Godot physics fixture uses source rows supplied by a fixture owner, not the production N3 triangle producer. It proves two-block installation and exact source-bound startup readiness; a real `CharacterBody3D.move_and_collide` contacts the new terrain body; an occupied actor delays edit publication; a caller-mutated triangle row with the same artifact key is rejected; a changed source identity and revision update one block; a deliberate post-install probe failure restores the old collider after a physics frame, retains the barrier and allows a corrected retry. It also proves a 65-block empty-artifact startup staged as 64+1, rejects a missing produced block even when required demand names it, and drains without remaining bodies when stopped during preparation or physics acknowledgement. Same-revision demand-closure drift during startup acknowledgement now restores the empty physical state and permits a corrected retry. Pre-switch canonical row drift leaves old physics unchanged and permits retry. If the second row drifts after the first block switches, rollback restores the first old collider, verified by a physics ray against that exact body, before retry succeeds.

Focused command (from the isolated N5 project root):

```powershell
$env:N5_RESIDENT_COLLISION_REPORT = 'C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot-native-n5\artifacts\native-world-backend\n5-resident-owner-final-7.json'
& 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --audio-driver Dummy --path . res://scenes/testing/native_world/N5ResidentCollisionOwnerFixture.tscn
```

The receipt is `artifacts/native-world-backend/n5-resident-owner-final-7.json`: `passed: true`, 2.85 seconds, and no Godot script errors in the headed command. This is a physical mechanism fixture, not normal gameplay, native triangle source integration, or Gate 5 acceptance.

Production remains blocked. N3 has now integrated an exact native triangle producer with independently derived pinned resident closure and `collision_source_snapshot`/`collision_artifact_row` service methods, but this owner has not yet been exercised against that live producer. The owner currently caps one resident set at 4,096 blocks and has no demand-driven retirement. A valid planner request at 128-cell distance and vertical bounds -128..128 can require 4,913 mesh blocks, so spatial partitions or explicit retryable backpressure are needed before binding. The fixture's tiny shape preparation timings do not prove the 6 ms publication budget for real native meshes; record mesher, vertex copy, shape construction and physics synchronization separately. The production `VoxelTerrainRuntime` still generates Voxel Tools collision, and no player menu flow, Continue, live edit, NPC route, or normal-world actor passage has been accepted on this owner.

An independent N5 review found that the prior receipt bound logical owner generation
but not the physical `NativeResidentCollisionOwner` Node installation. A distinct
coordinator-assigned `<instance id>:<registration sequence>` epoch now flows
through window registration, resident owner receipts, broker retention/lease
validation, and final acknowledgment. The focused owner report
`artifacts/native-world-backend/n5-resident-collision-owner-1790217113789-71b1f538/report.json`
passes; it rejects owner A's receipt for owner B even when logical owner,
window token, source, membership and block rows are identical. The coordinator
replacement contract also passed at
`C:\Users\arkam\.codex\worktrees\n5-physical-owner-epoch\voxel-biome-world-godot\artifacts\native-world-backend\n5-coordinator-stop-physical-epoch.json`;
I independently reran its Godot script on primary and observed exit code 0.
Both are service/fixture evidence only (`productionCutover: false`). The focused
N3 triangle artifact contract was updated to pass an explicit physical epoch
and rejects replayed epochs for both lease validation and receipt acknowledgment;
it passed at
`artifacts/native-world-backend/n3-triangle-artifact-1790217091785-e635f0a9/report.json`.

The review also found that validation and freshness checks still synchronously
scan/build maps for up to 4,096 resident members. Cursorizing those scans would
change broker/readiness contracts and remains a separate bounded-work issue;
this receipt fix does not claim a bounded stop latency or close N5 production
cutover.

## Aggregate collision-memory admission remains open

The current count limits do not impose a hard byte ceiling on prepared, active,
or retiring collision. `NativeResidentCollisionOwner.MAX_VERTICES_PER_BLOCK` is
65,536, or up to 786,432 bytes of packed `Vector3` triangle positions at 12
bytes/vertex. At those per-block maxima, one 4,096-block owner admits about 3
GiB of source triangle payload before physics-server allocation, temporary
copies, or old-plus-candidate replacement overlap. A 64-block replacement may
prepare roughly 48 MiB of new vertex payload while the old installation remains
active. `NativeWindowedCollisionReadiness` permits 128 windows of up to 4,096
blocks each; logical partitioning alone therefore does not impose a global
memory bound (the theoretical packed source ceiling is about 48 GiB).

`NativeTerrainArtifactRequests.MAX_RETIRED_VERTEX_BYTES` (256 MiB) is narrower:
it accounts for broker-held, inactive source-row vertex payload only. It does
not cover active-window rows, `ConcavePolygonShape3D` input/cooked storage,
temporary copies, or deferred frees. The resident owner's body-count drain is
not a byte receipt, and `queue_free()` does not itself prove the physics-side
memory has been released.

Before production N5 cutover, add a shared coordinator/service-owned byte
ledger with hard global and per-window admission. Derive reservations from
validated native artifact rows and conservatively account for peak old-plus-
candidate overlap before copying/cooking shapes. If the budget is unavailable,
retain the demand and return retryable pending backpressure without publishing
partial readiness. Transfer reservations at commit; keep old and aborted
candidate bytes charged until physics-safe destruction is acknowledged; require
all reservations to reach zero on stop/drain. Extend the focused owner and
window aggregate tests for exact/over-budget admission, cross-window
competition, replacement overlap/retry, rollback, deferred frees, and zero-byte
shutdown. The current eight-block/four-window physical tranche draft explicitly
does not prove a full 4,913-block physical installation or this byte budget.
