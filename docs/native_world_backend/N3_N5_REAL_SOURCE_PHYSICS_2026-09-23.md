# N3 to N5 real-source physics handoff — 2026-09-23

The focused `N3N5PhysicalHandoffFixture` uses `NativeWorldBackend` padded voxel bytes, `NativeTerrainTriangleArtifactProducer`, and `NativeResidentCollisionOwner` in real Godot Forward+ physics. Its two-block pinned demand contains one nonempty surface block and one empty upper block. The source snapshot remains pending before and after the first row; it becomes ready only after both source-owned rows exist with the exact planner closure token and source identity. The physical owner then installs the real Transvoxel triangles, acknowledges both blocks, and a `CharacterBody3D` contacts the nonempty collider before actor admission releases.

A durable native edit increments source revision. The old physical receipt becomes stale, a new producer's incomplete source stays pending, the old identity is rejected, and the complete new source republishes both blocks with a new physical receipt. `stop_and_drain` leaves no owner bodies. The owner now preserves a source's honest `pending` state and reason instead of treating it as a terminal revision mismatch; exact identity checks still run for ready snapshots.

Command from the isolated N5 project root:

```powershell
node tools/run-n3-n5-physical-handoff.mjs
```

The headed report is `artifacts/native-world-backend/n3-n5-physical-handoff-1790178747658-242cd010/report.json`: `passed: true`, exit 0, one solid and one empty block, actor contact, exact first and second physical receipts, and one-frame physics acknowledgement per block. Shape preparation reached 2.581 ms per block; the first producer `advance()` peaked at 36.401 ms. This is **not** proof of a 6 ms frame budget or stall-free loading; full native meshing/copy and physics publication need measured queue budgets at larger closures.

This fixture is a source and physics service test that connects the producer directly to the owner. It does not exercise the composed `NativeTerrainRuntimeOwner` artifact broker or live gameplay. `productionCutover` remains false. The production runtime still uses Voxel Tools collision. The 4,096-block resident cap cannot cover a valid 4,913-block planner closure; deterministic physical partitions, safe retirement, and one logical complete readiness are required before startup or live edit binding. Main menu, Continue, NPC passage, and Gate 5 remain unaccepted.

## Main-thread face extraction follow-up

Attribution in `artifacts/native-world-backend/n3-n5-physical-handoff-1790179112024-b8d3781b/report.json` found a 36.945 ms producer `advance()` peak for 4,686 surface vertices: `Mesh.surface_get_arrays()` alone consumed 33.088 ms. The original `Mesh.get_faces()` path likewise consumed about 34 ms. Indexed expansion took only 0.425 ms. Both mesh readback APIs therefore produced a visible main-thread stall in this focused case.

The producer now sends the exact `Mesh.get_faces()` call to a dedicated worker thread. It retains the encoded source and pending block while that worker runs, rechecks source and demand identity before publishing, and joins the worker during stop, cancellation, or failure drain. The headed report `artifacts/native-world-backend/n3-n5-physical-handoff-1790179365606-9d0af061/report.json` passed: peak measured main-thread `advance()` was 5.023 ms, worker face extraction took 53.105 ms off-thread, and an independent synchronous mesh of the same native padded bytes matched all 4,686 world-space triangle vertices exactly and in order. A stop while extraction was in flight returned pending and drained to ready. `node tools/run-n3-triangle-artifact.mjs` also passed in `artifacts/native-world-backend/n3-triangle-artifact-1790179332385-d6c57b5b/report.json` with a 5.456 ms peak.

These runs isolate one surface block. They do not establish a worst-case main-thread budget for varied biomes, larger resident closures, source churn, or physics publication. Keep the async worker and shape publication timed separately in broader observations before production binding.

The headed fixture was repeated three times with a durable native source revision change during face extraction. Reports `n3-n5-physical-handoff-1790179484139-8a6ada7f`, `n3-n5-physical-handoff-1790179498926-e532d20a`, and `n3-n5-physical-handoff-1790179506472-42615624` under `artifacts/native-world-backend/` all passed with no Godot errors or resource leak output. Each returned `triangle_mesh_worker_draining` while the old worker was active, then `triangle_source_revision_changed` without publishing its stale row; the owner drained to zero bodies. Measured main-thread `advance()` peaks were 3.655, 2.820, and 3.323 ms respectively. This is focused lifecycle evidence, not a broad thread safety or gameplay claim.
